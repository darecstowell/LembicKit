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

    /// Changes when Messages commits anything: a new row, an edit, an unsend, or a
    /// delete. Poll it to refresh an open thread. Compare tokens from one
    /// `ChatDatabase` only: `dataVersion` is per connection.
    public struct ChangeToken: Hashable, Sendable {
        public let messageWatermark: Int64
        public let dataVersion: Int64
    }

    public func changeToken() throws -> ChangeToken {
        try read { db in
            ChangeToken(
                messageWatermark: try Int64.fetchOne(db, sql: "SELECT MAX(ROWID) FROM message")
                    ?? 0,
                dataVersion: try Int64.fetchOne(db, sql: "PRAGMA data_version") ?? 0)
        }
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
            return (Extractor.appleDate(lo), Extractor.appleDate(hi))
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
            let cols = try SchemaColumns.load(db)
            let placeholders = Array(repeating: "?", count: handles.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.ROWID cid, \(cols.column("c", "chat", "chat_identifier")) ident,
                           \(cols.column("c", "chat", "service_name")) svc, chj.handle_id hid
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
        /// `chat.guid`: stable across renames, Contacts changes, and member changes.
        public let guid: String?
        /// The owner's own addresses seen in this chat (`destination_caller_id` of
        /// the owner's messages), raw.
        public let ownerIdentifiers: Set<String>

        public init(
            chatID: Int64, identifier: String?, service: String?,
            handleID: Int64, lastMessageDate: Date, messageCount: Int, guid: String? = nil,
            ownerIdentifiers: Set<String> = []
        ) {
            self.ownerIdentifiers = ownerIdentifiers
            self.chatID = chatID
            self.identifier = identifier
            self.service = service
            self.handleID = handleID
            self.lastMessageDate = lastMessageDate
            self.messageCount = messageCount
            self.guid = guid
        }
    }

    /// Every 1:1 (style = 45) chat with a real message, newest first — the raw
    /// material for the contact-centric picker. Counts/dates use *real* messages
    /// only (item_type 0, no reactions) so the recency sort and size read true.
    /// Contact grouping + multi-identifier union happen in the caller (they need the
    /// runtime Contacts map).
    public func conversationSummaries() throws -> [ConversationSummary] {
        try read { db in
            let cols = try SchemaColumns.load(db)
            let handleJoin =
                cols.has("handle", "id") ? "LEFT JOIN handle h ON h.ROWID = chj.handle_id" : ""
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.ROWID cid,
                           COALESCE(\(cols.column("c", "chat", "chat_identifier")),
                                    \(cols.column("h", "handle", "id"))) ident,
                           \(cols.column("c", "chat", "service_name")) svc,
                           \(cols.column("c", "chat", "guid")) cguid,
                           chj.handle_id hid, MAX(\(Self.sentDate(cols))) lastDate,
                           COUNT(*) cnt, \(Self.ownerAddresses(cols)) me
                    FROM chat c
                    JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
                    \(handleJoin)
                    JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE c.style = 45 AND \(Self.realMessageFilter(cols))
                    GROUP BY c.ROWID
                    ORDER BY lastDate DESC
                    """)
            return rows.map { row in
                return ConversationSummary(
                    chatID: row["cid"],
                    identifier: row["ident"],
                    service: row["svc"],
                    handleID: row["hid"] ?? 0,
                    lastMessageDate: Self.summaryDate(row["lastDate"]),
                    messageCount: row["cnt"] ?? 0,
                    guid: row["cguid"],
                    ownerIdentifiers: Self.splitAddresses(row["me"]))
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
        /// `chat.guid`: stable across renames, Contacts changes, and member changes.
        public let guid: String?
        /// `chat.group_id`: chats that share one are the same group.
        public let groupID: String?
        /// The oldest real message, or nil when unknown.
        public let firstMessageDate: Date?
        /// The owner's own addresses seen in this chat, raw.
        public let ownerIdentifiers: Set<String>

        public init(
            chatID: Int64, identifier: String?, service: String?, displayName: String?,
            lastMessageDate: Date, messageCount: Int, participantHandles: [Int64],
            guid: String? = nil, groupID: String? = nil, firstMessageDate: Date? = nil,
            ownerIdentifiers: Set<String> = []
        ) {
            self.ownerIdentifiers = ownerIdentifiers
            self.chatID = chatID
            self.identifier = identifier
            self.service = service
            self.displayName = displayName
            self.lastMessageDate = lastMessageDate
            self.messageCount = messageCount
            self.participantHandles = participantHandles
            self.guid = guid
            self.groupID = groupID
            self.firstMessageDate = firstMessageDate
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

            let cols = try SchemaColumns.load(db)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.ROWID cid, \(cols.column("c", "chat", "chat_identifier")) ident,
                           \(cols.column("c", "chat", "service_name")) svc,
                           \(cols.column("c", "chat", "display_name")) dname,
                           \(cols.column("c", "chat", "guid")) cguid,
                           \(cols.column("c", "chat", "group_id")) gid,
                           MIN(CASE WHEN m.date > 0 THEN m.date END) firstDate,
                           MAX(\(Self.sentDate(cols))) lastDate, COUNT(*) cnt,
                           \(Self.ownerAddresses(cols)) me
                    FROM chat c
                    JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE c.style = 43 AND \(Self.realMessageFilter(cols))
                    GROUP BY c.ROWID
                    ORDER BY lastDate DESC
                    """)
            return rows.map { row in
                let cid: Int64 = row["cid"]
                let name = (row["dname"] as String?).flatMap { $0.isEmpty ? nil : $0 }
                let firstNS: Int64? = row["firstDate"]
                return GroupConversationSummary(
                    chatID: cid,
                    identifier: row["ident"],
                    service: row["svc"],
                    displayName: name,
                    lastMessageDate: Self.summaryDate(row["lastDate"]),
                    messageCount: row["cnt"] ?? 0,
                    participantHandles: (rosters[cid] ?? []).sorted(),
                    guid: row["cguid"],
                    groupID: row["gid"],
                    firstMessageDate: Extractor.appleDate(firstNS),
                    ownerIdentifiers: Self.splitAddresses(row["me"]))
            }
        }
    }

    /// Handle ROWID to `handle.person_centric_id`: Apple's link between the
    /// handles of one person. Empty when the column is missing.
    public func personCentricIDs() throws -> [Int64: String] {
        try read { db in
            let cols = try SchemaColumns.load(db, tables: ["handle"])
            guard cols.has("handle", "person_centric_id") else { return [:] }
            var map: [Int64: String] = [:]
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT ROWID, person_centric_id pcid FROM handle
                    WHERE person_centric_id IS NOT NULL AND person_centric_id != ''
                    """)
            while let row = try rows.next() { map[row["ROWID"]] = row["pcid"] }
            return map
        }
    }

    /// Group chat ROWID to its `chat_lookup` identifiers (macOS 26). Group chats
    /// that share one are the same thread split across services. Empty when the
    /// table is missing.
    public func groupChatLinks() throws -> [Int64: Set<String>] {
        try read { db in
            let cols = try SchemaColumns.load(db, tables: ["chat_lookup"])
            guard cols.has("chat_lookup", "chat"), cols.has("chat_lookup", "identifier") else {
                return [:]
            }
            var links: [Int64: Set<String>] = [:]
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT cl.chat cid, cl.identifier ident FROM chat_lookup cl
                    JOIN chat c ON c.ROWID = cl.chat
                    WHERE c.style = 43 AND cl.identifier IS NOT NULL AND cl.identifier != ''
                    """)
            while let row = try rows.next() {
                links[row["cid"], default: []].insert(row["ident"])
            }
            return links
        }
    }

    /// Per-(group chat, participant) real-message volume — one **grouped** read
    /// over every style=43 chat, keyed `chatID → (handleID → count)`. Runs ONCE
    /// per session alongside `groupConversationSummaries()`, NOT per row, so
    /// `Conversations.groupGroups` can order each roster most-active-first and
    /// find people who are no longer in `chat_handle_join`.
    ///
    /// Counts use *real* messages only (`COALESCE(item_type,0) = 0`, reactions and
    /// system events excluded), matching the recency/size reads. "Me"
    /// (`is_from_me = 1`) is excluded. A person an add or remove event names
    /// (`other_handle`) who never wrote has a count of 0, so former members who
    /// stayed silent still reach the roster.
    public func groupParticipantMessageCounts() throws -> [Int64: [Int64: Int]] {
        try read { db in
            let cols = try SchemaColumns.load(db)
            let itemType = "COALESCE(\(cols.column("m", "message", "item_type")), 0)"
            let other = "COALESCE(\(cols.column("m", "message", "other_handle")), 0)"
            var counts: [Int64: [Int64: Int]] = [:]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT cmj.chat_id cid,
                           CASE WHEN \(itemType) = 1 THEN \(other) ELSE m.handle_id END hid,
                           SUM(CASE WHEN \(itemType) = 1 THEN 0 ELSE 1 END) cnt
                    FROM chat c
                    JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE c.style = 43
                      AND ((m.is_from_me = 0 AND \(Self.realMessageFilter(cols)))
                           OR (\(itemType) = 1 AND \(other) > 0))
                    GROUP BY cid, hid
                    """)
            for row in rows {
                let cid: Int64 = row["cid"]
                guard let hid: Int64 = row["hid"], hid > 0 else { continue }
                counts[cid, default: [:]][hid] = row["cnt"] ?? 0
            }
            return counts
        }
    }

    /// SQL that keeps real messages only: no system rows, no reactions.
    static func realMessageFilter(_ cols: SchemaColumns) -> String {
        "COALESCE(\(cols.column("m", "message", "item_type")), 0) = 0"
            + " AND COALESCE(\(cols.column("m", "message", "associated_message_type")), 0) = 0"
    }

    /// The distinct `destination_caller_id` values of the owner's messages, as one
    /// comma-joined string per group.
    static func ownerAddresses(_ cols: SchemaColumns) -> String {
        let caller = cols.column("m", "message", "destination_caller_id")
        return "GROUP_CONCAT(DISTINCT CASE WHEN m.is_from_me = 1 THEN \(caller) END)"
    }

    static func splitAddresses(_ joined: String?) -> Set<String> {
        Set(
            (joined ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
    }

    /// A summary's newest date; the 2001 epoch when no row has a known date.
    static func summaryDate(_ raw: Int64?) -> Date {
        Extractor.appleDate(raw) ?? Date(timeIntervalSince1970: Extractor.appleEpochOffset)
    }

    /// `m.date`, or NULL for a Send Later row that has not gone out, so a future
    /// date never pins a conversation to the top.
    static func sentDate(_ cols: SchemaColumns) -> String {
        let type = cols.column("m", "message", "schedule_type")
        let sent = cols.column("m", "message", "is_sent")
        return "CASE WHEN \(type) = 2 AND COALESCE(\(sent), 0) = 0 THEN NULL ELSE m.date END"
    }

    // MARK: - Schema-sanity guard

    /// The columns the engine cannot work without. A missing one fails closed.
    /// Every other column the SQL reads is in `optionalSchema` and is probed at
    /// query time. `ROWID` is absent on purpose: SQLite has it on every table, but
    /// `PRAGMA table_info` does not list it for the join tables.
    public static let requiredSchema: [(table: String, columns: [String])] = [
        ("handle", ["id"]),
        ("chat", ["style"]),
        ("chat_handle_join", ["chat_id", "handle_id"]),
        ("chat_message_join", ["chat_id", "message_id"]),
        ("message", ["guid", "date", "is_from_me", "handle_id"]),
    ]

    /// The message body: at least one of these columns must exist.
    public static let requiredBodyColumns = ["text", "attributedBody"]

    /// Columns read when present. A missing one degrades one feature (a NULL is
    /// selected in its place), never the whole export. Keep in lockstep with the SQL.
    public static let optionalSchema: [(table: String, columns: [String])] = [
        ("chat", ["guid", "chat_identifier", "service_name", "display_name", "group_id"]),
        ("handle", ["person_centric_id"]),
        (
            "message",
            [
                "service", "text", "attributedBody", "item_type", "associated_message_type",
                "associated_message_guid", "associated_message_emoji", "balloon_bundle_id",
                "date_retracted", "payload_data", "group_action_type", "group_title",
                "other_handle", "error", "is_sent", "schedule_type", "destination_caller_id",
            ]
        ),
        ("message_attachment_join", ["message_id", "attachment_id"]),
        (
            "attachment",
            [
                "mime_type", "uti", "transfer_name", "is_sticker",
                "emoji_image_short_description", "guid",
            ]
        ),
        ("chat_lookup", ["chat", "identifier"]),
    ]

    /// Every missing core table or column. Empty means the engine can read the
    /// database. Unknown `chat.style` values and an empty store are valid, so
    /// neither is reported here.
    public func schemaProblems() throws -> [SchemaProblem] {
        try read { db in
            var problems: [SchemaProblem] = []
            let columns = try SchemaColumns.load(db, tables: Self.requiredSchema.map(\.table))
            for (table, required) in Self.requiredSchema {
                guard columns.hasTable(table) else {
                    problems.append(SchemaProblem(table: table, column: nil))
                    continue
                }
                for column in required where !columns.has(table, column) {
                    problems.append(SchemaProblem(table: table, column: column))
                }
            }
            if columns.hasTable("message"),
                !Self.requiredBodyColumns.contains(where: { columns.has("message", $0) })
            {
                problems += Self.requiredBodyColumns.map {
                    SchemaProblem(table: "message", column: $0)
                }
            }
            return problems
        }
    }

    /// Every optional table or column the database lacks: the features that will
    /// degrade. For diagnostics only; `preflight()` never fails on these.
    public func missingOptionalColumns() throws -> [SchemaProblem] {
        try read { db in
            let columns = try SchemaColumns.load(db, tables: Self.optionalSchema.map(\.table))
            var gaps: [SchemaProblem] = []
            for (table, optional) in Self.optionalSchema {
                guard columns.hasTable(table) else {
                    gaps.append(SchemaProblem(table: table, column: nil))
                    continue
                }
                gaps += optional.filter { !columns.has(table, $0) }.map {
                    SchemaProblem(table: table, column: $0)
                }
            }
            return gaps
        }
    }

    /// Fail-closed gate for the export path: throws `UnsupportedSchemaError` when a
    /// core column is missing, so the caller shows a clear error instead of a
    /// wrong export. Missing optional columns pass.
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
        let schema = try SchemaColumns.load(db, tables: [table])
        return columns.allSatisfy { schema.has(table, $0) }
    }
}

/// The columns a database actually has, read once per query with `PRAGMA
/// table_info`. Lets each query select `NULL` in place of an absent optional column.
struct SchemaColumns: Sendable {
    private var tables: [String: Set<String>] = [:]

    /// `tables` are chat.db table-name constants from the engine, never user input,
    /// so interpolating them into PRAGMA (which cannot bind an identifier) is safe.
    static func load(_ db: GRDB.Database, tables names: [String]) throws -> SchemaColumns {
        var schema = SchemaColumns()
        for name in Set(names) {
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(name))")
                .map { ($0["name"] as String).lowercased() }
            if !columns.isEmpty { schema.tables[name.lowercased()] = Set(columns) }
        }
        return schema
    }

    /// Every table the engine's SQL can touch.
    static let engineTables = [
        "handle", "chat", "chat_handle_join", "chat_message_join", "message",
        "message_attachment_join", "attachment",
    ]

    static func load(_ db: GRDB.Database) throws -> SchemaColumns {
        try load(db, tables: engineTables)
    }

    func hasTable(_ table: String) -> Bool { tables[table.lowercased()] != nil }

    func has(_ table: String, _ column: String) -> Bool {
        tables[table.lowercased()]?.contains(column.lowercased()) ?? false
    }

    /// `alias.column` when the column exists, else `NULL`.
    func column(_ alias: String, _ table: String, _ column: String) -> String {
        has(table, column) ? "\(alias).\(column)" : "NULL"
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
