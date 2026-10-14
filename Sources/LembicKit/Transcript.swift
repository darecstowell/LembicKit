import Foundation

/// Renders the compact daily-grouped .txt and the .jsonl, byte-compatible
/// with the Python prototype's `write_direct` (the diff target).
public enum Transcript {
    /// The account owner's speaker label, set by `Extractor.label(isFromMe:…)`.
    /// The renderer already hardcodes it in the legend; named here so the
    /// anonymization map can anchor the owner to Person 1.
    static let meLabel = "Me"
    /// The other person's speaker label in a 1:1, set by `Extractor.label(isFromMe:…)`.
    static let themLabel = "Them"
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
        /// People who wrote or were named in an event but are no longer members.
        /// The header lists them after the members, as "Carla (left)".
        public let formerLabels: [String]

        public init(name: String, participantLabels: [String], formerLabels: [String] = []) {
            self.name = name
            self.participantLabels = participantLabels
            self.formerLabels = formerLabels
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
    static func anonymizationMap(
        for records: [MessageRecord], knownNames: [String: [String]] = [:]
    ) -> [String: String] {
        var seen: [String] = []
        func note(_ label: String) { if !seen.contains(label) { seen.append(label) } }
        for r in records {
            note(r.speaker)
            for reaction in r.reactions { note(reaction.by) }
        }
        // Labels the caller names but that never spoke (a quiet group member).
        for label in knownNames.keys.sorted() { note(label) }
        // Float the owner to the front (stable order for everyone else).
        let ordered = seen.filter { $0 == meLabel } + seen.filter { $0 != meLabel }
        var map: [String: String] = [:]
        for (i, label) in ordered.enumerated() { map[label] = "P\(i + 1)" }
        return map
    }
}
