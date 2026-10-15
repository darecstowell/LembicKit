import Foundation
import Testing

@testable import LembicKit

// The two prepared-record APIs share one prepare step. These tests hold them to the
// two separate pipelines they replaced (kept below as the reference).
@Suite("prepared records")
struct PreparedRecordsTests {
    let dump = ScopeFixtures.dump

    static func scopes(_ records: [MessageRecord]) -> [Export.Scope] {
        let dates = records.map(\.date)
        let mid = dates[dates.count / 3]...dates[dates.count * 2 / 3]
        var out: [Export.Scope] = []
        for range in [nil, mid] {
            for trim in [
                Transcript.TrimOptions.none,
                .init(dropAttachmentPlaceholders: true, dropReactions: true),
            ] {
                for anonymize in [false, true] {
                    for scrubbers in [[], Set(ScrubberCategory.allCases)] {
                        out.append(
                            Export.Scope(
                                dateRange: range, trim: trim, anonymizeSpeakers: anonymize,
                                enabledScrubbers: scrubbers,
                                knownNames: ["Them": ["Sarah Chen"], "Me": ["Sam Lee"]]))
                    }
                }
            }
        }
        out.append(Export.Scope(enabledDetectors: []))
        return out
    }

    @Test("both prepared-record APIs match the pipelines they replaced")
    func matchesReference() {
        let records = ScopeFixtures.thread(count: 400, seed: 3)
        let manual = ScopeFixtures.redactions(for: records)
        for scope in Self.scopes(records) {
            #expect(
                dump(Export.unredactedPreparedRecords(records, scope: scope))
                    == dump(Reference.unredacted(records, scope: scope)))
            for redactions in [RedactionSet(), manual] {
                #expect(
                    dump(
                        Export.preparedRedactedRecords(
                            records, scope: scope, redactions: redactions))
                        == dump(Reference.redacted(records, scope: scope, redactions: redactions)))
            }
        }
    }

    @Test("with nothing to redact or alias, both APIs give the same records")
    func sameWithoutRedaction() {
        let records = ScopeFixtures.thread(count: 300, seed: 5)
        for scope in Self.scopes(records)
        where !scope.anonymizeSpeakers && scope.enabledScrubbers.isEmpty {
            #expect(
                dump(Export.unredactedPreparedRecords(records, scope: scope))
                    == dump(
                        Export.preparedRedactedRecords(
                            records, scope: scope, redactions: RedactionSet())))
        }
    }

    /// The 0.4.0 pipelines, kept verbatim as the reference.
    enum Reference {
        static func unredacted(_ records: [MessageRecord], scope: Export.Scope) -> [MessageRecord] {
            var scope = scope
            let filtered = Export.identityScrubbed(
                Export.unredactedRecords(records, scope: scope), scope: &scope)
            let aliases =
                scope.anonymizeSpeakers
                ? Transcript.anonymizationMap(for: filtered, knownNames: scope.knownNames) : [:]
            var out: [MessageRecord] = []
            for record in filtered {
                var text = record.text
                if scope.trim.dropAttachmentPlaceholders, record.hadAttachment {
                    text = Transcript.stripPlaceholders(text)
                    if text.isEmpty { continue }
                }
                out.append(prepared(record, text: text, scope: scope, aliases: aliases))
            }
            return out
        }

        static func redacted(
            _ records: [MessageRecord], scope: Export.Scope, redactions: RedactionSet
        ) -> [MessageRecord] {
            var scope = scope
            let filtered = Export.identityScrubbed(
                Export.unredactedRecords(records, scope: scope), scope: &scope)
            let effective = Export.effectiveRedactions(
                manual: redactions, records: filtered, scope: scope)
            let aliases =
                scope.anonymizeSpeakers
                ? Transcript.anonymizationMap(for: filtered, knownNames: scope.knownNames) : [:]
            let names =
                scope.anonymizeSpeakers
                ? NameMatcher(aliases: aliases, knownNames: scope.knownNames) : nil
            var out: [MessageRecord] = []
            for record in filtered {
                let strip = scope.trim.dropAttachmentPlaceholders && record.hadAttachment
                if strip, Transcript.stripPlaceholders(record.text).isEmpty { continue }
                guard
                    let body = Transcript.renderedBody(
                        of: record, redactions: effective, names: names, stripPlaceholders: strip)
                else { continue }
                out.append(prepared(record, text: body, scope: scope, aliases: aliases))
            }
            return out
        }

        static func prepared(
            _ record: MessageRecord, text: String, scope: Export.Scope, aliases: [String: String]
        ) -> MessageRecord {
            var reactions = scope.trim.dropReactions ? [] : record.reactions
            var speaker = record.speaker
            if scope.anonymizeSpeakers {
                speaker = aliases[record.speaker] ?? record.speaker
                reactions = reactions.map { Reaction(by: aliases[$0.by] ?? $0.by, emoji: $0.emoji) }
            }
            if text == record.text, speaker == record.speaker, reactions == record.reactions {
                return record
            }
            return MessageRecord(
                guid: record.guid, date: record.date, speaker: speaker,
                isTarget: record.isTarget, service: record.service, text: text,
                hadAttachment: record.hadAttachment, reactions: reactions,
                flags: record.flags, isInvisibleInk: record.isInvisibleInk)
        }
    }
}
