import Foundation
import Testing

@testable import LembicKit

@Suite("body splice")
struct BodySpliceTests {
    private func redaction(_ r: Range<Int>) -> BodySplice.Substitution {
        BodySplice.Substitution(range: r, token: "[redacted]", isRedaction: true)
    }

    private func alias(_ r: Range<Int>, _ token: String) -> BodySplice.Substitution {
        BodySplice.Substitution(range: r, token: token, isRedaction: false)
    }

    /// The indented output body and its map, as `compactText` builds them.
    private func render(_ text: String, _ reps: [BodySplice.Substitution]) -> (NSString, OffsetMap)
    {
        let source = text as NSString
        let body = BodySplice.apply(to: source, reps)
            .replacingOccurrences(of: "\n", with: "\n        ")
        return (body as NSString, BodySplice.offsetMap(source: source, reps))
    }

    /// Every source unit outside a substitution maps to the same unit in the output and back.
    private func expectRoundTrip(_ text: String, _ reps: [BodySplice.Substitution]) {
        let source = text as NSString
        let (output, map) = render(text, reps)
        #expect(map.sourceToOutput(source.length) == output.length)
        #expect(map.outputToSource(output.length) == source.length)
        for i in 0..<source.length where !reps.contains(where: { $0.range.contains(i) }) {
            let o = map.sourceToOutput(i)
            #expect(output.character(at: o) == source.character(at: i), "unit \(i) of \(text)")
            #expect(map.outputToSource(o) == i, "round trip at \(i) of \(text)")
        }
        for rep in reps {
            let o = map.sourceToOutput(rep.range.lowerBound)
            let len = (rep.token as NSString).length
            #expect(output.substring(with: NSRange(location: o, length: len)) == rep.token)
            #expect(map.outputToSource(o) == rep.range.lowerBound)
        }
    }

    @Test func roundTripsAcrossMultiByteText() {
        let text = "héllo 👋🏽 secret 4111\nnext 🇺🇸 line ✓"
        let ns = text as NSString
        let secret = ns.range(of: "secret 4111")
        let flag = ns.range(of: "🇺🇸")
        #expect(flag.length == 4, "a flag is two surrogate pairs")
        expectRoundTrip(text, [])
        expectRoundTrip(text, [redaction(Range(secret)!)])
        expectRoundTrip(text, [redaction(Range(secret)!), alias(Range(flag)!, "P2")])
    }

    @Test func roundTripsWhenATokenIsLongerOrShorterThanItsSpan() {
        expectRoundTrip("ab\ncd ef", [redaction(0..<1), alias(6..<8, "P10")])
        expectRoundTrip("Sarah Chen\nsaid hi", [alias(0..<10, "P2")])
    }

    @Test func adjacentSpansMergeIntoOneToken() {
        let merged = BodySplice.mergedRedactions([4..<6, 2..<4])
        #expect(merged.map(\.range) == [2..<6])
        #expect(BodySplice.apply(to: "abcdefgh", merged) == "ab[redacted]gh")
        expectRoundTrip("abcdefgh", merged)
    }

    @Test func overlappingAndNestedSpansMergeIntoOneToken() {
        #expect(BodySplice.mergedRedactions([2..<6, 4..<9]).map(\.range) == [2..<9])
        #expect(BodySplice.mergedRedactions([1..<9, 3..<4]).map(\.range) == [1..<9])
        #expect(BodySplice.mergedRedactions([0..<2, 5..<7]).map(\.range) == [0..<2, 5..<7])
    }

    @Test func dedupKeepsTheEarlierListedOnOverlap() {
        let kept = BodySplice.deduped([redaction(4..<9), alias(0..<5, "P2"), alias(4..<6, "P3")])
        #expect(kept.map(\.range) == [0..<5], "the alias starts first, so it wins the overlap")
        let tie = BodySplice.deduped([redaction(0..<5), alias(0..<5, "P2"), alias(6..<9, "P3")])
        #expect(tie.map(\.token) == ["[redacted]", "P3"], "a tie keeps the redaction")
    }

    @Test func adjacentRedactionAndAliasBothSplice() {
        let reps = [redaction(5..<9), alias(0..<5, "P2")]
        let kept = BodySplice.deduped(reps)
        #expect(BodySplice.apply(to: "Sarah1234 ok", kept) == "P2[redacted] ok")
        expectRoundTrip("Sarah1234 ok", kept)
    }

    @Test func normalizedHitMapsBackToSource() {
        let source = "pin １２３４ ok"
        let normalized = TextNormalizer.normalize(source)
        let hit = normalized.text.range(of: "1234")
        #expect(hit.location != NSNotFound)
        let back = normalized.sourceRange(hit).map {
            (source as NSString).substring(with: NSRange($0))
        }
        #expect(back == "１２３４")
    }

    @Test func publicBodyHelpersShareTheSplice() {
        let rec = Fixtures.redRec("g0", 0, "Them", "Sarah: card 4111 ok")
        var set = RedactionSet()
        set.add(Redaction(guid: "g0", range: 12..<16))
        let direct = BodySplice.body(of: rec, redactions: set, names: nil, stripPlaceholders: false)
        #expect(direct == "Sarah: card [redacted] ok")
        #expect(Transcript.redactedText(of: rec, redactions: set) == direct)
        #expect(Transcript.renderedBody(of: rec, redactions: set, aliases: [:]) == direct)
        var whole = RedactionSet()
        whole.add(Redaction(guid: "g0", range: nil))
        #expect(Transcript.redactedText(of: rec, redactions: whole) == nil)
        #expect(Transcript.renderedBody(of: rec, redactions: whole, aliases: [:]) == nil)
    }
}
