import Foundation
import GRDB
import Testing

@testable import LembicKit

// Bodies that do not decode are marked, and rows that are not shown are counted
// (lembickit.md F12, redaction.md F32).
@Suite("unreadable and skipped messages")
struct UnreadableMessageTests {
    private static let long =
        "This is parsing, and then a long tail of words that never made it into the blob, "
        + "so the decoder has to stop early and say so."

    private static func cut(_ text: String, keeping count: Int) throws -> Data {
        let blob = TypedStreamFixture.body(text)
        let start = try #require(blob.range(of: Data(text.utf8))).lowerBound
        return blob.prefix(upTo: start + count)
    }

    private static func render(_ blob: Data?, text: String? = nil) -> (
        text: String, hadAttachment: Bool, flags: MessageRecord.Flags
    ) {
        Extractor.renderText(
            attributedBody: blob, fallbackText: text, balloonBundleID: nil, attachments: [])
    }

    @Test func truncatedBlobIsSalvagedAndMarked() throws {
        let blob = try Self.cut(Self.long, keeping: 15)
        #expect(AttributedBody.decode(blob) == nil, "the strict decoder rejects it")
        #expect(AttributedBody.salvage(blob)?.text == "This is parsing")
        #expect(AttributedBody.salvage(blob)?.isComplete == false)
        let out = Self.render(blob)
        #expect(out.text == "This is parsing [message may be incomplete]")
        #expect(out.flags == .incomplete)
    }

    @Test func shortTruncatedBlobIsSalvaged() throws {
        let blob = try Self.cut("Short note here", keeping: 10)
        #expect(Self.render(blob).text == "Short note [message may be incomplete]")
    }

    @Test func completeStringBeforeDamageIsNotMarked() throws {
        let text = "hello there"
        let blob = TypedStreamFixture.body(text)
        let end = try #require(blob.range(of: Data(text.utf8))).upperBound
        let damaged = blob.prefix(upTo: end) + Data([0xFF, 0xFF, 0x00, 0xFF])
        let out = Self.render(damaged)
        #expect(out.text == "hello there")
        #expect(out.flags.isEmpty)
    }

    @Test func undecodableBlobUsesTextWithAMarker() {
        let out = Self.render(Data("not a typedstream".utf8), text: "older text")
        #expect(out.text == "older text [message may be incomplete]")
        #expect(out.flags == .incomplete)
    }

    @Test func nothingReadableIsAMarkerLine() {
        let out = Self.render(Data([0x04, 0x0B, 0xFF, 0xFF]))
        #expect(out.text == "[message could not be read]")
        #expect(out.flags == .unreadable)
    }

    @Test func orphanObjectMarkIsAnAttachment() {
        let out = Self.render(nil, text: "look \u{FFFC} here")
        #expect(out.text == "look [attachment] here")
        #expect(out.hadAttachment)
        let app = Extractor.renderText(
            attributedBody: nil, fallbackText: "\u{FFFC}",
            balloonBundleID: "com.apple.Handwriting.HandwritingProvider", attachments: [])
        #expect(app.text == "[handwritten message]", "an app message has no attachment row")
    }

    static let sql = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER,
            chat_identifier TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
            is_from_me INTEGER, handle_id INTEGER, text TEXT, attributedBody BLOB,
            item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0,
            associated_message_guid TEXT);
        INSERT INTO handle VALUES (3,'+18160000003');
        INSERT INTO chat VALUES (1,'iMessage;-;+18160000003',45,'+18160000003');
        INSERT INTO chat_handle_join VALUES (1,3);
        INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, text, item_type,
            associated_message_type, associated_message_guid) VALUES
            (10,'a',1000000000000,0,3,'See you Sunday',0,0,NULL),
            (11,'b',2000000000000,1,0,'Pinned: Sunday 6pm',17,0,NULL),
            (12,'c',3000000000000,1,0,NULL,17,0,NULL),
            (13,'d',4000000000000,0,3,NULL,0,0,NULL),
            (14,'e',5000000000000,0,3,'Reacted to a',0,5000,'p:0/a'),
            (15,'f',6000000000000,0,3,'Group renamed',2,0,NULL);
        INSERT INTO chat_message_join (chat_id, message_id) SELECT 1, ROWID FROM message;
        """

    @Test func unknownTypesAreMarkedOrCounted() throws {
        let queue = try Fixtures.makeInMemoryDB(populating: Self.sql)
        let extraction = try queue.read {
            try Extractor(targetHandles: [3], handleLabels: [:]).extract($0, chatIDs: [1])
        }
        #expect(
            extraction.records.map(\.text) == [
                "See you Sunday", "Pinned: Sunday 6pm [unknown message type]",
            ])
        #expect(extraction.records.last?.flags == .unknownType)
        #expect(
            extraction.skipped.map(\.reason) == [.unknownType, .emptyBody, .unknownReaction],
            "a known system event (item_type 2) is not a skip")
    }

    @Test func renderReportsSkipsInScope() throws {
        let db = try Fixtures.openChatDB(populating: Self.sql)
        defer { db.cleanUp() }
        let export = Export(database: db)
        let conversation = try #require(
            try Conversations.list(from: db, resolvingContacts: false).first)
        let all = try export.render(conversation, detect: false, resolveContacts: false)
        #expect(all.skipped.count == 3)
        let late = Date(timeIntervalSinceReferenceDate: 3500)...Date.distantFuture
        let scoped = try export.render(
            conversation, scope: Export.Scope(dateRange: late), detect: false,
            resolveContacts: false)
        #expect(scoped.skipped.map(\.reason) == [.emptyBody, .unknownReaction])
    }
}
