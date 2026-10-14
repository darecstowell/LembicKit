import Foundation
import Testing

@testable import LembicKit

// Each U+FFFC pairs with the attachment its transfer GUID names, not the next
// one in join order (lembickit.md F16).
@Suite("attachment order")
struct AttachmentOrderTests {
    private let photo = AttachmentInfo(
        mimeType: "image/jpeg", uti: "public.jpeg", transferName: "view.jpeg",
        guid: "at_1_PHOTO-GUID")
    private let pdf = AttachmentInfo(
        mimeType: "application/pdf", uti: "com.adobe.pdf", transferName: "lease.pdf",
        guid: "PDF-GUID")

    private func body(_ first: String, _ second: String) -> Data {
        let mark = "__kIMFileTransferGUIDAttributeName"
        return TypedStreamFixture.body([
            ("Lease: ", [:]), ("\u{FFFC}", [mark: first]), (" and the view: ", [:]),
            ("\u{FFFC}", [mark: second]),
        ])
    }

    private func render(_ blob: Data, _ attachments: [AttachmentInfo]) -> String {
        Extractor.renderText(
            attributedBody: blob, fallbackText: nil, balloonBundleID: nil,
            attachments: attachments
        ).text
    }

    @Test func guidBeatsJoinOrder() {
        #expect(
            render(body("at_0_PDF-GUID", "at_1_PHOTO-GUID"), [photo, pdf])
                == "Lease: [pdf] and the view: [photo]")
    }

    @Test func unknownGUIDFallsBackToOrder() {
        #expect(
            render(body("at_0_NOPE", "at_1_ALSO-NOPE"), [photo, pdf])
                == "Lease: [photo] and the view: [pdf]")
    }

    @Test func prefixesOnEitherSideMatch() {
        #expect(photo.matches(transferGUID: "PHOTO-GUID"))
        #expect(pdf.matches(transferGUID: "at_3_PDF-GUID"))
        #expect(!pdf.matches(transferGUID: "PHOTO-GUID"))
    }
}
