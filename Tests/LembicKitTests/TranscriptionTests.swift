import Foundation
import Testing

@testable import LembicKit

@Suite("voice note transcription")
struct TranscriptionTests {
    private let audio = AttachmentInfo(
        mimeType: "audio/x-m4a", uti: "com.apple.m4a-audio", transferName: "Audio Message.caf")

    @Test func attributeRunsAreRead() {
        let blob = TypedStreamFixture.body([
            ("Hi ", ["__kIMMessagePartAttributeName": 0]),
            (
                "\u{FFFC}",
                [
                    "__kIMMessagePartAttributeName": 1,
                    "__kIMFileTransferGUIDAttributeName": "at_1_AAA",
                    "IMAudioTranscription": "This is a test",
                ]
            ),
            (" ok \u{FFFC}", ["__kIMMessagePartAttributeName": 2]),
        ])
        let body = AttributedBody.parse(blob)
        #expect(body?.text == "Hi \u{FFFC} ok \u{FFFC}")
        #expect(
            body?.objects == [
                [
                    "__kIMFileTransferGUIDAttributeName": "at_1_AAA",
                    "IMAudioTranscription": "This is a test",
                ],
                [:],
            ])
        #expect(AttributedBody.decode(blob) == "Hi \u{FFFC} ok \u{FFFC}")
    }

    @Test func transcriptionRendersWithTheAudioToken() {
        let blob = TypedStreamFixture.body([
            ("\u{FFFC}", ["IMAudioTranscription": "This is\na test "])
        ])
        let (text, hadAttachment) = Extractor.renderText(
            attributedBody: blob, fallbackText: nil, balloonBundleID: nil, attachments: [audio])
        #expect(text == "[audio: \"This is a test\"]")
        #expect(hadAttachment)
    }

    @Test func audioWithoutTranscriptionStaysPlain() {
        let blob = TypedStreamFixture.body("\u{FFFC}")
        let (text, _) = Extractor.renderText(
            attributedBody: blob, fallbackText: nil, balloonBundleID: nil, attachments: [audio])
        #expect(text == "[audio]")
    }
}
