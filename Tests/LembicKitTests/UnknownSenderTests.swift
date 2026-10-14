import Foundation
import GRDB
import Testing

@testable import LembicKit

// A received row with a NULL, 0, or unknown handle never reads "h0"
// (lembickit.md F21).
@Suite("unknown sender")
struct UnknownSenderTests {
    static let sql = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER,
            chat_identifier TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
            is_from_me INTEGER, handle_id INTEGER, text TEXT, associated_message_type INTEGER
            DEFAULT 0, associated_message_guid TEXT);
        INSERT INTO handle VALUES (3,'+18160000003');
        INSERT INTO chat VALUES (1,'iMessage;-;+18160000003',45,'+18160000003');
        INSERT INTO chat_handle_join VALUES (1,3);
        INSERT INTO message VALUES
            (10,'a',1000000000000,0,3,'Sending the files now',0,NULL),
            (11,'b',2000000000000,0,0,'Here are the two files',0,NULL),
            (12,'c',3000000000000,0,NULL,'Got them?',0,NULL),
            (13,'d',4000000000000,0,0,'Loved',2000,'p:0/a'),
            (14,'e',5000000000000,0,3,'Removed a heart',3000,'p:0/a');
        INSERT INTO chat_message_join (chat_id, message_id) SELECT 1, ROWID FROM message;
        """

    @Test func oneToOneRowsAreThem() throws {
        let queue = try Fixtures.makeInMemoryDB(populating: Self.sql)
        let records = try queue.read {
            try Extractor(targetHandles: [3], handleLabels: [3: "Ana"]).extractConversation(
                $0, chatIDs: [1])
        }
        #expect(records.map(\.speaker) == ["Them", "Them", "Them"])
        #expect(records.allSatisfy { $0.isTarget })
        #expect(records.first?.reactions == [], "the heart and its removal net as one reactor")
    }

    @Test func groupRowsWithNoHandleAreUnknownSender() {
        let extractor = Extractor(targetHandles: [], handleLabels: [5: "Ana"])
        #expect(extractor.label(isFromMe: false, handleID: 0) == "Unknown sender")
        #expect(extractor.label(isFromMe: false, handleID: 99) == "Unknown sender")
        #expect(extractor.label(isFromMe: false, handleID: 5) == "Ana")
        #expect(extractor.systemEventLabel(isFromMe: false, handleID: 99) == nil)
    }
}
