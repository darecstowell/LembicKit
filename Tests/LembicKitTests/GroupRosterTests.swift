import Foundation
import GRDB
import Testing

@testable import LembicKit

// The roster lists former members, never the owner, and labels everyone the same
// way in the header, the body, and event lines (lembickit.md F15).
@Suite("group roster")
struct GroupRosterTests {
    static let labels: [Int64: String] = [
        1: "+15555550101", 2: "+15555550106", 3: "+15555550108", 4: "darec@example.com",
        5: "+15555550109",
    ]
    static let names = [
        "+15555550101": "Ana Ruiz", "+15555550106": "Dev Shah", "+15555550108": "Carla Reed",
        "darec@example.com": "Darec Kim", "+15555550109": "Eli Park",
    ]

    static func chat(_ handles: [Int64]) -> ChatDatabase.GroupConversationSummary {
        ChatDatabase.GroupConversationSummary(
            chatID: 10, identifier: "chat10", service: "iMessage", displayName: "Trip crew",
            lastMessageDate: Date(timeIntervalSince1970: 100), messageCount: 6,
            participantHandles: handles.sorted(), guid: "iMessage;+;chat10")
    }

    @Test func sendersAndEventTargetsWhoLeftAreFormerMembers() throws {
        let groups = Conversations.groupGroups(
            [Self.chat([1, 2])], handleLabels: Self.labels, names: Self.names,
            participantCounts: [10: [1: 3, 2: 1, 3: 2, 5: 0]])
        let group = try #require(groups.first)
        #expect(group.participants.map(\.label) == ["Ana", "Dev", "Carla", "Eli"])
        #expect(group.participants.map(\.isFormer) == [false, false, true, true])
        #expect(group.targetHandles == [1, 2, 3, 5])
        let info = try #require(Export.groupRenderInfo(for: group))
        #expect(info.participantLabels == ["Ana", "Dev"])
        #expect(info.formerLabels == ["Carla", "Eli"])
        let extractor = Extractor.forConversation(group, globalLabels: Self.labels)
        #expect(
            extractor.label(isFromMe: false, handleID: 3) == "Carla", "same label as the header")
    }

    @Test func ownerHandleIsNeverAMember() throws {
        let groups = Conversations.groupGroups(
            [Self.chat([1, 2, 4])], handleLabels: Self.labels, names: Self.names,
            participantCounts: [10: [1: 3, 2: 1, 4: 1]], owner: ["darec@example.com"])
        let group = try #require(groups.first)
        #expect(group.participants.map(\.label) == ["Ana", "Dev"])
        #expect(group.ownerHandles == [4])
        let extractor = Extractor.forConversation(group, globalLabels: Self.labels)
        #expect(extractor.label(isFromMe: false, handleID: 4) == "Me")
    }

    @Test func ownerDoesNotSplitAStitch() {
        let groups = Conversations.groupGroups(
            [
                Self.chat([1, 2, 4]),
                ChatDatabase.GroupConversationSummary(
                    chatID: 11, identifier: "chat11", service: "SMS", displayName: nil,
                    lastMessageDate: Date(timeIntervalSince1970: 50), messageCount: 1,
                    participantHandles: [1, 2], guid: "SMS;+;chat11"),
            ], handleLabels: Self.labels, owner: ["darec@example.com"])
        #expect(groups.count == 1, "the owner's own handle is not a different roster")
    }

    @Test func headerListsFormerMembersLast() {
        let records = [
            MessageRecord(
                guid: "a", date: Date(timeIntervalSince1970: 1_700_000_000), speaker: "Carla",
                isTarget: false, service: "iMessage", text: "I can drive", hadAttachment: false,
                reactions: [])
        ]
        let text = Transcript.compactText(
            records: records, number: "chat10", redactions: RedactionSet(), detected: [],
            group: Transcript.GroupRenderInfo(
                name: "Trip crew", participantLabels: ["Ana", "Dev"], formerLabels: ["Carla"])
        ).text
        #expect(
            text.contains("# Participants: Me = the account owner · Ana · Dev · Carla (left)\n"))
    }

    @Test func fuzzyRosterIgnoresFormerMembers() {
        let a = Conversation(
            id: "a", displayName: "a", chatIDs: [1], targetHandles: [1, 2, 3], identifiers: [],
            lastMessageDate: .now, messageCount: 1, primaryIdentifier: "a", isContact: false,
            isGroup: true,
            participants: [
                Participant(handleID: 1, identifier: "x"),
                Participant(handleID: 2, identifier: "y"),
                Participant(handleID: 3, identifier: "z", isFormer: true),
            ])
        #expect(Conversations.rosterKeys(a) == ["x", "y"])
    }

    static let sql = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER,
            chat_identifier TEXT, display_name TEXT);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
            is_from_me INTEGER, handle_id INTEGER, text TEXT, item_type INTEGER DEFAULT 0,
            group_action_type INTEGER DEFAULT 0, other_handle INTEGER DEFAULT 0,
            destination_caller_id TEXT);
        INSERT INTO handle VALUES (1,'+15555550101'),(2,'+15555550106'),(3,'+15555550108'),
            (4,'darec@example.com'),(5,'+15555550109');
        INSERT INTO chat VALUES (10,'iMessage;+;chat10',43,'chat10','Trip crew'),
            (11,'iMessage;-;+15555550101',45,'+15555550101',NULL);
        INSERT INTO chat_handle_join VALUES (10,1),(10,2),(10,4),(11,1);
        INSERT INTO message VALUES
            (1,'a',1000000000000,0,1,'Who is driving?',0,0,0,NULL),
            (2,'b',2000000000000,0,1,NULL,1,0,3,NULL),
            (3,'c',3000000000000,0,3,'I can drive',0,0,0,NULL),
            (4,'d',4000000000000,0,1,NULL,1,0,5,NULL),
            (5,'e',5000000000000,1,0,'Thanks all',0,0,0,'darec@example.com');
        INSERT INTO chat_message_join (chat_id, message_id) SELECT 10, ROWID FROM message;
        INSERT INTO message VALUES
            (6,'f',6000000000000,1,0,'Lunch?',0,0,0,'darec@example.com');
        INSERT INTO chat_message_join VALUES (11,6);
        """

    @Test func databaseFindsFormerMembersAndTheOwner() throws {
        let db = try Fixtures.openChatDB(populating: Self.sql)
        defer { db.cleanUp() }
        #expect(try db.groupParticipantMessageCounts() == [10: [1: 1, 3: 1, 5: 0]])
        #expect(
            try db.groupConversationSummaries().first?.ownerIdentifiers == ["darec@example.com"])
        let group = try #require(
            try Conversations.list(from: db, contacts: Self.names, region: "US").first(
                where: \.isGroup))
        #expect(group.participants.map(\.label) == ["Ana", "Dev", "Carla", "Eli"])
        #expect(group.participants.map(\.isFormer) == [false, false, true, true])
        #expect(group.ownerHandles == [4])
    }

    @Test func oneOddAddressIsNotTheOwner() {
        #expect(Conversations.ownerAddresses(seen: [["+15555550101"], []]).isEmpty)
        #expect(
            Conversations.ownerAddresses(seen: [["Darec@Example.com"], ["darec@example.com"]])
                == ["darec@example.com"])
    }
}
