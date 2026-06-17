import Foundation

/// Renders the compact daily-grouped .txt and the .jsonl, byte-compatible
/// with the Python prototype's `write_direct` (the diff target).
public enum Transcript {
    /// The account owner's speaker label, set by `Extractor.label(isFromMe:…)`.
    /// The renderer already hardcodes it in the legend; named here so the
    /// anonymization map can anchor the owner to Person 1.
    static let meLabel = "Me"
    public struct Stats: Sendable {
        public let messages: Int
        public let reactions: Int
        public let withAttachments: Int
    }

    /// The group-render context for `compactText` (the roster header). Non-nil ⇒
    /// render the group roster header instead of the 1:1 `Them = <number>` legend;
    /// nil ⇒ the existing 1:1 path, byte-identical (the golden test enforces this).
    ///
    /// `name` is the group's display name — the chat's `display_name` when set,
    /// else a legible join of participant labels (the composed "first-3 + N" picker
    /// name is the conversation picker's concern; the header just needs something
    /// labeled and readable).
    /// `participantLabels` is the conversation's FULL roster — every member's
    /// resolved label (first name / `First L.` / formatted number), including any
    /// who never spoke — in the conversation's participant order. "Me" is NOT in
    /// this list (it's never a `chat_handle_join` member); the header prepends
    /// "Me = the account owner" itself. The body / day-section / reaction rendering
    /// is unchanged (already speaker-generic), so this only reshapes the preamble.
    public struct GroupRenderInfo: Sendable, Equatable {
        public let name: String
        public let participantLabels: [String]

        public init(name: String, participantLabels: [String]) {
            self.name = name
            self.participantLabels = participantLabels
        }
    }

    /// One group system event — a join/leave/rename narrative beat. Carried as a
    /// **separate, already-rendered stream** rather than
    /// a new `MessageRecord` kind: system events are opt-in (`Export.Scope.showSystemEvents`,
    /// off by default) and TXT-narrative-only, so threading them as a distinct list
    /// merged into `compactText` keeps the redaction and `MessageRecord`-consuming
    /// paths completely untouched. `line` is the full
    /// human-readable body the renderer emits after the `HH:mm — ` prefix (e.g.
    /// `Alice added Carla`, `Bob named the group "KC crew"`, `Alice left`); the
    /// extractor builds it with the same per-thread speaker labels the body uses, so
    /// an event reads consistently with the messages around it.
    public struct SystemEvent: Sendable, Equatable {
        public let date: Date
        public let line: String

        public init(date: Date, line: String) {
            self.date = date
            self.line = line
        }
    }

    public static func stats(for records: [MessageRecord]) -> Stats {
        Stats(
            messages: records.count,
            reactions: records.reduce(0) { $0 + $1.reactions.count },
            withAttachments: records.count { $0.hadAttachment })
    }

    /// Fidelity trims, surfaced only when an export is over a context budget.
    /// Ranked least-to-most lossy: attachment markers are low
    /// signal; reactions carry emotional tone, so they are
    /// never stripped automatically. Defaults to no trim, so the rendered
    /// output stays byte-identical to the validated reference.
    public struct TrimOptions: Sendable, Equatable {
        /// Strip the `[photo]`/`[video]`/… placeholders (and drop a message
        /// that was *only* an attachment — nothing remains to show).
        public var dropAttachmentPlaceholders: Bool
        /// Drop the `[Them: ❤️]` reaction suffixes.
        public var dropReactions: Bool

        public init(dropAttachmentPlaceholders: Bool = false, dropReactions: Bool = false) {
            self.dropAttachmentPlaceholders = dropAttachmentPlaceholders
            self.dropReactions = dropReactions
        }

        public static let none = TrimOptions()
        public var isActive: Bool { dropAttachmentPlaceholders || dropReactions }
    }

    /// The closed set of typed placeholders the renderer emits — the attachment
    /// markers from `AttachmentInfo.placeholder` plus the FindMy `[shared
    /// location]` fallback (`Extractor.renderText`). Kept here because stripping
    /// is a render-layer concern; keep in lockstep if a new marker is added.
    static let placeholderTokens = [
        "[photo]", "[video]", "[gif]", "[audio]", "[pdf]",
        "[contact]", "[attachment]", "[shared location]",
    ]

    /// Remove placeholder tokens from one already-rendered message body. Caller
    /// gates on `hadAttachment`, so a literally-typed "[pdf]" in a message with
    /// no real attachment is left alone (rare edge, acceptable for a trim).
    static func stripPlaceholders(_ s: String) -> String {
        var out = s
        for token in placeholderTokens {
            out = out.replacingOccurrences(of: token, with: " ")
        }
        return Extractor.collapseSpaceRuns(out)
            .trimmingCharacters(in: Extractor.pythonWhitespace)
    }

    static func formatter(_ format: String, timeZone: TimeZone = .current) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }

    /// Thousands separators, matching Python's f"{n:,}".
    public static func comma(_ n: Int) -> String {
        var digits = Array(String(n))
        var out: [Character] = []
        var count = 0
        while let d = digits.popLast() {
            if count > 0, count % 3 == 0, d.isNumber { out.append(",") }
            out.append(d)
            count += 1
        }
        return String(out.reversed())
    }

    static func formatReactions(
        _ reactions: [Reaction], aliases: [String: String] = [:]
    ) -> String {
        guard !reactions.isEmpty else { return "" }
        return "  "
            + reactions.map { "[\(aliases[$0.by] ?? $0.by): \($0.emoji)]" }.joined(separator: " ")
    }

    /// Build the speaker → `"P1"`/`"P2"`/… alias map for an anonymized render
    /// (the de-bias pass). The account owner (`meLabel`) anchors to P1 when present;
    /// every other distinct speaker is numbered by first appearance, so the
    /// mapping is stable and extends naturally to group chats (P3, P4…). The short
    /// `PN` form (vs. "Person N") is deliberate — it repeats on every line, so the
    /// abbreviation is defined once in the header and saves tokens in the body.
    /// Reaction authors share the map, so a reaction by "Them" reads `[P2: …]`.
    /// Built from the same record set both renderers see, so the `.txt` and
    /// `.jsonl` speaker labels can never diverge. The mapping itself is never
    /// written into the output, so an assistant can't tell which Person is the
    /// user — which is the point.
    static func anonymizationMap(for records: [MessageRecord]) -> [String: String] {
        var seen: [String] = []
        func note(_ label: String) { if !seen.contains(label) { seen.append(label) } }
        for r in records {
            note(r.speaker)
            for reaction in r.reactions { note(reaction.by) }
        }
        // Float the owner to the front (stable order for everyone else).
        let ordered = seen.filter { $0 == meLabel } + seen.filter { $0 != meLabel }
        var map: [String: String] = [:]
        for (i, label) in ordered.enumerated() { map[label] = "P\(i + 1)" }
        return map
    }

    // MARK: - Redaction-aware render

    /// One emitted, non-collapsed message that has a non-nil guid. `outputBody`
    /// is the UTF-16 range in `RenderResult.text` covering this message's
    /// rendered body — the text after `"HH:mm Speaker: "`, through the body,
    /// EXCLUDING the reaction suffix and the trailing newline.
    public struct RenderSpan: Sendable {
        public let guid: String
        public let outputBody: NSRange
        public init(guid: String, outputBody: NSRange) {
            self.guid = guid
            self.outputBody = outputBody
        }
    }

    /// One emitted `[redacted]` token (or a whole-message tombstone). For a run
    /// of ≥2 fully-redacted messages collapsed to `[N messages removed]`, the
    /// single mark's `.redaction` points at the FIRST message's whole-message
    /// redaction (a GUI caller only needs *a* handle to drive click-to-undo).
    public struct RedactedMark: Sendable {
        public let outputRange: NSRange
        public let redaction: Redaction
        public init(outputRange: NSRange, redaction: Redaction) {
            self.outputRange = outputRange
            self.redaction = redaction
        }
    }

    /// One UNREDACTED detected secret still visible in the output, to be
    /// highlighted (amber). A detected secret that is fully covered by a
    /// redaction produces no highlight — it already reads `[redacted]`.
    public struct HighlightMark: Sendable {
        public let outputRange: NSRange
        public let category: SecretCategory
        public init(outputRange: NSRange, category: SecretCategory) {
            self.outputRange = outputRange
            self.category = category
        }
    }

    public struct RenderResult: Sendable {
        public let text: String
        public let spans: [RenderSpan]
        public let redactedMarks: [RedactedMark]
        public let highlightMarks: [HighlightMark]

        // Per-guid offset maps, retained so `redactions(forSelectedOutput:)` can
        // reverse the per-message transforms. Internal — not part of the API.
        let bodyMaps: [String: OffsetMap]

        /// Map an output selection (NSRange into `text`) to the redaction(s) it
        /// implies — one per message body the selection touches, clamped to that
        /// body and reversed through the indentation transform to a UTF-16
        /// localRange into the message's source `text`. A selection that fully
        /// covers a body yields a whole-message redaction (`range == nil`). A
        /// selection over only headers / whitespace / reaction suffixes yields [].
        public func redactions(forSelectedOutput selection: NSRange) -> [Redaction] {
            guard selection.length > 0 else { return [] }
            let selStart = selection.location
            let selEnd = selection.location + selection.length
            var result: [Redaction] = []
            for span in spans {
                let bodyStart = span.outputBody.location
                let bodyEnd = span.outputBody.location + span.outputBody.length
                // Intersect the selection with this body's output range.
                let lo = max(selStart, bodyStart)
                let hi = min(selEnd, bodyEnd)
                guard lo < hi else { continue }
                // Whole body covered → whole-message redaction.
                if lo <= bodyStart, hi >= bodyEnd {
                    result.append(Redaction(guid: span.guid, range: nil))
                    continue
                }
                // Reverse the per-message transform (output-body offset → source).
                guard let map = bodyMaps[span.guid] else { continue }
                let srcLo = map.outputToSource(lo - bodyStart)
                let srcHi = map.outputToSource(hi - bodyStart)
                guard srcLo < srcHi else { continue }
                result.append(Redaction(guid: span.guid, range: srcLo..<srcHi))
            }
            return result
        }
    }

    /// Apply this message's span redactions to its source `text`, splicing each
    /// clamped span with the literal `[redacted]`. The single source of truth for
    /// the redaction substring contract — both `compactText` (the `.txt` path) and
    /// `jsonLines` (the `.jsonl` path) call this, so the substitution can never
    /// diverge between the two outputs. Span ranges are UTF-16 offsets into
    /// `text`; out-of-bounds / empty ranges are filtered. A `nil` guid (or no
    /// span redactions for the guid) returns `text` unchanged.
    static func applySpanRedactions(
        to text: String, guid: String?, redactions: RedactionSet
    ) -> String {
        guard let guid else { return text }
        let sourceNS = text as NSString
        let sourceLen = sourceNS.length
        let spansForGuid = redactions.redactions(forGuid: guid)
            .compactMap { $0.range }
            .filter {
                $0.lowerBound >= 0 && $0.upperBound <= sourceLen
                    && $0.lowerBound < $0.upperBound
            }
        guard !spansForGuid.isEmpty else { return text }
        // Splice descending so earlier replacements don't shift later spans.
        let redactedBody = NSMutableString(string: sourceNS)
        for sp in spansForGuid.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            redactedBody.replaceCharacters(
                in: NSRange(location: sp.lowerBound, length: sp.upperBound - sp.lowerBound),
                with: "[redacted]")
        }
        return redactedBody as String
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

    /// The in-body name-alias substitutions for one message under `anonymize`:
    /// every whole-word, case-insensitive mention of a known participant NAME,
    /// mapped to that participant's stable `PN` alias (so "tell Sarah hi" →
    /// "tell P2 hi"). Empty when not anonymizing or when the body mentions no
    /// participant. Reuses the SAME `aliases` map the speaker relabeling uses, so
    /// the in-body alias and the speaker prefix always agree.
    ///
    /// Only real NAMES are aliased: the owner label `"Me"`, the generic `"Them"`,
    /// and any label that is a formatted phone number (all digits / punctuation /
    /// whitespace, no letter) are skipped — those are not names worth pseudonymizing
    /// in the body, and `"Them"` would over-match the common English word. NO NER /
    /// no third-party-name detection — exact-match against the known participant
    /// labels only.
    static func nameAliasReplacements(
        in body: NSString, aliases: [String: String]
    ) -> [BodySubstitution] {
        guard !aliases.isEmpty, body.length > 0 else { return [] }
        var out: [BodySubstitution] = []
        // Stable order (longest label first) so a label that is a substring of a
        // longer one can't pre-empt the longer match; ties broken by the label so
        // the scan is deterministic.
        let labels = aliases.keys
            .filter { isAliasableName($0) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        let whole = NSRange(location: 0, length: body.length)
        for label in labels {
            guard let alias = aliases[label] else { continue }
            // Whole-word, case-insensitive literal match on the label. `\Q…\E`
            // quotes the label so any regex metacharacters in a name are literal.
            let pattern = #"(?i)\b\#(NSRegularExpression.escapedPattern(for: label))\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            regex.enumerateMatches(in: body as String, range: whole) { match, _, _ in
                guard let match, match.range.length > 0, let range = Range(match.range)
                else { return }
                out.append(BodySubstitution(range: range, token: alias, isRedaction: false))
            }
        }
        return out
    }

    /// True when a participant label is a real, aliasable NAME: not the owner
    /// label `"Me"`, not the generic `"Them"`, and not a formatted phone number
    /// (a label with no letter — all digits / punctuation / whitespace).
    static func isAliasableName(_ label: String) -> Bool {
        if label == meLabel || label == "Them" { return false }
        return label.contains { $0.isLetter }
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
        if let guid = record.guid,
            redactions.redactions(forGuid: guid).contains(where: { $0.range == nil })
        {
            return nil
        }
        return applySpanRedactions(to: record.text, guid: record.guid, redactions: redactions)
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
        source: NSString, guid: String?, redactions: RedactionSet, aliases: [String: String]
    ) -> [BodySubstitution] {
        let sourceLen = source.length

        // (a) Redaction span replacements (clamped to text bounds). Only a message
        // with a guid can be redacted.
        var redactionReps: [BodySubstitution] = []
        if let guid {
            for sp in redactions.redactions(forGuid: guid).compactMap(\.range)
            where sp.lowerBound >= 0 && sp.upperBound <= sourceLen
                && sp.lowerBound < sp.upperBound
            {
                redactionReps.append(
                    BodySubstitution(range: sp, token: "[redacted]", isRedaction: true))
            }
        }

        // (b) In-body name-alias replacements (anonymize only; empty otherwise).
        // On overlap with a redaction span the REDACTION wins — the value already
        // reads `[redacted]`.
        let aliasReps = Self.nameAliasReplacements(in: source, aliases: aliases)
            .filter { a in
                !redactionReps.contains { r in rangesOverlap(a.range, r.range) }
            }

        // (c) Unified, non-overlapping, ascending list. Redactions are placed first
        // so an alias that ties a redaction start is dropped.
        return dedupedReplacements(redactionReps + aliasReps)
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
        if let guid = record.guid {
            let rs = redactions.redactions(forGuid: guid)
            let len = (record.text as NSString).length
            // Whole-message redaction (explicit nil-range OR a span covering the
            // whole text) → omit the row (no inline splice).
            if rs.contains(where: { $0.range == nil || $0.range == 0..<len }) { return nil }
        }
        let source = record.text as NSString
        let reps = bodyReplacements(
            source: source, guid: record.guid, redactions: redactions, aliases: aliases)
        return applyReplacements(to: source, reps)
    }

    public static func compactText(
        records: [MessageRecord], number: String, trim: TrimOptions = .none,
        redactions: RedactionSet, detected: [DetectedSecret],
        anonymize: Bool = false,
        group: GroupRenderInfo? = nil,
        systemEvents: [SystemEvent] = [],
        timeZone: TimeZone = .current
    ) -> RenderResult {
        let day = formatter("yyyy-MM-dd", timeZone: timeZone)
        let weekday = formatter("EEE", timeZone: timeZone)
        let time = formatter("HH:mm", timeZone: timeZone)

        // Speaker → "Person N" map when de-biasing; empty otherwise (alias lookups
        // fall through to the real label). Built from the raw records so the .txt
        // and .jsonl maps are identical (same input set).
        let aliases = anonymize ? anonymizationMap(for: records) : [:]
        func alias(_ speaker: String) -> String { aliases[speaker] ?? speaker }

        // Group detected secrets by guid for O(1) lookup per message.
        var detectedByGuid: [String: [DetectedSecret]] = [:]
        for d in detected { detectedByGuid[d.guid, default: []].append(d) }

        // ---- Phase 1: build the same `emit` line list the reference path does,
        // tracking each emitted record's guid + whether it is fully redacted.
        struct Emit {
            let date: Date
            let speaker: String
            let text: String  // body BEFORE redaction transforms (post attach-trim)
            let reactions: [Reaction]
            let hadAttachment: Bool
            let guid: String?
            let whole: Redaction?  // non-nil → tombstone this message
        }
        var emit: [Emit] = []
        emit.reserveCapacity(records.count)
        for r in records {
            var text = r.text
            if trim.dropAttachmentPlaceholders, r.hadAttachment {
                text = stripPlaceholders(text)
                if text.isEmpty { continue }
            }
            // Whole-message redaction? Either an explicit nil-range redaction, or
            // a span that covers the entire (pre-trim) text. nil-guid records can
            // never be redacted.
            var whole: Redaction?
            if let guid = r.guid {
                let rs = redactions.redactions(forGuid: guid)
                if rs.contains(where: { $0.range == nil }) {
                    whole = Redaction(guid: guid, range: nil)
                } else {
                    // A span that covers the entire (pre-trim) text is a whole-
                    // message redaction in disguise; normalize it to a tombstone.
                    let len = (r.text as NSString).length
                    if rs.contains(where: { $0.range == 0..<len }) {
                        whole = Redaction(guid: guid, range: nil)
                    }
                }
            }
            emit.append(
                Emit(
                    date: r.date, speaker: r.speaker, text: text,
                    reactions: trim.dropReactions ? [] : r.reactions,
                    hadAttachment: r.hadAttachment, guid: r.guid, whole: whole))
        }

        // ---- Preamble (counts describe what the body shows, as the reference does).
        let messages = emit.count
        let reactionCount = emit.reduce(0) { $0 + $1.reactions.count }
        let withAttachments = emit.count { $0.hadAttachment }

        // Anonymizing scrubs identities, so the group roster header (which lists the
        // group's name + every member's real label) is suppressed under `anonymize`
        // — the de-biased `Person N` header covers groups generically (P3, P4…).
        // When `group` is nil OR anonymizing, the bytes are the 1:1/anonymized path,
        // unchanged (the golden tests enforce this).
        let renderGroup = group != nil && !anonymize

        var out = ""
        // Anonymizing scrubs the counterparty's number/name from the header — the
        // whole point is to hide who the thread is with.
        if let group, renderGroup {
            out += "# iMessage group transcript: \"\(group.name)\"\n"
        } else {
            out +=
                anonymize ? "# iMessage transcript\n" : "# iMessage transcript with \(number)\n"
        }
        if let first = emit.first, let last = emit.last {
            var parts = ["\(comma(messages)) messages"]
            if !trim.dropReactions { parts.append("\(comma(reactionCount)) reactions") }
            if !trim.dropAttachmentPlaceholders {
                parts.append("\(comma(withAttachments)) with attachments")
            }
            out +=
                "# \(day.string(from: first.date)) → \(day.string(from: last.date)) · "
                + parts.joined(separator: " · ") + "\n"
        }
        if let group, renderGroup {
            // The full roster: "Me = the account owner" plus every member's label
            // (incl. any who never spoke), so an assistant can attribute every line.
            let roster = (["Me = the account owner"] + group.participantLabels)
                .joined(separator: " · ")
            out += "# Participants: \(roster)\n"
        } else if anonymize {
            // Define the short PN labels used in the body (Person 1 (P1), …) once,
            // without revealing which one is the account owner.
            let people = (1...Swift.max(aliases.count, 1)).map { "Person \($0) (P\($0))" }
                .joined(separator: ", ")
            out += "# Speakers: \(people) — names anonymized.\n"
        } else {
            out += "# Speakers: Me = the account owner, Them = \(number)\n"
        }
        if !trim.dropReactions {
            // Concrete example reactor: a real participant label for a group, "Them"
            // for a 1:1, "PN" when anonymized — so the legend reads naturally.
            let reactor: String
            if let group, renderGroup {
                reactor = group.participantLabels.first ?? "a member"
            } else {
                reactor = anonymize ? "PN" : "Them"
            }
            out += "# Reactions shown as [\(reactor): ❤️] after the message they target.\n"
        }
        if !trim.dropAttachmentPlaceholders {
            out +=
                "# Attachments shown as typed placeholders: [photo] [video] [gif] "
                + "[audio] [pdf] [contact] [shared location].\n"
        }
        out += "# Times are local, 24h. Section headers are calendar days.\n\n"

        // ---- Phase 2: emit day-grouped body, applying redactions + collecting marks.
        var spans: [RenderSpan] = []
        var redactedMarks: [RedactedMark] = []
        var highlightMarks: [HighlightMark] = []
        var bodyMaps: [String: OffsetMap] = [:]

        // NSString accumulator so every appended length is measured in UTF-16.
        let acc = NSMutableString(string: out)
        var currentDay: String?

        // System events: an opt-in, already-rendered stream
        // interleaved by timestamp into the day-grouped body. Empty by default ⇒
        // the loop below is unchanged byte-for-byte. Suppressed when anonymizing —
        // a join/leave/rename names real people, which is exactly what the de-bias
        // pass scrubs. Sorted so the merge with the message stream is stable.
        let pendingEvents = (renderGroup ? systemEvents : []).sorted { $0.date < $1.date }
        var eventIndex = 0
        // Open the day section for `date` if it isn't the current one — shared by
        // the message loop and the event flush so an event that starts a new day
        // gets its own `## YYYY-MM-DD` header.
        func openDaySection(for date: Date) {
            let d = day.string(from: date)
            if d != currentDay {
                currentDay = d
                acc.append("\n## \(d) (\(weekday.string(from: date)))\n")
            }
        }
        // Emit every pending event at or before `boundary` (nil ⇒ drain all),
        // each on its own `HH:mm — <line>` line, opening day sections as needed.
        // Events carry no guid, so they produce no spans / redaction / highlight
        // marks — they're narrative metadata, not message content.
        func flushEvents(before boundary: Date?) {
            while eventIndex < pendingEvents.count {
                let ev = pendingEvents[eventIndex]
                if let boundary, ev.date > boundary { break }
                openDaySection(for: ev.date)
                acc.append("\(time.string(from: ev.date)) — \(ev.line)\n")
                eventIndex += 1
            }
        }

        var i = 0
        while i < emit.count {
            let r = emit[i]
            flushEvents(before: r.date)
            openDaySection(for: r.date)

            // -- Tombstone path: collapse a contiguous run of fully-redacted
            // messages WITHIN this day. A run breaks at a day boundary (simplest
            // correct behavior). N≥2 → "[N messages removed]"; lone → "[redacted message]".
            if r.whole != nil {
                var j = i
                while j < emit.count,
                    emit[j].whole != nil,
                    day.string(from: emit[j].date) == currentDay
                {
                    j += 1
                }
                let runLen = j - i
                let firstWhole = r.whole!  // undo handle = first message's whole redaction
                let token = runLen >= 2 ? "[\(runLen) messages removed]" : "[redacted message]"
                let tokStart = acc.length
                acc.append(token + "\n")
                redactedMarks.append(
                    RedactedMark(
                        outputRange: NSRange(
                            location: tokStart, length: (token as NSString).length),
                        redaction: firstWhole))
                i = j
                continue
            }

            // -- Normal path with inline span redaction (+ in-body name aliasing
            // when anonymizing). Redaction spans and name-alias mentions are
            // modelled as one unified `[BodySubstitution]` list so they splice +
            // offset-map through a SINGLE path: `OffsetMap` already supports a
            // variable token length per replacement, so an alias (`PN`) and a
            // `[redacted]` compose exactly. The no-anonymize path has an empty
            // alias set ⇒ the list is the redaction spans alone, so the bytes are
            // byte-identical to before (the goldens enforce this).
            let sourceNS = r.text as NSString
            let sourceLen = sourceNS.length
            let guid = r.guid

            // The unified, non-overlapping, ascending replacement list — redaction
            // spans (`[redacted]`) + in-body name aliases (`PN`), resolved
            // redaction-wins — via the SHARED `bodyReplacements` helper, so the
            // splice here is byte-identical to what `renderedBody` (the `.jsonl` +
            // downstream-formatter path) produces.
            let allReps = Self.bodyReplacements(
                source: sourceNS, guid: guid, redactions: redactions, aliases: aliases)

            // Build the transformed body (pre-indentation) by splicing every
            // replacement; with no replacements this returns `r.text` unchanged
            // (so the empty path is byte-identical).
            let transformedBody = Self.applyReplacements(to: sourceNS, allReps)

            // Indentation transform on the body (newline → newline+8sp).
            let indented = transformedBody.replacingOccurrences(
                of: "\n", with: "\n        ")
            let indentedNS = indented as NSString

            // Offset map covering BOTH transforms (the unified replacement collapse
            // + the newline→8-space expansion), in output-body coordinates. Forward
            // (source→output) drives the marks below; inverse (output→source) drives
            // `redactions(forSelectedOutput:)`. The map is fed the FULL unified set,
            // so a selection over an aliased name reverses correctly.
            let map = OffsetMap(
                sourceLength: sourceLen,
                replacements: allReps.map {
                    (range: $0.range, tokenLen: ($0.token as NSString).length)
                },
                source: sourceNS)
            if let guid { bodyMaps[guid] = map }

            // Append the line, recording the body's output range. `bodyStart` is
            // measured AFTER the (possibly anonymized) prefix, so redaction /
            // highlight output ranges stay correct regardless of label length.
            let prefix = "\(time.string(from: r.date)) \(alias(r.speaker)): "
            acc.append(prefix)
            let bodyStart = acc.length
            acc.append(indented)
            let bodyLen = indentedNS.length
            acc.append(formatReactions(r.reactions, aliases: aliases))
            acc.append("\n")

            if let guid {
                spans.append(
                    RenderSpan(
                        guid: guid, outputBody: NSRange(location: bodyStart, length: bodyLen)))

                // Redaction marks: ONLY the redaction replacements (an alias is a
                // content transform, not a redaction → no undo handle). The token
                // start in body coords = forward map of the span start.
                let token = "[redacted]"
                let tokenLen = (token as NSString).length
                for rep in allReps where rep.isRedaction {
                    let bodyOff = map.sourceToOutput(rep.range.lowerBound)
                    redactedMarks.append(
                        RedactedMark(
                            outputRange: NSRange(location: bodyStart + bodyOff, length: tokenLen),
                            redaction: Redaction(guid: guid, range: rep.range)))
                }

                // Highlight marks: each detected secret NOT covered by a REDACTION
                // (an alias never covers a secret — names and secrets are disjoint
                // categories, and an alias does not "clean" a value). Output offsets
                // route through the unified map, so an alias before the secret still
                // shifts the highlight correctly.
                for sec in detectedByGuid[guid] ?? [] {
                    let covered = allReps.contains {
                        $0.isRedaction
                            && $0.range.lowerBound <= sec.range.lowerBound
                            && $0.range.upperBound >= sec.range.upperBound
                    }
                    if covered { continue }
                    guard sec.range.lowerBound >= 0, sec.range.upperBound <= sourceLen else {
                        continue
                    }
                    let loOff = map.sourceToOutput(sec.range.lowerBound)
                    let hiOff = map.sourceToOutput(sec.range.upperBound)
                    guard hiOff > loOff else { continue }
                    highlightMarks.append(
                        HighlightMark(
                            outputRange: NSRange(
                                location: bodyStart + loOff, length: hiOff - loOff),
                            category: sec.category))
                }
            }
            i += 1
        }
        // Drain any system events after the last message (e.g. a final "left").
        flushEvents(before: nil)

        return RenderResult(
            text: acc as String, spans: spans, redactedMarks: redactedMarks,
            highlightMarks: highlightMarks, bodyMaps: bodyMaps)
    }

    /// One JSON object per message. Redaction-aware AND, under `anonymize`,
    /// in-body name-alias-aware: the `"m"` field is the SAME body the `.txt`
    /// renderer shows — span redactions spliced to `[redacted]` and in-body
    /// participant-name mentions rewritten to their `PN` alias — via the shared
    /// `renderedBody` helper, so the two outputs can never leak differently. An
    /// earlier pass aliased only the SPEAKER here, leaking raw in-body names that
    /// the `.txt` had aliased; routing the body through `renderedBody` closes that.
    ///
    /// Whole-message redactions (an explicit nil-range redaction, or a span
    /// covering the entire text) **omit the object entirely** — jsonl has no
    /// `[N messages removed]` tombstone, so dropping the line is the safe default
    /// (no leak). Note the asymmetry with `.txt`: a consumer reconciling line
    /// counts between the two formats sees fewer jsonl lines than `.txt` rendered
    /// (whose redacted run collapses to a single tombstone token instead).
    ///
    /// Default `redactions: RedactionSet()` + `anonymize: false` keeps the output
    /// byte-identical to the raw, unredacted rendering (`renderedBody` with `[:]`
    /// aliases and no redactions returns the body unchanged).
    public static func jsonLines(
        records: [MessageRecord], redactions: RedactionSet = RedactionSet(),
        anonymize: Bool = false,
        timeZone: TimeZone = .current
    ) -> String {
        let full = formatter("yyyy-MM-dd HH:mm:ss", timeZone: timeZone)
        // Same speaker → "Person N" map the .txt path uses, so the two outputs
        // label identically. Empty when not anonymizing (lookups fall through).
        let aliases = anonymize ? anonymizationMap(for: records) : [:]
        var out = ""
        for r in records {
            // Whole-message redaction → omit the object (no jsonl tombstone).
            // `renderedBody` returns nil for it; nil-guid records can never be
            // whole-redacted, so they always render. The body is the SAME unified
            // splice (redactions + in-body aliases) the `.txt` path shows.
            guard let body = Self.renderedBody(of: r, redactions: redactions, aliases: aliases)
            else { continue }
            var fields: [(String, String)] = [
                ("d", jsonString(full.string(from: r.date))),
                ("s", jsonString(aliases[r.speaker] ?? r.speaker)),
                ("m", jsonString(body)),
            ]
            if let svc = r.service, svc != "iMessage" {
                fields.append(("svc", jsonString(svc)))
            }
            if !r.reactions.isEmpty {
                let items = r.reactions
                    .map {
                        "{\"by\": \(jsonString(aliases[$0.by] ?? $0.by)), \"r\": \(jsonString($0.emoji))}"
                    }
                    .joined(separator: ", ")
                fields.append(("reacts", "[\(items)]"))
            }
            out += "{" + fields.map { "\"\($0.0)\": \($0.1)" }.joined(separator: ", ") + "}\n"
        }
        return out
    }

    /// JSON string literal matching Python json.dumps(ensure_ascii=False):
    /// raw UTF-8, only quotes/backslash/control characters escaped.
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
