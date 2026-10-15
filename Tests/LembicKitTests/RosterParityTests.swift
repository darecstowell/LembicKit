import Foundation
import Testing

@testable import LembicKit

// The prepared-record APIs must number `Member N` and alias quiet members as
// `Export.render` does, so every format of one export agrees.
@Suite("roster parity")
struct RosterParityTests {
    static let conversation = Conversation(
        id: "chat:g", displayName: "Trip", chatIDs: [2], targetHandles: [],
        identifiers: [], lastMessageDate: Fixtures.t0, messageCount: 3,
        primaryIdentifier: "chat2", isContact: false, isGroup: true,
        participants: [
            Participant(handleID: 1, identifier: "+15550000001", label: "Alice Park"),
            Participant(handleID: 2, identifier: "+15550000002"),
            Participant(handleID: 3, identifier: "+15550000003", label: "Member 1"),
            Participant(handleID: 4, identifier: "+15550000004", label: "Zed Quiet"),
            Participant(handleID: 5, identifier: "bob@example.com", isFormer: true),
        ],
        groupName: "Trip")
    static let labels: [Int64: String] = [1: "Alice Park", 4: "Zed Quiet"]

    static let records = [
        MessageRecord(
            guid: "r1", date: Fixtures.t0, speaker: "Me", isTarget: false, service: "iMessage",
            text: "hi Zed and Alice, call 913-555-0142", hadAttachment: false, reactions: []),
        MessageRecord(
            guid: "r2", date: Fixtures.t0.addingTimeInterval(60), speaker: "+15550000002",
            isTarget: false, service: "iMessage", text: "Zed is late again", hadAttachment: false,
            reactions: [Reaction(by: "Alice Park", emoji: "👍")]),
        MessageRecord(
            guid: "r3", date: Fixtures.t0.addingTimeInterval(120), speaker: "Alice Park",
            isTarget: false, service: "iMessage", text: "ok", hadAttachment: false,
            reactions: [Reaction(by: "+15550000002", emoji: "❤️")]),
    ]

    static var scopes: [Export.Scope] {
        var out: [Export.Scope] = []
        for anonymize in [false, true] {
            for scrubbers in [[], Set<ScrubberCategory>([.phone, .email])] {
                out.append(
                    Export.Scope(
                        anonymizeSpeakers: anonymize, enabledScrubbers: scrubbers,
                        knownNames: ["Me": ["Sam Lee"]]))
            }
        }
        return out
    }

    /// What the instance `render(_:)` does for `conversation`, without a database.
    static func rendered(_ scope: Export.Scope) -> Export.Rendered {
        var named = scope
        named.knownNames = Export.knownNames(
            for: conversation, labels: labels, adding: scope.knownNames)
        return Export.render(
            records: records, number: conversation.primaryIdentifier, formats: [.txt, .jsonl],
            scope: named, group: Export.groupRenderInfo(for: conversation))
    }

    static func lines(_ jsonl: String) -> [[String: Any]] {
        jsonl.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    static func speakers(_ jsonl: String) -> [String] {
        lines(jsonl).map { line in
            let by = (line["reacts"] as? [[String: Any]] ?? []).compactMap { $0["by"] as? String }
            return ([line["s"] as? String ?? ""] + by).joined(separator: "|")
        }
    }

    static func speakers(_ records: [MessageRecord]) -> [String] {
        records.map { ([$0.speaker] + $0.reactions.map(\.by)).joined(separator: "|") }
    }

    @Test("prepared records number Member N and alias names as render does")
    func preparedMatchesRender() {
        for scope in Self.scopes {
            let expected = Self.rendered(scope).jsonl ?? ""
            let redacted = Export.preparedRedactedRecords(
                Self.records, conversation: Self.conversation, labels: Self.labels, scope: scope,
                redactions: RedactionSet())
            #expect(Transcript.jsonLines(records: redacted) == expected, "\(scope)")
            let txt = Self.rendered(scope).txt ?? ""
            for r in redacted {
                #expect(txt.contains(" \(r.speaker): \(r.text)"), "\(scope)")
            }
            let unredacted = Export.unredactedPreparedRecords(
                Self.records, conversation: Self.conversation, labels: Self.labels, scope: scope)
            #expect(Self.speakers(unredacted) == Self.speakers(expected), "\(scope)")
        }
    }

    @Test("the group overloads match render given the same names")
    func groupOverloadsMatchRender() {
        let group = Export.groupRenderInfo(for: Self.conversation)
        for var scope in Self.scopes {
            scope.knownNames = Export.knownNames(
                for: Self.conversation, labels: Self.labels, adding: scope.knownNames)
            let expected = Self.rendered(scope).jsonl ?? ""
            let redacted = Export.preparedRedactedRecords(
                Self.records, scope: scope, redactions: RedactionSet(), group: group)
            #expect(Transcript.jsonLines(records: redacted) == expected, "\(scope)")
            let unredacted = Export.unredactedPreparedRecords(
                Self.records, scope: scope, group: group)
            #expect(Self.speakers(unredacted) == Self.speakers(expected), "\(scope)")
        }
    }

    @Test("the conversation scope renderer matches render")
    func scopeRendererMatchesRender() throws {
        let renderer = Export.ScopeRenderer(
            records: Self.records, conversation: Self.conversation, labels: Self.labels)
        for scope in Self.scopes {
            let actual = try renderer.render(formats: [.txt, .jsonl], scope: scope)
            #expect(
                ScopeRendererTests.dump(actual) == ScopeRendererTests.dump(Self.rendered(scope)))
        }
    }
}
