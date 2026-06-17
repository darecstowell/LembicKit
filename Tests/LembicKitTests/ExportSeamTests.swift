import Foundation
import Testing

@testable import LembicKit

// The render seam: `Export.render(records:number:…)` is the pure (no-DB) entry both
// a caller's in-memory path and the unit tests exercise. These lock the
// load-bearing detect→redact ordering, the format set, and the scope filter
// without a real chat.db.
@Suite("export seam")
struct ExportSeamTests {
    private let t0 = Fixtures.t0
    // g1 carries a planted password secret; g0/g2 are innocuous.
    private let recs = [
        Fixtures.exportRec(0, "Them", "hey there"),
        Fixtures.exportRec(1, "Me", "password is hunter2sekret"),
        Fixtures.exportRec(2, "Them", "got it"),
    ]

    @Test func bothFormatsFromOneCall() {
        let both = Export.render(records: recs, number: "+1", formats: [.txt, .jsonl])
        #expect(both.txt != nil, "txt produced when requested")
        #expect(both.jsonl != nil, "jsonl produced when requested")
        #expect(
            both.txt?.contains("# iMessage transcript with +1") ?? false,
            "txt has the daily-grouped header")
        #expect(
            both.jsonl?.split(separator: "\n").count == 3,
            "jsonl emits one object per in-range message")
        #expect(both.messageCount == 3, "messageCount reflects the full set")
        // Format set is honored.
        #expect(
            Export.render(records: recs, number: "+1", formats: [.txt]).jsonl == nil,
            "jsonl nil when only .txt requested")
        #expect(
            Export.render(records: recs, number: "+1", formats: [.jsonl]).txt == nil,
            "txt nil when only .jsonl requested")
    }

    @Test func detectionThreadsThrough() {
        let both = Export.render(records: recs, number: "+1", formats: [.txt, .jsonl])
        #expect(
            both.detected.contains { $0.guid == "g1" && $0.category == .password },
            "detect: true flags the planted password")
        #expect(
            !(both.result?.highlightMarks.isEmpty ?? true),
            "the visible secret produces a highlight mark")
        let noDetect = Export.render(
            records: recs, number: "+1", formats: [.txt], detect: false)
        #expect(noDetect.detected.isEmpty, "detect: false runs no detection")
        #expect(
            noDetect.result?.highlightMarks.isEmpty ?? false,
            "detect: false → no highlight marks")
    }

    @Test func redactionRemovesHighlight() {
        // Build a RedactionSet covering the detected secret's range, re-render, and
        // assert the secret text is gone, `[redacted]` is present, and the highlight
        // dropped out (proves detect-over-filtered → render-with-both).
        let both = Export.render(records: recs, number: "+1", formats: [.txt, .jsonl])
        var redactions = RedactionSet()
        for d in both.detected { redactions.add(Redaction(guid: d.guid, range: d.range)) }
        let redacted = Export.render(
            records: recs, number: "+1", formats: [.txt, .jsonl], redactions: redactions)
        #expect(
            !(redacted.txt?.contains("hunter2sekret") ?? true),
            "the redacted secret text is gone from the output")
        #expect(redacted.txt?.contains("[redacted]") ?? false, "the secret reads [redacted]")
        #expect(
            redacted.result?.highlightMarks.isEmpty ?? false,
            "a redacted secret drops out of highlightMarks (detect→redact ordering)")
        // DECISION #3: the `.jsonl` now honors redactions too — the
        // `--redact-detected` leak (redacted .txt but raw .jsonl) is closed.
        #expect(
            !(redacted.jsonl?.contains("hunter2sekret") ?? true),
            "the redacted secret never leaks into the .jsonl (the redaction-aware render closes the gap)")
        #expect(
            redacted.jsonl?.contains("[redacted]") ?? false,
            "the secret reads [redacted] in the jsonl too")
    }

    @Test func scopeFilter() {
        // A window covering only the middle day.
        let mid = t0.addingTimeInterval(86_400)
        let scoped = Export.render(
            records: recs, number: "+1", formats: [.txt],
            scope: .init(dateRange: mid...mid))
        #expect(scoped.messageCount == 1, "date range filters to the in-range set")
        #expect(scoped.records.map(\.guid) == ["g1"], "scope keeps exactly the in-range record")
    }

    @Test func emptyScopeContract() {
        // Empty scope → "" txt + nil result (the caller's empty-render contract).
        let empty = Export.render(
            records: recs, number: "+1", formats: [.txt, .jsonl],
            scope: .init(dateRange: t0.addingTimeInterval(-86_400)...t0.addingTimeInterval(-1)))
        #expect(empty.txt?.isEmpty ?? false, "empty scope → empty .txt string")
        #expect(empty.jsonl?.isEmpty ?? false, "empty scope → empty .jsonl string")
        #expect(empty.result == nil, "empty scope → nil RenderResult")
        #expect(empty.messageCount == 0, "empty scope → zero messages")
    }
}
