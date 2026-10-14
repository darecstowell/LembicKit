import CryptoKit
import Foundation
import GRDB
import Testing

@testable import LembicKit

// Where fix/data-coverage output meets fix/redaction scanning (release 0.4.0 merge).
@Suite("data and redaction interactions")
struct MergeInteractionTests {
    @Test("the effect column is read by position next to the send state columns")
    func invisibleInkWithFlags() throws {
        let sql = """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
                is_from_me INTEGER, handle_id INTEGER, text TEXT, error INTEGER DEFAULT 0,
                expressive_send_style_id TEXT);
            INSERT INTO handle VALUES (1, '+15550000001');
            INSERT INTO message VALUES
                (1, 'a', 100, 0, 1, 'hi', 0, NULL),
                (2, 'b', 200, 1, 0, 'Hunter2!x', 4, '\(Extractor.invisibleInkEffect)');
            INSERT INTO chat_message_join VALUES (1, 1), (1, 2);
            """
        let q = try Fixtures.makeInMemoryDB(populating: sql)
        let records = try q.read {
            try Extractor(targetHandles: [1], handleLabels: [:]).extractConversation(
                $0, chatIDs: [1])
        }
        #expect(records.map(\.isInvisibleInk) == [false, true])
        #expect(records.map(\.flags) == [[], .notDelivered])
        let ink = SecretDetector.detect(in: records).filter { $0.category == .invisibleInk }
        #expect(ink.first?.range == 0..<(records[1].text as NSString).length)
    }

    @Test("detectors and scrubbers read transcriptions and app message text")
    func newTextIsScanned() {
        let records = [
            Fixtures.attachRec(
                "v", 0, "Them", "[audio: \"my card is 4111 1111 1111 1111\"]", attach: true),
            Fixtures.attachRec("p", 60, "Them", "[Apple Pay: call 816-555-0123]"),
        ]
        let detected = SecretDetector.detect(in: records)
        #expect(detected.contains { $0.guid == "v" && $0.category == .creditCard })
        var scope = Export.Scope()
        scope.enabledScrubbers = [.phone]
        let out = Export.render(
            records: records, number: "+18165550188", formats: [.txt, .jsonl],
            scope: scope)
        #expect(!(out.txt ?? "").contains("555-0123"))
        #expect(!(out.jsonl ?? "").contains("555-0123"))
    }

    @Test("a former member with a number reads as a neutral label and keeps (left)")
    func formerMemberIsScrubbed() {
        let former = "(913) 555-0142"
        let group = Transcript.GroupRenderInfo(
            name: "Trip", participantLabels: ["Alice"], formerLabels: [former])
        let records = [
            MessageRecord(
                guid: "g1", date: Fixtures.t0, speaker: former, isTarget: false,
                service: "iMessage", text: "bye all", hadAttachment: false, reactions: [])
        ]
        var scope = Export.Scope()
        scope.enabledScrubbers = [.phone]
        let txt =
            Export.render(records: records, number: "chat1", scope: scope, group: group).txt
            ?? ""
        #expect(!txt.contains("555-0142"))
        #expect(txt.contains("# Participants: Me = the account owner · Alice · Member 1 (left)"))
        #expect(txt.contains("Member 1: bye all"))
    }

    @Test("a Genmoji strip keeps a later redaction on its text")
    func genmojiStripKeepsOffsets() {
        let text = "[genmoji: cat] ssn 123-45-6789"
        let record = Fixtures.attachRec("x", 0, "Them", text, attach: true)
        let start = (text as NSString).range(of: "123-45-6789").location
        var redactions = RedactionSet()
        redactions.add(Redaction(guid: "x", range: start..<(start + 11)))
        var scope = Export.Scope()
        scope.trim.dropAttachmentPlaceholders = true
        let out = Export.render(
            records: [record], number: "+18165550188", formats: [.txt, .jsonl], scope: scope,
            redactions: redactions,
            detect: false)
        #expect((out.txt ?? "").contains("Them: ssn [redacted]"))
        #expect((out.jsonl ?? "").contains("ssn [redacted]"))
    }

    @Test("anchors saved for a stitched conversation resolve on its records")
    func anchorsOnStitchedConversation() throws {
        let q = try Fixtures.makeInMemoryDB(populating: Fixtures.unionSchemaAndData)
        let records = try q.read {
            try Extractor(targetHandles: [3, 73], handleLabels: [:]).extractConversation(
                $0, chatIDs: [1, 2])
        }
        #expect(records.compactMap(\.guid) == ["A", "C", "B"], "message A is in both chats")
        var set = RedactionSet()
        set.add(Redaction(guid: "C", range: 0..<2))
        set.add(Redaction(guid: "B", range: nil))
        let key = SymmetricKey(size: .bits256)
        let anchors = set.anchors(in: records, key: key)
        let resolved = RedactionSet.resolve(anchors, records: records, key: key)
        #expect(resolved.redactions.all.count == 2)
        #expect(resolved.moved.isEmpty && resolved.wholeMessage.isEmpty)
    }
}
