import Foundation
import Testing

@testable import LembicKit

// Conversation.id comes from chat GUIDs, so names, Contacts access, and member
// changes do not move it. legacyIDs keeps the 0.3.1 keys for migration.
@Suite("stable conversation id")
struct StableIDTests {
    private func summary(
        _ chatID: Int64, _ identifier: String, _ handleID: Int64, guid: String, date: Int64
    ) -> ChatDatabase.ConversationSummary {
        ChatDatabase.ConversationSummary(
            chatID: chatID, identifier: identifier, service: "iMessage", handleID: handleID,
            lastMessageDate: Date(timeIntervalSince1970: Double(date)), messageCount: 1,
            guid: guid)
    }

    @Test func oneToOneIDIgnoresContactName() {
        let rows = [summary(1, "+18160000001", 3, guid: "iMessage;-;+18160000001", date: 100)]
        let bare = Conversations.group(rows, contacts: [:])
        let named = Conversations.group(rows, contacts: ["+18160000001": "Maya Thompson"])
        let renamed = Conversations.group(rows, contacts: ["+18160000001": "Maya T."])
        #expect(bare.first?.id == "chat:iMessage;-;+18160000001")
        #expect(named.first?.id == bare.first?.id, "granting Contacts keeps the id")
        #expect(renamed.first?.id == bare.first?.id, "renaming the contact keeps the id")
        #expect(named.first?.chatGUIDs == ["iMessage;-;+18160000001"])
        #expect(
            named.first?.legacyIDs == ["Maya Thompson", "+18160000001"],
            "the 0.3.1 keys: the contact name and the bare identifier")
    }

    @Test func mergedOneToOneTakesTheSmallestChatGUID() {
        let rows = [
            summary(1, "+18160000001", 3, guid: "iMessage;-;+18160000001", date: 100),
            summary(2, "maya@example.com", 4, guid: "iMessage;-;maya@example.com", date: 200),
        ]
        let merged = Conversations.group(
            rows, contacts: ["+18160000001": "Maya", "maya@example.com": "Maya"],
            contactIDs: ["+18160000001": "card-maya", "maya@example.com": "card-maya"])
        #expect(merged.count == 1)
        #expect(merged.first?.id == "chat:iMessage;-;+18160000001")
        #expect(merged.first?.chatGUIDs.count == 2)
        #expect(
            merged.first?.legacyIDs == ["Maya", "+18160000001", "maya@example.com"],
            "every key 0.3.1 could have used")
    }

    @Test func groupIDIgnoresNameAndMembers() {
        func group(_ handles: [Int64], name: String?) -> Conversation? {
            Conversations.groupGroups(
                [
                    ChatDatabase.GroupConversationSummary(
                        chatID: 7, identifier: "chat123", service: "iMessage", displayName: name,
                        lastMessageDate: Date(timeIntervalSince1970: 100), messageCount: 1,
                        participantHandles: handles, guid: "iMessage;+;chat123")
                ],
                handleLabels: [3: "+18160000003", 4: "+18160000004", 5: "+18160000005"]
            ).first
        }
        let before = group([3, 4], name: "Trip")
        let after = group([3, 4, 5], name: "Trip 2026")
        #expect(before?.id == "chat:iMessage;+;chat123")
        #expect(after?.id == before?.id, "a rename and a new member keep the id")
        #expect(before?.legacyIDs == ["group:3,4"])
    }

    @Test func missingGUIDFallsBackToRowID() {
        let rows = [Fixtures.summary(9, "+18160000009", 3, date: 100)]
        #expect(Conversations.group(rows, contacts: [:]).first?.id == "chat:rowid:9")
    }

    @Test func listReadsChatGUIDs() throws {
        let sql =
            Fixtures.groupSchemaAndData.replacingOccurrences(
                of: "service_name TEXT, display_name TEXT);",
                with: "service_name TEXT, display_name TEXT, guid TEXT);"
            ) + "UPDATE chat SET guid = 'any;' || chat_identifier;"
        let db = try Fixtures.openChatDB(populating: sql)
        let conversations = try Conversations.list(from: db, resolvingContacts: false)
        let ids = conversations.map(\.id)
        #expect(Set(ids).count == ids.count, "ids are unique")
        #expect(ids.contains("chat:any;+18160000009"), "the 1:1 id is its chat GUID")
        #expect(ids.contains("chat:any;group-A"), "the stitched group takes its smallest chat GUID")
    }

    @Test func businessChatKeepsItsOldKeyForMigration() {
        let biz = "urn:biz:8a6f2c3e-1d2b-4c5d-9e8f-0123456789ab"
        let rows = [summary(1, biz, 3, guid: "iMessage;-;" + biz, date: 100)]
        let chat = Conversations.group(rows, contacts: [:])
        #expect(chat.first?.displayName == biz)
        #expect(
            chat.first?.legacyIDs == [biz, "+186231245980123456789"],
            "0.3.1 keyed this chat by a fake number")
    }
}
