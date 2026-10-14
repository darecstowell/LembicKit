import Foundation
import GRDB
import Testing

@testable import LembicKit

// App messages (Apple Pay, polls, Check In, games, handwriting, Digital Touch)
// render as one typed line instead of vanishing (lembickit.md F4).
@Suite("app messages")
struct AppMessageTests {
    static let ext = "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:"

    /// A keyed-archive payload like the ones Messages writes to `payload_data`.
    static func payload(_ fields: [String: Any]) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: fields, requiringSecureCoding: false)
    }

    static func pollURL(_ json: String) -> NSURL {
        NSURL(string: "data:," + Data(json.utf8).base64EncodedString() + "?src=p&c=4")!
    }

    @Test func applePayShowsTheSummary() throws {
        let data = try Self.payload(["ldtext": "Sent $265 with Apple Pay.", "an": "Apple Pay"])
        let token = AppMessage.token(
            bundleID: Self.ext + "com.apple.PassbookUIService.PeerPaymentMessagesExtension",
            payload: data)
        #expect(token == "[Apple Pay: Sent $265 with Apple Pay.]")
    }

    @Test func checkInAndThirdPartyApps() throws {
        let checkIn = try Self.payload([
            "ldtext": "Check\u{00A0}In: Timer Started", "an": "Check In",
        ])
        #expect(
            AppMessage.token(
                bundleID: Self.ext + "com.apple.SafetyMonitorApp.SafetyMonitorMessages",
                payload: checkIn) == "[Check In: Timer Started]")
        let game = try Self.payload(["ldtext": "Dots & Boxes", "an": "GamePigeon"])
        #expect(
            AppMessage.token(bundleID: Self.ext + "com.gamepigeon.GamePigeon.Ext", payload: game)
                == "[app: GamePigeon (Dots & Boxes)]")
        #expect(
            AppMessage.token(bundleID: Self.ext + "com.example.Unknown", payload: nil)
                == "[app message]", "an unknown app with no payload still leaves a trace")
        #expect(
            AppMessage.token(bundleID: Self.ext + "com.example.Bad", payload: Data([1, 2, 3]))
                == "[app message]", "a payload that does not parse never crashes")
    }

    @Test func builtInBalloons() {
        #expect(
            AppMessage.token(bundleID: "com.apple.Handwriting.HandwritingProvider", payload: nil)
                == "[handwritten message]")
        #expect(
            AppMessage.token(bundleID: "com.apple.DigitalTouchBalloonProvider", payload: nil)
                == "[Digital Touch]")
        #expect(
            AppMessage.token(
                bundleID: Self.ext + "com.apple.findmy.FindMyMessagesApp", payload: nil)
                == "[shared location]")
        #expect(
            AppMessage.token(bundleID: "com.apple.messages.URLBalloonProvider", payload: nil)
                == nil,
            "a link preview is not an app message: the URL is already in the text")
    }

    @Test func pollListsItsOptions() throws {
        let json = """
            {"item":{"title":"Lunch spot?","orderedPollOptions":[
            {"optionIdentifier":"A","text":"Thai"},{"optionIdentifier":"B","text":"Tacos"}]}}
            """
        let data = try Self.payload([
            "ldtext": "Sent a poll", "an": "Polls", "URL": Self.pollURL(json),
        ])
        let poll = try #require(AppMessage.poll(from: data))
        #expect(
            poll.options == [
                AppMessage.PollOption(id: "A", text: "Thai"), .init(id: "B", text: "Tacos"),
            ])
        #expect(
            AppMessage.token(bundleID: Self.ext + "com.apple.messages.Polls", payload: data)
                == "[poll: Lunch spot? (Thai / Tacos)]")
    }

    static func appSQL(_ payloads: [String: Data]) -> (String, [Data]) {
        let sql = """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, style INTEGER, chat_identifier TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
                is_from_me INTEGER, handle_id INTEGER, text TEXT, attributedBody BLOB,
                item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0,
                associated_message_guid TEXT, balloon_bundle_id TEXT, payload_data BLOB);
            INSERT INTO handle VALUES (3,'+18160000003');
            INSERT INTO chat VALUES (1,45,'+18160000003');
            INSERT INTO chat_handle_join VALUES (1,3);
            """
        return (sql, Array(payloads.values))
    }

    @Test func pollAndVoteRenderInTheTranscript() throws {
        let poll = try Self.payload([
            "ldtext": "Sent a poll", "an": "Polls",
            "URL": Self.pollURL(
                #"{"item":{"title":"Lunch spot?","orderedPollOptions":[{"optionIdentifier":"A","text":"Thai"},{"optionIdentifier":"B","text":"Tacos"}]}}"#
            ),
        ])
        let vote = try Self.payload([
            "an": "Polls",
            "URL": Self.pollURL(#"{"item":{"votes":[{"voteOptionIdentifier":"B"}]}}"#),
        ])
        let pay = try Self.payload(["ldtext": "Sent $20 with Apple Pay.", "an": "Apple Pay"])
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: Self.appSQL([:]).0)
            let rows: [(Int64, String, Int64, Int64, String?, Int64, String?, String?, Data?)] = [
                (
                    10, "poll", 100, 1, "\u{FFFC}", 0, nil, Self.ext + "com.apple.messages.Polls",
                    poll
                ),
                (
                    11, "vote", 200, 0, "\u{FFFC}", 4000, "poll",
                    Self.ext + "com.apple.messages.Polls", vote
                ),
                (
                    12, "pay", 300, 1, "\u{FFFC}", 0, nil,
                    Self.ext + "com.apple.PassbookUIService.PeerPaymentMessagesExtension", pay
                ),
                (13, "thanks", 400, 0, "thanks!", 0, nil, nil, nil),
            ]
            for r in rows {
                try db.execute(
                    sql: """
                        INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, text,
                            associated_message_type, associated_message_guid, balloon_bundle_id,
                            payload_data) VALUES (?,?,?,?,?,?,?,?,?,?)
                        """,
                    arguments: [r.0, r.1, r.2, r.3, r.3 == 1 ? 0 : 3, r.4, r.5, r.6, r.7, r.8])
                try db.execute(sql: "INSERT INTO chat_message_join VALUES (1, ?)", arguments: [r.0])
            }
        }
        let records = try queue.read {
            try Extractor(targetHandles: [3], handleLabels: [:]).extractConversation(
                $0, chatIDs: [1])
        }
        #expect(
            records.map(\.text) == [
                "[poll: Lunch spot? (Thai / Tacos)]", "[Apple Pay: Sent $20 with Apple Pay.]",
                "thanks!",
            ], "the poll and the payment are lines; the vote is not a message")
        #expect(
            records.first?.reactions == [Reaction(by: "Them", emoji: "voted Tacos")],
            "the vote attaches to the poll")
    }
}
