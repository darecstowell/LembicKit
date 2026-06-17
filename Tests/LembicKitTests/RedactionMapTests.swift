import Foundation
import Testing

@testable import LembicKit

// The offset-map extraction: `OffsetMap` (the redaction output↔source coordinate
// machinery) gets its own ISOLATED test surface. These construct an `OffsetMap`
// directly with synthetic source strings + replacement lists and assert the
// forward (`sourceToOutput`) / inverse (`outputToSource`) maps across the edge
// cases that can't be pinned without re-driving `compactText` end-to-end:
// identity, the +8 indentation gap, the `[redacted]` token collapse, span +
// newline interaction, and boundary clamps.
@Suite("redaction map (OffsetMap)")
struct RedactionMapTests {

    // MARK: Identity — no spans, no newlines → both maps are the identity.
    @Test func identity() {
        let src = "hello world" as NSString  // len 11, no `\n`, no redactions
        let map = OffsetMap(sourceLength: src.length, replacements: [], source: src)
        for i in 0...src.length {
            #expect(map.sourceToOutput(i) == i, "forward identity at \(i)")
            #expect(map.outputToSource(i) == i, "inverse identity at \(i)")
        }
        #expect(!map.isInsideRedaction(0), "nothing is inside a redaction")
        #expect(!map.isInsideRedaction(src.length - 1))
    }

    // MARK: Indentation shift only — each surviving `\n` inserts 8 spaces, so
    // every output index past it shifts by +8. An index inside the inserted
    // 8-space gap must CLAMP back to the segment end (the newline boundary),
    // not overshoot into the next source char.
    @Test func indentationGapClampsToNewlineBoundary() {
        let src = "a\nb" as NSString  // len 3, `\n` at index 1
        let map = OffsetMap(sourceLength: src.length, replacements: [], source: src)

        // `a` (0) and the `\n` (1) are before the insertion → no shift.
        #expect(map.sourceToOutput(0) == 0, "`a` at output 0")
        #expect(map.sourceToOutput(1) == 1, "`\\n` at output 1")
        // `b` lands after `a` + `\n` + 8 inserted spaces → +8 shift.
        #expect(map.sourceToOutput(2) == 10, "`b` shifts to output 10 (a, \\n, 8 spaces)")
        #expect(map.sourceToOutput(3) == 11, "end-of-source maps to output 11")

        // Output indices 2...9 are the inserted 8-space gap; every one of them
        // clamps back to source index 2 (the newline boundary), never into `b`.
        for out in 2...9 {
            #expect(
                map.outputToSource(out) == 2,
                "output \(out) (inside the 8-space gap) clamps to the newline boundary (src 2)")
        }
        #expect(map.outputToSource(10) == 2, "output 10 is the start of `b` (src 2)")
        #expect(map.outputToSource(11) == 3, "output 11 is end-of-source (src 3)")
    }

    // MARK: Single span redaction — a span collapses to the literal `[redacted]`
    // (10 chars). Source indices inside the span map to the token START; output
    // indices inside the token map back to the span start; indices after the
    // span shift by (tokenLen − spanLen).
    @Test func singleSpanCollapsesToToken() {
        // 12-char source, no newlines, span [2,8) (6 src chars) → 10 token chars.
        let src = "012345678901" as NSString  // len 12
        let map = OffsetMap(
            sourceLength: src.length,
            replacements: [(range: 2..<8, tokenLen: 10)],
            source: src)

        // Every source index inside the span maps to the token start (output 2).
        for s in 2..<8 {
            #expect(map.sourceToOutput(s) == 2, "src \(s) inside span → token start (output 2)")
        }
        // Every output index inside the `[redacted]` token (output [2,12)) maps
        // back to the span start (src 2).
        for out in 2..<12 {
            #expect(
                map.outputToSource(out) == 2, "output \(out) inside token → span start (src 2)")
        }

        // Indices after the span shift by (10 − 6) = +4.
        #expect(map.sourceToOutput(8) == 12, "first src after span shifts +4")
        #expect(map.sourceToOutput(12) == 16, "end-of-source shifts +4")

        #expect(map.isInsideRedaction(2), "lower bound is inside")
        #expect(map.isInsideRedaction(7), "last index is inside")
        #expect(!map.isInsideRedaction(8), "upperBound is NOT inside (half-open)")
        #expect(!map.isInsideRedaction(1), "before the span is not inside")
    }

    // MARK: Multiple spans — cumulative shifts compose; the init sorts the
    // replacements, so passing them out of order yields the same result.
    @Test func multipleSpansCompose() {
        // 20-char source. Two spans: [2,4) (2 chars → 10) and [10,12) (2 → 10).
        let src = "01234567890123456789" as NSString  // len 20
        let unsorted: [(range: Range<Int>, tokenLen: Int)] = [
            (range: 10..<12, tokenLen: 10), (range: 2..<4, tokenLen: 10),
        ]
        let map = OffsetMap(sourceLength: src.length, replacements: unsorted, source: src)

        // After span 1: shift +8 (10 − 2). After span 2: shift +16 total.
        #expect(map.sourceToOutput(0) == 0, "before any span: no shift")
        #expect(map.sourceToOutput(4) == 12, "after span 1: +8 (4 → 12)")
        #expect(map.sourceToOutput(12) == 28, "after both spans: +16 (12 → 28)")
        #expect(map.sourceToOutput(20) == 36, "end shifts by both deltas (+16)")

        // Both spans collapse correctly regardless of input order: each source
        // index inside a span maps to that span's token start (output 2 and 18).
        #expect(map.sourceToOutput(3) == 2, "src in span 1 → its token start (output 2)")
        #expect(map.sourceToOutput(11) == 18, "src in span 2 → its token start (output 18)")
    }

    // MARK: Span + newline interaction — a span that straddles a `\n` swallows
    // the newline (those chars are gone), so the +8 indent does NOT apply for
    // them. The post-span mapping and total length must account for the span
    // having eaten the newline.
    @Test func spanSwallowsNewline() {
        // "ab\ncd" len 5, `\n` at index 2. Redact [1,4) → swallows the `\n`.
        let src = "ab\ncd" as NSString  // len 5
        let map = OffsetMap(
            sourceLength: src.length,
            replacements: [(range: 1..<4, tokenLen: 10)],
            source: src)

        // emitPlain(0,1): `a` → output [0,1). Redacted [1,4) → output [1,11)
        // (token, 10 chars). emitPlain(4,5): `d` → output 11. No +8 anywhere
        // because the only `\n` lived inside the collapsed span.
        #expect(map.sourceToOutput(0) == 0, "`a` at output 0")
        #expect(
            map.sourceToOutput(2) == 1, "the swallowed `\\n` maps to the token start (output 1)")
        #expect(map.sourceToOutput(4) == 11, "`d` lands right after the token, NO +8 indent")
        #expect(map.sourceToOutput(5) == 12, "end-of-source at output 12")

        // The newline was consumed by the redaction → still reported inside it.
        #expect(map.isInsideRedaction(2), "the swallowed `\\n` is inside the redaction")
        // An output index inside the token maps back to the span start (src 1).
        #expect(map.outputToSource(5) == 1, "output inside token → span start (src 1)")
    }

    // MARK: Boundary clamps — negative / past-end inputs clamp to [0, end] on
    // the forward map; past-the-sentinel inputs resolve to `sourceLength` on the
    // inverse map. Exercised on an identity map (no transforms).
    @Test func boundaryClamps() {
        let src = "0123456789" as NSString  // len 10, identity
        let map = OffsetMap(sourceLength: src.length, replacements: [], source: src)

        // Forward: clamp(src) = max(0, min(src, len)).
        #expect(map.sourceToOutput(-1) == 0, "negative source clamps to output 0")
        #expect(map.sourceToOutput(-100) == 0, "far-negative source clamps to 0")
        #expect(map.sourceToOutput(0) == 0, "offset at 0")
        #expect(map.sourceToOutput(10) == 10, "offset at end")
        #expect(map.sourceToOutput(15) == 10, "beyond end clamps to len")
        #expect(map.sourceToOutput(1_000) == 10, "far-beyond clamps to len")

        // Inverse: anything at/past the terminal sentinel resolves to len.
        #expect(map.outputToSource(0) == 0, "output 0 → src 0")
        #expect(map.outputToSource(10) == 10, "output at end → src len")
        #expect(map.outputToSource(11) == 10, "output past end → src len (sentinel)")
        #expect(map.outputToSource(1_000) == 10, "far-past clamps to len")
    }

    // MARK: Round-trip composition — for a NON-redacted source index the inverse
    // recovers it exactly; for a REDACTED index the round-trip is LOSSY BY
    // DESIGN (it lands on the span start, not the original index).
    @Test func roundTripIsLossyOnlyInsideRedactions() {
        let src = "0123456789ABCDEF" as NSString  // len 16
        let map = OffsetMap(
            sourceLength: src.length,
            replacements: [(range: 4..<8, tokenLen: 10)],
            source: src)

        // Non-redacted indices round-trip exactly.
        for i in [0, 1, 2, 3, 8, 9, 15, 16] {
            #expect(
                map.outputToSource(map.sourceToOutput(i)) == i,
                "non-redacted src \(i) round-trips exactly")
        }
        // Indices inside the redacted span collapse to the span start (lossy).
        for i in 4..<8 {
            #expect(
                map.outputToSource(map.sourceToOutput(i)) == 4,
                "redacted src \(i) round-trips to the span start (4) — lossy by design")
        }
    }
}
