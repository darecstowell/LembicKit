import Foundation
import GRDB
import Testing

@testable import LembicKit

// Every line break indents like \n, and a NUL never cuts a message
// (lembickit.md F22).
@Suite("line breaks")
struct LineBreakTests {
    @Test func everyLineBreakBecomesNewline() {
        #expect(
            Extractor.normalizeLineBreaks("a\r\nb\rc\u{2028}d\u{2029}e\u{85}f")
                == "a\nb\nc\nd\ne\nf")
        #expect(Extractor.normalizeLineBreaks("a\u{0}b\u{7}c\td") == "a b c\td")
        #expect(Extractor.normalizeLineBreaks("café ’quoted’ €5") == "café ’quoted’ €5")
    }

    @Test func renderedBodyIndentsEveryLine() {
        let (text, _, _) = Extractor.renderText(
            attributedBody: nil, fallbackText: "From the stream:\r\u{FFFC}\rTo structures:",
            balloonBundleID: nil,
            attachments: [AttachmentInfo(mimeType: "image/jpeg", uti: nil, transferName: nil)])
        #expect(text == "From the stream:\n[photo]\nTo structures:")
    }

    @Test func nulDoesNotCutTheTextColumn() throws {
        let queue = try Fixtures.makeInMemoryDB(
            populating: """
                CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
                CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
                    is_from_me INTEGER, handle_id INTEGER, text TEXT);
                INSERT INTO message VALUES (1,'a',1000000000000,0,3,'before' || char(0) || 'after');
                INSERT INTO chat_message_join VALUES (1,1);
                """)
        let records = try queue.read {
            try Extractor(targetHandles: [3], handleLabels: [:]).extractConversation(
                $0, chatIDs: [1])
        }
        #expect(records.map(\.text) == ["before after"])
    }
}
