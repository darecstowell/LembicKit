import Foundation
import GRDB
import Testing

@testable import LembicKit

// Photo and background changes are not "left", and a number change is not
// "X added X" (lembickit.md F7).
@Suite("group event kinds")
struct GroupEventTests {
    static let sql = """
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
            is_from_me INTEGER, handle_id INTEGER, item_type INTEGER DEFAULT 0,
            group_action_type INTEGER DEFAULT 0, group_title TEXT, other_handle INTEGER DEFAULT 0);
        INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, item_type,
            group_action_type, other_handle) VALUES
            (1,'a',100,0,3,3,0,0),(2,'b',200,0,5,3,1,0),(3,'c',300,1,0,3,2,0),
            (4,'d',400,0,3,3,4,0),(5,'e',500,0,5,3,6,0),(6,'f',600,0,5,1,0,5),
            (7,'g',700,0,3,3,9,0),(8,'h',800,0,3,1,7,5),(9,'i',900,0,3,1,1,5);
        INSERT INTO chat_message_join SELECT 10, ROWID FROM message;
        """

    @Test func eachActionHasItsOwnLine() throws {
        let queue = try Fixtures.makeInMemoryDB(populating: Self.sql)
        let extractor = Extractor(
            targetHandles: [], handleLabels: [3: "Priya", 5: "Dev"], rosterHandles: [3, 5])
        let lines = try queue.read { try extractor.extractSystemEvents($0, chatIDs: [10]) }.map(
            \.line)
        #expect(
            lines == [
                "Priya left",
                "Dev changed the group photo",
                "Me removed the group photo",
                "Priya changed the chat background",
                "Dev removed the chat background",
                "Dev changed their phone number",
                "Priya removed Dev",
            ], "unknown action values (3/9, 1/7) are skipped, never guessed")
    }
}
