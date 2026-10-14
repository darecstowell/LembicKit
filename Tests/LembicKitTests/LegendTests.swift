import Foundation
import Testing

@testable import LembicKit

// The legend lists the placeholders that occur, the header does not claim
// iMessage, and JSONL services read plainly (lembickit.md F25).
@Suite("legend and header")
struct LegendTests {
    @Test func legendListsOnlyTokensThatOccur() {
        #expect(
            Transcript.legendTokens(in: [
                "look [photo]", "[audio: \"on my way\"]", "[genmoji: pink poodle] hi",
                "[attachment]", "plain text",
            ]) == ["[photo]", "[audio]", "[genmoji: …]", "[attachment]"])
        #expect(Transcript.legendTokens(in: ["no attachments at all"]).isEmpty)
    }

    @Test func headerSaysMessagesAndOmitsAnEmptyLegend() {
        let record = MessageRecord(
            guid: "a", date: Date(timeIntervalSince1970: 1_700_000_000), speaker: "Them",
            isTarget: true, service: "SMS", text: "Your package was delivered.",
            hadAttachment: false, reactions: [])
        let text = Transcript.compactText(
            records: [record], number: "72975", redactions: RedactionSet(), detected: []
        ).text
        #expect(text.hasPrefix("# Messages transcript with 72975\n"))
        #expect(!text.contains("# Attachments shown"))
    }

    @Test func servicesReadPlainly() {
        #expect(Transcript.serviceLabel("iMessage") == nil)
        #expect(Transcript.serviceLabel("iMessageLite") == "iMessage via satellite")
        #expect(Transcript.serviceLabel("SMS") == "SMS")
        #expect(Transcript.serviceLabel("RCS") == "RCS")
    }

    @Test func trimStripsGenmojiButKeepsVoiceNoteWords() {
        #expect(Transcript.stripPlaceholders("hi [genmoji: cat in a top hat] there") == "hi there")
        #expect(Transcript.stripPlaceholders("[audio: \"on my way\"]") == "[audio: \"on my way\"]")
    }
}
