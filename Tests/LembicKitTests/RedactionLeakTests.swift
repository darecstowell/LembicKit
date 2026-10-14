import Foundation
import Testing

@testable import LembicKit

// Leak paths from the redaction audit: a value the user redacted, or told Lembic
// to remove, must not reach any output.
@Suite("redaction leak paths")
struct RedactionLeakTests {
    private let card = "4111 1111 1111 1111"

    private func rec(
        _ guid: String, _ s: Int, _ speaker: String, _ text: String, attach: Bool = false
    ) -> MessageRecord {
        Fixtures.attachRec(guid, s, speaker, text, attach: attach)
    }

    private func redactAll(_ detected: [DetectedSecret]) -> RedactionSet {
        var set = RedactionSet()
        for d in detected { set.add(Redaction(guid: d.guid, range: d.range)) }
        return set
    }

    private var trimScope: Export.Scope {
        var scope = Export.Scope()
        scope.trim = .init(dropAttachmentPlaceholders: true)
        return scope
    }

    // MARK: - F1: attachment trim and redaction offsets

    @Test("trim on: Redact All hides the card in TXT and in the prepared records")
    func trimKeepsRedactionOffsets() {
        let rs = [
            rec("a1", 0, "Them", "[photo] my card is \(card)", attach: true),
            rec("a2", 1, "Them", "[photo] card \(card) thanks for dinner tonight", attach: true),
        ]
        let first = Export.render(records: rs, number: "+15555550100", formats: [.txt])
        #expect(first.detected.count == 2)
        let set = redactAll(first.detected)
        for scope in [trimScope, Export.Scope()] {
            let out = Export.render(
                records: rs, number: "+15555550100", formats: [.txt, .jsonl], scope: scope,
                redactions: set)
            let txt = out.txt ?? ""
            #expect(!txt.contains("1111"), "TXT hides the card (trim \(scope.trim.isActive))")
            #expect(!(out.jsonl ?? "").contains("1111"))
            #expect(txt.contains("my card is [redacted]"))
            #expect(txt.contains("card [redacted] thanks for dinner tonight"))
            #expect(out.result?.highlightMarks.isEmpty == true)
            let pro = Export.preparedRedactedRecords(rs, scope: scope, redactions: set)
            #expect(!pro.map(\.text).joined().contains("1111"))
        }
        let trimmedPro = Export.preparedRedactedRecords(rs, scope: trimScope, redactions: set)
        #expect(
            trimmedPro.map(\.text)
                == ["my card is [redacted]", "card [redacted] thanks for dinner tonight"])
    }

    @Test("trim on: a still-visible secret is counted and highlighted on the right text")
    func trimHighlightsTheSecret() throws {
        let rs = [rec("h1", 0, "Them", "[photo] [video] my card is \(card) ok", attach: true)]
        let out = Export.render(records: rs, number: "+1", formats: [.txt], scope: trimScope)
        let result = try #require(out.result)
        #expect(result.highlightMarks.count == 1)
        let mark = try #require(result.highlightMarks.first)
        #expect((result.text as NSString).substring(with: mark.outputRange) == card)
    }

    @Test("trim on: a selection anchors to source offsets, so every output hides it")
    func trimSelectionAnchorsToSource() throws {
        let rs = [rec("t1", 0, "Them", "[photo] call me at 816-555-0123 tonight", attach: true)]
        let shown = Export.render(records: rs, number: "x", formats: [.txt], scope: trimScope)
        let result = try #require(shown.result)
        let selection = (result.text as NSString).range(of: "816-555-0123")
        let reds = result.redactions(forSelectedOutput: selection)
        #expect(reds.map(\.range) == [19..<31])
        var set = RedactionSet()
        for r in reds { set.add(r) }
        let trimmed = Export.render(
            records: rs, number: "x", formats: [.txt, .jsonl], scope: trimScope, redactions: set)
        let untrimmed = Export.render(records: rs, number: "x", formats: [.txt], redactions: set)
        for text in [trimmed.txt, trimmed.jsonl, untrimmed.txt] {
            #expect(!(text ?? "").contains("555"))
        }
        #expect((trimmed.txt ?? "").contains("Them: call me at [redacted] tonight"))
        #expect((untrimmed.txt ?? "").contains("Them: [photo] call me at [redacted] tonight"))
    }

    @Test("the source-offset strip gives the same text as the old string strip")
    func stripMatchesTheOldStrip() {
        func oldStrip(_ s: String) -> String {
            var out = s
            for token in Transcript.placeholderTokens {
                out = out.replacingOccurrences(of: token, with: " ")
            }
            return Extractor.collapseSpaceRuns(out)
                .trimmingCharacters(in: Extractor.pythonWhitespace)
        }
        let samples = [
            "hey [photo]", "[photo]", "[photo] [video]", "  [photo]  hi  there  ", "a[photo]b",
            "[photo]\nnext line", "line one\n[photo] two", "x\t[gif]\ty", "[shared location]",
            "caption [pdf] and [audio] mid", "no tokens here", "two  spaces", "", " ",
            "\u{2028}[photo]\u{2028}", "emoji 🎉[photo]🎉 ok", "[photo][photo]x[photo]",
            "tail space [contact] ", "\n\n[attachment]\n\n",
        ]
        for s in samples {
            #expect(
                Transcript.stripPlaceholders(s) == oldStrip(s), "strip of \(s.debugDescription)")
        }
    }
}
