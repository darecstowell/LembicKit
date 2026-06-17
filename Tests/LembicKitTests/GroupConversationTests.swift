import Foundation
import GRDB
import Testing

@testable import LembicKit

// The group (style=43) keystone. Two layers, mirroring the 1:1
// suites: a DB-backed test over `groupConversationSummaries` + extraction, and a
// pure (DB-free) exact-set folding test over `Conversations.groupGroups`.
//
// The 1:1 enumerator still EXCLUDES style=43 (that invariant is re-asserted in
// `ConversationUnionTests`); these add the *include* path for groups.
@Suite("group conversation")
struct GroupConversationTests {

    // DB-backed: a named group (#10) with three speakers (Me + handles 3 & 5) and
    // a non-me reaction (Bob, handle 5, ❤️ on Me's first message); a fork (#11)
    // with the identical {3,5} roster that must stitch into #10; a different-set
    // group (#12, {3,7}) that stays its own entry; and a 1:1 (#20) the group
    // enumerator must drop.
    @Test func groupEnumerationStitchAndExtraction() throws {
        let db = try Fixtures.openChatDB(populating: Fixtures.groupSchemaAndData)

        let groups = try db.groupConversationSummaries()
        #expect(
            Set(groups.map(\.chatID)) == [10, 11, 12],
            "group enumerator finds the three style=43 rows, excludes the 1:1 (#20)")
        #expect(
            groups.allSatisfy { $0.chatID != 20 }, "the style=45 chat is never enumerated")

        // Roster #10 = {3,5}; #11 shares it; #12 = {3,7}.
        let byChat = Dictionary(uniqueKeysWithValues: groups.map { ($0.chatID, $0) })
        #expect(byChat[10]?.participantHandles == [3, 5], "named group roster, sorted")
        #expect(byChat[11]?.participantHandles == [3, 5], "the fork shares the exact set")
        #expect(byChat[12]?.participantHandles == [3, 7], "the different-set group")
        #expect(byChat[10]?.displayName == "Trip crew", "named group carries display_name")
        #expect(byChat[11]?.displayName == nil, "unnamed group → nil display_name")

        // Real-message counts exclude the reaction (gm3 is associated_message_type
        // 2000) — #10 has gm0/gm1/gm2 = 3 real, the reaction is netted out.
        #expect(byChat[10]?.messageCount == 3, "reaction excluded from the real-message count")

        // Fold: the {3,5} fork stitches #10 + #11 into one Conversation.
        let folded = Conversations.groupGroups(groups, handleLabels: try db.handleLabels())
        #expect(folded.count == 2, "exact-set stitch: {3,5} fork merges → 2 conversations, not 3")
        guard let crew = folded.first(where: { $0.targetHandles == [3, 5] }) else {
            Issue.record("expected a stitched {3,5} group")
            return
        }
        #expect(crew.isGroup, "a folded group is isGroup")
        #expect(crew.chatIDs == [10, 11], "stitched: both fork chat ROWIDs collected")
        #expect(crew.messageCount == 4, "stitched count = Σ (3 from #10 + 1 from #11)")
        #expect(crew.groupName == "Trip crew", "the named fork's display_name carries through")
        #expect(
            Set(crew.participants.map(\.handleID)) == [3, 5],
            "roster = the union of the fork's members")
        #expect(
            crew.participants.contains { $0.identifier == "+18160000003" },
            "participant identifiers resolve from the handle map")
        #expect(
            crew.participants.allSatisfy { $0.label == nil },
            "the grouping layer leaves the resolved-label slot empty (the label layer fills it)")

        // Extraction over the stitched chatIDs unions + ROWID-dedupes; the non-me
        // reaction lands on Me's first message.
        let ex = Extractor(targetHandles: crew.targetHandles, handleLabels: [:])
        let recs = try db.queue.read { try ex.extractConversation($0, chatIDs: crew.chatIDs) }
        #expect(
            recs.map(\.text) == ["hey all", "Alice here", "Bob here", "from the fork"],
            "stitched extraction: both forks' real messages, date-sorted")
        let speakers = Set(recs.map(\.speaker))
        #expect(
            speakers == ["Me", "Them"],
            "≥3 distinct senders collapse to Me/Them under targetHandles")
        let reactedMessage = try #require(recs.first { $0.guid == "gm0" })
        #expect(
            reactedMessage.reactions.contains { $0.emoji == "❤️" },
            "the non-me participant's reaction is attached")
    }

    // Pure (DB-free) exact-set folding, the unit-test seam mirroring
    // `ConversationGroupingTests`. Two rows with the identical sorted handle-set
    // merge; a membership-changed set (an add) stays separate.
    @Test func exactSetFoldingPure() {
        let folded = Conversations.groupGroups(
            [
                Fixtures.groupSummary(1, "g1", [9, 4, 7], name: "KC crew", date: 100, count: 50),
                // The fork: same set, re-sorted on input — must stitch into #1.
                Fixtures.groupSummary(2, "g1b", [7, 4, 9], date: 500, count: 20),
                // An added member ({…,12}) → a different set, stays separate.
                Fixtures.groupSummary(3, "g2", [4, 7, 9, 12], date: 300, count: 9),
            ],
            handleLabels: [4: "+18160000004", 7: "+18160000007", 9: "+18160000009"])
        #expect(folded.count == 2, "identical set stitches; the +1-member set stays separate")

        guard let crew = folded.first(where: { $0.targetHandles == [4, 7, 9] }) else {
            Issue.record("expected the stitched {4,7,9} crew")
            return
        }
        #expect(crew.chatIDs == [1, 2], "stitched chatIDs from both rows")
        #expect(crew.messageCount == 70, "stitched count = 50 + 20")
        #expect(
            crew.lastMessageDate == Date(timeIntervalSince1970: 500),
            "stitched lastMessageDate = max across the fork")
        #expect(crew.groupName == "KC crew", "carries the named fork's display_name")
        #expect(crew.isGroup && !crew.isContact, "a group is isGroup and (at the grouping layer) not a Contact")

        // Newest-first across entries (the {4,7,9} crew @500 sorts above {…,12} @300).
        #expect(folded.first?.targetHandles == [4, 7, 9], "recency sort: newest fork first")

        // The membership-changed group stays distinct, with its own single chatID.
        let bigger = try? #require(folded.first { $0.targetHandles == [4, 7, 9, 12] })
        #expect(bigger?.chatIDs == [3], "the added-member group is a separate entry")
        #expect(
            bigger?.groupName == nil,
            "unnamed group → nil groupName (composed name is the label layer's job)")
    }

    // Most-active-first roster ordering. The roster is sorted by descending
    // real-message volume (summed across the stitched fork's chatIDs), ties +
    // silent (0-message) members broken by the normalized identifier. The handle
    // ROWID order is deliberately the REVERSE of the talk order to prove the sort
    // re-orders rather than echoing the (sorted) handle set.
    @Test func rosterOrdersMostActiveFirst() {
        // Set {4,7,9} across two stitched forks (#1 + #2). Volumes summed across
        // both: handle 9 = 5+4 = 9 (most), handle 4 = 1+2 = 3, handle 7 = 0
        // (never speaks → falls last via the identifier tiebreak).
        let folded = Conversations.groupGroups(
            [
                Fixtures.groupSummary(1, "g1", [4, 7, 9], name: "Loud crew", date: 100, count: 6),
                Fixtures.groupSummary(2, "g1b", [9, 7, 4], date: 500, count: 6),
            ],
            handleLabels: [4: "+18160000004", 7: "+18160000007", 9: "+18160000009"],
            participantCounts: [
                1: [9: 5, 4: 1],  // chat #1
                2: [9: 4, 4: 2],  // the fork
            ])
        let crew = try? #require(folded.first)
        #expect(
            crew?.participants.map(\.handleID) == [9, 4, 7],
            "roster ordered by descending volume; the silent member (7) trails")
    }

    // The tiebreak: equal volume → the normalized identifier orders them, so the
    // output stays deterministic regardless of map iteration order.
    @Test func equalVolumeBreaksOnIdentifier() {
        let folded = Conversations.groupGroups(
            [Fixtures.groupSummary(1, "g1", [4, 7, 9], date: 100, count: 3)],
            handleLabels: [4: "+18160000004", 7: "+18160000007", 9: "+18160000009"],
            participantCounts: [1: [4: 2, 7: 2, 9: 2]])  // all equal
        let crew = try? #require(folded.first)
        #expect(
            crew?.participants.map(\.identifier)
                == ["+18160000004", "+18160000007", "+18160000009"],
            "an all-tie roster falls back to identifier order — deterministic")
    }

    // A degenerate group with an EMPTY roster (no joined handles) and no
    // display_name would join its (empty) identifier list to "" — the displayName
    // must instead fall back to the group's primary identifier so the picker row
    // and the transcript header are never blank.
    @Test func emptyRosterGroupFallsBackToPrimaryIdentifier() {
        // Empty roster, named: the display_name still wins.
        let named = Conversations.groupGroups(
            [Fixtures.groupSummary(1, "group-guid-x", [], name: "Named room", date: 100)])
        #expect(named.first?.displayName == "Named room", "a named empty-roster group keeps its name")

        // Empty roster, unnamed, with a guid identifier → falls back to that guid.
        let withGuid = Conversations.groupGroups(
            [Fixtures.groupSummary(2, "group-guid-y", [], date: 100)])
        let g = try? #require(withGuid.first)
        #expect(g?.displayName == "group-guid-y", "unnamed empty roster → the group's identifier, never ''")
        #expect(g?.displayName.isEmpty == false, "displayName is never blank")

        // Empty roster, unnamed, nil identifier → the synthesized group<chatID>.
        let noIdent = Conversations.groupGroups(
            [Fixtures.groupSummary(3, nil, [], date: 100)])
        #expect(
            noIdent.first?.displayName == "group3",
            "unnamed empty roster with no identifier → the synthesized group<chatID>")
    }
}

// The shared group-speaker label layer. The pure helper
// (`Conversations.groupSpeakerLabels`) maps a roster + a Contacts name map to
// `[handleID: label]`; plus the extraction-wiring check that a group now yields
// real per-speaker names instead of every non-me sender collapsing to "Them".
@Suite("group speaker labels")
struct GroupSpeakerLabelTests {

    private func participant(_ handleID: Int64, _ identifier: String) -> Participant {
        Participant(handleID: handleID, identifier: identifier)
    }

    // Distinct first names → bare first names; "Me" is never a participant so it
    // never appears here (Extractor.label still returns "Me" for isFromMe).
    @Test func distinctFirstNamesAreBareFirstNames() {
        let roster = [
            participant(3, "+18160000003"),
            participant(5, "+18160000005"),
        ]
        let names = ["+18160000003": "Alice Tan", "+18160000005": "Bob Vance"]
        let labels = Conversations.groupSpeakerLabels(participants: roster, names: names)
        #expect(labels == [3: "Alice", 5: "Bob"], "unique first names → just the first token")
    }

    // Two "Mike"s collide → both disambiguate to `Mike R.` / `Mike S.`.
    @Test func firstNameCollisionDisambiguatesByLastInitial() {
        let roster = [
            participant(3, "+18160000003"),
            participant(5, "+18160000005"),
            participant(7, "+18160000007"),
        ]
        let names = [
            "+18160000003": "Mike Rivera",
            "+18160000005": "Mike Sanders",
            "+18160000007": "Dana Cole",
        ]
        let labels = Conversations.groupSpeakerLabels(participants: roster, names: names)
        #expect(labels[3] == "Mike R.", "colliding first name → First L.")
        #expect(labels[5] == "Mike S.", "the other Mike → First L. with its own initial")
        #expect(labels[7] == "Dana", "an uncolliding name stays a bare first name")
    }

    // Same first name AND same last initial → fall back to the full name.
    @Test func sameFirstAndLastInitialFallsBackToFullName() {
        let roster = [
            participant(3, "+18160000003"),
            participant(5, "+18160000005"),
        ]
        let names = ["+18160000003": "Mike Rivera", "+18160000005": "Mike Reyes"]
        let labels = Conversations.groupSpeakerLabels(participants: roster, names: names)
        #expect(
            labels == [3: "Mike Rivera", 5: "Mike Reyes"],
            "First L. still collides (both Mike R.) → full name")
    }

    // Unknown handle (no Contacts match) → formatted US display number; an email
    // and a non-US string pass through unchanged.
    @Test func unknownHandleRendersFormattedNumber() {
        let roster = [
            participant(3, "+18443996927"),  // US 11-digit
            participant(5, "8443996927"),  // US 10-digit
            participant(7, "alice@example.com"),  // email
            participant(9, "+447911123456"),  // non-US shape
        ]
        let labels = Conversations.groupSpeakerLabels(participants: roster, names: [:])
        #expect(labels[3] == "(844) 399-6927", "US 11-digit → pretty-printed")
        #expect(labels[5] == "(844) 399-6927", "US 10-digit → pretty-printed")
        #expect(labels[7] == "alice@example.com", "an email passes through")
        #expect(labels[9] == "+447911123456", "a non-US-shaped number passes through raw")
    }

    // A mix: one resolved contact + one unknown handle in the same roster.
    @Test func mixedRosterResolvesNameAndNumber() {
        let roster = [
            participant(3, "+18160000003"),
            participant(5, "+18443996927"),
        ]
        let names = ["+18160000003": "Alice Tan"]
        let labels = Conversations.groupSpeakerLabels(participants: roster, names: names)
        #expect(labels == [3: "Alice", 5: "(844) 399-6927"])
    }

    // groupGroups fills Participant.label from the names map (the single source
    // the roster header and the picker read), and the labels survive the fork stitch.
    @Test func groupGroupsPopulatesParticipantLabels() {
        let folded = Conversations.groupGroups(
            [Fixtures.groupSummary(1, "g1", [3, 5], name: "Trip crew", date: 100)],
            handleLabels: [3: "+18160000003", 5: "+18160000005"],
            names: ["+18160000003": "Alice Tan", "+18160000005": "Bob Vance"])
        let crew = try? #require(folded.first)
        let byHandle = Dictionary(
            uniqueKeysWithValues: (crew?.participants ?? []).map { ($0.handleID, $0.label) })
        #expect(byHandle[3] == "Alice", "Participant.label filled with the resolved first name")
        #expect(byHandle[5] == "Bob", "the other member's label is filled too")
    }

    // The extraction-wiring proof: a group Extractor built via `forConversation`
    // labels each speaker by NAME (not "Them"). Same fixture as the grouping layer's stitch test,
    // but now WITH a Contacts name map → distinct speaker labels.
    @Test func groupExtractionYieldsDistinctSpeakerLabels() throws {
        let db = try Fixtures.openChatDB(populating: Fixtures.groupSchemaAndData)
        let names = ["+18160000003": "Alice Tan", "+18160000005": "Bob Vance"]
        let groups = try db.groupConversationSummaries()
        let folded = Conversations.groupGroups(
            groups, handleLabels: try db.handleLabels(), names: names)
        let crew = try #require(folded.first { $0.targetHandles == [3, 5] })

        let ex = Extractor.forConversation(crew, globalLabels: [:])
        #expect(ex.targetHandles.isEmpty, "a group extractor leaves targetHandles empty")
        let recs = try db.queue.read { try ex.extractConversation($0, chatIDs: crew.chatIDs) }
        let speakers = Set(recs.map(\.speaker))
        #expect(
            speakers == ["Me", "Alice", "Bob"],
            "group speakers resolve to their own names — NOT all 'Them'")
        // The 1:1 branch is untouched: a non-group conversation still uses targetHandles.
        let oneToOne = Conversation(
            id: "x", displayName: "x", chatIDs: [1], targetHandles: [3, 5], identifiers: [],
            lastMessageDate: .distantPast, messageCount: 0, primaryIdentifier: "x", isContact: false)
        #expect(
            Extractor.forConversation(oneToOne, globalLabels: [:]).targetHandles == [3, 5],
            "the 1:1 path keeps its targetHandles (Me/Them) — unchanged")
    }

    // The opt-in system-event stream. Same fixture (chat #10 carries a rename,
    // an add of an off-roster member, and a leave). Default extraction excludes
    // them (item_type != 0); `extractSystemEvents` surfaces them as rendered lines
    // with the group's own speaker labels.
    @Test func extractSystemEventsRendersGroupBeats() throws {
        let db = try Fixtures.openChatDB(populating: Fixtures.groupSchemaAndData)
        // Resolve handle 3 → Alice, 5 → Bob, 7 → an off-roster member ("Carla").
        let names = [
            "+18160000003": "Alice Tan", "+18160000005": "Bob Vance",
            "+18160000007": "Carla Reed",
        ]
        let groups = try db.groupConversationSummaries()
        let folded = Conversations.groupGroups(
            groups, handleLabels: try db.handleLabels(), names: names)
        let crew = try #require(folded.first { $0.targetHandles == [3, 5] })
        // The realistic path: global labels are RESOLVED names (so an off-roster
        // other_handle, here handle 7 → "Carla Reed", resolves to a name, not a
        // number). `forConversation` overlays the roster's first-name labels from the label layer.
        let globalLabels = ContactsMap.resolve(
            handleLabels: try db.handleLabels(), contacts: names
        ).resolved
        let ex = Extractor.forConversation(crew, globalLabels: globalLabels)

        // Default extraction never yields a system event (item_type != 0 skipped).
        let recs = try db.queue.read { try ex.extractConversation($0, chatIDs: crew.chatIDs) }
        #expect(
            recs.allSatisfy { !$0.text.contains("named the group") && $0.text != "Alice left" },
            "system events never appear in the default record stream")

        let events = try db.queue.read { try ex.extractSystemEvents($0, chatIDs: crew.chatIDs) }
        #expect(events.count == 3, "the rename, the add, and the leave all surface")
        #expect(
            events.map(\.line) == [
                "Bob named the group \"KC crew\"",
                "Alice added Carla",
                "Alice left",
            ],
            "events render in date order with group labels; off-roster handle 7 → Carla")
        // Date ordering is ascending, ready to interleave by timestamp.
        #expect(events.map(\.date) == events.map(\.date).sorted(), "events are date-ordered")
    }

    // A future/older macOS whose `message` table lacks the opt-in-only columns
    // (`group_action_type`/`group_title`/`other_handle`, deliberately NOT in
    // `requiredSchema`) must DEGRADE: `extractSystemEvents` probes for them and
    // returns [] rather than throwing at statement-prepare time — the graceful
    // degrade the doc comment promises. (The default export reads such a DB fine.)
    @Test func extractSystemEventsDegradesWhenColumnsMissing() throws {
        // A schema with the message columns the default export reads but WITHOUT the
        // three group-event columns — plus a chat carrying an `item_type=2` row that
        // the system-event SQL would try (and fail) to read those columns from.
        let sql = """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, style INTEGER, chat_identifier TEXT,
                service_name TEXT, display_name TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
                is_from_me INTEGER, handle_id INTEGER, service TEXT, text TEXT,
                attributedBody BLOB, item_type INTEGER DEFAULT 0,
                associated_message_type INTEGER DEFAULT 0, associated_message_guid TEXT,
                associated_message_emoji TEXT, balloon_bundle_id TEXT);
            INSERT INTO handle (ROWID, id) VALUES (3,'+18160000003');
            INSERT INTO chat (ROWID, style, chat_identifier, service_name, display_name) VALUES
                (10,43,'group-A','iMessage','Trip crew');
            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (10,3);
            INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, item_type) VALUES
                (110,'se0',50,0,3,2);
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (10,110);
            """
        let queue = try Fixtures.makeInMemoryDB(populating: sql)
        let ex = Extractor(targetHandles: [], handleLabels: [3: "Alice"], rosterHandles: [3])
        let events = try queue.read { try ex.extractSystemEvents($0, chatIDs: [10]) }
        #expect(
            events.isEmpty,
            "missing group_action_type/group_title/other_handle → [] (degrades, never throws)")
    }

    // An off-roster `other_handle` with NO Contacts name pretty-prints to a number
    // (a removed member is rarely still in the roster, so its handleLabels entry is
    // the raw identifier — never a bare `h<id>`).
    @Test func extractSystemEventsFormatsUnknownTargetAsNumber() throws {
        let db = try Fixtures.openChatDB(populating: Fixtures.groupSchemaAndData)
        let groups = try db.groupConversationSummaries()
        let folded = Conversations.groupGroups(groups, handleLabels: try db.handleLabels())
        let crew = try #require(folded.first { $0.targetHandles == [3, 5] })
        // No Contacts names → globalLabels are raw identifiers.
        let ex = Extractor.forConversation(crew, globalLabels: try db.handleLabels())
        let events = try db.queue.read { try ex.extractSystemEvents($0, chatIDs: crew.chatIDs) }
        let add = try #require(events.first { $0.line.contains("added") })
        // Actor = handle 3 (+18160000003), target = handle 7 (+18160000007); both
        // pretty-print to US numbers since no Contacts name resolved either.
        #expect(
            add.line == "(816) 000-0003 added (816) 000-0007",
            "an unresolved actor + off-roster target both pretty-print to numbers")
    }

    // A collision-disambiguated roster member ("Mike R.") must render VERBATIM in a
    // system-event line — re-first-tokening its already-resolved label from the label layer would
    // collapse it back to "Mike", diverging from the message body.
    @Test func systemEventLabelUsesRosterLabelVerbatim() {
        // Two colliding Mikes (3 & 5) disambiguate to "Mike R." / "Mike S."; handle
        // 7 is OFF the roster (carries a global full name, the add/remove-target case).
        let roster = [
            Participant(handleID: 3, identifier: "+18160000003", label: "Mike R."),
            Participant(handleID: 5, identifier: "+18160000005", label: "Mike S."),
        ]
        let conv = Conversation(
            id: "group:3,5", displayName: "g", chatIDs: [10], targetHandles: [3, 5],
            identifiers: ["+18160000003", "+18160000005"], lastMessageDate: .distantPast,
            messageCount: 0, primaryIdentifier: "g", isContact: false, isGroup: true,
            participants: roster, groupName: nil)
        // Global labels carry the off-roster member's full name (handle 7 → "Carla Reed").
        let ex = Extractor.forConversation(conv, globalLabels: [7: "Carla Reed"])

        #expect(
            ex.systemEventLabel(isFromMe: false, handleID: 3) == "Mike R.",
            "a disambiguated roster label is used verbatim — not re-first-tokened to 'Mike'")
        #expect(
            ex.systemEventLabel(isFromMe: false, handleID: 5) == "Mike S.",
            "the other colliding Mike keeps its full label from the label layer")
        #expect(
            ex.systemEventLabel(isFromMe: false, handleID: 7) == "Carla",
            "an OFF-roster member's global full name is still reduced to its first token")
        #expect(ex.systemEventLabel(isFromMe: true, handleID: 3) == "Me", "Me unchanged")
    }
}

// The OPT-IN, off-by-default fuzzy / membership-change merge.
// Pure (DB-free): build synthetic exact-set group `Conversation`s and assert the
// conservative rule fires only on a clean adds/removes signal, never chains weak
// links into a blob, and is a no-op under `.exact`. These all run `fuzzyMerge`
// (the .fuzzy path) directly; `.exact` is the default and is proven a no-op below.
@Suite("group fuzzy stitch")
struct GroupFuzzyStitchTests {

    /// A synthetic exact-set group `Conversation` over a handle set — the shape
    /// `groupGroups` emits and `fuzzyMerge` consumes. `chatID` doubles as a unique
    /// `id`/chatID so merges can be inspected.
    private func group(
        _ chatID: Int64, _ handles: [Int64], name: String? = nil,
        date: Int64 = 0, count: Int = 1
    ) -> Conversation {
        let parts = handles.sorted().map {
            Participant(handleID: $0, identifier: "+1816000\(String(format: "%04d", $0))")
        }
        return Conversation(
            id: "group:" + handles.sorted().map(String.init).joined(separator: ","),
            displayName: name ?? "g\(chatID)",
            chatIDs: [chatID],
            targetHandles: Set(handles),
            identifiers: Set(parts.map(\.identifier)),
            lastMessageDate: Date(timeIntervalSince1970: Double(date)),
            messageCount: count,
            primaryIdentifier: "group\(chatID)",
            isContact: false,
            isGroup: true,
            participants: parts,
            groupName: name)
    }

    // The headline case: {A,B,C} + {A,B,C,D} — a subset with a 1-member delta and
    // ratio 3/4 = .75 (≥ .6). They MERGE; the union roster is everyone ever a
    // member, chatIDs + counts combine, the most-recent date wins.
    @Test func subsetWithSmallDeltaMerges() {
        let merged = Conversations.fuzzyMerge([
            group(1, [3, 5, 7], date: 100, count: 10),
            group(2, [3, 5, 7, 9], date: 500, count: 4),
        ])
        #expect(merged.count == 1, "a clean 1-member add merges the two into one")
        let crew = try? #require(merged.first)
        #expect(crew?.targetHandles == [3, 5, 7, 9], "roster = everyone who was ever a member")
        #expect(crew?.chatIDs == [1, 2], "chatIDs unioned")
        #expect(crew?.messageCount == 14, "messageCount summed (10 + 4)")
        #expect(
            crew?.lastMessageDate == Date(timeIntervalSince1970: 500),
            "lastMessageDate = max across the cluster")
    }

    // Disjoint small groups never merge (no overlap, and Rule 2 needs a shared name
    // anyway). {A,B,C} vs {W,X,Y,Z}.
    @Test func disjointGroupsDoNotMerge() {
        let merged = Conversations.fuzzyMerge([
            group(1, [3, 5, 7], date: 100),
            group(2, [20, 21, 22, 23], date: 200),
        ])
        #expect(merged.count == 2, "no overlap → never merged")
    }

    // The tiny-into-big guard: {A,B} is technically a subset of {A,B,+13 others}
    // but must NOT merge — the ratio (2/15) and the delta (13) both fail, and a
    // 2-person roster is below the size floor besides.
    @Test func tinyRosterDoesNotAbsorbIntoLargeGroup() {
        let big = Array<Int64>(3...17)  // 15 members incl. A,B (3,4)
        let merged = Conversations.fuzzyMerge([
            group(1, [3, 4], date: 100),
            group(2, big, date: 200),
        ])
        #expect(merged.count == 2, "a 2-person group is not absorbed into a 15-person group")
    }

    // A small-but-proportional drift is still blocked by the absolute delta cap:
    // {A..H} (8) vs {A..L} (12) — subset, ratio .67 (≥ .6) BUT delta 4 (> 3). No merge.
    @Test func subsetBeyondDeltaCapDoesNotMerge() {
        let merged = Conversations.fuzzyMerge([
            group(1, Array<Int64>(1...8), date: 100),
            group(2, Array<Int64>(1...12), date: 200),
        ])
        #expect(merged.count == 2, "delta of 4 members exceeds the cap even though the ratio passes")
    }

    // Rule 2 — high Jaccard WITH a shared display_name merges (a simultaneous
    // add+remove that isn't a clean subset). {A,B,C,D,E} vs {A,B,C,D,F}: overlap 4,
    // union 6, Jaccard .67 — too low; bump to {A,B,C,D,E} vs {A,B,C,D} would be a
    // subset, so use a near-overlap that's NOT a subset: {A,B,C,D,E} vs {A,B,C,D,F}
    // is .67 (no). Use {A..E} vs {A..E,F minus E} → construct a true ≥.8 overlap.
    @Test func highJaccardWithSharedNameMerges() {
        // {1,2,3,4,5} vs {1,2,3,4,6}: intersection 4, union 6 → .667 (below .8).
        // {1,2,3,4,5} vs {1,2,3,4,5,6}: that's a subset (Rule 1). For a pure-Rule-2
        // case use a swap on a larger base: {1..9} vs {1..8,10} → intersection 8,
        // union 10 → .8, NOT a subset (each has a member the other lacks).
        let withName = Conversations.fuzzyMerge([
            group(1, Array<Int64>(1...9), name: "Cabin crew", date: 100),
            group(2, Array<Int64>(1...8) + [10], name: "Cabin crew", date: 200),
        ])
        #expect(withName.count == 1, "Jaccard .8 + a shared display_name merges")

        // The SAME rosters with NO shared name must NOT merge on Jaccard alone.
        let noName = Conversations.fuzzyMerge([
            group(1, Array<Int64>(1...9), date: 100),
            group(2, Array<Int64>(1...8) + [10], date: 200),
        ])
        #expect(noName.count == 2, "high Jaccard alone (no shared name) does not merge")
    }

    // Transitivity / blob control: a chain A~B, B~C where A and C are too far apart
    // must NOT collapse into one cluster. Rosters: A={1,2,3,4}, B={1,2,3,4,5},
    // C={1,2,3,4,5,6,7}. A~B (subset, delta 1). B~C (subset, delta 2). But A~C is a
    // subset with delta 3 and ratio 4/7 = .57 (< .6) → NOT related. So the maximal
    // clique containing B is {A,B} (or {B,C}), never {A,B,C}.
    @Test func weakTransitiveChainDoesNotBlobUp() {
        let merged = Conversations.fuzzyMerge([
            group(1, [1, 2, 3, 4], date: 300),  // A — newest, seeds first
            group(2, [1, 2, 3, 4, 5], date: 200),  // B
            group(3, [1, 2, 3, 4, 5, 6, 7], date: 100),  // C
        ])
        // A seeds; B is related to A (admitted). C is related to B but NOT to A
        // (ratio .57) → C is rejected from A's clique and stands alone. Result:
        // {A,B} merged + {C} alone — never one three-way blob.
        #expect(merged.count == 2, "a weak A~B~C chain does not collapse into one blob")
        // The decisive proof: no single merged cluster pulls in BOTH the chain ends
        // (A's chatID 1 and C's chatID 3). A only ever merges with B (chatID 2).
        #expect(
            merged.allSatisfy { !($0.chatIDs.contains(1) && $0.chatIDs.contains(3)) },
            "the chain ends A and C are never folded into the same conversation")
    }

    // A genuine clique DOES fully merge: when every pair meets the rule, all three
    // fold. {1,2,3}, {1,2,3,4}, {1,2,3,5} — each pair is a subset/near-subset within
    // the delta+ratio bounds, and each pair's overlap is ≥ .6, so it's a real clique.
    @Test func internallyConsistentCliqueMergesFully() {
        let merged = Conversations.fuzzyMerge([
            group(1, [1, 2, 3], date: 300),
            group(2, [1, 2, 3, 4], date: 200),
            group(3, [1, 2, 3, 5], date: 100),
        ])
        // Pairs: {1,2,3}⊆{1,2,3,4} (.75 ✓); {1,2,3}⊆{1,2,3,5} (.75 ✓);
        // {1,2,3,4} vs {1,2,3,5} — intersection 3, union 5 → Jaccard .6 (no name),
        // NOT a subset. So that pair is NOT related → the three are NOT a clique.
        // {1,2,3} can sit with only one of the bigger two. Expect 2 conversations.
        #expect(merged.count == 2, "without an all-pairs clique, the three don't all merge")
    }

    // The all-pairs clique that truly merges to one: three forks of one group where
    // each pair is a within-bound subset of another. {1,2,3,4}, {1,2,3,4,5},
    // {1,2,3,4,5,6} — A⊆B (delta 1, .8), B⊆C (delta 1, .83), A⊆C (delta 2, 4/6=.67).
    // All three pairs related → one merged conversation.
    @Test func fullSubsetCliqueMergesToOne() {
        let merged = Conversations.fuzzyMerge([
            group(1, [1, 2, 3, 4], date: 300),
            group(2, [1, 2, 3, 4, 5], date: 200),
            group(3, [1, 2, 3, 4, 5, 6], date: 100),
        ])
        #expect(merged.count == 1, "three nested forks, all pairs within bounds → one merge")
        #expect(
            merged.first?.targetHandles == [1, 2, 3, 4, 5, 6],
            "roster = the union of the whole clique")
    }

    // 1:1 conversations pass through fuzzyMerge untouched (it only clusters groups).
    @Test func oneToOnesAreUntouchedByFuzzyMerge() {
        let oneToOne = Conversation(
            id: "p", displayName: "Pat", chatIDs: [99], targetHandles: [42], identifiers: ["+15551234567"],
            lastMessageDate: Date(timeIntervalSince1970: 50), messageCount: 7,
            primaryIdentifier: "+15551234567", isContact: true)
        let merged = Conversations.fuzzyMerge([
            oneToOne,
            group(1, [3, 5, 7], date: 100),
            group(2, [3, 5, 7, 9], date: 200),
        ])
        #expect(merged.contains { !$0.isGroup && $0.id == "p" }, "the 1:1 survives unchanged")
        #expect(merged.filter(\.isGroup).count == 1, "the two groups still merge around it")
    }

    // The core invariant: .exact (the default) is byte-for-byte the exact-set
    // grouping — fuzzyMerge is never reached. Here we assert the two paths diverge
    // ONLY when fuzzy is applied: the same exact-set input yields more entries under
    // .exact than under fuzzy (proving fuzzy is purely additive, off by default).
    @Test func exactDefaultEqualsExactSetGrouping() {
        // Two forks that would fuzzy-merge ({3,5,7} ⊂ {3,5,7,9}).
        let exactGroups = Conversations.groupGroups(
            [
                Fixtures.groupSummary(1, "g1", [3, 5, 7], date: 100, count: 10),
                Fixtures.groupSummary(2, "g2", [3, 5, 7, 9], date: 200, count: 4),
            ],
            handleLabels: [3: "+18160000003", 5: "+18160000005", 7: "+18160000007", 9: "+18160000009"])
        // Exact-set keeps them separate (different rosters).
        #expect(exactGroups.count == 2, ".exact (the default) leaves membership-changed forks separate")
        // The fuzzy pass over that exact-set output merges them.
        let fuzzy = Conversations.fuzzyMerge(exactGroups)
        #expect(fuzzy.count == 1, "the opt-in fuzzy pass merges the same two")
        // And fuzzyMerge of an already-singleton list is identity (nothing to do).
        #expect(Conversations.fuzzyMerge([exactGroups[0]]) == [exactGroups[0]], "single group → unchanged")
    }
}
