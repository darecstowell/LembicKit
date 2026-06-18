import Foundation

/// The single home for the export pipeline: open + preflight (steps 1–2),
/// delegate people-listing to `Conversations` (step 3), and render one
/// conversation (steps 4–9) with secret-detection + redaction **always**
/// threaded through. Before this seam existed every caller (a GUI app, the
/// `lembic-cli`) reassembled the 9-step extract→detect→render incantation by
/// hand and they drifted (the CLI shipped transcripts with no redaction parity
/// at all). `Export.render` is the one place that ordering lives, so every
/// caller and any OSS consumer get the same behavior.
///
/// A **class**, not a struct: it owns a reference-typed, session-lived
/// `ChatDatabase` and a lazily-built handle-label cache. A caller opens the DB
/// once (in place, read-only) and reuses it for the conversation list AND every
/// render (the open-once, reuse path); `Export` is the natural home for that
/// handle. `@unchecked Sendable` for the same reason `ChatDatabase` is — it only
/// wraps thread-safe read state — so it can cross into `Task.detached`.
public final class Export: @unchecked Sendable {
    /// The open, preflighted database. Exposed so a caller that ALSO wants the
    /// conversation list can pass it to `Conversations.list(from:)` without
    /// re-copying.
    public let database: ChatDatabase

    private var ownsDatabase = false
    /// Lazily-built `handle ROWID → resolved label` cache, keyed by whether
    /// Contacts were resolved, shared across every `render` on this instance (the
    /// labels are the same for the whole db).
    private var cachedLabels: [Bool: [Int64: String]] = [:]

    /// Wrap an already-open `ChatDatabase` (the long-lived caller path: it opens
    /// once, lists, and renders against the same instance). Does NOT preflight; assumes the
    /// caller already did, matching how `Conversations.list(from:)` expects a
    /// preflighted db. The wrapper does NOT own the db lifecycle (`close()` /
    /// `deinit` leave it open), so a caller's session db is never cleaned up out
    /// from under it.
    public init(database: ChatDatabase) {
        self.database = database
    }

    /// One-shot path (CLI / scripts): open in place + preflight + own the db. The
    /// connection is closed on `close()` / `deinit` (nothing to delete — the DB is
    /// never copied). Throws `UnsupportedSchemaError` from preflight (fail-closed)
    /// — this is the schema guard the CLI skipped before it routed through `Export`.
    public convenience init(chatDBAt url: URL) throws {
        let db = try ChatDatabase(at: url)
        try db.preflight()  // step 2 — the guard the CLI skips today
        self.init(database: db)
        self.ownsDatabase = true
    }

    /// Close the db connection (only meaningful for the `chatDBAt:` path; a no-op
    /// when the caller owns the db lifecycle). Idempotent.
    public func close() {
        if ownsDatabase { database.cleanUp() }
    }

    deinit { close() }

    /// Resolved `handle ROWID → label` map, built once per mode and cached.
    /// Contacts resolution degrades gracefully: a denial → bare-identifier labels,
    /// never throws (mirroring `Conversations.list` and the caller's loader).
    private func resolvedLabels(resolveContacts: Bool) throws -> [Int64: String] {
        if let cached = cachedLabels[resolveContacts] { return cached }
        let handleLabels = try database.handleLabels()
        // Only touch Contacts (a TCC-gated request) when the caller opts in, so a
        // CLI export without `--contacts` neither prompts nor silently relabels.
        let names = resolveContacts ? ((try? ContactsMap.buildContactInfo().names) ?? [:]) : [:]
        let resolved = ContactsMap.resolve(handleLabels: handleLabels, contacts: names).resolved
        cachedLabels[resolveContacts] = resolved
        return resolved
    }
}

// MARK: - Rendering — one call, a format set, detection auto-run by default

extension Export {
    /// Output format. `.txt` = the compact daily-grouped transcript; `.jsonl` =
    /// one JSON object per message. A caller asks for one or both (a `Set`), so a
    /// single extract+detect pass feeds both renderers.
    public enum Format: Sendable, Hashable, CaseIterable {
        case txt
        case jsonl
    }

    /// Date window + token-fit trims for one render (mirrors the scope levers a
    /// UI exposes). All optional → the default is "full history, no trim".
    public struct Scope: Sendable, Equatable {
        /// Inclusive date window; nil = full history. The caller computes its
        /// bounded presets (last-30-days etc.) anchored to the thread's last
        /// message; that anchoring stays in the caller. `Export` takes the resolved
        /// absolute range, keeping locale/preset policy out of the OSS surface.
        public var dateRange: ClosedRange<Date>?
        /// Least-to-most-lossy fidelity trims.
        public var trim: Transcript.TrimOptions
        /// De-bias: relabel speakers as Person 1, Person 2, … and scrub the
        /// counterparty's number/name from the header. Off by default, so the
        /// rendered output is byte-identical to the validated reference. Unlike
        /// `trim`, this is not a fidelity lever — it changes identities, not
        /// content — so it lives alongside `trim` rather than inside it.
        public var anonymizeSpeakers: Bool
        /// Surface group **system events** (participant added/removed, rename, a
        /// member leaving) interleaved into the `.txt` body. An
        /// **additive include-toggle, off by default** — when off the output is
        /// byte-identical to today (system events excluded, as always). Meaningful
        /// only for a group; a 1:1 has none. The instance `render(_:)` extracts the
        /// events when this is set; the static `render(records:…)` takes them as a
        /// `systemEvents:` argument.
        public var showSystemEvents: Bool
        /// Which **scrubber** categories to auto-remove. Each enabled category's
        /// matches are scrubbed to `[redacted]`
        /// through the same reversible redaction pipeline as a manual redaction —
        /// no separate alert (the toggle is the consent). **Default `[]`** (all
        /// scrubbers off), so the rendered output is byte-identical to today.
        public var enabledScrubbers: Set<ScrubberCategory>
        /// Which **detector** categories to flag for review. A disabled category
        /// is never returned in `detected`, so the caller can honor a per-category
        /// "flag for review" toggle. **Default = all cases** (detectors on), so
        /// the rendered output / highlight marks are byte-identical to today.
        public var enabledDetectors: Set<SecretCategory>

        public init(
            dateRange: ClosedRange<Date>? = nil, trim: Transcript.TrimOptions = .none,
            anonymizeSpeakers: Bool = false, showSystemEvents: Bool = false,
            enabledScrubbers: Set<ScrubberCategory> = [],
            enabledDetectors: Set<SecretCategory> = Set(SecretCategory.allCases)
        ) {
            self.dateRange = dateRange
            self.trim = trim
            self.anonymizeSpeakers = anonymizeSpeakers
            self.showSystemEvents = showSystemEvents
            self.enabledScrubbers = enabledScrubbers
            self.enabledDetectors = enabledDetectors
        }

        /// Full history, no trim.
        public static let all = Scope()
    }

    /// What one render produced.
    ///
    /// - `txt` / `jsonl` are nil when that format wasn't requested; `txt` is the
    ///   empty string and `jsonl` empty for an empty (out-of-range) scope.
    /// - `result` is the redaction-aware `RenderResult` (spans + marks) a GUI caller
    ///   needs for select-to-redact + an unredacted-secret count; nil
    ///   when no `.txt` was asked for or the scope is empty (the CLI ignores it).
    ///   `RenderResult`'s init is internal to the engine, so an empty scope
    ///   cannot synthesize one (`nil` *is* the empty render, which a caller
    ///   already treats as "empty scope," not "error.")
    /// - `records` is the in-range record set, so a caller can size a meter /
    ///   reconcile counts without re-extracting.
    public struct Rendered: Sendable {
        public let txt: String?
        public let jsonl: String?
        public let result: Transcript.RenderResult?
        public let detected: [DetectedSecret]
        public let records: [MessageRecord]
        public let messageCount: Int

        public init(
            txt: String?,
            jsonl: String?,
            result: Transcript.RenderResult?,
            detected: [DetectedSecret],
            records: [MessageRecord],
            messageCount: Int
        ) {
            self.txt = txt
            self.jsonl = jsonl
            self.result = result
            self.detected = detected
            self.records = records
            self.messageCount = messageCount
        }
    }

    /// Extract → detect → render one conversation. The ONE seam.
    ///
    /// - `conversation`: a `Conversation`; its `chatIDs` / `targetHandles` feed
    ///   the extractor, its `primaryIdentifier` is the header / file identifier.
    /// - `formats`: which outputs to produce (default both).
    /// - `scope`: date window + trim (default full history, no trim).
    /// - `redactions`: caller-applied redactions to bake in (default none — the
    ///   app passes its live `RedactionSet`; the CLI passes none unless
    ///   `--redact-detected` builds one from the detected secrets). `render` only
    ///   *applies* redactions; it never invents them — redaction is a user action.
    /// - `detect`: when true (default), run `SecretDetector.detect` over the
    ///   in-range records and thread it into the redaction-aware renderer, so the
    ///   result's `highlightMarks` reflect what still looks sensitive. When
    ///   false, render with an empty detection set (still redaction-aware).
    /// - resolveContacts: when true (default), resolve handles to contact names
    ///   for the "Them" labels — this makes a TCC-gated Contacts request. Pass
    ///   false (e.g. a CLI export without `--contacts`) to keep bare-identifier
    ///   labels and never prompt.
    ///
    /// Detection/redaction ordering (load-bearing): (1) filter records to
    /// `scope.dateRange`; (2) detect over the FILTERED set; (3) render with
    /// `redactions:` + `detected:` together. A now-redacted secret drops out of
    /// `highlightMarks` because the renderer is handed both at once.
    ///
    /// - Note: BOTH outputs honor `redactions`: the `.txt` redaction-aware
    ///   renderer and `jsonLines` share one `applySpanRedactions` splice, so under
    ///   `--redact-detected` neither the `.txt` nor the `.jsonl` leaks a redacted
    ///   span. A whole-message redaction tombstones the `.txt` line and OMITS the
    ///   jsonl object (jsonl has no tombstone token — see `jsonLines`).
    public func render(
        _ conversation: Conversation,
        formats: Set<Format> = [.txt, .jsonl],
        scope: Scope = .all,
        redactions: RedactionSet = RedactionSet(),
        detect: Bool = true,
        resolveContacts: Bool = true
    ) throws -> Rendered {
        let labels = try resolvedLabels(resolveContacts: resolveContacts)
        let extractor = Extractor.forConversation(conversation, globalLabels: labels)
        let records = try database.read { db in
            try extractor.extractConversation(db, chatIDs: conversation.chatIDs)
        }
        // System events are opt-in (off by default) and group-only; extract them
        // only when both hold, so the default path never reads the extra columns.
        let systemEvents: [Transcript.SystemEvent]
        if scope.showSystemEvents, conversation.isGroup {
            systemEvents = try database.read { db in
                try extractor.extractSystemEvents(db, chatIDs: conversation.chatIDs)
            }
        } else {
            systemEvents = []
        }
        return Export.render(
            records: records, number: conversation.primaryIdentifier,
            formats: formats, scope: scope, redactions: redactions, detect: detect,
            group: Export.groupRenderInfo(for: conversation), systemEvents: systemEvents)
    }

    /// The `Transcript.GroupRenderInfo` for a group conversation (the roster
    /// header), or nil for a 1:1 — so a caller threads the group header through
    /// `render` straight from the selected `Conversation`. The display name is the
    /// group's `display_name` when set, else a legible join of participant labels
    /// (the composed "first-3 + N" picker name is the conversation picker's concern).
    /// The roster lists every member's resolved label (the label layer fills it),
    /// falling back to the normalized identifier for a member the label layer left
    /// unresolved.
    public static func groupRenderInfo(
        for conversation: Conversation
    ) -> Transcript.GroupRenderInfo? {
        guard conversation.isGroup else { return nil }
        let labels = conversation.participants.map { $0.label ?? $0.identifier }
        // A degenerate group with an empty roster has no labels to join, so fall
        // back to the conversation's (already non-empty) displayName so the
        // `# iMessage group transcript:` header is never blank.
        let joined = labels.joined(separator: ", ")
        let name = conversation.groupName ?? (joined.isEmpty ? conversation.displayName : joined)
        return Transcript.GroupRenderInfo(name: name, participantLabels: labels)
    }

    /// The scope-filtered record set — the exact slice `render` feeds the
    /// renderers (date-window filter; full history when `scope.dateRange` is nil).
    /// Exposed `public` so a downstream formatter can drive its own
    /// per-message layout over the same scoped records WITHOUT re-rendering the
    /// `.txt`/`.jsonl` strings. `render` calls this too, so there is a single
    /// filtering path and the two can never disagree.
    ///
    /// - Note: this applies the **date window only**. It does NOT apply
    ///   `scope.trim` or `scope.anonymizeSpeakers` — those transforms live inside
    ///   `Transcript.compactText`/`jsonLines`. A downstream formatter that bypasses
    ///   those engine renderers must call `preparedRecords(_:scope:)` instead, or
    ///   it silently ignores those toggles (the alternate-format deviation this fixes).
    public static func records(_ records: [MessageRecord], scope: Scope) -> [MessageRecord] {
        scope.dateRange.map { range in records.filter { range.contains($0.date) } } ?? records
    }

    /// The **fully-prepared** record set for a scope — the date-filtered slice with
    /// `scope.trim` and `scope.anonymizeSpeakers` already baked into each record, so
    /// a downstream formatter that consumes `MessageRecord`s directly
    /// (a tabular or document layout) honors those toggles using the engine's
    /// OWN logic — never a re-implemented transform that could drift (an
    /// alternate format is "an alternate output of the same scoped+redacted data").
    ///
    /// This reuses the exact helpers `Transcript.compactText` applies, in the same
    /// order, so the prepared records carry the identical relabeling/trim the
    /// `.txt`/`.jsonl` paths show:
    ///
    /// 1. **Date filter** (shared `records(_:scope:)` path).
    /// 2. **`trim.dropAttachmentPlaceholders`** — on a record with an attachment,
    ///    strip the typed placeholders from `text` via `Transcript.stripPlaceholders`;
    ///    a record left empty (an attachment-only message) is **dropped**, exactly as
    ///    `compactText` skips it.
    /// 3. **`trim.dropReactions`** — clear the reactions.
    /// 4. **`anonymizeSpeakers`** — relabel `speaker` AND each reaction's `by`
    ///    through `Transcript.anonymizationMap` (built from the date-filtered set, so
    ///    the `PN` numbering matches the `.txt`/`.jsonl` map exactly).
    ///
    /// Redaction is NOT applied here — that stays per-message at render time via
    /// `Transcript.redactedText(of:redactions:)`, mirroring `compactText` (which
    /// splices `[redacted]` over the trimmed body). A renderer feeds these prepared
    /// records to `redactedText`, so trim + anonymize + redaction all compose, and
    /// whole-message-redacted rows are still omitted by the renderer.
    public static func preparedRecords(
        _ records: [MessageRecord], scope: Scope
    ) -> [MessageRecord] {
        let filtered = Self.records(records, scope: scope)
        // The PN alias map is built from the date-filtered set — the same input
        // `compactText`/`jsonLines` see — so the speaker numbering is identical.
        let aliases =
            scope.anonymizeSpeakers ? Transcript.anonymizationMap(for: filtered) : [:]

        var out: [MessageRecord] = []
        out.reserveCapacity(filtered.count)
        for record in filtered {
            var text = record.text
            if scope.trim.dropAttachmentPlaceholders, record.hadAttachment {
                text = Transcript.stripPlaceholders(text)
                // Attachment-only message → nothing remains → drop it (matches
                // `compactText`'s `if text.isEmpty { continue }`).
                if text.isEmpty { continue }
            }

            var reactions = scope.trim.dropReactions ? [] : record.reactions
            var speaker = record.speaker
            if scope.anonymizeSpeakers {
                speaker = aliases[record.speaker] ?? record.speaker
                reactions = reactions.map {
                    Reaction(by: aliases[$0.by] ?? $0.by, emoji: $0.emoji)
                }
            }

            // Only rebuild when something changed (the no-trim/no-anonymize default
            // returns the record untouched, preserving its guid/date/flags).
            if text == record.text, speaker == record.speaker,
                reactions == record.reactions
            {
                out.append(record)
            } else {
                out.append(
                    MessageRecord(
                        guid: record.guid, date: record.date, speaker: speaker,
                        isTarget: record.isTarget, service: record.service, text: text,
                        hadAttachment: record.hadAttachment, reactions: reactions))
            }
        }
        return out
    }

    /// The **effective** redaction set for a render: the caller's manual
    /// `redactions` UNIONed with every span an enabled scrubber category produces
    /// over `records`. This is the SINGLE home for the
    /// scrubber→redaction fold — `Export.render` (the `.txt`/`.jsonl` path) and
    /// `preparedRedactedRecords` (the CSV/XLSX/PDF/DOCX path) both derive
    /// their effective redactions here, so a scrubbed value can never reach one
    /// format in cleartext while another shows `[redacted]`.
    ///
    /// `records` MUST be the already-date-filtered slice (the same set the renderer
    /// sees), so the scrubber scans exactly what is rendered. With
    /// `scope.enabledScrubbers` empty (the default) this returns `manual` unchanged,
    /// so today's bytes are reproduced.
    public static func effectiveRedactions(
        manual: RedactionSet, records: [MessageRecord], scope: Scope
    ) -> RedactionSet {
        guard !scope.enabledScrubbers.isEmpty else { return manual }
        var effective = manual
        for r in SecretScrubber.scrub(in: records, categories: scope.enabledScrubbers).all {
            effective.add(r)
        }
        return effective
    }

    /// The fully-prepared, fully-redacted record set for downstream formatters
    /// (CSV/XLSX/PDF/DOCX) — the parity fix that closes the scrubber data
    /// leak. A sibling of `preparedRecords` that goes one step further: it bakes the
    /// **rendered body** into each record's `text` so the formatters consume
    /// already-clean text and CANNOT leak a scrubbed value or a raw in-body
    /// participant name in any binary format.
    ///
    /// Pipeline, all via the engine's OWN logic (never re-implemented by the caller):
    /// 1. **Date filter + trim + speaker-alias** — `preparedRecords(_:scope:)`
    ///    (so the downstream-formatter path honors `trim`/`anonymizeSpeakers` identically).
    /// 2. **Effective redactions** — `manual` ∪ enabled scrubbers, via
    ///    `effectiveRedactions` (the SAME fold `Export.render` uses).
    /// 3. **Unified body render** — each record's `text` becomes
    ///    `Transcript.renderedBody` (redaction spans → `[redacted]` AND, under
    ///    anonymize, in-body name mentions → `PN`) in ONE pass over the ORIGINAL
    ///    offsets, so an alias before a redaction never desyncs the span. A
    ///    whole-message-redacted record returns `nil` → it is **dropped** (the row
    ///    omission the formatters used to do themselves).
    ///
    /// The returned records carry the FINAL body: a caller hands them to a
    /// formatter with an **empty** `RedactionSet()` (the redaction is already baked).
    ///
    /// - Important: redactions are applied against each record's **untrimmed**
    ///   `text` offsets, matching `compactText`. Under the non-default
    ///   `dropAttachmentPlaceholders`, placeholder stripping happens in step 1
    ///   while redaction offsets anchor to the original text — the same documented
    ///   trim/redaction edge `compactText` carries (not made worse here).
    public static func preparedRedactedRecords(
        _ records: [MessageRecord], scope: Scope, redactions: RedactionSet
    ) -> [MessageRecord] {
        // The same date-filtered slice the renderer scans, so the scrubber fold and
        // the body render see exactly what is exported.
        let filtered = Self.records(records, scope: scope)
        let effective = Self.effectiveRedactions(
            manual: redactions, records: filtered, scope: scope)
        // The speaker→PN map, built from the date-filtered set so the in-body alias
        // numbering matches `compactText`/`jsonLines` exactly. Empty when not
        // anonymizing (so `renderedBody` aliases nothing).
        let aliases =
            scope.anonymizeSpeakers ? Transcript.anonymizationMap(for: filtered) : [:]

        // trim + speaker-alias prepared records (date filter already applied above,
        // re-applied identically inside — `preparedRecords` is idempotent on a
        // date-filtered set since `records(_:scope:)` is a no-op when in range).
        let prepared = Self.preparedRecords(filtered, scope: scope)

        var out: [MessageRecord] = []
        out.reserveCapacity(prepared.count)
        for record in prepared {
            // Bake the unified body: effective redactions + in-body name aliases.
            // nil ⇒ whole-message redacted ⇒ drop the row.
            guard
                let body = Transcript.renderedBody(
                    of: record, redactions: effective, aliases: aliases)
            else { continue }
            if body == record.text {
                out.append(record)
            } else {
                out.append(
                    MessageRecord(
                        guid: record.guid, date: record.date, speaker: record.speaker,
                        isTarget: record.isTarget, service: record.service, text: body,
                        hadAttachment: record.hadAttachment, reactions: record.reactions))
            }
        }
        return out
    }

    /// Render an already-extracted, in-memory record set (the in-memory caller path: extract
    /// once, re-render many scopes cheaply). Same detect / redact / format
    /// contract as the instance `render`, minus the SQLite read. `number` is the
    /// header / file identifier (= `conversation.primaryIdentifier`).
    ///
    /// Pure (no DB), so this is the unit-test seam and the method a caller's
    /// `recompute` calls off the main actor.
    public static func render(
        records: [MessageRecord],
        number: String,
        formats: Set<Format> = [.txt],
        scope: Scope = .all,
        redactions: RedactionSet = RedactionSet(),
        detect: Bool = true,
        group: Transcript.GroupRenderInfo? = nil,
        systemEvents: [Transcript.SystemEvent] = []
    ) -> Rendered {
        // (1) Filter to the scope's date window (nil = full history) — the single
        // filtering path, shared with the public `records(_:scope:)` accessor.
        let filtered = Self.records(records, scope: scope)

        // Empty scope → empty strings + nil result (the caller's existing
        // "nil RenderResult is the empty render" contract).
        guard !filtered.isEmpty else {
            return Rendered(
                txt: formats.contains(.txt) ? "" : nil,
                jsonl: formats.contains(.jsonl) ? "" : nil,
                result: nil, detected: [], records: [], messageCount: 0)
        }

        // (2) Detect over the FILTERED set — cheap, pure, idempotent. Honor the
        // per-category "flag for review" toggle: a disabled detector category is
        // never returned (default = all on, so today's behavior is unchanged).
        let detected =
            detect ? SecretDetector.detect(in: filtered, enabled: scope.enabledDetectors) : []

        // (2b) Fold the enabled opt-in scrubbers (default `[]` =
        // no-op) ON TOP of the caller's manual `redactions` via the shared
        // `effectiveRedactions` helper — the SINGLE home for the scrubber→redaction
        // fold, reused by the downstream-formatter path so a scrubbed value can never reach
        // one format in cleartext while another shows `[redacted]`.
        let effectiveRedactions = Self.effectiveRedactions(
            manual: redactions, records: filtered, scope: scope)

        // (3) Render. Both renderers are handed the same `redactions` so neither
        // output leaks a redacted span. The `.txt` renderer additionally
        // takes `detected:`, so a now-redacted secret drops out of
        // `highlightMarks`; jsonl emits no highlights, so it takes redactions only.
        // System events honor the same date window as the messages (so a narrowed
        // scope drops events outside it). Only the `.txt` path interleaves them;
        // `compactText` further suppresses them when anonymizing or for a 1:1.
        let scopedEvents =
            scope.showSystemEvents
            ? scope.dateRange.map { range in systemEvents.filter { range.contains($0.date) } }
                ?? systemEvents
            : []

        var txt: String?
        var result: Transcript.RenderResult?
        if formats.contains(.txt) {
            let rendered = Transcript.compactText(
                records: filtered, number: number, trim: scope.trim,
                redactions: effectiveRedactions, detected: detected,
                anonymize: scope.anonymizeSpeakers, group: group,
                systemEvents: scopedEvents)
            txt = rendered.text
            result = rendered
        }
        let jsonl =
            formats.contains(.jsonl)
            ? Transcript.jsonLines(
                records: filtered, redactions: effectiveRedactions,
                anonymize: scope.anonymizeSpeakers) : nil

        return Rendered(
            txt: txt, jsonl: jsonl, result: result, detected: detected,
            records: filtered, messageCount: filtered.count)
    }
}
