import Foundation

/// Forward/inverse offset map for ONE message body, source-`text` UTF-16
/// index ↔ output-body UTF-16 index (output-body = offsets relative to the
/// start of the rendered body, BEFORE the `"HH:mm Speaker: "` prefix is
/// added). Built by simulating both transforms once and recording each
/// breakpoint's cumulative output position, so lookups are O(log n) (or a
/// short linear scan) with no re-encoding.
///
/// Two transforms, applied in pipeline order, are modelled exactly:
///   (a) span redaction: each source `[start,end)` collapses to the literal
///       `[redacted]`. Any source index inside a replaced span maps to the
///       token's start; indices after it shift by (tokenLen − spanLen).
///   (b) `\n` → `\n` + 8 spaces: each surviving newline inserts 8 spaces
///       immediately after it, so every output index past it shifts by +8.
/// Both are folded into the breakpoint table, so `outStart` is the TRUE
/// output-body position and no caller needs to re-count newlines.
/// (Attachment-trim is intentionally NOT modelled — see the trim ruling in
/// `compactText`; trim+redaction overlap is best-effort for now. Concretely:
/// detected-secret highlight (and redaction) offsets are computed against the
/// UNTRIMMED message text, so under `dropAttachmentPlaceholders` a highlight or
/// redaction can be mis-positioned when an attachment placeholder is stripped
/// from the same message ahead of the secret. A deferred fast-follow will unify
/// the trim coordinate space.)
///
/// Extracted from the transcript renderer (the offset-map extraction) so the
/// redaction-coordinate math has its own isolated test surface (`RedactionMapTests`).
struct OffsetMap: Sendable {
    /// One contiguous span of source indices that maps affinely (slope 1)
    /// to output, plus the redacted spans which collapse to a point. A
    /// surviving `\n` ends one plain segment and starts the next 8 further
    /// along in output (the inserted indentation lands between them).
    private struct Seg: Sendable {
        let srcStart: Int  // first source index of this segment
        let srcEnd: Int  // one-past-last source index
        let outStart: Int  // output index srcStart maps to
        let isRedacted: Bool  // true → whole segment collapses to outStart (the token start)
    }
    private let segs: [Seg]
    private let redactedSourceRanges: [Range<Int>]
    let sourceLength: Int

    init(
        sourceLength: Int, replacements: [(range: Range<Int>, tokenLen: Int)], source: NSString
    ) {
        self.sourceLength = sourceLength
        self.redactedSourceRanges = replacements.map(\.range)
        var segs: [Seg] = []
        var srcCursor = 0
        var outCursor = 0

        // Emit a plain run [a,b) of source, splitting at each surviving `\n`
        // so the +8 indentation insertion becomes an exact output jump.
        func emitPlain(_ a: Int, _ b: Int) {
            var s = a
            while s < b {
                // Find next newline in [s,b).
                var nl = -1
                var k = s
                while k < b {
                    if source.character(at: k) == 0x0A {
                        nl = k
                        break
                    }
                    k += 1
                }
                if nl < 0 {
                    segs.append(
                        Seg(srcStart: s, srcEnd: b, outStart: outCursor, isRedacted: false))
                    outCursor += (b - s)
                    s = b
                } else {
                    // Include the newline itself in this segment, then jump +8.
                    let end = nl + 1
                    segs.append(
                        Seg(srcStart: s, srcEnd: end, outStart: outCursor, isRedacted: false))
                    outCursor += (end - s) + 8  // the 8 inserted spaces follow the \n
                    s = end
                }
            }
        }

        for r in replacements.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if srcCursor < r.range.lowerBound {
                emitPlain(srcCursor, r.range.lowerBound)
                srcCursor = r.range.lowerBound
            }
            // Replaced span collapses to a point token (no newline expansion
            // inside — those characters are gone, replaced by the literal).
            segs.append(
                Seg(
                    srcStart: r.range.lowerBound, srcEnd: r.range.upperBound,
                    outStart: outCursor, isRedacted: true))
            outCursor += r.tokenLen
            srcCursor = r.range.upperBound
        }
        if srcCursor < sourceLength { emitPlain(srcCursor, sourceLength) }
        // Terminal sentinel so lookups past the end resolve cleanly.
        segs.append(
            Seg(
                srcStart: sourceLength, srcEnd: sourceLength, outStart: outCursor,
                isRedacted: false))
        self.segs = segs
    }

    /// True if a source index falls inside any replaced span.
    func isInsideRedaction(_ src: Int) -> Bool {
        redactedSourceRanges.contains { $0.contains(src) }
    }

    /// Source UTF-16 index → output-body UTF-16 index. (Forward map.)
    func sourceToOutput(_ src: Int) -> Int {
        let clamped = max(0, min(src, sourceLength))
        // Last segment whose srcStart <= clamped.
        var seg = segs[0]
        for s in segs where s.srcStart <= clamped { seg = s }
        if seg.isRedacted {
            // Anywhere inside (or at the start of) a redacted span maps to the token start.
            return seg.outStart
        }
        return seg.outStart + (clamped - seg.srcStart)  // affine within a plain segment
    }

    /// Output-body UTF-16 index → source UTF-16 index. (Inverse map.)
    func outputToSource(_ out: Int) -> Int {
        // Last segment whose outStart <= out.
        var seg = segs[0]
        var idx = 0
        for (i, s) in segs.enumerated() where s.outStart <= out {
            seg = s
            idx = i
        }
        if seg.isRedacted {
            // Selection landed inside a `[redacted]` token; map to its span start.
            return seg.srcStart
        }
        // Plain run: slope 1, but clamp to the segment's own output extent so
        // an index inside the inserted 8-space gap (or past the segment) maps
        // to the segment end rather than overshooting into the next source.
        let segOutLen = seg.srcEnd - seg.srcStart
        let within = min(out - seg.outStart, segOutLen)
        let nextSrc = idx + 1 < segs.count ? segs[idx + 1].srcStart : sourceLength
        return min(seg.srcStart + within, nextSrc)
    }
}
