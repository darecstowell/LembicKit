import Foundation
import Testing

@testable import LembicKit

// Over-budget fidelity trims.
@Suite("transcript trim")
struct TranscriptTrimTests {
    private let recs = [
        Fixtures.rec(
            0, "Them", "hey [photo]", attach: true, reacts: [Reaction(by: "Me", emoji: "❤️")]),
        // attachment-only: nothing left once stripped
        Fixtures.rec(1, "Me", "[photo]", attach: true),
        Fixtures.rec(2, "Them", "ok"),
    ]

    // The one surviving renderer (the redaction-aware overload), called with
    // empty sets — the plain `compactText(records:number:trim:)` overload was
    // deleted in the renderer collapse, so these trim assertions now run
    // through it. `.text` gives the same string the old overload returned.
    private func render(_ trim: Transcript.TrimOptions = .none) -> String {
        Transcript.compactText(
            records: recs, number: "+1", trim: trim,
            redactions: RedactionSet(), detected: []
        ).text
    }

    @Test func trims() {
        // Default path is byte-identical to .none (the validated reference).
        #expect(render() == render(.none), "default render == trim .none")

        let full = render()
        #expect(
            full.contains("# Reactions shown as") && full.contains("# Attachments shown as"),
            "full render keeps both legend lines")
        #expect(
            full.contains("hey [photo]") && full.contains("[Me: ❤️]"),
            "full render keeps placeholders + reactions")
        #expect(full.contains("3 messages"), "full render counts all 3 messages")

        let noReacts = render(.init(dropReactions: true))
        #expect(
            !noReacts.contains("❤️") && !noReacts.contains("# Reactions shown as"),
            "dropReactions removes suffixes + reaction legend")
        #expect(noReacts.contains("hey [photo]"), "dropReactions leaves attachments untouched")

        let noAttach = render(.init(dropAttachmentPlaceholders: true))
        #expect(
            !noAttach.contains("[photo]") && !noAttach.contains("# Attachments shown as"),
            "dropAttachmentPlaceholders removes markers + attachment legend")
        #expect(
            noAttach.contains("[Me: ❤️]"),
            "dropAttachmentPlaceholders leaves reactions untouched")
        #expect(
            noAttach.contains("hey") && noAttach.contains("2 messages"),
            "caption kept, attachment-only message dropped (3 → 2)")
    }
}
