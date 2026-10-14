import Foundation
import GRDB
import Testing

@testable import LembicKit

// One person, two handles/services (3 = iMessage, 73 = SMS) in two 1:1 chats,
// plus a group chat that must be excluded. Message A is shared into both 1:1
// chats (dedup) and carries a photo (the placeholder must not double). C is an
// SMS sent between A and B by date (merge-sort + green bubble). D lives only in
// the group (must not appear).
//
// DB-backed: these call the *instance* query methods over a real `ChatDatabase`
// (materialized from the in-memory fixture via `openChatDB`), which is the
// surface kept when the static `func(db)` twins were folded. `throws` lets any
// fixture error fail the test with the real error.
@Suite("conversation union")
struct ConversationUnionTests {
    @Test func unionAndExtraction() throws {
        let db = try Fixtures.openChatDB(populating: Fixtures.unionSchemaAndData)
        let ex = Extractor(targetHandles: [3, 73], handleLabels: [:])

        let chats = try db.oneToOneChats(forHandles: [3, 73])
        #expect(chats.map(\.chatID) == [1, 2], "finds both 1:1 chats, excludes the group")

        let recs = try db.queue.read {
            try ex.extractConversation($0, chatIDs: Set(chats.map(\.chatID)))
        }
        #expect(recs.count == 3, "shared message de-duped (3 emitted, not 4)")
        #expect(
            recs.map(\.text) == ["look [photo]", "hi from sms", "reply"],
            "date-merged; photo not doubled")
        #expect(
            recs.map(\.speaker) == ["Them", "Them", "Me"], "both handles → Them; mine → Me")
        #expect(recs[1].service == "SMS", "the SMS (green-bubble) message is in the union")
        #expect(
            recs.allSatisfy { !$0.text.contains("group only") },
            "group-chat message excluded")
        let emptyUnion = try db.queue.read { try ex.extractConversation($0, chatIDs: []) }
        #expect(emptyUnion.isEmpty, "empty chat set → no rows")
    }

    @Test func retractedMessageExcluded() throws {
        let db = try Fixtures.openChatDB(populating: Fixtures.retractedSchemaAndData)
        let ex = Extractor(targetHandles: [3], handleLabels: [:])
        let recs = try db.queue.read { try ex.extractChat($0, chatID: 1) }
        #expect(recs.map(\.guid) == ["kept", "unsent"], "an unsend leaves a trace")
        #expect(
            recs.map(\.text) == ["still here", "[unsent a message]"],
            "retracted body never surfaces")
        #expect(recs.last?.flags == .unsent)
    }

    @Test func summariesAndGrouping() throws {
        let db = try Fixtures.openChatDB(populating: Fixtures.unionSchemaAndData)

        // Conversation picker: both 1:1 chats, group excluded,
        // recency-sorted (chat 1's last msg @300 > chat 2's @200), real counts.
        let summaries = try db.conversationSummaries()
        #expect(
            summaries.map(\.chatID) == [1, 2], "summaries: 1:1 chats only, newest first")
        #expect(summaries.map(\.messageCount) == [2, 2], "summaries: real-message counts")
        #expect(
            summaries.allSatisfy { $0.chatID != 3 },
            "1:1 enumerator still excludes the style=43 group (#3) — unchanged")

        // The complementary group enumerator (the grouping layer) INCLUDES the same #3 the
        // 1:1 path drops: the two enumerators partition style=45 vs style=43.
        let groupSummaries = try db.groupConversationSummaries()
        #expect(
            groupSummaries.map(\.chatID) == [3],
            "group enumerator includes exactly the style=43 chat the 1:1 path excludes")
        #expect(
            groupSummaries.first?.participantHandles == [3],
            "group enumerator carries the chat's participant handle-set")

        // End-to-end: `Conversations.group` folds the real (in-memory) summaries
        // into people. With no contacts the two distinct identifiers collapse by
        // normalized identifier; here both chats are '+18160000000', so it's one
        // person with both chats unioned.
        let grouped = Conversations.group(summaries, contacts: [:])
        #expect(grouped.count == 1, "grouped: both '+18160000000' chats → one person")
        #expect(grouped.first?.chatIDs == [1, 2], "grouped: union holds both chat ROWIDs")
        #expect(
            grouped.first?.targetHandles == [3, 73],
            "grouped: union holds both handle ROWIDs")
    }

    /// A 1:1 chat with two `chat_handle_join` rows counts each message once and
    /// reports its smallest handle.
    @Test func twoHandleRowsDoNotDoubleTheCount() throws {
        let sql =
            Fixtures.fullSchema + """
                INSERT INTO handle (ROWID, id) VALUES (4,'+15551230004'),(5,'+15551230005');
                INSERT INTO chat (ROWID, style, chat_identifier, service_name) VALUES (1,45,NULL,'iMessage');
                INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1,5),(1,4);
                INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, service, text) VALUES
                    (1,'a',100,0,4,'iMessage','one'),
                    (2,'b',200,1,0,'iMessage','two'),
                    (3,'c',300,0,5,'iMessage','three');
                INSERT INTO chat_message_join (chat_id, message_id) VALUES (1,1),(1,2),(1,3);
                """
        let summaries = try Fixtures.openChatDB(populating: sql).conversationSummaries()
        #expect(summaries.map(\.messageCount) == [3])
        #expect(summaries.map(\.handleID) == [4])
        #expect(summaries.map(\.identifier) == ["+15551230004"])
    }
}
