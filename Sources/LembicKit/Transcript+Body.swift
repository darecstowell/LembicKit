import Foundation

extension Transcript {
    /// Apply this message's span redactions to its source `text`, splicing each
    /// clamped span with the literal `[redacted]`. Routes through the shared
    /// `bodyReplacements` + `applyReplacements` path (no aliases), so overlapping
    /// and nested spans are resolved to a non-overlapping set exactly as the
    /// `.txt`/`.jsonl` paths do — a second span inside an already-spliced
    /// `[redacted]` can never leak source bytes. Span ranges are UTF-16 offsets
    /// into `text`; out-of-bounds / empty ranges are filtered. A `nil` guid (or no
    /// span redactions for the guid) returns `text` unchanged.
    static func applySpanRedactions(
        to text: String, guid: String?, redactions: RedactionSet
    ) -> String {
        guard guid != nil else { return text }
        let source = text as NSString
        let reps = bodyReplacements(
            source: source, guid: guid, redactions: redactions, names: nil)
        return applyReplacements(to: source, reps)
    }

    /// One pending in-body substitution for `compactText`'s body assembly: a
    /// half-open UTF-16 source range and the literal token it collapses to. Both
    /// redaction spans (`token == "[redacted]"`) and name-alias mentions
    /// (`token == "P2"`) are modelled as `BodySubstitution`s so they splice +
    /// offset-map through a SINGLE path — variable token length is already
    /// first-class in `OffsetMap`. `isRedaction` distinguishes the two: only
    /// redactions produce a `RedactedMark` (an undo handle) and only redactions
    /// suppress a detected-secret highlight; an alias is a content transform, not a
    /// redaction.
    struct BodySubstitution {
        let range: Range<Int>
        let token: String
        let isRedaction: Bool
    }

    /// Two half-open ranges intersect.
    static func rangesOverlap(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }

    /// Resolve a mixed replacement list into an ascending, NON-overlapping set —
    /// `OffsetMap`'s precondition. Earlier-listed replacements win a conflict, so
    /// the caller orders redactions before aliases (redaction-wins). With a list
    /// of non-overlapping redactions alone (the no-anonymize path) every entry is
    /// kept in start order, so the splice + map are byte-identical to before.
    static func dedupedReplacements(_ reps: [BodySubstitution]) -> [BodySubstitution] {
        var kept: [BodySubstitution] = []
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

    /// Apply a unified `[BodySubstitution]` list to one message body, splicing each
    /// range with its token. Descending by start so earlier splices don't shift
    /// later ranges. The single body-assembly transform for `compactText`, so
    /// redaction spans (`[redacted]`) and name-alias mentions (`PN`) collapse
    /// through one path and the `OffsetMap` fed the same ranges/lengths stays
    /// exact. Ranges are assumed pre-clamped + non-overlapping (the caller
    /// resolves overlaps, redaction-wins, before calling).
    static func applyReplacements(to body: NSString, _ replacements: [BodySubstitution]) -> String {
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

    /// The redaction-aware redacted body for one message, the single public surface
    /// a downstream formatter uses so it inherits the exact `[redacted]` splice the
    /// `.txt`/`.jsonl` paths share and can never drift.
    ///
    /// Returns `nil` when the message is **whole-message redacted** — i.e. its
    /// `guid` is non-nil and a `range == nil` redaction is anchored to it. The
    /// caller omits that row (mirroring how `jsonLines` drops a tombstoned object).
    /// Otherwise returns `record.text` with the message's **span** redactions
    /// applied via the shared `applySpanRedactions` helper. A `nil` guid can never
    /// be redacted, so the text is returned unchanged.
    public static func redactedText(
        of record: MessageRecord, redactions: RedactionSet
    ) -> String? {
        if coversWholeMessage(record, redactions: redactions) { return nil }
        return applySpanRedactions(to: record.text, guid: record.guid, redactions: redactions)
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

    /// The unified, ascending, non-overlapping `[BodySubstitution]` list for ONE
    /// message body — redaction spans (`[redacted]`) plus, when anonymizing,
    /// in-body name-alias mentions (`PN`) — resolved redaction-wins. The SINGLE
    /// source of truth for "what splices into a body": `compactText` (which also
    /// needs the per-substitution offset map for its marks) and the bodies-only
    /// `renderedBody` (the `.jsonl` + downstream-formatter path) BOTH derive their splice from this,
    /// so the two can never diverge.
    ///
    /// `aliases` empty (the no-anonymize path) ⇒ the list is the redaction spans
    /// alone, so the spliced body stays byte-identical to the pre-alias output.
    /// `source` is the message body as an `NSString` (UTF-16 offsets); `guid` is
    /// nil-safe (a nil-guid message has no redactions, only aliases can apply).
    static func bodyReplacements(
        source: NSString, guid: String?, redactions: RedactionSet, names: NameMatcher?,
        stripPlaceholders: Bool = false
    ) -> [BodySubstitution] {
        let sourceLen = source.length

        // (a) Redaction span replacements (clamped to text bounds, then merged so
        // overlapping/nested/adjacent spans collapse to one covering `[redacted]` —
        // splicing them independently would leak source bytes between them).
        var redactionReps: [BodySubstitution] = []
        if let guid {
            let clamped =
                redactions.redactions(forGuid: guid).compactMap(\.range)
                .filter {
                    $0.lowerBound >= 0 && $0.upperBound <= sourceLen
                        && $0.lowerBound < $0.upperBound
                }
            redactionReps = mergedRedactionSubstitutions(clamped)
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
            ? placeholderStripSubstitutions(source).filter { s in
                !redactionReps.contains { r in rangesOverlap(s.range, r.range) }
            } : []

        // (c) Unified, non-overlapping, ascending list. Redactions are placed first
        // so an alias that ties a redaction start is dropped.
        return dedupedReplacements(redactionReps + stripReps + aliasReps)
    }

    /// Overlapping or touching spans merged into one `[redacted]` substitution each.
    static func mergedRedactionSubstitutions(_ spans: [Range<Int>]) -> [BodySubstitution] {
        var out: [BodySubstitution] = []
        for sp in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, sp.lowerBound <= last.range.upperBound {
                let merged = last.range.lowerBound..<Swift.max(last.range.upperBound, sp.upperBound)
                out[out.count - 1] = BodySubstitution(
                    range: merged, token: "[redacted]", isRedaction: true)
            } else {
                out.append(BodySubstitution(range: sp, token: "[redacted]", isRedaction: true))
            }
        }
        return out
    }

    /// The fully-rendered body for ONE message — redaction spans spliced to
    /// `[redacted]` AND, when `anonymize` is true, in-body participant-name
    /// mentions rewritten to their stable `PN` alias — in a SINGLE pass against
    /// the original UTF-16 offsets (so an alias before a redaction never desyncs
    /// the redaction span). Returns the same body the `.txt`/`.jsonl` paths show,
    /// so a downstream formatter that bakes this into a record's `text`
    /// can never leak a scrubbed value or a raw participant name.
    ///
    /// Returns `nil` for a **whole-message redaction** (a nil-range redaction, or a
    /// span covering the entire text) so the caller omits the row — mirroring
    /// `redactedText` and `jsonLines`. A nil-guid message can never be redacted, so
    /// only aliasing can transform it (never `nil`).
    ///
    /// `aliases` is the speaker→`PN` map (`anonymizationMap`); pass `[:]` to skip
    /// in-body aliasing. With `[:]` and no redactions for the guid, the text is
    /// returned unchanged (byte-identical to the raw body).
    public static func renderedBody(
        of record: MessageRecord, redactions: RedactionSet, aliases: [String: String]
    ) -> String? {
        renderedBody(
            of: record, redactions: redactions,
            names: aliases.isEmpty ? nil : NameMatcher(aliases: aliases), stripPlaceholders: false)
    }

    /// `renderedBody` with a prebuilt name matcher and the optional placeholder strip,
    /// both applied in source offsets.
    static func renderedBody(
        of record: MessageRecord, redactions: RedactionSet, names: NameMatcher?,
        stripPlaceholders: Bool
    ) -> String? {
        // Whole-message redaction → omit the row (no inline splice).
        if coversWholeMessage(record, redactions: redactions) { return nil }
        let source = record.text as NSString
        let reps = bodyReplacements(
            source: source, guid: record.guid, redactions: redactions, names: names,
            stripPlaceholders: stripPlaceholders)
        return applyReplacements(to: source, reps)
    }
}
