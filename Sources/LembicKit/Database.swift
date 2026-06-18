import Foundation
import GRDB

/// Read-only access to the live `chat.db`, opened **in place**: never copied,
/// never written, only read. The connection is `readonly = true`, so the engine
/// holds no write lock on the Messages store and Apple's WAL keeps writers
/// (Messages.app) and our reader from blocking each other. Each read sees the
/// live WAL — current data, including frames Messages just wrote and hasn't
/// checkpointed — so the export reflects what's on screen.
///
/// **Best-effort live contract:** every read is internally consistent (a read
/// transaction is a point-in-time snapshot), and a transient torn read while
/// Messages writes is absorbed by a bounded retry (`read(_:)` / `withRetry`).
///
/// `@unchecked Sendable`: after `init` the only mutable state is `connection`,
/// which is set once and then read-only until `cleanUp()`/`deinit` nils it; the
/// underlying GRDB `DatabaseQueue` is itself thread-safe for concurrent reads.
/// This lets the caller open the DB *once* and reuse the instance across the
/// conversation list and every transcript extraction (open once, reuse), and
/// pass it between the main actor and `Task.detached` readers.
public final class ChatDatabase: @unchecked Sendable {
    private var connection: DatabaseQueue?
    /// Read-only queue over the live `chat.db`. Valid until `cleanUp()`.
    public var queue: DatabaseQueue { connection! }

    /// Open `url` directly, read-only, in place — no copy, no sidecar copy, no
    /// temp dir. The read-only connection reads the live WAL and writes nothing.
    public init(at url: URL) throws {
        var config = Configuration()
        config.readonly = true
        self.connection = try DatabaseQueue(path: url.path, configuration: config)
    }

    /// Close the SQLite connection. Nothing to delete — the DB was opened in
    /// place, never copied — so this just drops the read-only connection.
    /// Idempotent; also runs from `deinit`.
    public func cleanUp() {
        connection = nil
    }

    deinit { cleanUp() }

    /// Bounded retry over a read transaction. A torn read while Messages writes
    /// can surface as a transient SQLite error; a fresh read transaction usually
    /// succeeds. This is the read entry point every engine query routes through,
    /// so the best-effort-live contract holds for the whole surface.
    public func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try Self.withRetry { try queue.read(block) }
    }

    /// Run `op` up to `attempts` times, sleeping `backoff` between tries, but only
    /// retrying on a *transient* SQLite error (`isTransient`); any other error
    /// rethrows immediately. Factored out so the retry policy is unit-testable
    /// without a live, contended database.
    static func withRetry<T>(
        attempts: Int = 3, backoff: TimeInterval = 0.15,
        _ op: () throws -> T
    ) throws -> T {
        var lastError: Error?
        for attempt in 0..<attempts {
            do { return try op() } catch {
                guard isTransient(error) else { throw error }
                lastError = error
                if attempt < attempts - 1 { Thread.sleep(forTimeInterval: backoff) }
            }
        }
        throw lastError!
    }

    /// Whether `error` is a transient SQLite error worth retrying — a torn read
    /// against the live WAL while Messages is mid-write can momentarily surface as
    /// busy/locked/I-O/corrupt/not-a-DB; a fresh read transaction usually clears
    /// it. A non-`DatabaseError` (or a genuine logic error like `.SQLITE_ERROR`)
    /// is not retried.
    static func isTransient(_ error: Error) -> Bool {
        guard let e = error as? DatabaseError else { return false }
        switch e.resultCode {
        case .SQLITE_BUSY, .SQLITE_LOCKED, .SQLITE_IOERR, .SQLITE_CORRUPT, .SQLITE_NOTADB:
            return true
        default: return false
        }
    }

    /// MAX(ROWID) over `message` — a single b-tree seek, O(1) even on a huge DB.
    /// The app polls this to detect new activity without re-running the list query.
    public func messageWatermark() throws -> Int64 {
        try read { try Int64.fetchOne($0, sql: "SELECT MAX(ROWID) FROM message") ?? 0 }
    }

    /// The oldest and newest real message timestamps in `message`, as Dates, or
    /// nils when the table is empty. Used to detect an incomplete (sparse) local
    /// store — a Mac whose Messages-in-iCloud history hasn't synced has a recent
    /// "oldest" floor. Filters out the date==0 sentinel rows so the floor is real.
    public func messageDateBounds() throws -> (oldest: Date?, newest: Date?) {
        try read { db in
            // One b-tree pass for the min/max of the real (date > 0) rows; the
            // `date == 0` sentinel rows are excluded so the floor is a real message.
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT MIN(date) lo, MAX(date) hi FROM message WHERE date > 0")
            else { return (nil, nil) }
            // Both are NULL together (no qualifying rows) or both present.
            let lo: Int64? = row["lo"]
            let hi: Int64? = row["hi"]
            func date(_ ns: Int64?) -> Date? {
                ns.map {
                    Date(timeIntervalSince1970: Double($0) / 1e9 + Extractor.appleEpochOffset)
                }
            }
            return (date(lo), date(hi))
        }
    }

    /// Handle ROWID → raw identifier (phone/email), e.g. 3 → "+15551234567".
    public func handleLabels() throws -> [Int64: String] {
        try read { db in
            var map: [Int64: String] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT ROWID, id FROM handle")
            while let row = try rows.next() {
                map[row["ROWID"]] = row["id"]
            }
            return map
        }
    }

    /// One 1:1 chat row belonging to a contact. On current macOS a number's
    /// iMessage/SMS/RCS are already merged into a single style=45 row, so the
    /// remaining union job is across a Contact's *identifiers* (phone + email).
    public struct ChatInfo: Sendable {
        public let chatID: Int64
        public let identifier: String?  // chat_identifier (the handle string)
        public let service: String?  // service_name: iMessage / SMS / RCS
        public let handleID: Int64?  // the chat's registered participant handle

        public init(chatID: Int64, identifier: String?, service: String?, handleID: Int64?) {
            self.chatID = chatID
            self.identifier = identifier
            self.service = service
            self.handleID = handleID
        }
    }

    /// Every 1:1 (style = 45) chat whose registered participant is one of
    /// `handles` — the contact-centric union of a person's threads.
    /// A Contact can span several identifiers (e.g. phone + email → separate
    /// chat rows); this gathers them all so an export drops none.
    public func oneToOneChats(forHandles handles: Set<Int64>) throws -> [ChatInfo] {
        guard !handles.isEmpty else { return [] }
        return try read { db in
            let placeholders = Array(repeating: "?", count: handles.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.ROWID cid, c.chat_identifier ident, c.service_name svc, chj.handle_id hid
                    FROM chat c JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
                    WHERE c.style = 45 AND chj.handle_id IN (\(placeholders))
                    ORDER BY c.ROWID
                    """,
                arguments: StatementArguments(handles.sorted()))
            return rows.map {
                ChatInfo(
                    chatID: $0["cid"], identifier: $0["ident"], service: $0["svc"],
                    handleID: $0["hid"])
            }
        }
    }

    public struct Counts: Sendable {
        public let messages: Int
        public let handles: Int
        public let chats: Int
    }

    public func counts() throws -> Counts {
        try read { db in
            Counts(
                messages: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0,
                handles: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM handle") ?? 0,
                chats: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat") ?? 0
            )
        }
    }

    /// One row in the conversation picker: a 1:1 chat with the
    /// metadata needed to label, sort, and group it. The caller resolves
    /// `identifier`/`handleID` to a Contact name and unions a person's chats.
    public struct ConversationSummary: Sendable {
        public let chatID: Int64
        public let identifier: String?  // chat_identifier (the handle string)
        public let service: String?  // iMessage / SMS / RCS
        public let handleID: Int64
        public let lastMessageDate: Date  // most-recent *real* message (recency sort)
        public let messageCount: Int  // real messages (reactions/system excluded)

        public init(
            chatID: Int64, identifier: String?, service: String?,
            handleID: Int64, lastMessageDate: Date, messageCount: Int
        ) {
            self.chatID = chatID
            self.identifier = identifier
            self.service = service
            self.handleID = handleID
            self.lastMessageDate = lastMessageDate
            self.messageCount = messageCount
        }
    }

    /// Every 1:1 (style = 45) chat with a real message, newest first — the raw
    /// material for the contact-centric picker. Counts/dates use *real* messages
    /// only (item_type 0, no reactions) so the recency sort and size read true.
    /// Contact grouping + multi-identifier union happen in the caller (they need the
    /// runtime Contacts map).
    public func conversationSummaries() throws -> [ConversationSummary] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.ROWID cid, c.chat_identifier ident, c.service_name svc,
                           chj.handle_id hid, MAX(m.date) lastDate, COUNT(*) cnt
                    FROM chat c
                    JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
                    JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE c.style = 45
                      AND COALESCE(m.item_type, 0) = 0
                      AND COALESCE(m.associated_message_type, 0) = 0
                    GROUP BY c.ROWID
                    ORDER BY lastDate DESC
                    """)
            return rows.map { row in
                let ns: Int64 = row["lastDate"] ?? 0
                return ConversationSummary(
                    chatID: row["cid"],
                    identifier: row["ident"],
                    service: row["svc"],
                    handleID: row["hid"] ?? 0,
                    lastMessageDate: Date(
                        timeIntervalSince1970: Double(ns) / 1e9 + Extractor.appleEpochOffset),
                    messageCount: row["cnt"] ?? 0)
            }
        }
    }

    // MARK: - Group chats (style = 43)

    /// One group-chat (style = 43) row, the group-side analog of
    /// `ConversationSummary`. Carries the chat's `display_name` (nil/empty when
    /// unnamed — 83% of groups are) and the sorted
    /// participant handle-set (from `chat_handle_join`, which lists only the
    /// *others*, so "me" is naturally excluded). Forks that share an identical
    /// `participantHandles` are stitched into one `Conversation` app-/engine-side
    /// (exact-set union).
    public struct GroupConversationSummary: Sendable {
        public let chatID: Int64
        public let identifier: String?  // chat_identifier / guid (the group's id string)
        public let service: String?  // iMessage / SMS / RCS
        public let displayName: String?  // chat.display_name, nil when unnamed
        public let lastMessageDate: Date  // most-recent *real* message (recency sort)
        public let messageCount: Int  // real messages (reactions/system excluded)
        public let participantHandles: [Int64]  // sorted handle ROWIDs (the set key)

        public init(
            chatID: Int64, identifier: String?, service: String?, displayName: String?,
            lastMessageDate: Date, messageCount: Int, participantHandles: [Int64]
        ) {
            self.chatID = chatID
            self.identifier = identifier
            self.service = service
            self.displayName = displayName
            self.lastMessageDate = lastMessageDate
            self.messageCount = messageCount
            self.participantHandles = participantHandles
        }
    }

    /// Every group (style = 43) chat with a real message, newest first — the
    /// group-side mirror of `conversationSummaries()`. Counts/dates use *real*
    /// messages only (`COALESCE(item_type,0) = 0`, no reactions) so the recency
    /// sort and size read true. Each row carries its sorted participant
    /// handle-set (the exact-set stitch key); exact-set folding +
    /// label resolution happen in `Conversations.group` (they need the runtime
    /// Contacts map), keeping this a pure read like its 1:1 twin.
    public func groupConversationSummaries() throws -> [GroupConversationSummary] {
        try read { db in
            // Rosters keyed by chat_id (one chat → many handles). A separate read
            // from the count/date aggregate below so the GROUP BY on the message
            // join doesn't fan out per participant.
            var rosters: [Int64: [Int64]] = [:]
            let rosterRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT chj.chat_id cid, chj.handle_id hid
                    FROM chat_handle_join chj
                    JOIN chat c ON c.ROWID = chj.chat_id
                    WHERE c.style = 43
                    """)
            for row in rosterRows {
                let cid: Int64 = row["cid"]
                let hid: Int64? = row["hid"]
                if let hid { rosters[cid, default: []].append(hid) }
            }

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.ROWID cid, c.chat_identifier ident, c.service_name svc,
                           c.display_name dname, MAX(m.date) lastDate, COUNT(*) cnt
                    FROM chat c
                    JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE c.style = 43
                      AND COALESCE(m.item_type, 0) = 0
                      AND COALESCE(m.associated_message_type, 0) = 0
                    GROUP BY c.ROWID
                    ORDER BY lastDate DESC
                    """)
            return rows.map { row in
                let ns: Int64 = row["lastDate"] ?? 0
                let cid: Int64 = row["cid"]
                let name = (row["dname"] as String?).flatMap { $0.isEmpty ? nil : $0 }
                return GroupConversationSummary(
                    chatID: cid,
                    identifier: row["ident"],
                    service: row["svc"],
                    displayName: name,
                    lastMessageDate: Date(
                        timeIntervalSince1970: Double(ns) / 1e9 + Extractor.appleEpochOffset),
                    messageCount: row["cnt"] ?? 0,
                    participantHandles: (rosters[cid] ?? []).sorted())
            }
        }
    }

    /// Per-(group chat, participant) real-message volume — one **grouped** read
    /// over every style=43 chat, keyed `chatID → (handleID → count)`. Runs ONCE
    /// per session alongside `groupConversationSummaries()`, NOT per row: the
    /// single `GROUP BY chat_id, handle_id` query lets `Conversations.groupGroups`
    /// order each group's roster most-active-first by summing a
    /// participant's counts across the stitched fork's chatIDs in memory — no
    /// per-participant query on the hot list-load path.
    ///
    /// Counts use *real* messages only (`COALESCE(item_type,0) = 0`, reactions and
    /// system events excluded), matching the recency/size reads. "Me"
    /// (`is_from_me = 1`) is excluded — it's never a roster member, so its volume
    /// would have nowhere to land; the roster orders the *others* by how much they
    /// talk. A silent member (0 real messages) simply has no row here and falls to
    /// the end of the order via the stable alphabetical tiebreak.
    public func groupParticipantMessageCounts() throws -> [Int64: [Int64: Int]] {
        try read { db in
            var counts: [Int64: [Int64: Int]] = [:]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT cmj.chat_id cid, m.handle_id hid, COUNT(*) cnt
                    FROM chat c
                    JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE c.style = 43
                      AND m.is_from_me = 0
                      AND COALESCE(m.item_type, 0) = 0
                      AND COALESCE(m.associated_message_type, 0) = 0
                    GROUP BY cmj.chat_id, m.handle_id
                    """)
            for row in rows {
                let cid: Int64 = row["cid"]
                guard let hid: Int64 = row["hid"] else { continue }
                counts[cid, default: [:]][hid] = row["cnt"] ?? 0
            }
            return counts
        }
    }

    // MARK: - Schema-sanity guard

    /// The chat.db surface LembicKit's SQL reads, table → required columns.
    /// **Keep in lockstep** with the queries in `Extractor` and `oneToOneChats`:
    /// this is the contract the guard enforces, so a column added there must be
    /// added here. `ROWID` is intentionally absent — SQLite exposes it on every
    /// (non WITHOUT-ROWID) table whether or not it's declared, so `PRAGMA
    /// table_info` won't list it for the join tables (e.g. message_attachment_join)
    /// and checking it would false-fail on a perfectly good database.
    public static let requiredSchema: [(table: String, columns: [String])] = [
        ("handle", ["id"]),
        ("chat", ["chat_identifier", "service_name", "style", "display_name"]),
        ("chat_handle_join", ["chat_id", "handle_id"]),
        ("chat_message_join", ["chat_id", "message_id"]),
        (
            "message",
            [
                "guid", "date", "is_from_me", "handle_id", "service", "text",
                "attributedBody", "item_type", "associated_message_type",
                "associated_message_guid", "associated_message_emoji", "balloon_bundle_id",
            ]
        ),
        ("message_attachment_join", ["message_id", "attachment_id"]),
        ("attachment", ["mime_type", "uti", "transfer_name"]),
    ]

    /// Structural check only: every required table/column the database is
    /// *missing*. Empty ⇒ the schema is the one the engine reads. Unknown
    /// `chat.style` values and an empty store are *valid* (a fresh install has
    /// no 1:1 chats yet), so neither is reported here — those are separate app
    /// states.
    public func schemaProblems() throws -> [SchemaProblem] {
        try read { db in
            var problems: [SchemaProblem] = []
            for (table, columns) in Self.requiredSchema {
                // `table` is a compile-time constant from `requiredSchema`, never
                // user input, so interpolating it into PRAGMA (which can't bind an
                // identifier) is safe. A missing table yields an empty result set.
                let present = Set(
                    try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                        .map { ($0["name"] as String).lowercased() })
                if present.isEmpty {
                    problems.append(SchemaProblem(table: table, column: nil))
                    continue
                }
                for column in columns where !present.contains(column.lowercased()) {
                    problems.append(SchemaProblem(table: table, column: column))
                }
            }
            return problems
        }
    }

    /// Fail-closed gate for the export path (app/CLI): no-op when the schema is
    /// supported, throws `UnsupportedSchemaError` otherwise. The caller turns the
    /// throw into a loud, copyable error rather than a silently-wrong export.
    public func preflight() throws {
        let problems = try schemaProblems()
        if !problems.isEmpty { throw UnsupportedSchemaError(problems: problems) }
    }

    /// Whether `table` carries **every** column in `columns` (case-insensitive),
    /// via the same `PRAGMA table_info` introspection `schemaProblems` uses. The
    /// opt-in seams that read columns *outside* `requiredSchema` (the group
    /// system-event stream's `group_action_type`/`group_title`/`other_handle`)
    /// probe with this before preparing their SQL, so a missing column degrades
    /// gracefully (the toggle yields nothing) rather than throwing at
    /// statement-prepare time. A missing table yields an empty result set ⇒ false.
    public func hasColumns(_ columns: [String], inTable table: String) throws -> Bool {
        try read { try Self.hasColumns(columns, inTable: table, db: $0) }
    }

    /// The `PRAGMA table_info` column probe, on an already-open `GRDB.Database` —
    /// the shared core of `hasColumns(_:inTable:)` and the reuse seam for callers
    /// that already hold a read connection (e.g. `Extractor.extractSystemEvents`,
    /// which probes inside its own `queue.read` before preparing its SQL).
    static func hasColumns(_ columns: [String], inTable table: String, db: GRDB.Database) throws
        -> Bool
    {
        // `table` is a caller-supplied constant (never user input), so
        // interpolating it into PRAGMA — which can't bind an identifier — is safe;
        // the only call sites pass literal chat.db table names.
        let present = Set(
            try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                .map { ($0["name"] as String).lowercased() })
        return columns.allSatisfy { present.contains($0.lowercased()) }
    }
}

/// One missing piece of the expected chat.db schema.
public struct SchemaProblem: Sendable, Equatable, CustomStringConvertible {
    public let table: String
    public let column: String?  // nil ⇒ the whole table is missing

    public init(table: String, column: String?) {
        self.table = table
        self.column = column
    }

    public var description: String {
        column.map { "\(table).\($0)" } ?? "\(table) (missing table)"
    }
}

/// Thrown by `ChatDatabase.preflight()` when the running Messages database
/// isn't the schema the engine was verified against, converted by the caller into
/// a fail-closed, visible error instead of a wrong export.
public struct UnsupportedSchemaError: Error, Sendable, CustomStringConvertible {
    public let problems: [SchemaProblem]
    public init(problems: [SchemaProblem]) { self.problems = problems }
    public var description: String {
        "Unsupported Messages database — missing "
            + problems.map(\.description).joined(separator: ", ")
    }
}
