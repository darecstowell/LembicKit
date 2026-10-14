import Foundation
import GRDB
import Testing

@testable import LembicKit

// Group stitching never merges two different groups (lembickit.md F1) and never
// splits one group across a member's second handle (F2).
@Suite("group stitch safety")
struct GroupStitchTests {
    static let labels: [Int64: String] = [
        1: "+15555550101", 5: "sam.lee@icloud.com", 6: "+15555550104", 7: "+15555550105",
        8: "+15555550106", 9: "+15555550107", 14: "+15555550104",
    ]

    static func chat(
        _ chatID: Int64, _ handles: [Int64], name: String? = nil, groupID: String? = nil,
        first: Int64 = 0, last: Int64 = 100
    ) -> ChatDatabase.GroupConversationSummary {
        ChatDatabase.GroupConversationSummary(
            chatID: chatID, identifier: "chat\(chatID)", service: "iMessage", displayName: name,
            lastMessageDate: Date(timeIntervalSince1970: Double(last)), messageCount: 1,
            participantHandles: handles.sorted(), guid: "iMessage;+;chat\(chatID)",
            groupID: groupID, firstMessageDate: Date(timeIntervalSince1970: Double(first)))
    }

    @Test func sameRosterDifferentNamesStayApart() {
        let groups = Conversations.groupGroups(
            [
                Self.chat(10, [1, 7], name: "Book club"),
                Self.chat(11, [1, 7], name: "Lisbon trip"),
            ],
            handleLabels: Self.labels)
        #expect(groups.count == 2, "two named groups with one roster are two conversations")
        #expect(Set(groups.compactMap(\.groupName)) == ["Book club", "Lisbon trip"])
    }

    @Test func sameRosterSameNameIgnoresCaseAndSpace() {
        let groups = Conversations.groupGroups(
            [
                Self.chat(10, [1, 7], name: "Book Club "),
                Self.chat(11, [1, 7], name: "book club"),
            ],
            handleLabels: Self.labels)
        #expect(groups.count == 1)
    }

    @Test func unnamedForkJoinsItsOnlyNamedTwin() {
        let groups = Conversations.groupGroups(
            [Self.chat(10, [1, 7], name: "Book club"), Self.chat(11, [1, 7])],
            handleLabels: Self.labels)
        #expect(groups.count == 1, "one name in the bucket: the unnamed fork joins it")
        #expect(groups.first?.chatIDs == [10, 11])
    }

    @Test func unnamedForkStaysApartWhenTheNameIsAmbiguous() {
        let groups = Conversations.groupGroups(
            [
                Self.chat(10, [1, 7], name: "Book club"),
                Self.chat(11, [1, 7], name: "Lisbon trip"),
                Self.chat(12, [1, 7]),
            ],
            handleLabels: Self.labels)
        #expect(groups.count == 3, "an unnamed chat is never guessed into one of two groups")
    }

    @Test func secondHandleForkStitches() {
        // Sam texts from email (5) in one fork and from phone (6) in the other.
        let groups = Conversations.groupGroups(
            [
                Self.chat(12, [5, 8, 1], name: "Climbing", last: 300),
                Self.chat(13, [6, 8, 1], name: "Climbing", last: 200),
            ],
            handleLabels: Self.labels,
            personKeys: [5: "+15555550104", 6: "+15555550104"])
        #expect(groups.count == 1, "one group, not one per handle")
        let climbing = try? #require(groups.first)
        #expect(climbing?.chatIDs == [12, 13])
        #expect(climbing?.participants.count == 3, "Sam is one participant")
        let sam = climbing?.participants.first { $0.handleIDs.contains(5) }
        #expect(sam?.handleIDs == [5, 6], "both of Sam's handles belong to one participant")
        #expect(climbing?.targetHandles == [1, 5, 6, 8])
    }

    @Test func sameNumberOnTwoServicesStitchesWithoutContacts() {
        // Handles 6 and 14 are the same number on iMessage and SMS (or RCS).
        let groups = Conversations.groupGroups(
            [Self.chat(20, [6, 8, 1]), Self.chat(21, [14, 8, 1])], handleLabels: Self.labels)
        #expect(groups.count == 1, "an SMS to RCS upgrade does not split the group")
        #expect(groups.first?.participants.count == 3)
    }

    @Test func sharedGroupIDStitchesButNeverAcrossNames() {
        let linked = Conversations.groupGroups(
            [Self.chat(30, [1, 7, 8], groupID: "G1"), Self.chat(31, [1, 7, 9], groupID: "G1")],
            handleLabels: Self.labels)
        #expect(linked.count == 1, "Apple's group_id links the two chats")
        let named = Conversations.groupGroups(
            [
                Self.chat(30, [1, 7, 8], name: "A", groupID: "G1"),
                Self.chat(31, [1, 7, 9], name: "B", groupID: "G1"),
            ],
            handleLabels: Self.labels)
        #expect(named.count == 2, "different names win over a shared group_id")
    }

    @Test func chatLinksStitch() {
        let groups = Conversations.groupGroups(
            [Self.chat(30, [1, 7, 8]), Self.chat(31, [1, 7, 9])], handleLabels: Self.labels,
            chatLinks: [30: ["lookup-x"], 31: ["lookup-x"]])
        #expect(groups.count == 1)
    }

    // MARK: Fuzzy

    @Test func fuzzyNeverMergesDifferentNames() {
        let exact = Conversations.groupGroups(
            [
                Self.chat(1, [9, 6, 7, 8], name: "Family"),
                Self.chat(2, [6, 7, 8], name: "Mom's surprise 60th"),
            ],
            handleLabels: Self.labels)
        #expect(Conversations.fuzzyMerge(exact).count == 2, "the secret group stays secret")
    }

    @Test func fuzzyNeverMergesConcurrentGroups() {
        let day: Int64 = 86_400
        let concurrent = Conversations.groupGroups(
            [
                Self.chat(1, [9, 6, 7, 8], first: 0, last: 100 * day),
                Self.chat(2, [6, 7, 8], first: 50 * day, last: 50 * day + 3600),
            ],
            handleLabels: Self.labels)
        #expect(
            Conversations.fuzzyMerge(concurrent).count == 2,
            "a subset group active inside the other's lifetime is a different group")
        let sequential = Conversations.groupGroups(
            [
                Self.chat(1, [6, 7, 8], first: 0, last: 10 * day),
                Self.chat(2, [9, 6, 7, 8], first: 10 * day, last: 20 * day),
            ],
            handleLabels: Self.labels)
        #expect(
            Conversations.fuzzyMerge(sequential).count == 1,
            "one roster ending as the next begins is a membership change")
    }

    // MARK: DB-backed

    static let forkSQL = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, person_centric_id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER, chat_identifier TEXT,
            service_name TEXT, display_name TEXT, group_id TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER, is_from_me INTEGER,
            handle_id INTEGER, service TEXT, text TEXT, attributedBody BLOB, item_type INTEGER DEFAULT 0,
            associated_message_type INTEGER DEFAULT 0, associated_message_guid TEXT);
        INSERT INTO handle (ROWID, id, person_centric_id) VALUES
            (1,'+15555550101',NULL),(5,'sam.lee@icloud.com','P-SAM'),(6,'+15555550104','P-SAM'),
            (8,'+15555550106',NULL);
        INSERT INTO chat (ROWID, guid, style, chat_identifier, display_name) VALUES
            (12,'g12',43,'chat555','Climbing'),(13,'g13',43,'chat556','Climbing');
        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
            (12,5),(12,8),(12,1),(13,6),(13,8),(13,1);
        INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, text) VALUES
            (100,'a',1000000000,0,5,'Bouldering Thursday?'),
            (101,'b',2000000000,0,6,'Correction: Friday'),
            (102,'c',3000000000,0,8,'Friday works');
        INSERT INTO chat_message_join (chat_id, message_id) VALUES (12,100),(13,101),(12,102);
        """

    @Test func personCentricIDStitchesForksAndLabelsBothHandles() throws {
        let db = try Fixtures.openChatDB(populating: Self.forkSQL)
        let names = [
            "+15555550104": "Sam Lee", "+15555550106": "Dev Shah", "+15555550101": "Ana Ruiz",
        ]
        let conversations = try Conversations.list(from: db, contacts: names)
        #expect(conversations.count == 1, "the email fork and the phone fork are one group")
        let climbing = try #require(conversations.first)
        let labels = ContactsMap.resolve(handleLabels: try db.handleLabels(), contacts: names)
        let extractor = Extractor.forConversation(climbing, globalLabels: labels.resolved)
        let records = try db.read {
            try extractor.extractConversation($0, chatIDs: climbing.chatIDs)
        }
        #expect(
            records.map(\.speaker) == ["Sam", "Sam", "Dev"], "both of Sam's handles read as Sam")
    }

    @Test func contactIDsStitchForks() throws {
        let sql = Self.forkSQL.replacingOccurrences(of: "'P-SAM'", with: "NULL")
        let db = try Fixtures.openChatDB(populating: sql)
        let names = ["+15555550104": "Sam Lee", "sam.lee@icloud.com": "Sam Lee"]
        let apart = try Conversations.list(from: db, contacts: names)
        #expect(apart.count == 2, "a name alone is not proof of one person")
        let together = try Conversations.list(
            from: db, contacts: names,
            contactIDs: ["+15555550104": "card-sam", "sam.lee@icloud.com": "card-sam"])
        #expect(together.count == 1, "one Contacts card links the two handles")
    }

    @Test func personKeysNeverJoinOnEmptyIdentifiers() {
        let keys = Conversations.personKeys(handleLabels: [1: "", 2: "", 3: "+15555550101"])
        #expect(keys[1] != keys[2], "two handles with no identifier are not one person")
        #expect(keys[3] == "+15555550101")
    }
}
