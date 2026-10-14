import Foundation
import Testing

@testable import LembicKit

// `Export.ScopeRenderer` must give exactly what `Export.render` gives, for any
// scope: text, JSONL, marks, detections, redaction offsets, and records.
@Suite("scope renderer")
struct ScopeRendererTests {
    /// Every observable field of a render, so two renders compare byte for byte.
    static func dump(_ r: Export.Rendered) -> [String] {
        var out = ["txt:\(r.txt ?? "nil")", "jsonl:\(r.jsonl ?? "nil")", "count:\(r.messageCount)"]
        out += r.detected.map { "det:\($0.guid) \($0.range) \($0.category)" }
        out += ScopeFixtures.dump(r.unredactedRecords).map { "rec:\($0)" }
        out += r.skipped.map { "skip:\($0)" }
        guard let result = r.result else { return out + ["result:nil"] }
        out.append("text:\(result.text)")
        out += result.spans.map { "span:\($0.guid) \($0.outputBody)" }
        out += result.redactedMarks.map {
            "red:\($0.outputRange) \($0.redaction.guid) \(String(describing: $0.redaction.range))"
        }
        out += result.highlightMarks.map { "hi:\($0.outputRange) \($0.category)" }
        // Selections over each body map back to the same source ranges.
        for span in result.spans {
            let body = span.outputBody
            for selection in [
                body, NSRange(location: body.location + 1, length: max(0, body.length - 2)),
                NSRange(location: body.location, length: min(3, body.length)),
            ] {
                out += result.redactions(forSelectedOutput: selection).map {
                    "sel:\(selection) \($0.guid) \(String(describing: $0.range))"
                }
            }
        }
        return out
    }

    /// Date windows over `records`: random pairs, exact record dates, ties,
    /// and windows before, after, and between records.
    static func ranges(_ records: [MessageRecord], count: Int, seed: UInt64)
        -> [ClosedRange<Date>?]
    {
        var rng = ScopeFixtures.SplitMix(seed: seed)
        let dates = records.map(\.date)
        func pick() -> Date { dates[Int(rng.next() % UInt64(dates.count))] }
        let first = dates.min()!
        let last = dates.max()!
        var out: [ClosedRange<Date>?] = [nil, first...last]
        out.append(first.addingTimeInterval(-10)...first.addingTimeInterval(-1))
        out.append(last.addingTimeInterval(1)...last.addingTimeInterval(10))
        for _ in 0..<count {
            let a = pick()
            let b = pick()
            let lo = min(a, b)
            let hi = max(a, b)
            switch rng.next() % 4 {
            case 0: out.append(lo...hi)
            case 1 where hi > lo.addingTimeInterval(0.5):
                out.append(lo.addingTimeInterval(0.5)...hi)
            case 2 where hi > lo.addingTimeInterval(0.5):
                out.append(lo...hi.addingTimeInterval(-0.5))
            default: out.append(lo...lo)
            }
        }
        return out
    }

    static let detectorSets: [Set<SecretCategory>] = [
        Set(SecretCategory.allCases), [], [.apiKey], [.password, .standingCode],
        [.creditCard, .ssn, .bankAccount, .seedPhrase],
    ]

    /// Compares the renderer with `Export.render` over many scopes of `records`.
    static func expectParity(
        _ records: [MessageRecord], ranges: Int, seed: UInt64,
        group: Transcript.GroupRenderInfo? = nil, events: [Transcript.SystemEvent] = []
    ) throws {
        let skipped = records.enumerated().compactMap { i, r in
            i % 17 == 0 ? SkippedMessage(date: r.date, reason: .emptyBody) : nil
        }
        let renderer = Export.ScopeRenderer(
            records: records, number: "+15035550146", group: group, systemEvents: events,
            skipped: skipped)
        let manual = ScopeFixtures.redactions(for: records, seed: seed)
        var rng = ScopeFixtures.SplitMix(seed: seed &+ 1)
        var compared = 0
        for range in Self.ranges(records, count: ranges, seed: seed) {
            let bits = rng.next()
            let scope = Export.Scope(
                dateRange: range,
                trim: .init(
                    dropAttachmentPlaceholders: bits & 1 != 0, dropReactions: bits & 2 != 0),
                anonymizeSpeakers: bits & 4 != 0, showSystemEvents: bits & 8 != 0,
                enabledScrubbers: bits & 16 != 0 ? Set(ScrubberCategory.allCases) : [],
                enabledDetectors: detectorSets[Int((bits >> 5) % UInt64(detectorSets.count))],
                knownNames: ["Them": ["Sarah Chen"], "Me": ["Sam Lee"]])
            let redactions = bits & 256 != 0 ? manual : RedactionSet()
            let formats: Set<Export.Format> = bits & 512 != 0 ? [.txt, .jsonl] : [.txt]
            let detect = bits & 1024 == 0
            let expected = Export.render(
                records: records, number: "+15035550146", formats: formats, scope: scope,
                redactions: redactions, detect: detect, group: group, systemEvents: events,
                skipped: skipped)
            let actual = try renderer.render(
                formats: formats, scope: scope, redactions: redactions, detect: detect)
            let a = dump(actual)
            let e = dump(expected)
            #expect(a == e, "scope \(String(describing: range)) bits \(bits)")
            if a != e { return }
            compared += 1
        }
        #expect(compared > ranges)
    }

    @Test("matches Export.render over many scopes of a mixed thread")
    func parityMixed() throws {
        try Self.expectParity(ScopeFixtures.thread(count: 700, seed: 11), ranges: 60, seed: 11)
    }

    @Test("matches Export.render over many scopes of the redaction corpus")
    func parityCorpus() throws {
        let corpus = try ScopeFixtures.corpusMessages()
        let records = ScopeFixtures.thread(count: 900, seed: 12, corpus: corpus)
        try Self.expectParity(records, ranges: 60, seed: 12)
    }

    @Test("matches Export.render for a group with events")
    func parityGroup() throws {
        try Self.expectParity(
            Fixtures.goldenGroupRecords, ranges: 12, seed: 13, group: Fixtures.goldenGroupInfo,
            events: Fixtures.goldenGroupEvents)
        let records = ScopeFixtures.thread(count: 300, seed: 14)
        let events = records.enumerated().compactMap { i, r in
            i % 9 == 0 ? Transcript.SystemEvent(date: r.date, line: "Alice added Carla") : nil
        }
        try Self.expectParity(
            records, ranges: 20, seed: 14,
            group: .init(name: "Trip", participantLabels: ["Alice", "+1 (555) 201-3344"]),
            events: events)
    }

    @Test("matches Export.render for the golden fixtures")
    func parityGoldens() throws {
        try Self.expectParity(Fixtures.goldenRecords, ranges: 10, seed: 15)
        try Self.expectParity(Fixtures.goldenNameAliasRecords, ranges: 6, seed: 16)
    }

    @Test("records out of date order fall back to the full pass")
    func unsorted() throws {
        try Self.expectParity(
            ScopeFixtures.thread(count: 200, seed: 17).reversed(), ranges: 10, seed: 17)
    }

    /// Each scope edge on every record: the first record loses the message before
    /// it, and a join, answer, or key block is cut where the scope ends.
    @Test("matches a full detector pass at every scope edge")
    func everyEdge() throws {
        let records = ScopeFixtures.edgeThread()
        let renderer = Export.ScopeRenderer(records: records, number: "x")
        let dates = records.map(\.date)
        for lo in dates.indices {
            for hi in lo..<dates.count {
                let scope = Export.Scope(dateRange: dates[lo]...dates[hi])
                let full = SecretDetector.detect(
                    in: Export.unredactedRecords(records, scope: scope))
                #expect(try renderer.render(scope: scope).detected == full, "\(lo)...\(hi)")
            }
        }
        try Self.expectParity(records, ranges: 40, seed: 20)
    }

    /// Built from a conversation, it renders as the instance `Export.render` does.
    @Test("matches the instance render for a conversation")
    func parityConversation() throws {
        let db = try Fixtures.openChatDB(populating: Fixtures.groupSchemaAndData)
        defer { db.cleanUp() }
        let exporter = Export(database: db)
        let labels = ContactsMap.resolve(handleLabels: try db.handleLabels(), contacts: [:])
            .resolved
        for conversation in try Conversations.list(from: db, resolvingContacts: false) {
            let extractor = Extractor.forConversation(conversation, globalLabels: labels)
            let extraction = try db.read {
                try extractor.extract($0, chatIDs: conversation.chatIDs)
            }
            let events =
                conversation.isGroup
                ? try db.read {
                    try extractor.extractSystemEvents($0, chatIDs: conversation.chatIDs)
                }
                : []
            let renderer = Export.ScopeRenderer(
                records: extraction.records, conversation: conversation, labels: labels,
                systemEvents: events, skipped: extraction.skipped)
            for scope in [
                Export.Scope(), Export.Scope(anonymizeSpeakers: true, showSystemEvents: true),
                Export.Scope(
                    showSystemEvents: true, enabledScrubbers: Set(ScrubberCategory.allCases),
                    knownNames: ["Me": ["Sam Lee"]]),
            ] {
                let expected = try exporter.render(
                    conversation, formats: [.txt, .jsonl], scope: scope, resolveContacts: false)
                let actual = try renderer.render(formats: [.txt, .jsonl], scope: scope)
                #expect(Self.dump(actual) == Self.dump(expected))
            }
        }
    }

    @Test("a cancelled renderer throws")
    func cancel() {
        let renderer = Export.ScopeRenderer(
            records: ScopeFixtures.thread(count: 10, seed: 19), number: "x")
        renderer.cancel()
        #expect(throws: CancellationError.self) { try renderer.render() }
    }

    @Test("the empty render result is empty")
    func emptyResult() {
        let empty = Transcript.RenderResult.empty
        #expect(empty.text.isEmpty && empty.spans.isEmpty)
        #expect(empty.redactedMarks.isEmpty && empty.highlightMarks.isEmpty)
        #expect(empty.redactions(forSelectedOutput: NSRange(location: 0, length: 5)).isEmpty)
    }
}
