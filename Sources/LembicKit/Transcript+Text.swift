import Foundation

extension Transcript {
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

    public static func compactText(
        records: [MessageRecord], number: String, trim: TrimOptions = .none,
        redactions: RedactionSet, detected: [DetectedSecret],
        anonymize: Bool = false,
        group: GroupRenderInfo? = nil,
        systemEvents: [SystemEvent] = [],
        knownNames: [String: [String]] = [:],
        timeZone: TimeZone = .current,
        noteToSelf: Bool = false
    ) -> RenderResult {
        let local = LocalClock(timeZone: timeZone)

        // Speaker → "Person N" map when de-biasing; empty otherwise (alias lookups
        // fall through to the real label). Built from the raw records so the .txt
        // and .jsonl maps are identical (same input set).
        let aliases = anonymize ? anonymizationMap(for: records, knownNames: knownNames) : [:]
        let names = anonymize ? NameMatcher(aliases: aliases, knownNames: knownNames) : nil
        func alias(_ speaker: String) -> String { aliases[speaker] ?? speaker }

        // Group detected secrets by guid for O(1) lookup per message.
        var detectedByGuid: [String: [DetectedSecret]] = [:]
        for d in detected { detectedByGuid[d.guid, default: []].append(d) }

        // ---- Phase 1: build the same `emit` line list the reference path does,
        // tracking each emitted record's guid + whether it is fully redacted.
        struct Emit {
            let date: Date
            let speaker: String
            let text: String  // source body; trim and redaction both splice in source offsets
            let stripPlaceholders: Bool
            let reactions: [Reaction]
            let hadAttachment: Bool
            let guid: String?
            let whole: Redaction?  // non-nil → tombstone this message
        }
        var emit: [Emit] = []
        emit.reserveCapacity(records.count)
        for r in records {
            let strip = trim.dropAttachmentPlaceholders && r.hadAttachment
            if strip, stripPlaceholders(r.text).isEmpty { continue }
            // Whole-message redaction? A nil range, a span over the entire source
            // text, or a stale span past its end. nil-guid records are never redacted.
            var whole: Redaction?
            if let guid = r.guid, coversWholeMessage(r, redactions: redactions) {
                whole = Redaction(guid: guid, range: nil)
            }
            emit.append(
                Emit(
                    date: r.date, speaker: r.speaker, text: r.text, stripPlaceholders: strip,
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
            out += "# Messages group transcript: \"\(group.name)\"\n"
        } else if noteToSelf, !anonymize {
            out += "# Messages transcript: notes to self\n"
        } else {
            out +=
                anonymize ? "# Messages transcript\n" : "# Messages transcript with \(number)\n"
        }
        if let first = emit.first, let last = emit.last {
            var parts = ["\(comma(messages)) messages"]
            if !trim.dropReactions { parts.append("\(comma(reactionCount)) reactions") }
            if !trim.dropAttachmentPlaceholders {
                parts.append("\(comma(withAttachments)) with attachments")
            }
            out +=
                "# \(local.day(first.date)) → \(local.day(last.date)) · "
                + parts.joined(separator: " · ") + "\n"
        }
        if let group, renderGroup {
            // The full roster: "Me = the account owner" plus every member's label
            // (incl. any who never spoke), so an assistant can attribute every line.
            let roster =
                (["Me = the account owner"] + group.participantLabels
                + group.formerLabels.map { "\($0) (left)" })
                .joined(separator: " · ")
            out += "# Participants: \(roster)\n"
        } else if anonymize {
            // Define the short PN labels used in the body (Person 1 (P1), …) once,
            // without revealing which one is the account owner.
            let people = (1...Swift.max(aliases.count, 1)).map { "Person \($0) (P\($0))" }
                .joined(separator: ", ")
            out += "# Speakers: \(people) — names anonymized.\n"
        } else if noteToSelf {
            out += "# Speakers: Me = the account owner\n"
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
                reactor = anonymize ? "PN" : noteToSelf ? "Me" : "Them"
            }
            out += "# Reactions shown as [\(reactor): ❤️] after the message they target.\n"
        }
        let shown = legendTokens(in: emit.map(\.text))
        if !trim.dropAttachmentPlaceholders, !shown.isEmpty {
            out +=
                "# Attachments shown as typed placeholders: "
                + shown.joined(separator: " ") + ".\n"
        }
        let zoneName = anonymize ? "" : " (\(timeZone.identifier))"
        out += "# Times are local\(zoneName), 24h. Section headers are calendar days.\n\n"

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
        // A clock time inside a DST fall-back hour happens twice, so it names its zone.
        let dates = [
            emit.first?.date, emit.last?.date, pendingEvents.first?.date,
            pendingEvents.last?.date,
        ].compactMap { $0 }
        let repeated =
            dates.min().map {
                repeatedHours(from: $0, to: dates.max() ?? $0, in: timeZone)
            } ?? []
        let zone = formatter("HH:mm zzz", timeZone: timeZone)
        func clock(_ date: Date) -> String {
            repeated.contains { $0.contains(date) }
                ? zone.string(from: date) : local.time(date)
        }
        // Open the day section for `date` if it isn't the current one — shared by
        // the message loop and the event flush so an event that starts a new day
        // gets its own `## YYYY-MM-DD` header.
        func openDaySection(for date: Date) {
            let d = local.day(date)
            if d != currentDay {
                currentDay = d
                acc.append("\n## \(d) (\(local.weekday(date)))\n")
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
                acc.append("\(clock(ev.date)) — \(ev.line)\n")
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
                    local.day(emit[j].date) == currentDay
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
                source: sourceNS, guid: guid, redactions: redactions, names: names,
                stripPlaceholders: r.stripPlaceholders)

            // Build the transformed body (pre-indentation) by splicing every
            // replacement; with no replacements this returns `r.text` unchanged
            // (so the empty path is byte-identical).
            let transformedBody = Self.applyReplacements(to: sourceNS, allReps)

            // Indentation transform on the body (newline → newline+8sp).
            let indented =
                transformedBody.contains("\n")
                ? transformedBody.replacingOccurrences(of: "\n", with: "\n        ")
                : transformedBody
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
            let prefix = "\(clock(r.date)) \(alias(r.speaker)): "
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
}
