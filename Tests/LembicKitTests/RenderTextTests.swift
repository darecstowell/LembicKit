import Foundation
import Testing

@testable import LembicKit

@Suite("render text")
struct RenderTextTests {
    private func render(
        _ raw: String?, _ attachments: [AttachmentInfo] = [], balloon: String? = nil
    ) -> (String, Bool) {
        Extractor.renderText(
            attributedBody: nil, fallbackText: raw, balloonBundleID: balloon,
            attachments: attachments)
    }

    @Test func renderText() {
        let photo = AttachmentInfo(mimeType: "image/jpeg", uti: nil, transferName: nil)
        let preview = AttachmentInfo(
            mimeType: nil, uti: nil, transferName: "p.pluginPayloadAttachment")

        #expect(render("hello world") == ("hello world", false), "plain text")
        #expect(
            render("look \u{FFFC} here", [photo]) == ("look [photo] here", true),
            "placeholder spliced at U+FFFC")
        #expect(
            render("https://x.co \u{FFFC}", [preview]) == ("https://x.co", false),
            "dropped preview leaves no placeholder")
        #expect(
            render("caption", [photo]) == ("caption [photo]", true),
            "leftover placeholder appended")
        #expect(
            render("  a \t b  \n   c   ") == ("a b\nc", false), "whitespace collapsed per line")
        #expect(
            render(nil, [], balloon: "com.apple.findmy.FindMyMessagesApp") == (
                "[shared location]", false
            ), "FindMy balloon")
        #expect(render(nil) == ("", false), "empty stays empty")
    }
}
