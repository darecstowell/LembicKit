import Foundation
import GRDB
import Testing

@testable import LembicKit

// A chat with your own number shows each note once, as "Me" (lembickit.md F19).
@Suite("notes to self")
struct NoteToSelfTests {
    static let sql = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER,
            chat_identifier TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
            is_from_me INTEGER, handle_id INTEGER, text TEXT, destination_caller_id TEXT);
        INSERT INTO handle VALUES (1,'+15555550199'),(2,'+15555550101');
        INSERT INTO chat VALUES (1,'iMessage;-;+15555550199',45,'+15555550199'),
            (2,'iMessage;-;+15555550101',45,'+15555550101');
        INSERT INTO chat_handle_join VALUES (1,1),(2,2);
        INSERT INTO message VALUES
            (10,'a',1000000000000,1,1,'Buy milk and stamps','+15555550199'),
            (11,'b',1002000000000,0,1,'Buy milk and stamps',NULL),
            (12,'c',2000000000000,0,1,'Sent from my other phone',NULL),
            (13,'d',3000000000000,1,0,'Lunch?','+15555550199'),
            (14,'e',4000000000000,0,2,'Sure',NULL);
        INSERT INTO chat_message_join VALUES (1,10),(1,11),(1,12),(2,13),(2,14);
        """

    @Test func echoesDropAndEveryRowIsMe() throws {
        let db = try Fixtures.openChatDB(populating: Self.sql)
        defer { db.cleanUp() }
        let list = try Conversations.list(from: db, resolvingContacts: false, region: "US")
        let notes = try #require(list.first { $0.primaryIdentifier == "+15555550199" })
        #expect(notes.isNoteToSelf)
        #expect(list.first { $0.primaryIdentifier == "+15555550101" }?.isNoteToSelf == false)

        let rendered = try Export(database: db).render(
            notes, detect: false, resolveContacts: false)
        #expect(
            rendered.records.map(\.text) == ["Buy milk and stamps", "Sent from my other phone"])
        #expect(rendered.records.allSatisfy { $0.speaker == "Me" })
        #expect(rendered.skipped.map(\.reason) == [.echo])
        let txt = try #require(rendered.txt)
        #expect(txt.hasPrefix("# Messages transcript: notes to self\n"))
        #expect(txt.contains("# Speakers: Me = the account owner\n"))
    }

    @Test func ownerOnAnotherPersonsCardIsNotANoteToSelf() {
        let rows = [
            Fixtures.summary(1, "+15555550199", 1, date: 100),
            Fixtures.summary(2, "mom@example.com", 2, date: 200),
        ]
        let merged = Conversations.group(
            rows, contacts: [:],
            contactIDs: ["+15555550199": "card-mom", "mom@example.com": "card-mom"],
            owner: ["+15555550199"])
        #expect(merged.count == 1)
        #expect(merged.first?.isNoteToSelf == false, "a mixed union is never all Me")
    }
}
