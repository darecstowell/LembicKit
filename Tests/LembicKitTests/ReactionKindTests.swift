import Foundation
import GRDB
import Testing

@testable import LembicKit

// Sticker tapbacks and unknown reaction types never become messages
// (lembickit.md F6, redaction.md F32).
@Suite("reaction kinds")
struct ReactionKindTests {
    static let sql = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, style INTEGER, chat_identifier TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
            is_from_me INTEGER, handle_id INTEGER, text TEXT, attributedBody BLOB,
            item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0,
            associated_message_guid TEXT, associated_message_emoji TEXT);
        CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, mime_type TEXT, uti TEXT,
            transfer_name TEXT);
        CREATE TABLE message_attachment_join (ROWID INTEGER PRIMARY KEY, message_id INTEGER,
            attachment_id INTEGER);
        INSERT INTO handle VALUES (3,'+18160000003');
        INSERT INTO chat VALUES (1,45,'+18160000003');
        INSERT INTO chat_handle_join VALUES (1,3);
        INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, text,
            associated_message_type, associated_message_guid, associated_message_emoji) VALUES
            (10,'q',100,0,3,'Lunch Friday?',0,NULL,NULL),
            (11,'a',200,1,0,'Yes! Thai place?',0,NULL,NULL),
            (12,'s1',300,0,3,'Reacted with a sticker to “Yes! Thai place?” ￼',2007,'p:0/a',NULL),
            (13,'s2',310,1,0,'￼',1000,'p:0/q',NULL),
            (14,'f1',320,0,3,'Reacted ✨ to “Lunch Friday?”',2008,'p:0/q','✨'),
            (15,'f2',330,1,0,'Reacted to “Lunch Friday?”',2099,'p:0/q',NULL),
            (16,'x1',340,0,3,'Pinned “Hunter2!x”',5000,'p:0/a',NULL),
            (17,'s3',350,1,0,'Removed a sticker',3007,'p:0/a',NULL),
            (18,'s4',360,0,3,'Reacted with a sticker to “Lunch Friday?” ￼',2007,'p:0/q',NULL),
            (19,'n',400,0,3,'see you then',0,NULL,NULL);
        INSERT INTO chat_message_join (chat_id, message_id)
            SELECT 1, ROWID FROM message;
        INSERT INTO attachment VALUES (1,'image/heic','public.heic','sticker.heic'),
            (2,'image/png','public.png','Sticker.png'),(3,'image/heic','public.heic','s.heic');
        INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (12,1),(13,2),(18,3);
        """

    @Test func stickersAndUnknownTypesAttachOrDrop() throws {
        let queue = try Fixtures.makeInMemoryDB(populating: Self.sql)
        let records = try queue.read {
            try Extractor(targetHandles: [3], handleLabels: [:]).extractConversation(
                $0, chatIDs: [1])
        }
        #expect(
            records.map(\.text) == ["Lunch Friday?", "Yes! Thai place?", "see you then"],
            "no reaction row, sticker, or unknown type shows as a message")
        let question = try #require(records.first)
        #expect(
            question.reactions == [
                Reaction(by: "Them", emoji: "sticker"), Reaction(by: "Them", emoji: "✨"),
                Reaction(by: "Me", emoji: "sticker"), Reaction(by: "Me", emoji: "•"),
            ], "sticker tapbacks net apart from emoji ones; a placed sticker attaches; 2099 shows •"
        )
        #expect(
            records[1].reactions == [Reaction(by: "Them", emoji: "sticker")],
            "Me removing a sticker does not remove Them's")
    }
}
