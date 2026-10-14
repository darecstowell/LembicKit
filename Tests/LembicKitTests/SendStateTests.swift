import Foundation
import GRDB
import Testing

@testable import LembicKit

// Failed sends and pending Send Later messages never read as sent (lembickit.md F13).
@Suite("send state")
struct SendStateTests {
    static let sql = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER,
            chat_identifier TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
            is_from_me INTEGER, handle_id INTEGER, text TEXT, error INTEGER DEFAULT 0,
            is_sent INTEGER DEFAULT 0, schedule_type INTEGER DEFAULT 0);
        INSERT INTO handle VALUES (3,'+18160000003');
        INSERT INTO chat VALUES (1,'iMessage;-;+18160000003',45,'+18160000003');
        INSERT INTO chat_handle_join VALUES (1,3);
        INSERT INTO message VALUES
            (10,'a',1000000000000,0,3,'Wedding is on the 5th',0,0,0),
            (11,'b',2000000000000,1,0,'Are you coming to the wedding?',4,0,0),
            (12,'c',3000000000000,1,0,'Yes, see you there',0,1,0),
            (13,'d',9000000000000,1,0,'Merry Christmas Theo!',0,0,2),
            (14,'e',4000000000000,1,0,'Sent later, and it went out',0,1,2);
        INSERT INTO chat_message_join (chat_id, message_id) SELECT 1, ROWID FROM message;
        """

    @Test func failedAndScheduledAreMarked() throws {
        let queue = try Fixtures.makeInMemoryDB(populating: Self.sql)
        let records = try queue.read {
            try Extractor(targetHandles: [3], handleLabels: [:]).extractConversation(
                $0, chatIDs: [1])
        }
        #expect(
            records.map(\.text) == [
                "Wedding is on the 5th",
                "Are you coming to the wedding? [not delivered]",
                "Yes, see you there",
                "Sent later, and it went out",
                "Merry Christmas Theo! [scheduled, not sent]",
            ])
        #expect(records.map(\.flags) == [[], .notDelivered, [], [], .scheduled])
    }

    @Test func pendingScheduledDoesNotSetRecency() throws {
        let db = try Fixtures.openChatDB(populating: Self.sql)
        defer { db.cleanUp() }
        let summary = try #require(try db.conversationSummaries().first)
        #expect(
            summary.lastMessageDate == Date(timeIntervalSinceReferenceDate: 4000),
            "the newest sent message, not the future Send Later date")
        #expect(summary.messageCount == 5)
    }
}
