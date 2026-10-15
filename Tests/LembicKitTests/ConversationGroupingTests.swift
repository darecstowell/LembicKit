import Foundation
import Testing

@testable import LembicKit

// `Conversations.group` is the multi-identifier union lifted out of
// the caller into the engine. These build ConversationSummary fixtures by hand
// (public init) and lock its semantics with no DB in play.
@Suite("conversation grouping")
struct ConversationGroupingTests {
    private func summary(
        _ chatID: Int64, _ identifier: String?, _ handleID: Int64,
        date: Int64, count: Int = 1
    ) -> ChatDatabase.ConversationSummary {
        Fixtures.summary(chatID, identifier, handleID, date: date, count: count)
    }

    @Test func multiIdentifierUnion() {
        // Multi-identifier union: phone + email, both resolving to "Alice".
        let aliceContacts = [
            "+18160000000": "Alice", "a@b.com": "Alice",
        ]
        let union = Conversations.group(
            [
                summary(1, "+18160000000", 3, date: 100, count: 4),
                summary(2, "a@b.com", 7, date: 200, count: 6),
            ], contacts: aliceContacts,
            contactIDs: ["+18160000000": "card-alice", "a@b.com": "card-alice"])
        #expect(union.count == 1, "phone + email under one contact → one Conversation")
        if let alice = union.first {
            #expect(alice.id == "chat:rowid:1", "union id is the smallest chat key")
            #expect(alice.legacyIDs.contains("Alice"), "the 0.3.1 id (the name) is kept")
            #expect(alice.displayName == "Alice", "union displayName is the contact name")
            #expect(alice.isContact, "resolved contact → isContact true")
            #expect(alice.chatIDs == [1, 2], "union chatIDs = both rows")
            #expect(alice.targetHandles == [3, 7], "union targetHandles = both handles")
            #expect(alice.messageCount == 10, "union messageCount = sum of both rows")
            #expect(
                alice.identifiers == ["+18160000000", "a@b.com"],
                "identifiers contains both normalized union members")
        }
    }

    @Test func twoCardsWithOneNameStayApart() {
        let rows = [
            summary(1, "+15555550102", 2, date: 100, count: 2),
            summary(2, "+15555550103", 3, date: 200, count: 2),
        ]
        let names = ["+15555550102": "Mike", "+15555550103": "Mike"]
        let split = Conversations.group(
            rows, contacts: names,
            contactIDs: ["+15555550102": "card-plumber", "+15555550103": "card-coworker"])
        #expect(split.count == 2, "two Contacts cards are two people")
        #expect(split.allSatisfy { $0.displayName == "Mike" && $0.isContact })
        #expect(Set(split.map(\.targetHandles)) == [[2], [3]])
        let nameOnly = Conversations.group(rows, contacts: names)
        #expect(nameOnly.count == 2, "a name alone never joins two handles")
    }

    @Test func unknownNumbersStandAlone() {
        // Unknown numbers stand alone, displayName == normalized id (NOT pretty).
        let strangers = Conversations.group(
            [
                summary(10, "+18161111111", 11, date: 100),
                summary(11, "+18162222222", 12, date: 200),
            ], contacts: [:])
        #expect(strangers.count == 2, "two unknown numbers → two Conversations")
        #expect(
            strangers.allSatisfy { !$0.isContact }, "no contact match → isContact false")
        #expect(
            strangers.contains { $0.displayName == "+18161111111" }
                && strangers.contains { $0.displayName == "+18162222222" },
            "displayName is the raw normalized identifier (engine never pretty-prints)")
        #expect(
            strangers.allSatisfy { $0.legacyIDs == [$0.displayName] },
            "unknown number: the 0.3.1 id is its normalized identifier")
    }

    @Test func recencyOrdering() {
        // Within a union the newest row sets primaryIdentifier + lastMessageDate;
        // across conversations the list is newest-first.
        let recency = Conversations.group(
            [
                summary(20, "+18163333333", 21, date: 100),  // older, in Bob's union
                summary(21, "b@b.com", 22, date: 500),  // newest in Bob's union
                summary(22, "+18164444444", 23, date: 300),  // a separate, mid-date person
            ],
            contacts: ["+18163333333": "Bob", "b@b.com": "Bob"],
            contactIDs: ["+18163333333": "card-bob", "b@b.com": "card-bob"])
        #expect(recency.count == 2, "Bob's two identifiers union; the stranger stands alone")
        if let bob = recency.first(where: { $0.displayName == "Bob" }) {
            #expect(
                bob.primaryIdentifier == "b@b.com",
                "primaryIdentifier = the newest row's normalized identifier")
            #expect(
                bob.lastMessageDate == Date(timeIntervalSince1970: 500),
                "lastMessageDate = the newest row's date")
        }
        #expect(
            recency.first?.displayName == "Bob",
            "newest-first: Bob (last @500) sorts above the stranger (@300)")
    }

    @Test func numberFormatNormalization() {
        // Same number, different formats normalize together (no contact).
        let formats = Conversations.group(
            [
                summary(30, "8160000000", 31, date: 100),  // bare 10-digit
                summary(31, "+18160000000", 32, date: 200),  // E.164
            ], contacts: [:])
        #expect(
            formats.count == 1,
            "8160000000 and +18160000000 normalize to one key → one Conversation")
        #expect(
            formats.first?.identifiers == ["+18160000000"],
            "both formats fold to the single normalized identifier")
    }

    @Test func straySharedHandlesUnified() {
        // A person whose number has TWO handle ROWIDs (re-registration churn):
        // only ROWID 3 is the chat's registered counterpart, but ROWID 99 also
        // sent messages in that chat. `handlesByIdentifier` must fold BOTH into
        // targetHandles so neither leaks in as a phantom extra speaker once
        // anonymized. Handles for OTHER identifiers stay out.
        let union = Conversations.group(
            [summary(1, "+18160000000", 3, date: 100, count: 4)],
            contacts: ["+18160000000": "Alice"],
            handlesByIdentifier: [
                "+18160000000": [3, 99],  // both of Alice's handle rows
                "+18169999999": [42],  // a stranger's handle — must NOT be claimed
            ])
        #expect(union.count == 1, "one person")
        #expect(
            union.first?.targetHandles == [3, 99],
            "every handle row sharing Alice's number is claimed as 'Them' (no phantom speaker)")
        #expect(
            union.first?.targetHandles.contains(42) == false,
            "a different identifier's handle is never folded in")
    }

    @Test func emailCaseFolding() {
        // Email case-folding: A@B.com and a@b.com share one key.
        let emails = Conversations.group(
            [
                summary(40, "A@B.com", 41, date: 100),
                summary(41, "a@b.com", 42, date: 200),
            ], contacts: [:])
        #expect(emails.count == 1, "A@B.com and a@b.com lowercase to one key → one Conversation")
        #expect(
            emails.first?.identifiers == ["a@b.com"],
            "email identifiers are lowercased to one normalized member")
    }

    /// Conversations with the same date sort by `id`, so the order is stable.
    @Test func equalDatesSortByID() throws {
        let tied = (1...12).map { summary($0, "+1816555\(1000 + $0)", $0, date: 100) }
        let grouped = Conversations.group(tied, contacts: [:])
        #expect(grouped.map(\.id) == grouped.map(\.id).sorted())

        var sql = Fixtures.fullSchema
        for i in 1...12 {
            sql += """
                INSERT INTO handle (ROWID, id) VALUES (\(i),'+1816555\(1000 + i)');
                INSERT INTO chat (ROWID, style, chat_identifier, service_name)
                    VALUES (\(i),45,'+1816555\(1000 + i)','iMessage');
                INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (\(i),\(i));
                INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, service, text)
                    VALUES (\(i),'m\(i)',0,0,\(i),'iMessage','no date');
                INSERT INTO chat_message_join (chat_id, message_id) VALUES (\(i),\(i));

                """
        }
        let listed = try Conversations.list(
            from: Fixtures.openChatDB(populating: sql), resolvingContacts: false, region: "US")
        #expect(listed.count == 12)
        #expect(listed.map(\.id) == listed.map(\.id).sorted())
    }
}
