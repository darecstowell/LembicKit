import Foundation
import GRDB
import Testing

@testable import LembicKit

// Optional columns degrade one feature; only core columns fail closed (lembickit.md F3).
@Suite("schema degrade")
struct SchemaDegradeTests {
    /// The `fullSchema` message table without `associated_message_emoji` (macOS 14 shape).
    static let sonomaSQL =
        Fixtures.fullSchema.replacingOccurrences(of: "associated_message_emoji TEXT, ", with: "")
            + """
            INSERT INTO handle (ROWID, id) VALUES (3,'+18160000003');
            INSERT INTO chat (ROWID, style, chat_identifier, service_name) VALUES (1,45,'+18160000003','iMessage');
            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1,3);
            INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, service, text,
                associated_message_type, associated_message_guid) VALUES
                (10,'m1',100,1,0,'iMessage','hello',0,NULL),
                (11,'r1',200,0,3,'iMessage','Reacted 🥳 to “hello”',2006,'p:0/m1');
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1,10),(1,11);
            """

    @Test func sonomaSchemaPassesPreflight() throws {
        let db = try Fixtures.openChatDB(populating: Self.sonomaSQL)
        #expect(
            try db.schemaProblems().isEmpty, "a missing optional column is not a schema problem")
        try db.preflight()
        #expect(
            try db.missingOptionalColumns().contains(
                SchemaProblem(table: "message", column: "associated_message_emoji")),
            "the gap is still reported for diagnostics")
    }

    @Test func sonomaSchemaExportsWithFallbackEmoji() throws {
        let db = try Fixtures.openChatDB(populating: Self.sonomaSQL)
        let conversations = try Conversations.list(from: db, resolvingContacts: false)
        let conversation = try #require(conversations.first)
        let rendered = try Export(database: db).render(
            conversation, formats: [.txt], resolveContacts: false)
        #expect(
            rendered.unredactedRecords.map(\.text) == ["hello"], "the reaction row is not a message"
        )
        #expect(
            rendered.unredactedRecords.first?.reactions == [Reaction(by: "Them", emoji: "•")],
            "an emoji tapback without the emoji column falls back to a dot")
    }

    /// Only the core columns: no service, item_type, reactions, balloon, retracted, or attachments.
    static let bareSQL = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, style INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
            is_from_me INTEGER, handle_id INTEGER, text TEXT);
        INSERT INTO handle (ROWID, id) VALUES (3,'+18160000003'),(4,'+18160000004');
        INSERT INTO chat (ROWID, style) VALUES (1,45),(2,43);
        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1,3),(2,3),(2,4);
        INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, text) VALUES
            (10,'m1',100,0,3,'one to one'),(11,'m2',200,1,0,'group hello');
        INSERT INTO chat_message_join (chat_id, message_id) VALUES (1,10),(2,11);
        """

    @Test func coreOnlySchemaListsAndExtracts() throws {
        let db = try Fixtures.openChatDB(populating: Self.bareSQL)
        try db.preflight()
        let conversations = try Conversations.list(from: db, resolvingContacts: false)
        #expect(conversations.count == 2, "one 1:1 and one group, with no optional columns")
        let oneToOne = try #require(conversations.first { !$0.isGroup })
        #expect(oneToOne.primaryIdentifier == "+18160000003", "identifier falls back to the handle")
        let exporter = Export(database: db)
        for conversation in conversations {
            let rendered = try exporter.render(
                conversation, formats: [.txt], resolveContacts: false)
            #expect(rendered.unredactedRecords.count == 1, "each chat still yields its message")
        }
        let events = try db.read {
            try Extractor(targetHandles: [], handleLabels: [:]).extractSystemEvents(
                $0, chatIDs: [2])
        }
        #expect(events.isEmpty, "system events degrade to none")
    }

    @Test func missingCoreColumnStillFailsClosed() throws {
        let sql = Self.bareSQL.replacingOccurrences(of: "guid TEXT, ", with: "")
            .replacingOccurrences(of: "guid, ", with: "")
            .replacingOccurrences(of: "'m1',", with: "").replacingOccurrences(of: "'m2',", with: "")
        let db = try Fixtures.openChatDB(populating: sql)
        #expect(throws: UnsupportedSchemaError.self) { try db.preflight() }
        #expect(try db.schemaProblems() == [SchemaProblem(table: "message", column: "guid")])
    }

    @Test func bodyNeedsTextOrAttributedBody() throws {
        let sql = Self.bareSQL.replacingOccurrences(of: ", text TEXT", with: "")
            .replacingOccurrences(of: ", text)", with: ")")
            .replacingOccurrences(of: ",'one to one'", with: "")
            .replacingOccurrences(of: ",'group hello'", with: "")
        let db = try Fixtures.openChatDB(populating: sql)
        #expect(
            try db.schemaProblems() == [
                SchemaProblem(table: "message", column: "text"),
                SchemaProblem(table: "message", column: "attributedBody"),
            ], "with neither body column, both are reported")
    }
}
