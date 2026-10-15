import Foundation
import GRDB
import Testing

@testable import LembicKit

@Suite("invisible ink")
struct InvisibleInkTests {
    static let schema = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER, is_from_me INTEGER,
            handle_id INTEGER, service TEXT, text TEXT, attributedBody BLOB, item_type INTEGER DEFAULT 0,
            associated_message_type INTEGER DEFAULT 0, associated_message_guid TEXT,
            associated_message_emoji TEXT, balloon_bundle_id TEXT, date_retracted INTEGER DEFAULT 0
            EFFECT_COLUMN);
        CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, mime_type TEXT, uti TEXT, transfer_name TEXT);
        CREATE TABLE message_attachment_join (ROWID INTEGER PRIMARY KEY, message_id INTEGER, attachment_id INTEGER);
        INSERT INTO handle VALUES (1, '+15550000001');
        INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, service, text) VALUES
            (1, 'a', 100, 0, 1, 'iMessage', 'see you soon'),
            (2, 'b', 200, 1, 0, 'iMessage', 'Hunter2!x');
        INSERT INTO chat_message_join VALUES (1, 1), (1, 2);
        """

    func extract(withEffectColumn: Bool) throws -> [MessageRecord] {
        var sql = Self.schema.replacingOccurrences(
            of: "EFFECT_COLUMN", with: withEffectColumn ? ", expressive_send_style_id TEXT" : "")
        if withEffectColumn {
            sql += "UPDATE message SET expressive_send_style_id = '\(Extractor.invisibleInkEffect)' WHERE ROWID = 2;"
        }
        let q = try Fixtures.makeInMemoryDB(populating: sql)
        let ex = Extractor(targetHandles: [1], handleLabels: [:])
        return try q.read { try ex.extractConversation($0, chatIDs: [1]) }
    }

    @Test("a message sent with Invisible Ink is flagged whole, the others are not")
    func flagsWholeMessage() throws {
        let records = try extract(withEffectColumn: true)
        #expect(records.map(\.isInvisibleInk) == [false, true])
        let flags = SecretDetector.detect(in: records).filter { $0.category == .invisibleInk }
        #expect(flags.count == 1)
        #expect(flags.first?.guid == "b")
        #expect(flags.first?.range == 0..<("Hunter2!x" as NSString).length)
    }

    @Test("a chat.db without the effect column still exports, with no flag")
    func olderSchema() throws {
        let records = try extract(withEffectColumn: false)
        #expect(records.count == 2)
        #expect(records.allSatisfy { !$0.isInvisibleInk })
    }

    @Test("turning the category off removes the flag")
    func categoryOff() throws {
        let records = try extract(withEffectColumn: true)
        let enabled = Set(SecretCategory.allCases).subtracting([.invisibleInk])
        #expect(SecretDetector.detect(in: records, enabled: enabled).isEmpty)
    }
}
