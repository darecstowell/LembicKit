import Foundation
import Testing

@testable import LembicKit

// The header names the zone, a repeated fall-back hour shows its zone, and JSONL
// dates carry an offset (lembickit.md F24).
@Suite("time zone")
struct TimeZoneTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!

    // 2026-11-01: clocks fall back from 02:00 CDT to 01:00 CST.
    private func record(_ guid: String, _ iso: String, _ text: String) -> MessageRecord {
        MessageRecord(
            guid: guid, date: ISO8601DateFormatter().date(from: iso)!, speaker: "Them",
            isTarget: true, service: "iMessage", text: text, hadAttachment: false, reactions: [])
    }

    private var records: [MessageRecord] {
        [
            record("a", "2026-11-01T06:30:00Z", "leaving the party now"),
            record("b", "2026-11-01T07:10:00Z", "home safe"),
            record("c", "2026-11-01T09:00:00Z", "slept well"),
        ]
    }

    @Test func repeatedHourNamesItsZone() {
        let text = Transcript.compactText(
            records: records, number: "+15555550111", redactions: RedactionSet(), detected: [],
            timeZone: chicago
        ).text
        #expect(text.contains("# Times are local (America/Chicago), 24h."))
        #expect(text.contains("01:30 CDT Them: leaving the party now\n"))
        #expect(text.contains("01:10 CST Them: home safe\n"))
        #expect(text.contains("03:00 Them: slept well\n"), "an hour that happens once stays plain")
    }

    @Test func anonymizedHeaderOmitsTheZone() {
        let text = Transcript.compactText(
            records: records, number: "+15555550111", redactions: RedactionSet(), detected: [],
            anonymize: true, timeZone: chicago
        ).text
        #expect(text.contains("# Times are local, 24h."))
    }

    @Test func jsonlDatesCarryAnOffset() {
        let jsonl = Transcript.jsonLines(records: records, timeZone: chicago)
        #expect(jsonl.contains("\"d\": \"2026-11-01T01:30:00-05:00\""))
        #expect(jsonl.contains("\"d\": \"2026-11-01T01:10:00-06:00\""))
    }

    @Test func zonesWithoutDSTHaveNoRepeatedHours() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            Transcript.repeatedHours(
                from: start, to: start.addingTimeInterval(86_400 * 400),
                in: TimeZone(identifier: "Asia/Tokyo")!
            ).isEmpty)
    }
}
