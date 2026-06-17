import Foundation
import Testing

@testable import LembicKit

@Suite("attachment placeholders")
struct AttachmentTests {
    private func placeholder(_ mime: String?, _ uti: String?, _ name: String? = nil) -> String? {
        AttachmentInfo(mimeType: mime, uti: uti, transferName: name).placeholder
    }

    @Test func placeholders() {
        #expect(placeholder("image/gif", nil) == "[gif]", "gif by mime")
        #expect(placeholder(nil, "com.compuserve.gif") == "[gif]", "gif by uti")
        #expect(placeholder("image/jpeg", "public.jpeg") == "[photo]", "photo by mime")
        #expect(placeholder(nil, "public.heic") == "[photo]", "photo by uti")
        #expect(placeholder("video/mp4", nil) == "[video]", "video by mime")
        #expect(placeholder(nil, "com.apple.quicktime-movie") == "[video]", "video by uti")
        #expect(placeholder("application/pdf", nil) == "[pdf]", "pdf")
        #expect(placeholder("text/vcard", nil) == "[contact]", "contact by mime")
        #expect(placeholder(nil, nil, "card.vcf") == "[contact]", "contact by extension")
        #expect(placeholder("audio/amr", nil) == "[audio]", "audio")
        #expect(placeholder("application/zip", nil) == "[attachment]", "generic fallback")
        #expect(
            placeholder("image/png", nil, "x.pluginPayloadAttachment") == nil,
            "rich-link preview dropped")
    }
}
