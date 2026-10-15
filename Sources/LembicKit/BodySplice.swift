import Foundation

/// One message body's splice: substitutions in source UTF-16 offsets, the map from
/// source to output body (`OffsetMap`), and the map from normalized text to source.
enum BodySplice {
    /// A half-open UTF-16 source range and the token it collapses to. Only a redaction
    /// gets an undo mark or hides a detected-secret highlight; an alias or a strip does not.
    struct Substitution {
        let range: Range<Int>
        let token: String
        let isRedaction: Bool
    }

    /// Two half-open ranges intersect.
    static func rangesOverlap(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }

    /// An ascending, non-overlapping set (the `OffsetMap` precondition). On a
    /// conflict the earlier-listed substitution wins, so callers list redactions first.
    static func deduped(_ reps: [Substitution]) -> [Substitution] {
        var kept: [Substitution] = []
        // Stable by start; ties keep input order (redactions precede aliases).
        for rep in reps.enumerated().sorted(by: {
            $0.element.range.lowerBound != $1.element.range.lowerBound
                ? $0.element.range.lowerBound < $1.element.range.lowerBound
                : $0.offset < $1.offset
        }).map(\.element) where !kept.contains(where: { rangesOverlap($0.range, rep.range) }) {
            kept.append(rep)
        }
        return kept
    }

    /// Splice pre-clamped, non-overlapping substitutions into `body`, last first so
    /// earlier ranges do not shift.
    static func apply(to body: NSString, _ replacements: [Substitution]) -> String {
        guard !replacements.isEmpty else { return body as String }
        let mutable = NSMutableString(string: body)
        for rep in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            mutable.replaceCharacters(
                in: NSRange(
                    location: rep.range.lowerBound,
                    length: rep.range.upperBound - rep.range.lowerBound),
                with: rep.token)
        }
        return mutable as String
    }

    /// Overlapping or touching spans merged into one `[redacted]` substitution each.
    static func mergedRedactions(_ spans: [Range<Int>]) -> [Substitution] {
        var out: [Substitution] = []
        for sp in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, sp.lowerBound <= last.range.upperBound {
                let merged = last.range.lowerBound..<Swift.max(last.range.upperBound, sp.upperBound)
                out[out.count - 1] = Substitution(
                    range: merged, token: "[redacted]", isRedaction: true)
            } else {
                out.append(Substitution(range: sp, token: "[redacted]", isRedaction: true))
            }
        }
        return out
    }

    /// Everything that splices into one body: redaction spans, then the placeholder
    /// strip and name aliases that do not touch a redaction. Ascending, non-overlapping.
    static func substitutions(
        source: NSString, guid: String?, redactions: RedactionSet, names: NameMatcher?,
        stripPlaceholders: Bool = false
    ) -> [Substitution] {
        let sourceLen = source.length

        // (a) Redaction span replacements (clamped to text bounds, then merged so
        // overlapping/nested/adjacent spans collapse to one covering `[redacted]` —
        // splicing them independently would leak source bytes between them).
        var redactionReps: [Substitution] = []
        if let guid {
            let clamped =
                redactions.redactions(forGuid: guid).compactMap(\.range)
                .filter {
                    $0.lowerBound >= 0 && $0.upperBound <= sourceLen
                        && $0.lowerBound < $0.upperBound
                }
            redactionReps = mergedRedactions(clamped)
        }

        // (b) In-body name-alias replacements (anonymize only; empty otherwise).
        // On overlap with a redaction span the REDACTION wins — the value already
        // reads `[redacted]`.
        let aliasReps = (names?.substitutions(in: source) ?? [])
            .filter { a in
                !redactionReps.contains { r in rangesOverlap(a.range, r.range) }
            }

        // A strip that touches a redaction is dropped: the redaction already hides it.
        let stripReps =
            stripPlaceholders
            ? Transcript.placeholderStripSubstitutions(source).filter { s in
                !redactionReps.contains { r in rangesOverlap(s.range, r.range) }
            } : []

        // (c) Unified, non-overlapping, ascending list. Redactions are placed first
        // so an alias that ties a redaction start is dropped.
        return deduped(redactionReps + stripReps + aliasReps)
    }

    /// True when a redaction hides the whole message: a nil range, a span over the
    /// whole text, or a span past the end of the text (a stale anchor never fails open).
    static func coversWholeMessage(_ record: MessageRecord, redactions: RedactionSet) -> Bool {
        guard let guid = record.guid else { return false }
        let len = (record.text as NSString).length
        return redactions.redactions(forGuid: guid).contains { r in
            guard let range = r.range else { return true }
            return range == 0..<len || range.lowerBound < 0 || range.upperBound > len
        }
    }

    /// The one body every output shows, or nil when the whole message is redacted.
    static func body(
        of record: MessageRecord, redactions: RedactionSet, names: NameMatcher?,
        stripPlaceholders: Bool
    ) -> String? {
        if coversWholeMessage(record, redactions: redactions) { return nil }
        let source = record.text as NSString
        let reps = substitutions(
            source: source, guid: record.guid, redactions: redactions, names: names,
            stripPlaceholders: stripPlaceholders)
        return apply(to: source, reps)
    }

    /// The source-to-output map for `source` after `reps` and the line indent.
    static func offsetMap(source: NSString, _ reps: [Substitution]) -> OffsetMap {
        OffsetMap(
            sourceLength: source.length,
            replacements: reps.map { (range: $0.range, tokenLen: ($0.token as NSString).length) },
            source: source)
    }
}

/// Maps one body's source UTF-16 offsets to output-body offsets and back. It folds
/// each substitution and the 8-space indent after every newline into one breakpoint table.
/// Tested in `RedactionMapTests` and `BodySpliceTests`.
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
        // An unchanged one-line body maps 1:1; skip the per-character scan.
        if replacements.isEmpty, source.range(of: "\n").location == NSNotFound {
            let end = Seg(
                srcStart: sourceLength, srcEnd: sourceLength, outStart: sourceLength,
                isRedacted: false)
            segs =
                sourceLength > 0
                ? [Seg(srcStart: 0, srcEnd: sourceLength, outStart: 0, isRedacted: false), end]
                : [end]
            return
        }
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

/// A detection copy of one message body plus the map back to source UTF-16 offsets.
/// Detectors run on `text`; every hit maps back through `sourceRange`.
struct NormalizedText {
    let text: NSString
    /// For each UTF-16 unit of `text`, the source range it came from. Empty means identity.
    private let map: [Range<Int>]

    init(identity text: NSString) {
        self.text = text
        self.map = []
    }

    init(text: NSString, map: [Range<Int>]) {
        self.text = text
        self.map = map
    }

    var isIdentity: Bool { map.isEmpty }

    func sourceRange(_ r: NSRange) -> Range<Int>? {
        guard r.location != NSNotFound, r.length > 0, r.location + r.length <= text.length else {
            return nil
        }
        guard !map.isEmpty else { return r.location..<(r.location + r.length) }
        return map[r.location].lowerBound..<map[r.location + r.length - 1].upperBound
    }
}
