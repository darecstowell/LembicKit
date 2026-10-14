import Foundation

/// One member of a group chat's roster. Carries the handle ROWID
/// (the extraction/label key) and its normalized identifier (phone/email). The
/// resolved speaker label (first name / `First L.` / formatted number) is left
/// nil here — the label layer's helper fills it from a Contacts map; the grouping
/// layer only stashes the raw roster so the grouping stays Contacts-free and
/// unit-testable. "Me" is never a participant: the owner's own handles are kept
/// out of the roster (see `Conversation.ownerHandles`).
public struct Participant: Sendable, Equatable {
    /// The participant's main handle ROWID (their most active one in the group).
    public let handleID: Int64
    /// The normalized identifier (E.164 phone / lowercased email), or `h<id>`
    /// when the handle string is unknown. The human-readable counterpart to
    /// `handleID`.
    public let identifier: String
    /// The resolved speaker label (the label layer fills this: first name /
    /// `First L.` / formatted number). Nil at the raw-roster grouping layer.
    public var label: String?
    /// Every handle ROWID of this person in the group (email and phone, or one
    /// number on iMessage, SMS, and RCS). Always contains `handleID`.
    public let handleIDs: Set<Int64>
    /// The person identity the stitch compares, the same across handles.
    let personKey: String
    /// True for someone who wrote in the group, or was added or removed, but is
    /// no longer in its member list. The header shows them as "(left)".
    public var isFormer: Bool

    public init(
        handleID: Int64, identifier: String, label: String? = nil, handleIDs: Set<Int64> = [],
        isFormer: Bool = false
    ) {
        self.init(
            handleID: handleID, identifier: identifier, label: label, handleIDs: handleIDs,
            personKey: identifier, isFormer: isFormer)
    }

    init(
        handleID: Int64, identifier: String, label: String?, handleIDs: Set<Int64>,
        personKey: String, isFormer: Bool = false
    ) {
        self.handleID = handleID
        self.identifier = identifier
        self.label = label
        self.handleIDs = handleIDs.union([handleID])
        self.personKey = personKey
        self.isFormer = isFormer
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
    /// Stable key: `chat:` plus the smallest of `chatGUIDs`. A rename, a Contacts
    /// change, or a member change does not move it. When chats regroup, the new
    /// conversation keeps the id of one of its chats; see `chatGUIDs`.
    public let id: String
    /// Every key 0.3.1 could have used as `id` for this conversation (contact
    /// name, bare identifiers, `group:<handle ROWIDs>`). Migration only: two
    /// conversations can share one.
    public let legacyIDs: Set<String>
    /// The `chat.guid` of every chat in the union (`rowid:<ROWID>` when the column
    /// is missing). Saved state keyed `chat:<g>` for any `g` here belongs to this
    /// conversation.
    public let chatGUIDs: Set<String>
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
    /// The oldest real message across the union, when known.
    public let firstMessageDate: Date?
    /// Handles in this conversation that belong to the owner (a second number or
    /// email). Their messages label as "Me", and they are never participants.
    public let ownerHandles: Set<Int64>
    /// A 1:1 with the owner's own address (notes to self).
    public let isNoteToSelf: Bool

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
        groupName: String? = nil,
        legacyIDs: Set<String> = [],
        chatGUIDs: Set<String> = [],
        firstMessageDate: Date? = nil,
        ownerHandles: Set<Int64> = [],
        isNoteToSelf: Bool = false
    ) {
        self.ownerHandles = ownerHandles
        self.isNoteToSelf = isNoteToSelf
        self.id = id
        self.legacyIDs = legacyIDs
        self.chatGUIDs = chatGUIDs
        self.firstMessageDate = firstMessageDate
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
/// - `.exact`: rows merge only when they hold the same people (a person's email,
///   phone, SMS, and RCS handles count as one) and their names do not conflict,
///   or when Apple links them (`chat.group_id`, `chat_lookup`). A membership
///   change is a different roster and stays a separate `Conversation`.
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
    ///
    /// `contactIDs` (`ContactsMap.ContactInfo.contactIDs`) says which handles share
    /// one Contacts card. Without it, a name alone never joins two handles.
    /// `ownerIdentifiers` (`ContactInfo.ownerIdentifiers`) adds the Me card's
    /// handles to the owner addresses read from the database.
    /// `region` completes numbers stored without a country code.
    public static func list(
        from db: ChatDatabase,
        resolvingContacts: Bool = true,
        contacts: [String: String]? = nil,
        contactIDs: [String: String]? = nil,
        ownerIdentifiers: Set<String> = [],
        stitch: GroupStitch = .exact,
        region: String = ContactsMap.currentRegion()
    ) throws -> [Conversation] {
        let summaries = try db.conversationSummaries()
        var names: [String: String]
        var cards = contactIDs ?? [:]
        var owner = ownerIdentifiers
        if let contacts {
            names = contacts
        } else if resolvingContacts {
            // Contacts is optional: a denial falls back to identifiers, never throws.
            let info = try? ContactsMap.buildContactInfo(region: region)
            names = info?.names ?? [:]
            if contactIDs == nil { cards = info?.contactIDs ?? [:] }
            owner.formUnion(info?.ownerIdentifiers ?? [])
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
            by: { ContactsMap.normalizeHandle($0.value, defaultRegion: region) }
        ).mapValues { Set($0.map(\.key)) }
        (names, cards) = ContactsMap.withNationalFallback(
            names: names, contactIDs: cards,
            handles: Array(handlesByIdentifier.keys)
                + summaries.compactMap(\.identifier).map {
                    ContactsMap.normalizeHandle($0, defaultRegion: region)
                })
        let groupSummaries = try db.groupConversationSummaries()
        owner.formUnion(
            ownerAddresses(
                seen: summaries.map(\.ownerIdentifiers) + groupSummaries.map(\.ownerIdentifiers),
                region: region))
        let oneToOnes = group(
            summaries, contacts: names, contactIDs: cards,
            handlesByIdentifier: handlesByIdentifier, owner: owner, region: region)

        // Group chats (style=43): exact-participant-set stitched, then merged into
        // the same recency-sorted list. handleLabels lets the roster carry each
        // participant's normalized identifier without a re-query.
        // `participantCounts` (one grouped query, this session) orders each
        // roster most-active-first — summed across a fork's chatIDs
        // in memory, never per row.
        let participantCounts = try db.groupParticipantMessageCounts()
        let people = personKeys(
            handleLabels: handleLabels, personCentricIDs: try db.personCentricIDs(),
            contactIDs: cards, region: region)
        var groups = groupGroups(
            groupSummaries, handleLabels: handleLabels, names: names,
            participantCounts: participantCounts, personKeys: people,
            chatLinks: try db.groupChatLinks(), owner: owner, region: region)

        // The opt-in fuzzy merge: a conservative second pass that merges exact-set
        // groups representing the same group with changed membership. `.exact` (the
        // default) skips this entirely, so the output is unchanged.
        if stitch == .fuzzy {
            groups = fuzzyMerge(groups, names: names)
        }

        return (oneToOnes + groups).sorted(by: newestFirst)
    }

    /// Newest first; equal dates order by `id` so the list is stable.
    static func newestFirst(_ a: Conversation, _ b: Conversation) -> Bool {
        a.lastMessageDate != b.lastMessageDate ? a.lastMessageDate > b.lastMessageDate : a.id < b.id
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

    /// The owner's addresses from `destination_caller_id`: an address counts only
    /// when the owner sent from it in two or more chats, so one odd row can never
    /// turn another person into "Me".
    public static func ownerAddresses(
        seen perChat: [Set<String>], region: String = ContactsMap.defaultRegion
    ) -> Set<String> {
        var chats: [String: Int] = [:]
        for addresses in perChat {
            let normalized = Set(
                addresses.map { ContactsMap.normalizeHandle($0, defaultRegion: region) })
            for address in normalized { chats[address, default: 0] += 1 }
        }
        return Set(chats.filter { $0.value >= 2 }.keys)
    }

    // MARK: - 1:1 multi-identifier union

    /// Pure grouping: fold raw per-chat summaries into people. No DB, no Contacts
    /// I/O — `contacts` is the normalized-handle → name map, used for display only.
    /// Keyed by Contacts card (`contactIDs`, so one card's phone + email merge),
    /// else by the normalized identifier. Two cards with the same name stay two
    /// conversations. Newest conversation first. This is the unit-test seam.
    /// A conversation whose identifiers are all in `owner` is a note to self.
    public static func group(
        _ summaries: [ChatDatabase.ConversationSummary],
        contacts: [String: String],
        contactIDs: [String: String] = [:],
        handlesByIdentifier: [String: Set<Int64>] = [:],
        owner: Set<String> = [],
        region: String = ContactsMap.defaultRegion
    ) -> [Conversation] {
        struct Acc {
            var chatIDs = Set<Int64>()
            var chatKeys = Set<String>()
            var handles = Set<Int64>()
            var identifiers = Set<String>()
            var legacy = Set<String>()
            var last = Date.distantPast
            var count = 0
            var name: String?
            var number = ""
        }
        var groups: [String: Acc] = [:]
        for s in summaries {
            let ident = s.identifier ?? "h\(s.handleID)"
            let norm = ContactsMap.normalizeHandle(ident, defaultRegion: region)
            let name = contacts[norm]
            let key = contactIDs[norm].map { "card:" + $0 } ?? norm
            var acc = groups[key] ?? Acc()
            acc.chatIDs.insert(s.chatID)
            acc.chatKeys.insert(chatKey(guid: s.guid, chatID: s.chatID))
            acc.handles.insert(s.handleID)
            acc.identifiers.insert(norm)
            acc.legacy.insert(legacyHandleKey(ident))
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
            .map { _, a in
                // Claim every handle ROWID sharing one of this person's normalized
                // identifiers — not just the one each chat registered — so all of
                // the counterparty's messages label as "Them". Without this, a
                // stray duplicate handle leaks them in as an extra speaker (glaring
                // once anonymized: a 1:1 sprouts a phantom "Person 3").
                var handles = a.handles
                for id in a.identifiers { handles.formUnion(handlesByIdentifier[id] ?? []) }
                return Conversation(
                    id: stableID(a.chatKeys),
                    displayName: a.name ?? a.number,
                    chatIDs: a.chatIDs,
                    targetHandles: handles,
                    identifiers: a.identifiers,
                    lastMessageDate: a.last,
                    messageCount: a.count,
                    primaryIdentifier: a.number,
                    isContact: a.name != nil,
                    legacyIDs: a.identifiers.union(a.legacy).union(a.name.map { [$0] } ?? []),
                    chatGUIDs: a.chatKeys,
                    isNoteToSelf: !a.identifiers.isEmpty && a.identifiers.isSubset(of: owner))
            }
            .sorted(by: newestFirst)
    }

    // MARK: - Group exact-set stitch

    /// Pure group stitching. No DB, no Contacts I/O; this is the unit-test seam.
    /// `handleLabels` (handle ROWID to raw phone/email) gives each member's
    /// normalized identifier, and `names` (normalized handle to contact name) fills
    /// `Participant.label` (pass `[:]` to leave labels nil).
    ///
    /// Chats join when they hold the same people and their names agree: one has
    /// no name, or both have the same name after trimming and case folding. A
    /// person is `personKeys[handle]` (see `personKeys(handleLabels:...)`), else the
    /// normalized identifier, so one number on iMessage, SMS, and RCS is one
    /// person. When one roster has two or more names, its unnamed chats stay
    /// apart, because there is no way to tell which group they belong to.
    /// Chats that share `groupID` or a `chatLinks` key also join, unless their
    /// names conflict. Two different names never end up in one conversation.
    ///
    /// `participantCounts` (`chatID → (handleID → real-message count)`) orders the
    /// roster most active first; ties break on the identifier. A handle in it that
    /// is not in `chat_handle_join` is a former member. Handles whose normalized
    /// identifier is in `owner` are the owner's, never members.
    public static func groupGroups(
        _ summaries: [ChatDatabase.GroupConversationSummary],
        handleLabels: [Int64: String] = [:],
        names: [String: String] = [:],
        participantCounts: [Int64: [Int64: Int]] = [:],
        personKeys: [Int64: String] = [:],
        chatLinks: [Int64: Set<String>] = [:],
        owner: Set<String> = [],
        region: String = ContactsMap.defaultRegion
    ) -> [Conversation] {
        func identifier(_ handle: Int64) -> String {
            handleLabels[handle].map { ContactsMap.normalizeHandle($0, defaultRegion: region) }
                ?? "h\(handle)"
        }
        func person(_ handle: Int64) -> String { personKeys[handle] ?? identifier(handle) }
        func isOwner(_ handle: Int64) -> Bool {
            owner.contains(identifier(handle)) || owner.contains(person(handle))
        }

        let rows = summaries.sorted { $0.chatID < $1.chatID }
        var components = NameAwareUnion(names: rows.map { normalizedGroupName($0.displayName) })

        // Same people: one bucket per roster, split by name when the names conflict.
        var buckets: [[String]: [Int]] = [:]
        for (i, row) in rows.enumerated() {
            let people = Set(row.participantHandles.filter { !isOwner($0) }.map(person)).sorted()
            if !people.isEmpty { buckets[people, default: []].append(i) }
        }
        for key in buckets.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let members = buckets[key] ?? []
            let named = Dictionary(grouping: members.filter { components.name(of: $0) != nil }) {
                components.name(of: $0) ?? ""
            }
            let unnamed = members.filter { components.name(of: $0) == nil }
            let parts = named.count <= 1 ? [members] : Array(named.values) + [unnamed]
            for part in parts { for j in part.dropFirst() { components.union(part[0], j) } }
        }

        // Apple's links: a shared group_id or chat_lookup identifier.
        var linked: [String: [Int]] = [:]
        for (i, row) in rows.enumerated() {
            var keys = chatLinks[row.chatID] ?? []
            if let groupID = row.groupID?.trimmingCharacters(in: .whitespaces), !groupID.isEmpty {
                keys.insert("group_id:" + groupID)
            }
            for key in keys { linked[key, default: []].append(i) }
        }
        for key in linked.keys.sorted() {
            let members = linked[key] ?? []
            for j in members.dropFirst() { components.union(members[0], j) }
        }

        return components.groups().map { members in
            buildGroup(
                members.map { rows[$0] }, identifier: identifier, person: person,
                isOwner: isOwner, names: names, participantCounts: participantCounts)
        }
        .sorted(by: newestFirst)
    }

    /// One stitched group conversation from its chats.
    private static func buildGroup(
        _ chats: [ChatDatabase.GroupConversationSummary],
        identifier: (Int64) -> String,
        person: (Int64) -> String,
        isOwner: (Int64) -> Bool,
        names: [String: String],
        participantCounts: [Int64: [Int64: Int]]
    ) -> Conversation {
        let byRecency = chats.sorted {
            ($0.lastMessageDate, $0.chatID) > ($1.lastMessageDate, $1.chatID)
        }
        let latest = byRecency[0]
        let primaryIdentifier = latest.identifier ?? "group\(latest.chatID)"
        let groupName = byRecency.compactMap(\.displayName).first { !$0.isEmpty }
        let chatIDs = Set(chats.map(\.chatID))

        var totals: [Int64: Int] = [:]
        for chatID in chatIDs {
            for (handle, n) in participantCounts[chatID] ?? [:] { totals[handle, default: 0] += n }
        }
        let listed = Set(chats.flatMap(\.participantHandles))
        let seen = listed.union(totals.keys)
        let ownerHandles = seen.filter(isOwner)
        let allHandles = seen.subtracting(ownerHandles)
        var handlesByPerson: [String: Set<Int64>] = [:]
        for handle in allHandles { handlesByPerson[person(handle), default: []].insert(handle) }
        var participants = handlesByPerson.map { key, handles in
            var p = makeParticipant(
                key: key, handles: handles, totals: totals, identifier: identifier, names: names)
            p.isFormer = handles.isDisjoint(with: listed)
            return p
        }
        sortRoster(&participants, totals: totals)
        relabel(&participants, names: names)

        let rosterName = participants.filter { !$0.isFormer }.map(\.identifier).sorted()
            .joined(separator: ", ")
        // An empty roster with no name falls back to the chat identifier, never "".
        let display = groupName ?? (rosterName.isEmpty ? primaryIdentifier : rosterName)
        let chatKeys = Set(chats.map { chatKey(guid: $0.guid, chatID: $0.chatID) })
        return Conversation(
            id: stableID(chatKeys),
            displayName: display,
            chatIDs: chatIDs,
            targetHandles: allHandles,
            identifiers: Set(allHandles.map(identifier)),
            lastMessageDate: latest.lastMessageDate,
            messageCount: chats.reduce(0) { $0 + $1.messageCount },
            primaryIdentifier: primaryIdentifier,
            isContact: false,
            isGroup: true,
            participants: participants,
            groupName: groupName,
            legacyIDs: Set(chats.map { legacyGroupID($0.participantHandles) })
                .union([legacyGroupID(listed)]),
            chatGUIDs: chatKeys,
            firstMessageDate: chats.compactMap(\.firstMessageDate).min(),
            ownerHandles: ownerHandles)
    }

    /// One person: their most active handle leads, and the identifier is one that
    /// resolves to a contact name when any does.
    private static func makeParticipant(
        key: String, handles: Set<Int64>, totals: [Int64: Int],
        identifier: (Int64) -> String, names: [String: String]
    ) -> Participant {
        let lead = handles.min { lhs, rhs in
            let (l, r) = (totals[lhs] ?? 0, totals[rhs] ?? 0)
            return l != r ? l > r : lhs < rhs
        }!
        let candidates = [identifier(lead), key] + handles.map(identifier).sorted()
        let ident = candidates.first { names[$0] != nil } ?? identifier(lead)
        return Participant(
            handleID: lead, identifier: ident, label: nil, handleIDs: handles, personKey: key)
    }

    /// Current members first, then most active (summed over the person's handles),
    /// then by identifier.
    private static func sortRoster(_ roster: inout [Participant], totals: [Int64: Int]) {
        func volume(_ p: Participant) -> Int { p.handleIDs.reduce(0) { $0 + (totals[$1] ?? 0) } }
        roster.sort { lhs, rhs in
            if lhs.isFormer != rhs.isFormer { return !lhs.isFormer }
            let (l, r) = (volume(lhs), volume(rhs))
            return l != r ? l > r : lhs.identifier < rhs.identifier
        }
    }

    /// Fill each label from `names`; an empty map leaves the labels nil.
    private static func relabel(_ roster: inout [Participant], names: [String: String]) {
        guard !names.isEmpty else { return }
        let byHandle = groupSpeakerLabels(participants: roster, names: names)
        for i in roster.indices { roster[i].label = byHandle[roster[i].handleID] }
    }

    /// A group name for comparison: trimmed, case-folded, inner spaces collapsed.
    static func normalizedGroupName(_ name: String?) -> String? {
        guard let name else { return nil }
        let folded = name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded.isEmpty ? nil : folded
    }

    /// Handle ROWID to a person key. Handles join when they share a normalized
    /// identifier (one number on iMessage, SMS, and RCS), a `person_centric_id`, or
    /// a Contacts card. The key is the smallest normalized identifier in the set.
    public static func personKeys(
        handleLabels: [Int64: String],
        personCentricIDs: [Int64: String] = [:],
        contactIDs: [String: String] = [:],
        region: String = ContactsMap.defaultRegion
    ) -> [Int64: String] {
        let handles = handleLabels.keys.sorted()
        let normalized = Dictionary(
            uniqueKeysWithValues: handles.map {
                ($0, ContactsMap.normalizeHandle(handleLabels[$0] ?? "", defaultRegion: region))
            })
        var parent = Dictionary(uniqueKeysWithValues: handles.map { ($0, $0) })
        func find(_ h: Int64) -> Int64 {
            var root = h
            while let next = parent[root], next != root { root = next }
            parent[h] = root
            return root
        }
        func link(_ groups: [String: [Int64]]) {
            for members in groups.values {
                for h in members.dropFirst() {
                    let (a, b) = (find(members[0]), find(h))
                    if a != b { parent[max(a, b)] = min(a, b) }
                }
            }
        }
        link(
            Dictionary(grouping: handles.filter { !(normalized[$0] ?? "").isEmpty }) {
                normalized[$0] ?? ""
            })
        link(
            Dictionary(grouping: handles.filter { personCentricIDs[$0] != nil }) {
                "pc:" + (personCentricIDs[$0] ?? "")
            })
        link(
            Dictionary(grouping: handles.filter { contactIDs[normalized[$0] ?? ""] != nil }) {
                "card:" + (contactIDs[normalized[$0] ?? ""] ?? "")
            })
        let members = Dictionary(grouping: handles, by: find)
        var keys: [Int64: String] = [:]
        for group in members.values {
            let key = group.compactMap { normalized[$0] }.filter { !$0.isEmpty }.min() ?? ""
            for h in group { keys[h] = key.isEmpty ? "h\(h)" : key }
        }
        return keys
    }

    /// The per-chat key behind `Conversation.chatGUIDs`.
    static func chatKey(guid: String?, chatID: Int64) -> String {
        if let guid, !guid.isEmpty { return guid }
        return "rowid:\(chatID)"
    }

    /// `chat:` plus the smallest chat key, so it never depends on ROWID order.
    static func stableID(_ chatKeys: Set<String>) -> String {
        "chat:" + (chatKeys.min() ?? "")
    }

    /// The 0.3.1 key for a 1:1 identifier: its normalizer with the US default.
    static func legacyHandleKey(_ handle: String) -> String {
        if handle.contains("@") { return handle.lowercased() }
        let digits = handle.filter(\.isNumber)
        guard digits.count >= 7 else { return handle }
        if handle.contains("+") || (digits.count == 11 && digits.hasPrefix("1")) {
            return "+" + digits
        }
        return "+1" + (digits.hasPrefix("0") ? String(digits.dropFirst()) : digits)
    }

    /// The 0.3.1 group id: `group:` plus the sorted handle ROWIDs.
    static func legacyGroupID(_ handles: some Sequence<Int64>) -> String {
        "group:" + handles.sorted().map(String.init).joined(separator: ",")
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
    ///
    /// Two vetoes override both rules: different non-empty names never merge, and
    /// two groups active at the same time never merge, because a membership
    /// change ends one roster as the next begins.
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
        /// Active ranges may overlap this much (stragglers in the old chat).
        static let maxOverlap: TimeInterval = 86_400
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
        let nodes = groupChats.sorted(by: newestFirst)

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
        if let an = normalizedGroupName(a.groupName), let bn = normalizedGroupName(b.groupName),
            an != bn
        {
            return false
        }
        if wereActiveTogether(a, b) { return false }
        let lhs = rosterKeys(a)
        let rhs = rosterKeys(b)
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
        if jaccard >= FuzzyRule.minJaccard, normalizedGroupName(a.groupName) != nil,
            normalizedGroupName(a.groupName) == normalizedGroupName(b.groupName)
        {
            return true
        }
        return false
    }

    /// The current people in a group roster (one key per person, not per handle).
    static func rosterKeys(_ conversation: Conversation) -> Set<String> {
        conversation.participants.isEmpty
            ? Set(conversation.targetHandles.map { "h\($0)" })
            : Set(conversation.participants.filter { !$0.isFormer }.map(\.personKey))
    }

    /// True when both groups were active at the same time: their date ranges
    /// overlap by more than `FuzzyRule.maxOverlap`, or one range sits inside the
    /// other. Unknown first dates never veto.
    static func wereActiveTogether(_ a: Conversation, _ b: Conversation) -> Bool {
        guard let aFirst = a.firstMessageDate, let bFirst = b.firstMessageDate else {
            return false
        }
        let overlap =
            min(a.lastMessageDate, b.lastMessageDate).timeIntervalSince(max(aFirst, bFirst))
        guard overlap > 0 else { return false }
        if overlap > FuzzyRule.maxOverlap { return true }
        let aInsideB = aFirst >= bFirst && a.lastMessageDate <= b.lastMessageDate
        let bInsideA = bFirst >= aFirst && b.lastMessageDate <= a.lastMessageDate
        return aInsideB || bInsideA
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

        // Roster = everyone ever a member, one entry per person (their handles
        // unioned). Re-label from `names` when supplied; else keep the input labels.
        // The newest member's current roster is the group's current roster.
        let current = Set(byRecency[0].participants.filter { !$0.isFormer }.map(\.personKey))
        var participants: [Participant] = []
        var indexByPerson: [String: Int] = [:]
        for member in byRecency {
            for p in member.participants {
                if let i = indexByPerson[p.personKey] {
                    let kept = participants[i]
                    participants[i] = Participant(
                        handleID: kept.handleID, identifier: kept.identifier, label: kept.label,
                        handleIDs: kept.handleIDs.union(p.handleIDs), personKey: kept.personKey,
                        isFormer: kept.isFormer)
                } else {
                    var added = p
                    added.isFormer = !current.contains(p.personKey)
                    indexByPerson[p.personKey] = participants.count
                    participants.append(added)
                }
            }
        }
        participants = participants.filter { !$0.isFormer } + participants.filter(\.isFormer)
        relabel(&participants, names: names)
        let identifiers = Set(participants.map(\.identifier))
        let display =
            groupName
            ?? Set(participants.filter { !$0.isFormer }.map(\.identifier)).sorted()
            .joined(separator: ", ")

        let chatKeys = members.reduce(into: Set<String>()) { $0.formUnion($1.chatGUIDs) }
        return Conversation(
            id: stableID(chatKeys),
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
            groupName: groupName,
            legacyIDs: members.reduce(into: [legacyGroupID(targetHandles)]) {
                $0.formUnion($1.legacyIDs)
            },
            chatGUIDs: chatKeys,
            firstMessageDate: members.compactMap(\.firstMessageDate).min(),
            ownerHandles: members.reduce(into: Set<Int64>()) { $0.formUnion($1.ownerHandles) })
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

/// Union-find over chat indexes that refuses to join two different group names.
struct NameAwareUnion {
    private var parent: [Int]
    private var namesByRoot: [Int: Set<String>]
    private let rowNames: [String?]

    init(names: [String?]) {
        rowNames = names
        parent = Array(names.indices)
        namesByRoot = Dictionary(
            uniqueKeysWithValues: names.enumerated().map {
                ($0.offset, Set([$0.element].compactMap { $0 }))
            })
    }

    func name(of row: Int) -> String? { rowNames[row] }

    mutating func find(_ row: Int) -> Int {
        var root = row
        while parent[root] != root { root = parent[root] }
        parent[row] = root
        return root
    }

    /// Joins the two sets unless that would put two different names together.
    mutating func union(_ a: Int, _ b: Int) {
        let (ra, rb) = (find(a), find(b))
        guard ra != rb else { return }
        let merged = (namesByRoot[ra] ?? []).union(namesByRoot[rb] ?? [])
        guard merged.count <= 1 else { return }
        let (keep, drop) = (min(ra, rb), max(ra, rb))
        parent[drop] = keep
        namesByRoot[keep] = merged
        namesByRoot[drop] = nil
    }

    mutating func groups() -> [[Int]] {
        Dictionary(grouping: parent.indices, by: { find($0) }).values.map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
    }
}
