import Foundation
import GRDB
import Testing

@testable import LembicKit

// An unsend leaves a marker, and the unsent text never surfaces (lembickit.md F23).
@Suite("unsent messages")
struct UnsentTests {
    private static func summaryInfo(_ parts: [Int]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["rp": parts, "otr": [:]], format: .binary, options: 0)
    }

    private static let photo = AttachmentInfo(
        mimeType: "image/jpeg", uti: "public.jpeg", transferName: "a.jpeg", guid: "PHOTO")

    private static let twoParts = TypedStreamFixture.body([
        ("Look at this", ["__kIMMessagePartAttributeName": 0]),
        (
            "\u{FFFC}",
            [
                "__kIMMessagePartAttributeName": 1,
                "__kIMFileTransferGUIDAttributeName": "at_1_PHOTO",
            ]
        ),
    ])

    @Test func unsentPartsAreRead() throws {
        #expect(Extractor.unsentParts(try Self.summaryInfo([0, 2])) == [0, 2])
        #expect(Extractor.unsentParts(nil).isEmpty)
        #expect(Extractor.unsentParts(Data("junk".utf8)).isEmpty)
    }

    @Test func partlyUnsentKeepsTheRest() {
        let out = Extractor.renderText(
            attributedBody: Self.twoParts, fallbackText: nil, balloonBundleID: nil,
            attachments: [Self.photo], unsentParts: [0])
        #expect(out.text == "[photo] [part of this message was unsent]")
        #expect(out.flags == .partlyUnsent)

        let photoGone = Extractor.renderText(
            attributedBody: Self.twoParts, fallbackText: nil, balloonBundleID: nil,
            attachments: [Self.photo], unsentParts: [1])
        #expect(photoGone.text == "Look at this [part of this message was unsent]")
    }

    @Test func everyPartUnsentIsOneMarker() {
        let out = Extractor.renderText(
            attributedBody: Self.twoParts, fallbackText: "Look at this",
            balloonBundleID: nil, attachments: [Self.photo], unsentParts: [0, 1])
        #expect(out.text == "[unsent a message]")
        #expect(out.flags == .unsent)
    }

    @Test func partsThatCannotBeFoundHideTheWholeBody() {
        let out = Extractor.renderText(
            attributedBody: TypedStreamFixture.body("no part runs here"),
            fallbackText: "no part runs here", balloonBundleID: nil, attachments: [],
            unsentParts: [0])
        #expect(out.text == "[unsent a message]", "fail safe: never show text that may be unsent")
    }

    @Test func rpWithoutDateRetractedIsUnsent() throws {
        let info = try Self.summaryInfo([0])
        let queue = try Fixtures.makeInMemoryDB(
            populating: """
                CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
                CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
                    is_from_me INTEGER, handle_id INTEGER, text TEXT, attributedBody BLOB,
                    date_retracted INTEGER DEFAULT 0, message_summary_info BLOB);
                INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, text) VALUES
                    (1,'a',1000000000000,1,0,NULL);
                INSERT INTO chat_message_join VALUES (1,1);
                """)
        try queue.write {
            try $0.execute(
                sql: "UPDATE message SET message_summary_info = ? WHERE ROWID = 1",
                arguments: [info])
        }
        let records = try queue.read {
            try Extractor(targetHandles: [3], handleLabels: [:]).extractConversation(
                $0, chatIDs: [1])
        }
        #expect(records.map(\.text) == ["[unsent a message]"])
    }
}
