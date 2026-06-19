import Foundation

/// One member of a group chat's roster. Carries the handle ROWID
/// (the extraction/label key) and its normalized identifier (phone/email). The
/// resolved speaker label (first name / `First L.` / formatted number) is left
/// nil here — the label layer's helper fills it from a Contacts map; the grouping
/// layer only stashes the raw roster so the grouping stays Contacts-free and
/// unit-testable. "Me" is never a participant (it isn't in `chat_handle_join`).
public struct Participant: Sendable, Equatable {
    /// The participant's handle ROWID — the key `Extractor.label` resolves.
    public let handleID: Int64
    /// The normalized identifier (E.164 phone / lowercased email), or `h<id>`
    /// when the handle string is unknown. The human-readable counterpart to
    /// `handleID`.
    public let identifier: String
    /// The resolved speaker label (the label layer fills this: first name /
    /// `First L.` / formatted number). Nil at the raw-roster grouping layer.
    public var label: String?

    public init(handleID: Int64, identifier: String, label: String? = nil) {
        self.handleID = handleID
        self.identifier = identifier
        self.label = label
    }
}

/// One conversation, **either** a 1:1 *or* a group (the unified noun for both).
///
/// - **1:1** (`isGroup == false`): the union of every 1:1 (style=45) chat that
///   belongs to one person across all their identifiers (phone + email → one).
///   `participants` is empty and `groupName` is nil.
/// - **Group** (`isGroup == true`): the exact-participant-set union of every
///   style=43 chat sharing an identical roster (forks stitched into one).
///   `participants` is the roster; `groupName` is the chat's `display_name`
///   (nil when unnamed — the composed name is computed later, by the label layer).
///
/// `ChatDatabase.ConversationSummary` / `GroupConversationSummary` are the
/// row-level nouns this is folded from.
///
/// A value type with no `Data` blobs, so it's trivially `Sendable` and crosses
/// freely between the main actor and `Task.detached` readers. Display formatting
/// (US number pretty-printing) and avatars are deliberately *not* here — those
/// are UI concerns a caller layers on (e.g. reading `avatars[identifier]` from
/// `ContactsMap.ContactInfo` and pretty-printing bare numbers itself).
public struct Conversation: Identifiable, Sendable, Equatable {
    /// Stable key: the resolved contact name when known (so a person's phone +
    /// email chats share one id), else the normalized identifier (each unknown
    /// number stands alone).
    public let id: String
    /// Display label: the resolved contact name, else the normalized identifier
    /// (raw E.164 / email — the engine does NOT pretty-print; that's a UI concern).
    public let displayName: String
    /// Every 1:1 chat ROWID unioned for this person — the input to
    /// `Extractor.extractConversation(_:chatIDs:)`.
    public let chatIDs: Set<Int64>
    /// Their handle ROWIDs across all identifiers — the input to
    /// `Extractor(targetHandles:handleLabels:)` ("Them" vs "Me" labeling).
    public let targetHandles: Set<Int64>
    /// Every normalized identifier (phone/email) in this person's union. The
    /// human-readable counterpart to `targetHandles`; lets a caller re-attach a
    /// per-identifier avatar ("first identifier with a photo wins") or otherwise
    /// reconstruct the union without re-querying.
    public let identifiers: Set<String>
    /// Most-recent real message across the union (recency sort).
    public let lastMessageDate: Date
    /// Total real messages across the union (reactions/system excluded).
    public let messageCount: Int
    /// The identifier passed to the transcript renderer / used in file names —
    /// the normalized identifier of the most-recent chat in the union.
    public let primaryIdentifier: String
    /// Whether this matched a Contact (name resolved) vs. a bare number/email.
    /// For a group: true once any participant resolves (currently always false at
    /// the grouping layer; the label layer doesn't run here).
    public let isContact: Bool
    /// Whether this is a group chat (style=43) vs. a 1:1 (style=45). Drives the
    /// conversation picker's glyph, its conditional prompt, and the roster header.
    /// False for every 1:1.
    public let isGroup: Bool
    /// The group's roster (empty for a 1:1): every other member's handle +
    /// normalized identifier, with a slot for a resolved label (the label layer
    /// fills it). Stitched forks contribute the **union** of their members.
    public let participants: [Participant]
    /// The group's `display_name` when named, else nil (most groups are unnamed —
    /// the composed name is the label layer's and the picker's job). Always nil for
    /// a 1:1.
    public let groupName: String?

    public init(
        id: String,
        displayName: String,
        chatIDs: Set<Int64>,
        targetHandles: Set<Int64>,
        identifiers: Set<String>,
        lastMessageDate: Date,
        messageCount: Int,
        primaryIdentifier: String,
        isContact: Bool,
        isGroup: Bool = false,
        participants: [Participant] = [],
        groupName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.chatIDs = chatIDs
        self.targetHandles = targetHandles
        self.identifiers = identifiers
        self.lastMessageDate = lastMessageDate
        self.messageCount = messageCount
        self.primaryIdentifier = primaryIdentifier
        self.isContact = isContact
        self.isGroup = isGroup
        self.participants = participants
        self.groupName = groupName
    }
}

/// How group-chat rows are stitched into `Conversation`s. The
/// default is `.exact` — the only behavior that ever shipped — so a caller that
/// doesn't opt in gets byte-identical output to the exact-set pass.
///
/// - `.exact`: rows merge **only** when their sorted participant-handle-set is
///   identical (the raw-roster grouping). A membership change (someone
///   added/removed) is a different set and stays a separate `Conversation`. This
///   is deterministic and has no false-merge risk.
/// - `.fuzzy`: an **opt-in, heuristic** second pass over the exact-set groups
///   that additionally merges groups whose rosters look like the *same group with
///   changed membership* (members added/removed over time). Approximate by
///   nature — see `fuzzyMerge` for the conservative rule and its caveats. Never
///   the default; a caller can gate it behind an off-by-default toggle.
public enum GroupStitch: Sendable {
    case exact
    case fuzzy
}

/// The engine's entry point for going from a `chat.db` to people-level
/// `Conversation`s. Mirrors `ContactsMap`'s enum-of-statics shape. Two layers so
/// the pure grouping (`group`) is unit-testable without a real DB, while
/// `list(from:)` / `list(at:)` wire it to one.
public enum Conversations {
    /// Open the conversation list from a `ChatDatabase` that's already been opened
    /// + preflighted. Resolves Contacts when `resolvingContacts` is true (graceful:
    /// a Contacts denial degrades to bare identifiers, never throws). The returned
    /// list is newest-first.
    ///
    /// `contacts` lets a caller inject an already-built normalized-handle → name
    /// map (a caller builds `ContactInfo` once for names AND avatars AND
    /// handle-label resolution, so it passes the map in rather than paying for a
    /// second enumeration). Pass nil to let this build it internally when
    /// `resolvingContacts` is true.
    ///
    /// `stitch` selects the group-merge strategy. `.exact` (the
    /// default) stitches only identical participant-sets — byte-identical to what
    /// always shipped. `.fuzzy` additionally runs the opt-in membership-change
    /// merge over the exact-set groups; 1:1 conversations are untouched either way.
    public static func list(
        from db: ChatDatabase,
        resolvingContacts: Bool = true,
        contacts: [String: String]? = nil,
        stitch: GroupStitch = .exact
    ) throws -> [Conversation] {
        let summaries = try db.conversationSummaries()
        let names: [String: String]
        if let contacts {
            names = contacts
        } else if resolvingContacts {
            // Contacts is optional: resolve names when granted,
            // else fall back to identifiers. A denial must never throw out of the
            // list path.
            names = (try? ContactsMap.buildContactInfo().names) ?? [:]
        } else {
            names = [:]
        }
        // Every handle ROWID grouped by its normalized identifier. chat.db often
        // carries more than one handle row for the same number/email (service or
        // re-registration churn); only one lands in a chat's `chat_handle_join`,
        // so the others' messages fall through to the contact name and split the
        // counterparty into a phantom extra speaker. Handing this to `group` lets
        // it claim ALL of a person's handles as "Them".
        let handleLabels = try db.handleLabels()
        let handlesByIdentifier = Dictionary(
            grouping: handleLabels,
            by: { ContactsMap.normalizeHandle($0.value) }
        ).mapValues { Set($0.map(\.key)) }
        let oneToOnes = group(summaries, contacts: names, handlesByIdentifier: handlesByIdentifier)

        // Group chats (style=43): exact-participant-set stitched, then merged into
        // the same recency-sorted list. handleLabels lets the roster carry each
        // participant's normalized identifier without a re-query.
        // `participantCounts` (one grouped query, this session) orders each
        // roster most-active-first — summed across a fork's chatIDs
        // in memory, never per row.
        let groupSummaries = try db.groupConversationSummaries()
        let participantCounts = try db.groupParticipantMessageCounts()
        var groups = groupGroups(
            groupSummaries, handleLabels: handleLabels, names: names,
            participantCounts: participantCounts)

        // The opt-in fuzzy merge: a conservative second pass that merges exact-set
        // groups representing the same group with changed membership. `.exact` (the
        // default) skips this entirely, so the output is unchanged.
        if stitch == .fuzzy {
            groups = fuzzyMerge(groups, names: names)
        }

        return (oneToOnes + groups).sorted { $0.lastMessageDate > $1.lastMessageDate }
    }

    /// One-shot convenience for a CLI / script: open + preflight + list, owning
    /// the `ChatDatabase` for the duration and closing it on return. Apps that
    /// reuse the db for extraction should call `list(from:)` with their own
    /// instance instead (open once, reuse). The DB is opened in place, read-only;
    /// nothing is copied.
    public static func list(
        at url: URL,
        resolvingContacts: Bool = true
    ) throws -> [Conversation] {
        let db = try ChatDatabase(at: url)
        defer { db.cleanUp() }
        try db.preflight()
        return try list(from: db, resolvingContacts: resolvingContacts)
    }

    // MARK: - 1:1 multi-identifier union

    /// Pure grouping: fold raw per-chat summaries into people. No DB, no Contacts
    /// I/O — `contacts` is the normalized-handle → name map (empty ⇒ every chat
    /// stands alone as a bare identifier). Keyed by resolved contact name when
    /// known (so phone + email merge), else by the normalized identifier (each
    /// unknown number stands alone). Newest conversation first. This is the
    /// engine's multi-identifier union and the unit-test seam.
    public static func group(
        _ summaries: [ChatDatabase.ConversationSummary],
        contacts: [String: String],
        handlesByIdentifier: [String: Set<Int64>] = [:]
    ) -> [Conversation] {
        struct Acc {
            var chatIDs = Set<Int64>()
            var handles = Set<Int64>()
            var identifiers = Set<String>()
            var last = Date.distantPast
            var count = 0
            var name: String?
            var number = ""
        }
        var groups: [String: Acc] = [:]
        for s in summaries {
            let ident = s.identifier ?? "h\(s.handleID)"
            let norm = ContactsMap.normalizeHandle(ident)
            let name = contacts[norm]
            let key = name ?? norm
            var acc = groups[key] ?? Acc()
            acc.chatIDs.insert(s.chatID)
            acc.handles.insert(s.handleID)
            acc.identifiers.insert(norm)
            acc.count += s.messageCount
            acc.name = acc.name ?? name
            if s.lastMessageDate >= acc.last {
                acc.last = s.lastMessageDate
                acc.number = norm
            }
            groups[key] = acc
        }
        return
            groups
            .map { key, a in
                // Claim every handle ROWID sharing one of this person's normalized
                // identifiers — not just the one each chat registered — so all of
                // the counterparty's messages label as "Them". Without this, a
                // stray duplicate handle leaks them in as an extra speaker (glaring
                // once anonymized: a 1:1 sprouts a phantom "Person 3").
                var handles = a.handles
                for id in a.identifiers { handles.formUnion(handlesByIdentifier[id] ?? []) }
                return Conversation(
                    id: key,
                    displayName: a.name ?? key,
                    chatIDs: a.chatIDs,
                    targetHandles: handles,
                    identifiers: a.identifiers,
                    lastMessageDate: a.last,
                    messageCount: a.count,
                    primaryIdentifier: a.number.isEmpty ? key : a.number,
                    isContact: a.name != nil)
            }
            .sorted { $0.lastMessageDate > $1.lastMessageDate }
    }

    // MARK: - Group exact-set stitch

    /// Pure exact-participant-set grouping for group chats — the
    /// group-side mirror of `group`. No DB, no Contacts I/O; this is the unit-test
    /// seam. `handleLabels` (handle ROWID → raw phone/email) resolves each
    /// roster member's normalized identifier.
    ///
    /// `names` (the `ContactsMap.buildContactInfo().names` map, keyed by normalized
    /// handle) fills each `Participant.label` with its resolved group-speaker label
    /// (first name / `First L.` / formatted number). Pass `[:]` to leave labels
    /// nil (the raw-roster behavior — the grouping stays Contacts-free).
    ///
    /// Forks that share an **identical** sorted participant-handle-set merge into
    /// one `Conversation` (collect all their `chatIDs`; `lastMessageDate` = max,
    /// `messageCount` = Σ) — extraction then unions + ROWID-dedupes their messages.
    /// A membership change (someone added/removed) is a *different* set, so it
    /// stays a separate entry. Newest conversation first; the caller re-sorts the
    /// merged 1:1-plus-group list, so ordering here is only a stable convenience.
    ///
    /// `participantCounts` (`chatID → (handleID → real-message count)`, from
    /// `ChatDatabase.groupParticipantMessageCounts()`) orders each group's roster
    /// **most-active-first**: a participant's volume is summed across
    /// the stitched fork's chatIDs, and `participants` is sorted by descending
    /// total, ties (incl. silent 0-message members absent from the map) broken by
    /// the normalized identifier so the order stays deterministic. Pass `[:]` to
    /// keep the raw handle-ROWID order (the unit-test default — order isn't
    /// asserted there).
    public static func groupGroups(
        _ summaries: [ChatDatabase.GroupConversationSummary],
        handleLabels: [Int64: String] = [:],
        names: [String: String] = [:],
        participantCounts: [Int64: [Int64: Int]] = [:]
    ) -> [Conversation] {
        struct Acc {
            var chatIDs = Set<Int64>()
            var handleSet: [Int64] = []  // the sorted set key (shared by the fork)
            var last = Date.distantPast
            var count = 0
            var groupName: String?
            var primaryIdentifier = ""
        }
        // Key by the sorted participant-handle-set so forks collapse. An empty
        // roster (a degenerate group with no joined handles) keys on "" and stands
        // alone rather than colliding with other empty-roster rows by accident —
        // tag it with the chatID so each stays distinct.
        var groups: [String: Acc] = [:]
        for s in summaries {
            let handles = s.participantHandles  // already sorted by the enumerator
            let key =
                handles.isEmpty
                ? "empty:\(s.chatID)"
                : handles.map(String.init).joined(separator: ",")
            var acc = groups[key] ?? Acc()
            acc.chatIDs.insert(s.chatID)
            acc.handleSet = handles
            acc.count += s.messageCount
            // Keep the first non-nil display name across the fork (a re-created
            // group usually carries the same name; prefer a name to nil).
            acc.groupName = acc.groupName ?? s.displayName
            if s.lastMessageDate >= acc.last {
                acc.last = s.lastMessageDate
                acc.primaryIdentifier = s.identifier ?? "group\(s.chatID)"
            }
            groups[key] = acc
        }
        return
            groups
            .map { _, a in
                // Sum each member's real-message volume across the stitched fork's
                // chatIDs, then order the roster most-active-first.
                // Silent members (no count row) sit at 0 and fall to the end; ties
                // break on the normalized identifier so the order is deterministic.
                let totals: [Int64: Int] = a.chatIDs.reduce(into: [:]) { acc, cid in
                    for (hid, n) in participantCounts[cid] ?? [:] { acc[hid, default: 0] += n }
                }
                let ordered = a.handleSet.map { hid -> Participant in
                    let ident =
                        handleLabels[hid].map { ContactsMap.normalizeHandle($0) } ?? "h\(hid)"
                    return Participant(handleID: hid, identifier: ident)
                }
                .sorted { lhs, rhs in
                    let lc = totals[lhs.handleID] ?? 0
                    let rc = totals[rhs.handleID] ?? 0
                    if lc != rc { return lc > rc }
                    return lhs.identifier < rhs.identifier
                }
                var participants = ordered
                // Fill each member's resolved speaker label when a Contacts
                // name map is supplied — the single source the roster header,
                // the picker's composed name, and group extraction all read.
                // An empty `names` map means "no resolution requested" → leave the
                // labels nil (the raw-roster contract; the change stays additive).
                if !names.isEmpty {
                    let byHandle = groupSpeakerLabels(participants: participants, names: names)
                    for i in participants.indices {
                        participants[i].label = byHandle[participants[i].handleID]
                    }
                }
                let identifiers = Set(participants.map(\.identifier))
                // Display name: the group's display_name when named, else a stable
                // placeholder (the composed first-3-names name is the label layer's
                // and the picker's job — the grouping layer only needs something
                // non-empty + deterministic).
                // A degenerate group with an EMPTY roster (no joined handles, no
                // display_name) would otherwise join to "" — fall back to the
                // group's primary identifier (guid / `group<chatID>`) so neither the
                // picker row nor the `# iMessage group transcript:` header is blank.
                let rosterName = identifiers.sorted().joined(separator: ", ")
                let display = a.groupName ?? (rosterName.isEmpty ? a.primaryIdentifier : rosterName)
                return Conversation(
                    id: "group:" + a.handleSet.map(String.init).joined(separator: ","),
                    displayName: display,
                    chatIDs: a.chatIDs,
                    targetHandles: Set(a.handleSet),
                    identifiers: identifiers,
                    lastMessageDate: a.last,
                    messageCount: a.count,
                    primaryIdentifier: a.primaryIdentifier,
                    isContact: false,
                    isGroup: true,
                    participants: participants,
                    groupName: a.groupName)
            }
            .sorted { $0.lastMessageDate > $1.lastMessageDate }
    }

    // MARK: - Opt-in fuzzy / membership-change stitching
    //
    // ⚠️ HEURISTIC, opt-in, off by default. This runs ONLY when the caller passes
    // `stitch: .fuzzy` (a caller can gate it behind an off-by-default toggle).
    // When off, `groupGroups`' exact-set output is returned verbatim and
    // the whole pass is dead code — the proof the feature is purely additive.
    //
    // The risk this whole pass manages is FALSE merges (folding two genuinely
    // different groups into one) and runaway transitive CHAINING (A~B, B~C, B~D…
    // snowballing into one giant blob). The thresholds and the clique rule below
    // are deliberately conservative — tuned to only fire on a clean "members
    // added/removed over time" signal — and are all gathered in `FuzzyRule` so
    // they're easy to find and adjust.

    /// The tunable thresholds for the membership-change merge, all in one place.
    ///
    /// Two exact-set groups are deemed "the same group, changed membership" when
    /// **either**:
    ///
    /// 1. **Subset/superset with a bounded delta** — one roster fully contains the
    ///    other (the clean "N members added or removed" signal), the smaller is at
    ///    least `minSubsetRatio` of the larger, AND they differ by at most
    ///    `maxRosterDelta` members. The ratio floor stops a 2-person group folding
    ///    into a 15-person group just because it's technically a subset; the
    ///    absolute delta cap stops a small-but-proportional drift (e.g. 8 vs 12,
    ///    ratio .67) from merging. **Both** bounds must hold.
    /// 2. **High Jaccard corroborated by a shared name** — the symmetric overlap
    ///    `|A∩B| / |A∪B|` is at least `minJaccard`, AND both groups carry the
    ///    *same* non-nil `display_name`. The name is the corroboration that makes a
    ///    near-but-not-subset overlap (e.g. a simultaneous add+remove) safe to
    ///    merge; without a shared name we do NOT merge on Jaccard alone.
    ///
    /// Tiny rosters are additionally floored at `minRosterSize` on **both** sides
    /// of a pair, so a 1- or 2-person thread never anchors a fuzzy merge (those are
    /// where subset/Jaccard signals are least trustworthy).
    struct FuzzyRule {
        /// Smaller roster must be ≥ this fraction of the larger (subset rule).
        /// 0.6 ⇒ at a 5-member group you may drop to 3 (3/5 = .6) but not to 2.
        static let minSubsetRatio = 0.6
        /// Max member difference for the subset rule. ≤ 3 keeps it to a few
        /// adds/removes; a bigger jump is more likely two different groups.
        static let maxRosterDelta = 3
        /// Jaccard floor for the name-corroborated rule. 0.8 is a strong overlap
        /// (e.g. 4 of 5 shared), only ever acted on WITH a matching display_name.
        static let minJaccard = 0.8
        /// No fuzzy pair may involve a roster smaller than this (3 = a real group).
        static let minRosterSize = 3
    }

    /// The opt-in membership-change merge. Pure (no DB / Contacts I/O), so the
    /// heuristic and its transitivity control are unit-testable on synthetic
    /// `Conversation`s. Takes the exact-set groups from `groupGroups` and returns a
    /// (possibly shorter) list where clusters of "same group, changed membership"
    /// have been folded into one.
    ///
    /// **Transitivity / blob control:** pairs that satisfy `FuzzyRule` form an
    /// undirected graph, but we do NOT take connected components (that's exactly
    /// what lets a chain of weak links A~B~C~D collapse into one blob). Instead we
    /// merge only **maximal cliques** — a cluster is folded only when *every* pair
    /// inside it independently meets the rule. So A and C merge with B only if A~C
    /// also holds; a weak chain where A and C are too far apart leaves A~B and B~C
    /// as separate two-member merges (B joins whichever clique it fits, greedily by
    /// roster size). This caps the damage of one over-eager link to a pair.
    ///
    /// A merged cluster unions `chatIDs` and the roster (everyone who was ever a
    /// member), sums `messageCount`, takes the max `lastMessageDate`, and picks the
    /// most-recent non-nil `groupName` (else the composed identifier list).
    static func fuzzyMerge(
        _ groups: [Conversation],
        names: [String: String] = [:]
    ) -> [Conversation] {
        let groupChats = groups.filter(\.isGroup)
        let others = groups.filter { !$0.isGroup }
        guard groupChats.count > 1 else { return groups }

        // Stable order so clique assignment is deterministic regardless of input
        // order: newest first, then by id.
        let nodes = groupChats.sorted {
            if $0.lastMessageDate != $1.lastMessageDate {
                return $0.lastMessageDate > $1.lastMessageDate
            }
            return $0.id < $1.id
        }

        // Precompute pairwise "same group?" once.
        var related = Array(
            repeating: Array(repeating: false, count: nodes.count), count: nodes.count)
        for i in nodes.indices {
            for j in (i + 1)..<nodes.count where fuzzyPairMatches(nodes[i], nodes[j]) {
                related[i][j] = true
                related[j][i] = true
            }
        }

        // Greedy clique clustering: walk nodes newest-first; each ungrouped node
        // seeds a cluster, then we admit a candidate ONLY if it's related to every
        // member already in the cluster (the maximal-clique / internal-consistency
        // rule that blocks weak transitive chaining). A node that doesn't fit the
        // seed's clique falls through to seed/join a later one.
        var clusterOf = Array(repeating: -1, count: nodes.count)
        var clusters: [[Int]] = []
        for i in nodes.indices where clusterOf[i] == -1 {
            var members = [i]
            clusterOf[i] = clusters.count
            for j in nodes.indices where clusterOf[j] == -1 && j != i {
                if members.allSatisfy({ related[$0][j] }) {
                    members.append(j)
                    clusterOf[j] = clusters.count
                }
            }
            clusters.append(members)
        }

        let merged = clusters.map { members -> Conversation in
            members.count == 1
                ? nodes[members[0]] : mergeCluster(members.map { nodes[$0] }, names: names)
        }
        return others + merged
    }

    /// True when two exact-set groups are "the same group, changed membership"
    /// under `FuzzyRule`. The single pairwise predicate `fuzzyMerge` builds its
    /// relation graph from — kept separate so the rule is unit-testable on a pair.
    static func fuzzyPairMatches(_ a: Conversation, _ b: Conversation) -> Bool {
        let lhs = a.targetHandles
        let rhs = b.targetHandles
        // Tiny-roster floor: never let a 1- or 2-person thread anchor a merge.
        guard lhs.count >= FuzzyRule.minRosterSize, rhs.count >= FuzzyRule.minRosterSize else {
            return false
        }
        // Exact sets are already merged by groupGroups; identical rosters here would
        // be a no-op, but guard anyway so the ratio math below never divides oddly.
        guard lhs != rhs else { return true }

        let intersection = lhs.intersection(rhs).count
        let larger = Swift.max(lhs.count, rhs.count)
        let smaller = Swift.min(lhs.count, rhs.count)
        let delta = larger - smaller

        // Rule 1 — subset/superset with a bounded delta (clean adds/removes).
        let isSubset = intersection == smaller  // smaller ⊆ larger
        if isSubset, delta <= FuzzyRule.maxRosterDelta,
            Double(smaller) / Double(larger) >= FuzzyRule.minSubsetRatio
        {
            return true
        }

        // Rule 2 — high Jaccard, but ONLY with a corroborating shared display_name.
        let union = lhs.union(rhs).count
        let jaccard = union == 0 ? 0 : Double(intersection) / Double(union)
        if jaccard >= FuzzyRule.minJaccard,
            let an = a.groupName, let bn = b.groupName, !an.isEmpty, an == bn
        {
            return true
        }
        return false
    }

    /// Fold a clique of "same group" exact-set conversations into one. Unions
    /// `chatIDs` + the roster (everyone ever a member), sums `messageCount`, takes
    /// the max `lastMessageDate`, and keeps the most-recent non-nil `groupName`.
    /// Re-derives `participants` (deduped + relabeled via `names` when supplied) so
    /// the merged roster is coherent. Never called with fewer than two members.
    private static func mergeCluster(
        _ members: [Conversation],
        names: [String: String]
    ) -> Conversation {
        // The most-recent member anchors the name + primary identifier (a re-created
        // or renamed group's latest name is the one a user recognizes).
        let byRecency = members.sorted { $0.lastMessageDate > $1.lastMessageDate }
        let chatIDs = members.reduce(into: Set<Int64>()) { $0.formUnion($1.chatIDs) }
        let targetHandles = members.reduce(into: Set<Int64>()) { $0.formUnion($1.targetHandles) }
        let count = members.reduce(0) { $0 + $1.messageCount }
        let last = members.map(\.lastMessageDate).max() ?? .distantPast
        let groupName = byRecency.compactMap(\.groupName).first { !$0.isEmpty }
        let primaryIdentifier = byRecency.first?.primaryIdentifier ?? ""

        // Roster = the union of every member's participants, deduped by handle ROWID
        // (the same person may appear in several forks). Re-label from `names` when
        // a Contacts map is supplied so the merged roster carries resolved labels;
        // else keep whatever labels the inputs had.
        var seen = Set<Int64>()
        var participants: [Participant] = []
        for member in byRecency {
            for p in member.participants where seen.insert(p.handleID).inserted {
                participants.append(p)
            }
        }
        if !names.isEmpty {
            let byHandle = groupSpeakerLabels(participants: participants, names: names)
            for i in participants.indices {
                participants[i].label = byHandle[participants[i].handleID]
            }
        }
        let identifiers = Set(participants.map(\.identifier))
        let display = groupName ?? identifiers.sorted().joined(separator: ", ")

        return Conversation(
            id: "group:" + targetHandles.sorted().map(String.init).joined(separator: ","),
            displayName: display,
            chatIDs: chatIDs,
            targetHandles: targetHandles,
            identifiers: identifiers,
            lastMessageDate: last,
            messageCount: count,
            primaryIdentifier: primaryIdentifier,
            isContact: false,
            isGroup: true,
            participants: participants,
            groupName: groupName)
    }

    /// Per-thread group speaker labels: a group's roster + a
    /// Contacts name map → `[handleID: speakerLabel]`. The single source every
    /// renderer reads (the roster header, the picker's composed name, and
    /// group extraction's `handleLabels`). Pure — no DB, no Contacts I/O — so it's
    /// unit-testable on a synthetic roster.
    ///
    /// `names` is keyed by **normalized handle** (the `ContactsMap.buildContactInfo`
    /// output); each `Participant.identifier` is already normalized, so they match.
    ///
    /// Rules:
    /// - Resolved contact name → its **first token** ("Alice Tan" → "Alice").
    /// - **Per-thread collision:** if ≥2 members resolve to the same first name,
    ///   disambiguate every colliding member as `First L.` (last initial). If that
    ///   still collides (same first name + last initial), fall back to the full name.
    /// - **Unknown handle** (no name) → a **formatted display number**
    ///   (`(844) 399-6927` for a US 10/11-digit; otherwise the raw identifier).
    /// - "Me" is never in `chat_handle_join`, so it's never a participant here —
    ///   `Extractor.label` keeps returning "Me" for `isFromMe`.
    public static func groupSpeakerLabels(
        participants: [Participant],
        names: [String: String]
    ) -> [Int64: String] {
        // The name resolved for each participant (nil ⇒ unknown handle).
        let resolvedName: [Int64: String] = participants.reduce(into: [:]) { acc, p in
            acc[p.handleID] = names[p.identifier]
        }

        // Count first-name collisions across the *named* members only — an unknown
        // handle never collides (it renders as a number, not a name).
        func firstToken(_ full: String) -> String {
            full.split(separator: " ").first.map(String.init) ?? full
        }
        func lastInitial(_ full: String) -> String? {
            let parts = full.split(separator: " ")
            guard parts.count >= 2, let ch = parts.last?.first else { return nil }
            return String(ch).uppercased()
        }

        var firstNameCounts: [String: Int] = [:]
        for p in participants {
            guard let name = resolvedName[p.handleID] else { continue }
            firstNameCounts[firstToken(name), default: 0] += 1
        }

        // For a first name that collides, count how many share the SAME last
        // initial too — those must fall back to the full name.
        var firstPlusInitialCounts: [String: Int] = [:]
        for p in participants {
            guard let name = resolvedName[p.handleID] else { continue }
            let first = firstToken(name)
            guard (firstNameCounts[first] ?? 0) >= 2 else { continue }
            let key = first + "\u{0}" + (lastInitial(name) ?? "")
            firstPlusInitialCounts[key, default: 0] += 1
        }

        var labels: [Int64: String] = [:]
        for p in participants {
            guard let name = resolvedName[p.handleID] else {
                labels[p.handleID] = displayNumber(p.identifier)
                continue
            }
            let first = firstToken(name)
            if (firstNameCounts[first] ?? 0) < 2 {
                labels[p.handleID] = first  // unique first name → bare first name
            } else if let initial = lastInitial(name),
                (firstPlusInitialCounts[first + "\u{0}" + initial] ?? 0) < 2
            {
                labels[p.handleID] = "\(first) \(initial)."  // disambiguate by last initial
            } else {
                labels[p.handleID] = name  // still colliding (or no last name) → full name
            }
        }
        return labels
    }

    /// Light US pretty-printing for a bare identifier, mirroring a caller's
    /// number-formatting; kept here so the group-label helper can format a
    /// fallback number with no caller dependency. `+18443996927`/`8443996927` →
    /// `(844) 399-6927`; an email or any non-US-shaped string passes through unchanged.
    static func displayNumber(_ identifier: String) -> String {
        if identifier.contains("@") { return identifier }
        let digits = identifier.filter(\.isNumber)
        let national: Substring
        if digits.count == 11, digits.hasPrefix("1") {
            national = digits.dropFirst()
        } else if digits.count == 10 {
            national = digits[...]
        } else {
            return identifier
        }
        return "(\(national.prefix(3))) \(national.dropFirst(3).prefix(3))-\(national.suffix(4))"
    }
}
