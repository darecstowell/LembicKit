import Foundation
import GRDB

@testable import LembicKit

// Shared test fixtures: record builders, schema strings, and the DB helpers.
// Promoted out of the old `lembic-selftest` harness's nested closures so each
// suite can stay small. `Support/` is a plain source dir (no @Test); SPM
// compiles every .swift under the test target.

// MARK: - Record builders

enum Fixtures {
    /// Apple-epoch base used by most transcript/export fixtures.
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A transcript-trim record: `s` is the minute offset; speaker drives isTarget.
    static func rec(
        _ s: Int, _ speaker: String, _ text: String, attach: Bool = false,
        reacts: [Reaction] = []
    ) -> MessageRecord {
        MessageRecord(
            guid: "g\(s)", date: t0.addingTimeInterval(Double(s) * 60), speaker: speaker,
            isTarget: speaker == "Them", service: "iMessage", text: text,
            hadAttachment: attach, reactions: reacts)
    }

    /// An export-seam record: `s` is the day offset (86_400s).
    static func exportRec(_ s: Int, _ speaker: String, _ text: String) -> MessageRecord {
        MessageRecord(
            guid: "g\(s)", date: t0.addingTimeInterval(Double(s) * 86_400),
            speaker: speaker, isTarget: speaker == "Them", service: "iMessage",
            text: text, hadAttachment: false, reactions: [])
    }

    /// A detector record (fixed date, "Them" speaker), guid may be nil to test skipping.
    static func detRec(_ guid: String?, _ text: String) -> MessageRecord {
        MessageRecord(
            guid: guid, date: t0, speaker: "Them",
            isTarget: true, service: "iMessage", text: text, hadAttachment: false, reactions: []
        )
    }

    /// A redaction-render record: `s` is the minute offset.
    static func redRec(
        _ guid: String?, _ s: Int, _ speaker: String, _ text: String,
        reacts: [Reaction] = []
    ) -> MessageRecord {
        MessageRecord(
            guid: guid,
            date: t0.addingTimeInterval(Double(s) * 60),
            speaker: speaker, isTarget: speaker == "Them", service: "iMessage",
            text: text, hadAttachment: false, reactions: reacts)
    }

    /// A redaction-render record carrying an attachment flag (for the trim path).
    static func attachRec(
        _ guid: String?, _ s: Int, _ speaker: String, _ text: String,
        attach: Bool = false, reacts: [Reaction] = []
    ) -> MessageRecord {
        MessageRecord(
            guid: guid,
            date: t0.addingTimeInterval(Double(s) * 60),
            speaker: speaker, isTarget: speaker == "Them", service: "iMessage",
            text: text, hadAttachment: attach, reactions: reacts)
    }

    // MARK: - Golden-oracle fixture

    /// A FIXED `TimeZone` the golden tests render under, so the committed
    /// `golden_*.txt`/`.jsonl` bytes are deterministic on any contributor's
    /// machine regardless of the host timezone. Production keeps `.current`
    /// (local-time output is unchanged); only the golden tests pin this.
    /// Chosen as a stable, DST-aware zone so the committed bytes read naturally.
    static let goldenTimeZone = TimeZone(identifier: "America/Chicago")!

    /// Fixed epoch base for the golden fixture so dates never depend on "now".
    /// 1_700_000_000 = 2023-11-14 16:13:20 in America/Chicago.
    static let goldenBase = Date(timeIntervalSince1970: 1_700_000_000)

    /// One golden record. `s` is the minute offset from `goldenBase`; speaker
    /// drives `isTarget`.
    static func goldenRecord(
        _ guid: String, _ s: Int, _ speaker: String, _ text: String,
        reacts: [Reaction] = []
    ) -> MessageRecord {
        MessageRecord(
            guid: guid, date: goldenBase.addingTimeInterval(Double(s) * 60),
            speaker: speaker, isTarget: speaker == "Them", service: "iMessage",
            text: text, hadAttachment: false, reactions: reacts)
    }

    /// The deterministic record set the golden oracle renders. Exercises the
    /// preamble counts/legend, a reaction suffix, a multi-line message (+8
    /// indentation across two lines), two day sections (g3 is 1500 minutes ≈ next
    /// day), and a detectable SSN (for the redacted-variant golden + the leak
    /// proof).
    static let goldenRecords: [MessageRecord] = [
        goldenRecord("g0", 0, "Them", "hey there", reacts: [Reaction(by: "Me", emoji: "❤️")]),
        goldenRecord("g1", 1, "Me", "all good\nsecond line"),
        goldenRecord("g2", 2, "Them", "my ssn is 123-45-6789 keep it safe"),
        goldenRecord("g3", 1500, "Me", "next day"),
    ]

    /// A `RedactionSet` redacting every secret `SecretDetector` finds in
    /// `goldenRecords` (the planted SSN on g2). Drives the redacted goldens.
    static func goldenRedactionSet() -> RedactionSet {
        var rs = RedactionSet()
        for d in SecretDetector.detect(in: goldenRecords) {
            rs.add(Redaction(guid: d.guid, range: d.range))
        }
        return rs
    }

    /// A deterministic record set for the in-body **name-anonymize** golden:
    /// three named speakers — Me + "Sarah" +
    /// "Bob" — whose bodies MENTION each other by name, so an anonymized render
    /// must rewrite "tell Sarah hi" → "tell P2 hi" (the alias, not `[redacted]`),
    /// alias multiple mentions on one line, match whole-word + case-insensitively
    /// ("SARAH"/"sarah"), and leave the owner word "Me" and a non-participant name
    /// ("Carla") untouched. The plain (`anonymize: false`) render of this set is
    /// the byte-identical control.
    static let goldenNameAliasRecords: [MessageRecord] = [
        goldenRecord("na0", 0, "Me", "tell Sarah I said hi"),
        goldenRecord("na1", 1, "Sarah", "Bob and SARAH are both coming, not Carla"),
        goldenRecord("na2", 2, "Bob", "thanks Me, sarah already told me"),
    ]

    // MARK: - Group golden-oracle fixture

    /// One golden group record. Like `goldenRecord`, but `isTarget` is false (a
    /// group has no single "Them") and an optional attachment flag drives the
    /// `[photo]` placeholder + the "with attachments" count.
    static func goldenGroupRecord(
        _ guid: String, _ s: Int, _ speaker: String, _ text: String,
        attach: Bool = false, reacts: [Reaction] = []
    ) -> MessageRecord {
        MessageRecord(
            guid: guid, date: goldenBase.addingTimeInterval(Double(s) * 60),
            speaker: speaker, isTarget: false, service: "iMessage",
            text: text, hadAttachment: attach, reactions: reacts)
    }

    /// The deterministic GROUP record set the roster-header golden renders.
    /// Three speakers send messages — Me + "Alice" + "Bob" — and a
    /// fourth member ("(844) 399-6927", an unknown number) sits in the roster
    /// without ever speaking, to prove the header lists EVERY participant, not just
    /// the ones who appear in the body. Exercises: a reaction authored by a non-me
    /// speaker (Bob ❤️s Me's message), a message with an attachment (the `[photo]`
    /// placeholder + the attachment count), a multi-line body (+8 indentation), and
    /// two day sections (g3 is 1500 minutes ≈ next day).
    static let goldenGroupRecords: [MessageRecord] = [
        goldenGroupRecord(
            "gg0", 0, "Me", "hey all", reacts: [Reaction(by: "Bob", emoji: "❤️")]),
        goldenGroupRecord("gg1", 1, "Alice", "hi from Alice\nsecond line"),
        goldenGroupRecord("gg2", 2, "Bob", "look at this [photo]", attach: true),
        goldenGroupRecord("gg3", 1500, "Alice", "next day"),
    ]

    /// The `GroupRenderInfo` the group golden renders under: a named group whose
    /// roster includes a member ("(844) 399-6927") who never speaks, proving the
    /// header lists the full roster (the label layer), not just the speakers in the body.
    static let goldenGroupInfo = Transcript.GroupRenderInfo(
        name: "Trip crew",
        participantLabels: ["Alice", "Bob", "(844) 399-6927"])

    /// The opt-in system-event stream the `golden_group_events.txt` fixture renders
    /// (toggle ON). Exercises all three event kinds — a rename
    /// (`item_type=2`), an add (`item_type=1`, action 0), and a leave
    /// (`item_type=3`) — interleaved by timestamp with `goldenGroupRecords`: the
    /// rename lands before the first message (opening the day section itself), the
    /// add sits mid-day between two messages, and the leave trails the second-day
    /// message. The add names "Carla", a member NOT in the roster header, proving an
    /// off-roster `other_handle` still resolves.
    static let goldenGroupEvents: [Transcript.SystemEvent] = [
        Transcript.SystemEvent(
            date: goldenBase.addingTimeInterval(-60), line: "Bob named the group \"Trip crew\""),
        Transcript.SystemEvent(
            date: goldenBase.addingTimeInterval(90), line: "Alice added Carla"),
        Transcript.SystemEvent(
            date: goldenBase.addingTimeInterval(1530 * 60), line: "Alice left"),
    ]

    /// A ConversationSummary builder for the (DB-free) grouping suite.
    static func summary(
        _ chatID: Int64, _ identifier: String?, _ handleID: Int64,
        date: Int64, count: Int = 1
    ) -> ChatDatabase.ConversationSummary {
        ChatDatabase.ConversationSummary(
            chatID: chatID, identifier: identifier, service: "iMessage",
            handleID: handleID, lastMessageDate: Date(timeIntervalSince1970: Double(date)),
            messageCount: count)
    }

    // MARK: - Schema + DB fixtures

    /// The in-memory chat.db fixture for the conversation-union suite: one person
    /// over two handles/services in two 1:1 chats, plus a group chat to exclude.
    /// Message A is shared into both 1:1 chats (dedup) and carries a photo; C is
    /// an SMS; D lives only in the group.
    static let unionSchemaAndData = """
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, style INTEGER, chat_identifier TEXT, service_name TEXT, display_name TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER, is_from_me INTEGER,
            handle_id INTEGER, service TEXT, text TEXT, attributedBody BLOB, item_type INTEGER DEFAULT 0,
            associated_message_type INTEGER DEFAULT 0, associated_message_guid TEXT,
            associated_message_emoji TEXT, balloon_bundle_id TEXT);
        CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, mime_type TEXT, uti TEXT, transfer_name TEXT);
        CREATE TABLE message_attachment_join (ROWID INTEGER PRIMARY KEY, message_id INTEGER, attachment_id INTEGER);
        INSERT INTO chat (ROWID, style, chat_identifier, service_name) VALUES
            (1,45,'+18160000000','iMessage'),(2,45,'+18160000000','SMS'),(3,43,'group','iMessage');
        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1,3),(2,73),(3,3);
        INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, service, text) VALUES
            (10,'A',100,0,3,'iMessage','look \u{FFFC}'),(11,'B',300,1,0,'iMessage','reply'),
            (12,'C',200,0,73,'SMS','hi from sms'),(13,'D',400,0,3,'iMessage','group only');
        INSERT INTO chat_message_join (chat_id, message_id) VALUES (1,10),(1,11),(2,12),(2,10),(3,13);
        INSERT INTO attachment (ROWID, mime_type, uti, transfer_name) VALUES (1,'image/jpeg',NULL,NULL);
        INSERT INTO message_attachment_join (ROWID, message_id, attachment_id) VALUES (1,10,1);
        """

    /// A GroupConversationSummary builder for the (DB-free) group-grouping suite.
    static func groupSummary(
        _ chatID: Int64, _ identifier: String?, _ handles: [Int64],
        name: String? = nil, date: Int64, count: Int = 1
    ) -> ChatDatabase.GroupConversationSummary {
        ChatDatabase.GroupConversationSummary(
            chatID: chatID, identifier: identifier, service: "iMessage", displayName: name,
            lastMessageDate: Date(timeIntervalSince1970: Double(date)),
            messageCount: count, participantHandles: handles.sorted())
    }

    /// An in-memory chat.db fixture exercising the group (style=43) path.
    /// Carries:
    /// - A **named** group chat #10 ("Trip crew") with three speakers: Me +
    ///   handles 3 (Alice) and 5 (Bob). One message is a reaction (a ❤️ by Bob,
    ///   handle 5, on Me's message) — proving non-me reactions extract.
    /// - A **second** group chat #11 with the *identical* participant-set {3, 5}
    ///   but a different guid/no name — a fork that must stitch into the same
    ///   `Conversation` as #10 (both chatIDs, summed counts, max date).
    /// - A separate group chat #12 with a *different* roster {3, 7} that must
    ///   stay its own entry.
    /// - A 1:1 chat #20 (style=45) that the group enumerator must EXCLUDE.
    /// - Three **system events** in #10: a rename (`item_type=2`,
    ///   `group_title='KC crew'`, by handle 5/Bob), an add (`item_type=1`,
    ///   `group_action_type=0`, by handle 3/Alice, `other_handle=7`/an off-roster
    ///   member), and a leave (`item_type=3`, by handle 3/Alice). Excluded from the
    ///   default extraction; surfaced only by `extractSystemEvents`.
    static let groupSchemaAndData = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, style INTEGER, chat_identifier TEXT,
            service_name TEXT, display_name TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER, is_from_me INTEGER,
            handle_id INTEGER, service TEXT, text TEXT, attributedBody BLOB, item_type INTEGER DEFAULT 0,
            associated_message_type INTEGER DEFAULT 0, associated_message_guid TEXT,
            associated_message_emoji TEXT, balloon_bundle_id TEXT,
            group_action_type INTEGER DEFAULT 0, group_title TEXT, other_handle INTEGER DEFAULT 0);
        CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, mime_type TEXT, uti TEXT, transfer_name TEXT);
        CREATE TABLE message_attachment_join (ROWID INTEGER PRIMARY KEY, message_id INTEGER, attachment_id INTEGER);
        INSERT INTO handle (ROWID, id) VALUES
            (3,'+18160000003'),(5,'+18160000005'),(7,'+18160000007'),(9,'+18160000009');
        INSERT INTO chat (ROWID, style, chat_identifier, service_name, display_name) VALUES
            (10,43,'group-A','iMessage','Trip crew'),
            (11,43,'group-A2','iMessage',NULL),
            (12,43,'group-B','iMessage',NULL),
            (20,45,'+18160000009','iMessage',NULL);
        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
            (10,3),(10,5),(11,5),(11,3),(12,3),(12,7),(20,9);
        INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, service, text,
            item_type, associated_message_type, associated_message_guid,
            group_action_type, group_title, other_handle) VALUES
            (100,'gm0',100,1,0,'iMessage','hey all',0,0,NULL,0,NULL,0),
            (101,'gm1',200,0,3,'iMessage','Alice here',0,0,NULL,0,NULL,0),
            (102,'gm2',300,0,5,'iMessage','Bob here',0,0,NULL,0,NULL,0),
            (103,'gm3',400,0,5,'iMessage','',0,2000,'p:0/gm0',0,NULL,0),
            (104,'gm4',500,0,3,'iMessage','from the fork',0,0,NULL,0,NULL,0),
            (105,'gm5',600,1,0,'iMessage','group B msg',0,0,NULL,0,NULL,0),
            (106,'gm6',700,0,9,'iMessage','one to one',0,0,NULL,0,NULL,0),
            (110,'se0',50,0,5,'iMessage',NULL,2,0,NULL,0,'KC crew',0),
            (111,'se1',250,0,3,'iMessage',NULL,1,0,NULL,0,NULL,7),
            (112,'se2',650,0,3,'iMessage',NULL,3,0,NULL,0,NULL,0);
        INSERT INTO chat_message_join (chat_id, message_id) VALUES
            (10,100),(10,101),(10,102),(10,103),(11,104),(12,105),(20,106),
            (10,110),(10,111),(10,112);
        """

    /// The whole surface the engine reads; the schema guard must pass on it and
    /// pinpoint exactly what a future/older macOS would have dropped or renamed.
    static let fullSchema = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, style INTEGER, chat_identifier TEXT, service_name TEXT, display_name TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER, is_from_me INTEGER,
            handle_id INTEGER, service TEXT, text TEXT, attributedBody BLOB, item_type INTEGER DEFAULT 0,
            associated_message_type INTEGER DEFAULT 0, associated_message_guid TEXT,
            associated_message_emoji TEXT, balloon_bundle_id TEXT);
        CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, mime_type TEXT, uti TEXT, transfer_name TEXT);
        CREATE TABLE message_attachment_join (ROWID INTEGER PRIMARY KEY, message_id INTEGER, attachment_id INTEGER);
        """

    /// Build the in-memory union/schema fixture as a raw `DatabaseQueue`. Used
    /// where a test only needs the queue (e.g. `Extractor.extractConversation`).
    static func makeInMemoryDB(populating sql: String) throws -> DatabaseQueue {
        let q = try DatabaseQueue()  // in-memory; no real chat.db needed
        try q.write { try $0.execute(sql: sql) }
        return q
    }

    /// Materialize an in-memory fixture to a temp .db file, then open it as a real
    /// `ChatDatabase` (which copies it again into its own temp dir). Lets DB-backed
    /// tests exercise the *instance* query methods — the surface kept when the
    /// static twins were folded. The returned `ChatDatabase` cleans itself up on
    /// deinit; the helper deletes its own scratch dir.
    static func openChatDB(populating sql: String) throws -> ChatDatabase {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lembic-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("chat.db")
        // Write the fixture to an on-disk file, then drop the writer so the file
        // is flushed before ChatDatabase opens a read-only copy of it.
        do {
            let q = try DatabaseQueue(path: path.path)
            try q.write { try $0.execute(sql: sql) }
        }
        let db = try ChatDatabase(copying: path)  // copies into ITS temp dir, read-only
        try? FileManager.default.removeItem(at: dir)  // ChatDatabase has its own copy now
        return db
    }
}
