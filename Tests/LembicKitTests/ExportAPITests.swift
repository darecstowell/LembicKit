import Foundation
import Testing

@testable import LembicKit

// The public engine APIs that downstream formatters build on:
// `Transcript.redactedText(of:redactions:)` (the redaction-aware render behind one
// auditable surface) and `Export.records(_:scope:)` (the scoped record accessor that
// `render` shares its single filtering path with).
@Suite("export APIs")
struct ExportAPITests {
    private let t0 = Fixtures.t0

    // MARK: - Transcript.redactedText

    @Test func redactedTextNilOnWholeMessageRedaction() {
        let rec = Fixtures.redRec("g0", 0, "Them", "secret thing")
        var rs = RedactionSet()
        rs.add(Redaction(guid: "g0", range: nil))  // whole-message tombstone
        #expect(
            Transcript.redactedText(of: rec, redactions: rs) == nil,
            "a whole-message redaction yields nil so the caller omits the row")
    }

    @Test func redactedTextAppliesSpanRedaction() {
        // "password is hunter2" → redact the secret span "hunter2" (12..<19).
        let rec = Fixtures.redRec("g0", 0, "Me", "password is hunter2")
        let lo = ("password is " as NSString).length  // 12
        let hi = ("password is hunter2" as NSString).length  // 19
        var rs = RedactionSet()
        rs.add(Redaction(guid: "g0", range: lo..<hi))
        let out = Transcript.redactedText(of: rec, redactions: rs)
        #expect(out == "password is [redacted]", "the span splices to the shared [redacted] token")
        #expect(!(out?.contains("hunter2") ?? true), "the secret text is gone")
    }

    @Test func redactedTextPassesThroughWhenNoRedaction() {
        let rec = Fixtures.redRec("g0", 0, "Them", "nothing to hide")
        #expect(
            Transcript.redactedText(of: rec, redactions: RedactionSet()) == "nothing to hide",
            "no redaction for the guid → text unchanged")
    }

    @Test func redactedTextPassesThroughOnNilGuid() {
        // A nil-guid record can never be anchored, so even a populated set with a
        // matching range is moot — the text comes back unchanged (never nil).
        let rec = Fixtures.redRec(nil, 0, "Them", "no guid here")
        var rs = RedactionSet()
        rs.add(Redaction(guid: "g0", range: 0..<2))
        #expect(
            Transcript.redactedText(of: rec, redactions: rs) == "no guid here",
            "a nil guid is unredactable → text unchanged, not nil")
    }

    // Overlapping / nested spans must collapse to ONE clean token without leaking
    // any source byte between them (issue #8). Both input orderings are covered
    // because the merge sorts first, so order must not matter.
    private func overlappingRedaction(_ a: Range<Int>, _ b: Range<Int>) -> RedactionSet {
        var rs = RedactionSet()
        rs.add(Redaction(guid: "g0", range: a))
        rs.add(Redaction(guid: "g0", range: b))
        return rs
    }

    @Test func redactedTextMergesOverlappingSpans() {
        // "secret ABCDEFGH tail": spans [7,12) and [10,15) overlap.
        let rec = Fixtures.redRec("g0", 0, "Them", "secret ABCDEFGH tail")
        for (a, b) in [(7..<12, 10..<15), (10..<15, 7..<12)] {
            let out = Transcript.redactedText(of: rec, redactions: overlappingRedaction(a, b))
            #expect(out == "secret [redacted] tail", "overlap collapses to one clean token")
            // The pre-fix bug spliced into an already-spliced token, leaving an
            // `[redacted]edacted]` artifact — one clean token means no artifact.
            #expect(out?.components(separatedBy: "[redacted]").count == 2, "exactly one token")
        }
    }

    @Test func redactedTextMergesNestedSpans() {
        // "secret ABCDEFGH tail": [9,12) is nested inside [7,15).
        let rec = Fixtures.redRec("g0", 0, "Them", "secret ABCDEFGH tail")
        for (a, b) in [(7..<15, 9..<12), (9..<12, 7..<15)] {
            let out = Transcript.redactedText(of: rec, redactions: overlappingRedaction(a, b))
            #expect(out == "secret [redacted] tail", "nested span collapses to one clean token")
            #expect(!(out?.contains("FGH") ?? true), "source bytes do not leak past the token")
            #expect(out?.components(separatedBy: "[redacted]").count == 2, "exactly one token")
        }
    }

    // MARK: - Export.records(_:scope:)

    private let recs = [
        Fixtures.exportRec(0, "Them", "day zero"),
        Fixtures.exportRec(1, "Me", "day one"),
        Fixtures.exportRec(2, "Them", "day two"),
    ]

    @Test func recordsFullHistoryWhenNoDateRange() {
        let all = Export.records(recs, scope: .all)
        #expect(all.map(\.guid) == ["g0", "g1", "g2"], "nil dateRange → the full set unchanged")
    }

    @Test func recordsRespectsDateRangeScope() {
        // A window covering only the middle day (exportRec spaces records 86_400s).
        let mid = t0.addingTimeInterval(86_400)
        let scoped = Export.records(recs, scope: .init(dateRange: mid...mid))
        #expect(scoped.map(\.guid) == ["g1"], "date range filters to exactly the in-range record")
    }

    @Test func recordsMatchesRenderInternalFilter() {
        // The single-filtering-path invariant: the public accessor returns the
        // SAME set `render` exposes via `Rendered.records`.
        let mid = t0.addingTimeInterval(86_400)
        let scope = Export.Scope(dateRange: mid...mid)
        let accessor = Export.records(recs, scope: scope)
        let rendered = Export.render(records: recs, number: "+1", formats: [.txt], scope: scope)
        #expect(
            accessor.map(\.guid) == rendered.records.map(\.guid),
            "records(_:scope:) and render share one filtering path")
    }

    // MARK: - Export.preparedRecords(_:scope:)
    //
    // The fully-prepared set downstream formatters consume so they
    // honor `anonymizeSpeakers` + `trim` via the engine's OWN logic — the
    // DEVIATION-1 fix. Matched against `Transcript.compactText`'s transforms.

    @Test func preparedDefaultScopeIsIdentity() {
        // No trim, no anonymize → records pass through untouched (same guids,
        // speakers, reactions) so the default export is unchanged.
        let withReacts = [
            Fixtures.attachRec("g0", 0, "Them", "hi", reacts: [Reaction(by: "Me", emoji: "❤️")]),
            Fixtures.attachRec("g1", 1, "Me", "yo"),
        ]
        let prepared = Export.preparedRecords(withReacts, scope: .all)
        #expect(prepared.map(\.guid) == ["g0", "g1"], "no records dropped under the default scope")
        #expect(prepared.map(\.speaker) == ["Them", "Me"], "speakers unchanged")
        #expect(prepared[0].reactions == [Reaction(by: "Me", emoji: "❤️")], "reactions unchanged")
    }

    @Test func preparedAnonymizesSpeakerAndReactionAuthors() {
        // Owner ("Me") anchors to P1; the other distinct speaker → P2. Both the
        // speaker label and the reaction author relabel, matching compactText.
        let recs = [
            Fixtures.attachRec("g0", 0, "Me", "first"),
            Fixtures.attachRec("g1", 1, "Them", "second", reacts: [Reaction(by: "Me", emoji: "👍")]),
        ]
        let prepared = Export.preparedRecords(recs, scope: .init(anonymizeSpeakers: true))
        #expect(prepared.map(\.speaker) == ["P1", "P2"], "owner=P1, counterparty=P2 by first appearance")
        #expect(
            prepared[1].reactions == [Reaction(by: "P1", emoji: "👍")],
            "the reaction author is relabeled through the same alias map")
    }

    @Test func preparedDropsReactions() {
        let recs = [
            Fixtures.attachRec("g0", 0, "Them", "hi", reacts: [Reaction(by: "Me", emoji: "❤️")])
        ]
        let prepared = Export.preparedRecords(recs, scope: .init(trim: .init(dropReactions: true)))
        #expect(prepared[0].reactions.isEmpty, "dropReactions clears the reaction list")
    }

    @Test func preparedStripsPlaceholdersAndDropsAttachmentOnlyMessage() {
        // Mirrors TranscriptTrimTests: a caption keeps its text (placeholder
        // stripped); an attachment-only message is dropped entirely (3 → 2).
        let recs = [
            Fixtures.attachRec("g0", 0, "Them", "hey [photo]", attach: true),
            Fixtures.attachRec("g1", 1, "Me", "[photo]", attach: true),
            Fixtures.attachRec("g2", 2, "Them", "ok"),
        ]
        let prepared = Export.preparedRecords(
            recs, scope: .init(trim: .init(dropAttachmentPlaceholders: true)))
        #expect(prepared.map(\.guid) == ["g0", "g2"], "attachment-only message dropped")
        #expect(prepared[0].text == "hey", "the caption survives with the placeholder stripped")
    }

    @Test func preparedGroupAnonymizesEverySpeakerAndReactionAuthor() {
        // A group thread (>2 distinct speakers) flows through the SAME prepared-records
        // path the downstream formatters consume. Owner ("Me") anchors to P1; each further
        // distinct group speaker numbers by first appearance (P2, P3, P4), and a
        // reaction author relabels through the same alias map — proving the export
        // seam is N-speaker, not 2-party.
        let recs = [
            Fixtures.attachRec("g0", 0, "Me", "kickoff"),
            Fixtures.attachRec(
                "g1", 1, "Alice", "hi", reacts: [Reaction(by: "Bob", emoji: "👍")]),
            Fixtures.attachRec("g2", 2, "Bob", "yo"),
            Fixtures.attachRec("g3", 3, "(844) 555-0100", "here too"),
        ]
        let prepared = Export.preparedRecords(recs, scope: .init(anonymizeSpeakers: true))
        #expect(
            prepared.map(\.speaker) == ["P1", "P2", "P3", "P4"],
            "owner=P1, then each further group speaker numbers by first appearance")
        #expect(
            prepared[1].reactions == [Reaction(by: "P3", emoji: "👍")],
            "the reaction author (Bob → P3) relabels through the same N-speaker alias map")
    }

    @Test func preparedComposesWithDateFilter() {
        // Trim/anonymize run over the date-filtered slice, so the PN map numbers
        // only the in-window speakers.
        let recs = [
            Fixtures.exportRec(0, "Them", "day zero"),
            Fixtures.exportRec(1, "Me", "day one"),
        ]
        let mid = t0.addingTimeInterval(86_400)  // only day-one
        let prepared = Export.preparedRecords(
            recs, scope: .init(dateRange: mid...mid, anonymizeSpeakers: true))
        #expect(prepared.map(\.guid) == ["g1"], "date filter applied first")
        #expect(prepared[0].speaker == "P1", "the sole in-window speaker (the owner) anchors to P1")
    }

    // MARK: - Export.effectiveRedactions — the SINGLE scrubber→redaction fold

    @Test func effectiveRedactionsFoldsScrubbersOntoManual() {
        // A record with an email (scrubber target) + a manual span. The effective
        // set carries BOTH the manual span and the scrubbed email span.
        let rec = Fixtures.redRec("g0", 0, "Them", "my email is jane@example.com ok")
        var manual = RedactionSet()
        manual.add(Redaction(guid: "g0", range: 0..<2))  // "my"
        let scope = Export.Scope(enabledScrubbers: [.email])
        let effective = Export.effectiveRedactions(
            manual: manual, records: [rec], scope: scope)
        // The manual span survives.
        #expect(effective.contains(Redaction(guid: "g0", range: 0..<2)), "manual span kept")
        // The email span was folded in (some span over the email exists).
        let ns = rec.text as NSString
        let emailLoc = ns.range(of: "jane@example.com").location
        #expect(
            effective.all.contains { $0.range?.contains(emailLoc) == true },
            "the scrubbed email is folded into the effective set")
    }

    @Test func effectiveRedactionsIsIdentityWhenNoScrubbers() {
        let rec = Fixtures.redRec("g0", 0, "Them", "my email is jane@example.com ok")
        var manual = RedactionSet()
        manual.add(Redaction(guid: "g0", range: 0..<2))
        let effective = Export.effectiveRedactions(
            manual: manual, records: [rec], scope: .all)
        #expect(effective == manual, "no enabled scrubbers → the manual set is returned unchanged")
    }

    // MARK: - 6-format parity (engine half): txt + jsonl + the prepared-redacted
    // records downstream formatters consume all derive their body from one place.
    //
    // The fixture carries, in ONE message: (a) an email (an enabled `.email`
    // scrubber target), (b) an in-body participant-name mention ("Sarah", under
    // anonymize), and (c) a manual redaction span over "topsecret". Every output
    // must show `[redacted]` for the email + the manual span, the `P2` alias for
    // the name, and NEITHER the cleartext email NOR the raw name. The concrete file
    // formats (xlsx/pdf/docx) are out of scope for the engine; here we assert the
    // txt/jsonl strings AND the prepared-redacted record bodies that FEED a formatter.

    /// The leaky values that must NEVER survive any export.
    private static let leakEmail = "jane@example.com"
    private static let leakName = "Sarah"
    private static let leakSecret = "topsecret"

    /// Two records: a "Sarah" speaker (so the name is a known participant) and a
    /// "Me" message whose body mentions Sarah, carries the email, and contains the
    /// manually-redacted "topsecret".
    private static func parityRecords() -> [MessageRecord] {
        [
            Fixtures.redRec(
                "p0", 0, "Me", "tell Sarah my email is jane@example.com pw topsecret"),
            Fixtures.redRec("p1", 1, "Sarah", "got it"),
        ]
    }

    /// A manual span over "topsecret" in p0's body.
    private static func parityRedactions() -> RedactionSet {
        let body = parityRecords()[0].text as NSString
        let r = body.range(of: leakSecret)
        var rs = RedactionSet()
        rs.add(Redaction(guid: "p0", range: r.location..<(r.location + r.length)))
        return rs
    }

    private static let parityScope = Export.Scope(
        anonymizeSpeakers: true, enabledScrubbers: [.email])

    @Test func parityTxtAndJsonl() throws {
        let out = Export.render(
            records: Self.parityRecords(), number: "+15551234567",
            formats: [.txt, .jsonl], scope: Self.parityScope,
            redactions: Self.parityRedactions())
        for (label, body) in [("txt", try #require(out.txt)), ("jsonl", try #require(out.jsonl))] {
            #expect(!body.contains(Self.leakEmail), "\(label): scrubbed email must not leak")
            #expect(!body.contains(Self.leakName), "\(label): raw participant name must not leak")
            #expect(!body.contains(Self.leakSecret), "\(label): manual secret must not leak")
            #expect(body.contains("[redacted]"), "\(label): email + manual span read [redacted]")
            #expect(body.contains("P2"), "\(label): the name reads the P2 alias")
        }
    }

    @Test func parityPreparedRedactedRecordsFeedPro() {
        // The exact record set downstream formatters consume. The body is FINAL:
        // it must already carry the [redacted] splices + the P2 alias and leak
        // nothing — the renderers run with an empty RedactionSet on top.
        let prepared = Export.preparedRedactedRecords(
            Self.parityRecords(), scope: Self.parityScope, redactions: Self.parityRedactions())
        let body = prepared.first { $0.guid == "p0" }?.text
        let p0 = try! #require(body)
        #expect(!p0.contains(Self.leakEmail), "prepared body must not carry the scrubbed email")
        #expect(!p0.contains(Self.leakName), "prepared body must not carry the raw name")
        #expect(!p0.contains(Self.leakSecret), "prepared body must not carry the manual secret")
        #expect(p0.contains("[redacted]"), "the email + manual span are baked to [redacted]")
        #expect(p0.contains("tell P2"), "the in-body name is baked to the P2 alias")
        // The speaker is anonymized too (preparedRecords half).
        #expect(prepared.first { $0.guid == "p0" }?.speaker == "P1", "owner speaker → P1")
        // Feeding these through redactedText with an EMPTY set returns them
        // unchanged (no double-application), proving the body is final.
        #expect(
            Transcript.redactedText(of: prepared[0], redactions: RedactionSet()) == p0,
            "the baked body passes through redactedText with an empty set unchanged")
    }

    @Test func parityWholeMessageRedactionDropsRowInPrepared() {
        // A whole-message redaction must drop the row from the prepared set (the
        // formatters never see it), mirroring jsonl object omission.
        var rs = Self.parityRedactions()
        rs.add(Redaction(guid: "p1", range: nil))  // drop Sarah's "got it"
        let prepared = Export.preparedRedactedRecords(
            Self.parityRecords(), scope: Self.parityScope, redactions: rs)
        #expect(prepared.map(\.guid) == ["p0"], "the whole-message-redacted row is dropped")
    }
}
