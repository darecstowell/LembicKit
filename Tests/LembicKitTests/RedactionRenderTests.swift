import Foundation
import Testing

@testable import LembicKit

@Suite("redaction-aware render")
struct RedactionRenderTests {
    private func redRec(
        _ guid: String?, _ s: Int, _ speaker: String, _ text: String,
        reacts: [Reaction] = []
    ) -> MessageRecord {
        Fixtures.redRec(guid, s, speaker, text, reacts: reacts)
    }

    private func attachRec(
        _ guid: String?, _ s: Int, _ speaker: String, _ text: String,
        attach: Bool = false, reacts: [Reaction] = []
    ) -> MessageRecord {
        Fixtures.attachRec(guid, s, speaker, text, attach: attach, reacts: reacts)
    }

    private var recs: [MessageRecord] {
        [
            redRec("g0", 0, "Them", "hey there", reacts: [Reaction(by: "Me", emoji: "❤️")]),
            redRec("g1", 1, "Me", "all good\nsecond line"),
            redRec("g2", 2, "Them", "ok"),
        ]
    }

    // MARK: - Golden-file oracle
    //
    // The plain `compactText(records:number:trim:)` overload was deleted in the
    // renderer collapse. The old self-referential parity checks
    // (`empty.text == plainCompactText(...)`) only proved the two Swift renderers
    // agreed with EACH OTHER, never with a committed expected output — if both
    // drifted the same way the test stayed green and the bug shipped. They are
    // replaced here by golden-file assertions: an external byte anchor on disk.
    //
    // The renderer formats dates with `timeZone = .current`, so golden bytes are
    // machine-TZ-dependent. The goldens are generated AND asserted under a FIXED
    // injected `TimeZone` (`Fixtures.goldenTimeZone`) so `swift test` is green on
    // any contributor's clone WITHOUT changing user-facing local-time output
    // (production keeps the `.current` default).
    //
    // REGENERATE (when output legitimately changes): from the repo root run
    //   LEMBIC_REGOLD=1 swift test --filter golden
    // which rewrites the committed `Fixtures/golden_*.txt`/`.jsonl` from the
    // current renderer. Review the `git diff` of `Fixtures/*` to confirm the
    // change is intended, then commit.

    /// Load a committed golden from the test bundle (`Bundle.module`). The
    /// `subdirectory: "Fixtures"` argument is REQUIRED — `url(forResource:)` does
    /// NOT search recursively (see `ContactsVCardTests.bundleModuleResourceLoads`).
    private func loadGolden(_ name: String, _ ext: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "golden \(name).\(ext) missing from Fixtures (Bundle.module)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// On `LEMBIC_REGOLD=1`, write `rendered` back to the SOURCE `Fixtures/` dir
    /// (located via `#filePath`, NOT the `.build` bundle copy) and return true so
    /// the caller skips its `#expect`. Returns false on a normal run.
    private func regoldIfRequested(
        _ rendered: String, _ name: String, _ ext: String, file: String = #filePath
    ) throws -> Bool {
        guard ProcessInfo.processInfo.environment["LEMBIC_REGOLD"] != nil else { return false }
        let dest = URL(fileURLWithPath: file)  // …/Tests/LembicKitTests/RedactionRenderTests.swift
            .deletingLastPathComponent()  // …/Tests/LembicKitTests/
            .appendingPathComponent("Fixtures/\(name).\(ext)")
        try rendered.write(to: dest, atomically: true, encoding: .utf8)
        return true
    }

    @Test("basic render matches the committed golden")
    func goldenBasic() throws {
        let rendered = Transcript.compactText(
            records: Fixtures.goldenRecords, number: "+15551234567",
            redactions: RedactionSet(), detected: [],
            timeZone: Fixtures.goldenTimeZone
        ).text
        if try regoldIfRequested(rendered, "golden_basic", "txt") { return }
        #expect(rendered == (try loadGolden("golden_basic", "txt")))
    }

    @Test("redacted render matches the committed golden + leaks no secret")
    func goldenRedacted() throws {
        let rendered = Transcript.compactText(
            records: Fixtures.goldenRecords, number: "+15551234567",
            redactions: Fixtures.goldenRedactionSet(), detected: [],
            timeZone: Fixtures.goldenTimeZone
        ).text
        if try regoldIfRequested(rendered, "golden_redacted", "txt") { return }
        #expect(rendered == (try loadGolden("golden_redacted", "txt")))
        #expect(rendered.contains("[redacted]"), "the SSN span reads [redacted]")
        #expect(!rendered.contains("123-45-6789"), "the redacted SSN never appears in the .txt")
    }

    @Test("redacted jsonl honors redactions (DECISION #3 — closes the leak)")
    func goldenRedactedJsonl() throws {
        let rendered = Transcript.jsonLines(
            records: Fixtures.goldenRecords, redactions: Fixtures.goldenRedactionSet(),
            timeZone: Fixtures.goldenTimeZone)
        if try regoldIfRequested(rendered, "golden_redacted", "jsonl") { return }
        #expect(rendered == (try loadGolden("golden_redacted", "jsonl")))
        #expect(!rendered.contains("123-45-6789"), "the redacted SSN never leaks into the .jsonl")
        #expect(
            rendered.contains("[redacted]"),
            "the redacted span reads [redacted] in the jsonl 'm' field")
    }

    @Test("anonymized render matches the committed golden + scrubs identity")
    func goldenAnonymized() throws {
        let rendered = Transcript.compactText(
            records: Fixtures.goldenRecords, number: "+15551234567",
            redactions: RedactionSet(), detected: [], anonymize: true,
            timeZone: Fixtures.goldenTimeZone
        ).text
        if try regoldIfRequested(rendered, "golden_anonymized", "txt") { return }
        #expect(rendered == (try loadGolden("golden_anonymized", "txt")))
        // The counterparty's number is scrubbed from header AND legend.
        #expect(!rendered.contains("+15551234567"), "anonymized .txt never carries the number")
        // Real speaker labels are gone; short PN labels take their place.
        #expect(!rendered.contains("Them"), "the 'Them' label is fully replaced")
        #expect(!rendered.contains("Me = the account owner"), "the owner legend is dropped")
        #expect(
            rendered.contains("# Speakers: Person 1 (P1), Person 2 (P2)"),
            "the header defines the PN shorthand once")
        #expect(
            rendered.contains("16:13 P2: hey there"),
            "the counterparty renders as P2 (Me anchors to P1)")
        #expect(
            rendered.contains("[P1: ❤️]"),
            "the reaction author is anonymized with the same map")
        // The redacted-secret machinery is orthogonal to anonymization: the SSN
        // text is still present (unredacted here), proving labels-only rewriting.
        #expect(rendered.contains("123-45-6789"), "anonymization doesn't touch message bodies")
    }

    // MARK: - In-body name anonymize

    @Test("in-body name aliasing matches the committed golden (alias, not [redacted])")
    func goldenNameAlias() throws {
        let rendered = Transcript.compactText(
            records: Fixtures.goldenNameAliasRecords, number: "+15551234567",
            redactions: RedactionSet(), detected: [], anonymize: true,
            timeZone: Fixtures.goldenTimeZone
        ).text
        if try regoldIfRequested(rendered, "golden_name_alias", "txt") { return }
        #expect(rendered == (try loadGolden("golden_name_alias", "txt")))
        // The in-body mention is the ALIAS, never [redacted], never the raw name.
        #expect(rendered.contains("tell P2 I said hi"), "Sarah → P2 in the body")
        #expect(!rendered.contains("Sarah") && !rendered.contains("SARAH"),
            "no spelling of the participant name survives anywhere")
        #expect(!rendered.contains("[redacted]"), "an alias is NOT a redaction")
        // Multiple mentions on one line both alias; case-insensitive.
        #expect(rendered.contains("P3 and P2 are both coming"), "Bob→P3, SARAH→P2 on one line")
        // A non-participant name and the owner word "Me" are left untouched.
        #expect(rendered.contains("Carla"), "a non-participant name is not aliased (no NER)")
    }

    @Test("anonymize: false leaves the body byte-identical (no aliasing)")
    func nameAliasOffIsUnchanged() {
        let plain = Transcript.compactText(
            records: Fixtures.goldenNameAliasRecords, number: "+15551234567",
            redactions: RedactionSet(), detected: [], anonymize: false,
            timeZone: Fixtures.goldenTimeZone
        ).text
        // Names are present verbatim; no PN aliases appear in a non-anonymized render.
        #expect(plain.contains("tell Sarah I said hi"), "the raw name survives when not anonymizing")
        #expect(plain.contains("Bob and SARAH are both coming"), "bodies are untouched")
        #expect(!plain.contains(": P2") && !plain.contains(" P2 "), "no PN alias leaks in")
    }

    @Test("name aliasing preserves redaction + highlight offsets")
    func nameAliasOffsetIntegrity() {
        // A body where a participant name precedes a detected SSN: aliasing the
        // name shifts later offsets, so the redaction span and the highlight must
        // both still land on the right output substring.
        let recs = [
            Fixtures.redRec("x0", 0, "Me", "ask Sarah for the ssn 123-45-6789 please"),
            Fixtures.redRec("x1", 1, "Sarah", "ok"),
        ]
        let detected = SecretDetector.detect(in: recs)
        #expect(detected.contains { $0.category == .ssn }, "the SSN is detected")

        // (a) Highlight path: anonymize on, no redaction — the highlight must cover
        // the SSN exactly in the aliased output ("ask P2 for the ssn 123-45-6789").
        let hi = Transcript.compactText(
            records: recs, number: "+1", redactions: RedactionSet(), detected: detected,
            anonymize: true, timeZone: Fixtures.goldenTimeZone)
        #expect(hi.text.contains("ask P2 for the ssn 123-45-6789"), "name aliased, SSN intact")
        let hiNS = hi.text as NSString
        let ssnMark = hi.highlightMarks.first { $0.category == .ssn }
        let marked = ssnMark.map { hiNS.substring(with: $0.outputRange) }
        #expect(marked == "123-45-6789", "the highlight lands on the SSN after the alias shift")

        // (b) Redaction path: anonymize on, redact the SSN — the [redacted] token
        // and the undo mark must align on the post-alias body.
        var rs = RedactionSet()
        if let d = detected.first(where: { $0.category == .ssn }) {
            rs.add(Redaction(guid: d.guid, range: d.range))
        }
        let red = Transcript.compactText(
            records: recs, number: "+1", redactions: rs, detected: detected,
            anonymize: true, timeZone: Fixtures.goldenTimeZone)
        #expect(red.text.contains("ask P2 for the ssn [redacted]"), "alias + redaction compose")
        #expect(!red.text.contains("123-45-6789"), "the SSN never leaks")
        let redNS = red.text as NSString
        let mark = red.redactedMarks.first
        #expect(mark.map { redNS.substring(with: $0.outputRange) } == "[redacted]",
            "the redaction mark lands on the [redacted] token after the alias shift")
    }

    @Test("jsonl in-body name aliasing matches the .txt body (BLOCKER 2 fix)")
    func jsonlInBodyNameAlias() {
        // In an earlier pass, `jsonLines` aliased only the SPEAKER and ran the body
        // through redactions only — so under anonymize the `.txt` showed "tell P2
        // hi" while the `.jsonl` leaked the raw "Sarah". The body now routes
        // through the shared `renderedBody`, so the in-body alias matches the `.txt`.
        let jsonl = Transcript.jsonLines(
            records: Fixtures.goldenNameAliasRecords, anonymize: true,
            timeZone: Fixtures.goldenTimeZone)
        // The in-body mention is the ALIAS, never the raw name, in the "m" field.
        #expect(jsonl.contains("tell P2 I said hi"), "Sarah → P2 in the jsonl body")
        #expect(jsonl.contains("P3 and P2 are both coming"), "Bob→P3, SARAH→P2 in the body")
        #expect(
            !jsonl.contains("Sarah") && !jsonl.contains("SARAH"),
            "no spelling of the participant name survives in the jsonl")
        #expect(!jsonl.contains("[redacted]"), "an alias is NOT a redaction")
        // A non-participant name is left untouched (no NER), matching the .txt.
        #expect(jsonl.contains("Carla"), "a non-participant name is not aliased")
        // The speaker labels are still PN (the pre-existing speaker aliasing).
        #expect(jsonl.contains("\"s\": \"P1\""), "owner speaker → P1")
    }

    @Test("group render matches the committed golden roster header")
    func goldenGroup() throws {
        let rendered = Transcript.compactText(
            records: Fixtures.goldenGroupRecords, number: "group-A",
            redactions: RedactionSet(), detected: [],
            group: Fixtures.goldenGroupInfo,
            timeZone: Fixtures.goldenTimeZone
        ).text
        if try regoldIfRequested(rendered, "golden_group", "txt") { return }
        #expect(rendered == (try loadGolden("golden_group", "txt")))
        // The roster header lists the group name + EVERY member (incl. the silent
        // one), and never falls back to the 1:1 "Them = <number>" legend.
        #expect(
            rendered.contains("# iMessage group transcript: \"Trip crew\""),
            "the group header carries the group name")
        #expect(
            rendered.contains("# Participants: Me = the account owner · Alice · Bob"),
            "the roster prepends Me and lists each member's label")
        #expect(
            rendered.contains("(844) 399-6927"),
            "a member who never spoke is still in the roster")
        #expect(!rendered.contains("Them = "), "the 1:1 Them legend is gone for a group")
        // The body is unchanged (speaker-generic): real names, non-me reaction.
        #expect(rendered.contains("16:13 Me: hey all  [Bob: ❤️]"), "non-me reaction renders")
        #expect(rendered.contains("16:14 Alice: hi from Alice"), "named speaker renders")
    }

    @Test("group system-events render interleaved, toggle ON")
    func goldenGroupEvents() throws {
        let rendered = Transcript.compactText(
            records: Fixtures.goldenGroupRecords, number: "group-A",
            redactions: RedactionSet(), detected: [],
            group: Fixtures.goldenGroupInfo,
            systemEvents: Fixtures.goldenGroupEvents,
            timeZone: Fixtures.goldenTimeZone
        ).text
        if try regoldIfRequested(rendered, "golden_group_events", "txt") { return }
        #expect(rendered == (try loadGolden("golden_group_events", "txt")))
        // The three event kinds render, each on a `HH:mm — <line>` line.
        #expect(rendered.contains("— Bob named the group \"Trip crew\""), "rename event renders")
        #expect(rendered.contains("— Alice added Carla"), "add event renders (off-roster target)")
        #expect(rendered.contains("— Alice left"), "leave event renders")
        // Interleaving: the rename precedes the first message, the leave follows the
        // last message (both verified by line order in the golden, asserted here too).
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false)
        let renameIdx = try #require(lines.firstIndex { $0.contains("named the group") })
        let firstMsgIdx = try #require(lines.firstIndex { $0.contains("Me: hey all") })
        let leftIdx = try #require(lines.firstIndex { $0.contains("Alice left") })
        #expect(renameIdx < firstMsgIdx, "the rename interleaves before the first message")
        #expect(leftIdx > firstMsgIdx, "the leave interleaves after the messages")
    }

    @Test("system events suppressed when toggle off — byte-identical to golden_group")
    func systemEventsOffIsByteIdentical() throws {
        // The additive proof: rendering the group with the events stream OMITTED is
        // byte-identical to passing an empty stream, which is the committed
        // `golden_group.txt`. Toggle off ⇒ no output change anywhere.
        let off = Transcript.compactText(
            records: Fixtures.goldenGroupRecords, number: "group-A",
            redactions: RedactionSet(), detected: [],
            group: Fixtures.goldenGroupInfo,
            timeZone: Fixtures.goldenTimeZone
        ).text
        #expect(off == (try loadGolden("golden_group", "txt")), "no events == the existing golden")
    }

    @Test("anonymize suppresses system events (identities scrubbed)")
    func systemEventsSuppressedWhenAnonymized() {
        let anon = Transcript.compactText(
            records: Fixtures.goldenGroupRecords, number: "group-A",
            redactions: RedactionSet(), detected: [], anonymize: true,
            group: Fixtures.goldenGroupInfo,
            systemEvents: Fixtures.goldenGroupEvents,
            timeZone: Fixtures.goldenTimeZone
        ).text
        #expect(!anon.contains("named the group"), "rename event scrubbed when anonymizing")
        #expect(!anon.contains("Carla"), "an event participant name never leaks under anonymize")
        #expect(!anon.contains("Alice left"), "leave event scrubbed when anonymizing")
    }

    @Test("nil group param → the 1:1 header path, byte-identical")
    func groupNilEqualsOneToOne() {
        // The additive-change guard: rendering the 1:1 golden records with an
        // explicit `group: nil` is byte-identical to omitting the param (the old
        // path). Proves the group header is purely additive.
        let withNil = Transcript.compactText(
            records: Fixtures.goldenRecords, number: "+15551234567",
            redactions: RedactionSet(), detected: [], group: nil,
            timeZone: Fixtures.goldenTimeZone
        ).text
        let omitted = Transcript.compactText(
            records: Fixtures.goldenRecords, number: "+15551234567",
            redactions: RedactionSet(), detected: [],
            timeZone: Fixtures.goldenTimeZone
        ).text
        #expect(withNil == omitted, "group: nil == the default 1:1 path, byte-identical")
    }

    @Test("anonymize suppresses the group roster header (identities scrubbed)")
    func groupAnonymizedFallsBack() {
        // A group rendered with `anonymize: true` must NOT leak the group name or
        // member labels — it falls back to the de-biased Person N header.
        let anon = Transcript.compactText(
            records: Fixtures.goldenGroupRecords, number: "group-A",
            redactions: RedactionSet(), detected: [], anonymize: true,
            group: Fixtures.goldenGroupInfo,
            timeZone: Fixtures.goldenTimeZone
        ).text
        #expect(!anon.contains("Trip crew"), "the group name is scrubbed when anonymizing")
        #expect(
            !anon.contains("# iMessage group transcript") && !anon.contains("# Participants:"),
            "neither the group title nor the roster header is emitted when anonymizing")
        // Speaker LABELS are anonymized (the body text "hi from Alice" is untouched,
        // as anonymization relabels speakers, not message contents).
        #expect(
            !anon.contains("Alice: ") && !anon.contains("Bob: "),
            "member speaker labels are replaced by Person N in the body")
        #expect(
            anon.contains("# Speakers: Person 1 (P1)"),
            "anonymized group uses the Person N header")
    }

    @Test("anonymization map: owner anchors to Person 1, others by first appearance")
    func anonymizationMapSemantics() {
        // A group-shaped set: Them texts first, then Me, then a third party "Alex".
        // A reaction author ("Alex") who never sent a message still gets a slot.
        let group = [
            redRec("a", 0, "Them", "hi", reacts: [Reaction(by: "Alex", emoji: "👍")]),
            redRec("b", 1, "Me", "hey"),
            redRec("c", 2, "Alex", "yo"),
        ]
        let map = Transcript.anonymizationMap(for: group)
        // Owner floats to P1 even though "Them" appeared first.
        #expect(map["Me"] == "P1", "the account owner is always P1")
        #expect(map["Them"] == "P2", "first non-owner by appearance → P2")
        #expect(map["Alex"] == "P3", "third distinct speaker → P3")

        // The .jsonl path uses the same map (speaker + reaction author relabeled).
        let jsonl = Transcript.jsonLines(records: group, anonymize: true)
        #expect(jsonl.contains("\"s\": \"P2\""), "Them → P2 in jsonl")
        #expect(jsonl.contains("\"by\": \"P3\""), "reaction by Alex → P3 in jsonl")
        #expect(!jsonl.contains("\"Them\"") && !jsonl.contains("\"Alex\""), "no real labels leak")
    }

    @Test("unredacted jsonl default-arg path equals the no-arg path (additive-change guard)")
    func jsonlDefaultArgUnchanged() {
        // Same-overload comparison: proves the new `redactions:` default doesn't
        // move the no-redaction output (NOT a cross-renderer claim).
        #expect(
            Transcript.jsonLines(records: Fixtures.goldenRecords)
                == Transcript.jsonLines(
                    records: Fixtures.goldenRecords, redactions: RedactionSet()),
            "default redactions arg == empty set == today's raw jsonl")
    }

    @Test func spanRedaction() {
        // Span redaction replaces exactly that range with [redacted].
        // "hey there": redact "there" = UTF-16 [4,9).
        var rs = RedactionSet()
        rs.add(Redaction(guid: "g0", range: 4..<9))
        let spanRes = Transcript.compactText(
            records: recs, number: "+1", redactions: rs, detected: [])
        #expect(
            spanRes.text.contains("hey [redacted]"), "span redaction yields 'hey [redacted]'")
        #expect(
            spanRes.text.contains("all good") && spanRes.text.contains("ok"),
            "other messages render real text")
        #expect(spanRes.redactedMarks.count == 1, "one redacted mark for the one span")
        if let mark = spanRes.redactedMarks.first {
            let sliced = (spanRes.text as NSString).substring(with: mark.outputRange)
            #expect(
                sliced == "[redacted]",
                "RedactedMark.outputRange points at the literal [redacted]")
            #expect(
                mark.redaction == Redaction(guid: "g0", range: 4..<9),
                "mark carries the producing redaction")
        }
    }

    @Test func wholeMessageRedaction() {
        // Whole-message redaction → [redacted message]; ≥2 contiguous → [N messages removed].
        var rsWhole = RedactionSet()
        rsWhole.add(Redaction(guid: "g0", range: nil))
        let oneWhole = Transcript.compactText(
            records: recs, number: "+1", redactions: rsWhole, detected: [])
        #expect(
            oneWhole.text.contains("[redacted message]")
                && !oneWhole.text.contains("[2 messages"),
            "lone whole-message redaction → [redacted message]")
        #expect(
            oneWhole.redactedMarks.count == 1
                && oneWhole.redactedMarks[0].redaction.range == nil,
            "tombstone mark carries a whole-message redaction handle")

        var rsRun = RedactionSet()
        rsRun.add(Redaction(guid: "g0", range: nil))
        rsRun.add(Redaction(guid: "g1", range: nil))
        let run = Transcript.compactText(
            records: recs, number: "+1", redactions: rsRun, detected: [])
        #expect(
            run.text.contains("[2 messages removed]"),
            "contiguous run of 2 → [2 messages removed]")
        #expect(
            !run.text.contains("hey there") && !run.text.contains("all good"),
            "collapsed run consumes its lines")
        #expect(
            run.redactedMarks.count == 1
                && run.redactedMarks[0].redaction == Redaction(guid: "g0", range: nil),
            "collapsed-run mark points at the first message's whole redaction")
        #expect(run.text.contains("ok"), "message after the run renders normally")
    }

    @Test func redactionsForSelectedOutput() {
        let empty = Transcript.compactText(
            records: recs, number: "+1", redactions: RedactionSet(), detected: [])

        // redactions(forSelectedOutput:) round-trip: select the word "good".
        // Find "good" in the g1 body and select it; expect a localRange slicing "good".
        let ns = empty.text as NSString
        let goodRange = ns.range(of: "good")
        #expect(goodRange.location != NSNotFound, "found 'good' in output")
        let sel = empty.redactions(forSelectedOutput: goodRange)
        #expect(
            sel.count == 1 && sel.first?.guid == "g1",
            "selection over 'good' yields one g1 redaction")
        if let r = sel.first, let lr = r.range {
            let srcWord = ("all good\nsecond line" as NSString).substring(with: NSRange(lr))
            #expect(
                srcWord == "good", "round-trip localRange slices 'good' from the source text")
        }

        // Full-body selection → whole-message redaction (range nil).
        if let g2span = empty.spans.first(where: { $0.guid == "g2" }) {
            let whole = empty.redactions(forSelectedOutput: g2span.outputBody)
            #expect(
                whole.count == 1 && whole[0].range == nil,
                "full-body selection → whole-message redaction")
        }
        // Header/whitespace selection → [].
        #expect(
            empty.redactions(forSelectedOutput: NSRange(location: 0, length: 5)).isEmpty,
            "selection over preamble header → no redactions")
    }

    @Test func highlightWithPrecedingSpan() {
        // Highlight mark for an unredacted detected secret, with a preceding span
        // shifting offsets in the SAME message.
        // Message: "secret abc card 4111 1111 1111 1111" — redact "abc", highlight the card.
        let mixed = [redRec("m1", 0, "Them", "secret abc card 4111 1111 1111 1111")]
        // Only the card is detected here (no password trigger keyword present).
        let detected = SecretDetector.detect(in: mixed)
        #expect(
            detected.count == 1 && detected[0].category == .creditCard,
            "detector finds the card in mixed msg")
        var rsMix = RedactionSet()
        // redact "abc" = UTF-16 [7,10)
        rsMix.add(Redaction(guid: "m1", range: 7..<10))
        let mixRes = Transcript.compactText(
            records: mixed, number: "+1", redactions: rsMix, detected: detected)
        #expect(
            mixRes.highlightMarks.count == 1
                && mixRes.highlightMarks[0].category == .creditCard,
            "card still visible → one highlight mark")
        if let h = mixRes.highlightMarks.first {
            let sliced = (mixRes.text as NSString).substring(with: h.outputRange)
            #expect(
                sliced == "4111 1111 1111 1111",
                "highlight points at the card even though a preceding [redacted] shifted offsets"
            )
        }
        #expect(
            mixRes.text.contains("secret [redacted] card 4111"),
            "preceding span redacted, card untouched")
    }

    @Test func highlightOnSecondLine() {
        // Highlight on the 2nd line of a multi-line message (indentation applied).
        let multi = [redRec("ml", 0, "Them", "line one\nssn 123-45-6789 here")]
        let multiDet = SecretDetector.detect(in: multi)
        let multiRes = Transcript.compactText(
            records: multi, number: "+1", redactions: RedactionSet(), detected: multiDet)
        #expect(
            multiRes.highlightMarks.count == 1 && multiRes.highlightMarks[0].category == .ssn,
            "ssn on line 2 detected + highlighted")
        if let h = multiRes.highlightMarks.first {
            let sliced = (multiRes.text as NSString).substring(with: h.outputRange)
            #expect(
                sliced == "123-45-6789",
                "highlight on 2nd line correct after indentation offset (+8)")
        }
    }

    @Test func redactedSecretProducesNoHighlight() {
        // A detected secret that IS redacted produces no highlight.
        let hidden = [redRec("h1", 0, "Them", "password is topsecret")]
        let hiddenDet = SecretDetector.detect(in: hidden)  // value "topsecret"
        var rsHide = RedactionSet()
        if let d = hiddenDet.first { rsHide.add(Redaction(guid: "h1", range: d.range)) }
        let hideRes = Transcript.compactText(
            records: hidden, number: "+1", redactions: rsHide, detected: hiddenDet)
        #expect(
            hideRes.highlightMarks.isEmpty,
            "a redacted secret produces no highlight (already [redacted])")
        #expect(
            hideRes.text.contains("password is [redacted]"),
            "the secret value is redacted inline")
    }

    @Test func nilGuidRecord() {
        // nil-guid record: rendered normally, no spans/marks for it.
        let withNil = [
            redRec(nil, 0, "Them", "no guid here"), redRec("k1", 1, "Me", "anchored"),
        ]
        let nilRes = Transcript.compactText(
            records: withNil, number: "+1", redactions: RedactionSet(), detected: [])
        #expect(nilRes.text.contains("no guid here"), "nil-guid record still rendered")
        #expect(
            nilRes.spans.count == 1 && nilRes.spans[0].guid == "k1",
            "no RenderSpan emitted for nil-guid record")
    }

    @Test func trimThroughRedactionPath() {
        // Trim smoke through the (sole, redaction-aware) renderer. The old
        // self-referential `== plainOverload(...)` parity checks were deleted in
        // the renderer collapse (the plain overload is gone); the golden tests anchor the un-trimmed
        // byte contract and `TranscriptTrimTests` exhaustively covers trim
        // behavior, so these are `.contains` smoke checks that the trims still
        // take effect through this path.
        let trimRes = Transcript.compactText(
            records: recs, number: "+1", trim: .init(dropReactions: true),
            redactions: RedactionSet(), detected: [])
        #expect(
            !trimRes.text.contains("❤️") && !trimRes.text.contains("# Reactions shown as"),
            "dropReactions strips reaction suffixes + legend through the redaction path")

        // AC#6 under the RISKIEST trim: dropAttachmentPlaceholders mutates message
        // bodies (strips [photo] etc.) AND drops attachment-only messages.
        let attachRecs = [
            attachRec(
                "a0", 0, "Them", "hey [photo]", attach: true,
                reacts: [Reaction(by: "Me", emoji: "❤️")]),
            // attachment-only: dropped once stripped
            attachRec("a1", 1, "Me", "[photo]", attach: true),
            attachRec("a2", 2, "Them", "ok"),
        ]
        let attachTrim = Transcript.compactText(
            records: attachRecs, number: "+1", trim: .init(dropAttachmentPlaceholders: true),
            redactions: RedactionSet(), detected: [])
        #expect(
            !attachTrim.text.contains("[photo]")
                && !attachTrim.text.contains("# Attachments shown as")
                && attachTrim.text.contains("2 messages"),
            "dropAttachmentPlaceholders strips markers + legend, drops the attachment-only msg")

        let bothTrim = Transcript.compactText(
            records: attachRecs, number: "+1",
            trim: .init(dropAttachmentPlaceholders: true, dropReactions: true),
            redactions: RedactionSet(), detected: [])
        #expect(
            !bothTrim.text.contains("[photo]") && !bothTrim.text.contains("❤️")
                && !bothTrim.text.contains("# Attachments shown as")
                && !bothTrim.text.contains("# Reactions shown as"),
            "both trims strip markers AND reactions (+ both legend lines) through the redaction path"
        )
    }
}
