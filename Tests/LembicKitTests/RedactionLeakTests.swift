import Foundation
import Testing

@testable import LembicKit

// Leak paths from the redaction audit: a value the user redacted, or told Lembic
// to remove, must not reach any output.
@Suite("redaction leak paths")
struct RedactionLeakTests {
    private let card = "4111 1111 1111 1111"

    private func rec(
        _ guid: String, _ s: Int, _ speaker: String, _ text: String, attach: Bool = false
    ) -> MessageRecord {
        Fixtures.attachRec(guid, s, speaker, text, attach: attach)
    }

    private func redactAll(_ detected: [DetectedSecret]) -> RedactionSet {
        var set = RedactionSet()
        for d in detected { set.add(Redaction(guid: d.guid, range: d.range)) }
        return set
    }

    private var trimScope: Export.Scope {
        var scope = Export.Scope()
        scope.trim = .init(dropAttachmentPlaceholders: true)
        return scope
    }

    // MARK: - F1: attachment trim and redaction offsets

    @Test("trim on: Redact All hides the card in TXT and in the prepared records")
    func trimKeepsRedactionOffsets() {
        let rs = [
            rec("a1", 0, "Them", "[photo] my card is \(card)", attach: true),
            rec("a2", 1, "Them", "[photo] card \(card) thanks for dinner tonight", attach: true),
        ]
        let first = Export.render(records: rs, number: "+15555550100", formats: [.txt])
        #expect(first.detected.count == 2)
        let set = redactAll(first.detected)
        for scope in [trimScope, Export.Scope()] {
            let out = Export.render(
                records: rs, number: "+15555550100", formats: [.txt, .jsonl], scope: scope,
                redactions: set)
            let txt = out.txt ?? ""
            #expect(!txt.contains("1111"), "TXT hides the card (trim \(scope.trim.isActive))")
            #expect(!(out.jsonl ?? "").contains("1111"))
            #expect(txt.contains("my card is [redacted]"))
            #expect(txt.contains("card [redacted] thanks for dinner tonight"))
            #expect(out.result?.highlightMarks.isEmpty == true)
            let pro = Export.preparedRedactedRecords(rs, scope: scope, redactions: set)
            #expect(!pro.map(\.text).joined().contains("1111"))
        }
        let trimmedPro = Export.preparedRedactedRecords(rs, scope: trimScope, redactions: set)
        #expect(
            trimmedPro.map(\.text)
                == ["my card is [redacted]", "card [redacted] thanks for dinner tonight"])
    }

    @Test("trim on: a still-visible secret is counted and highlighted on the right text")
    func trimHighlightsTheSecret() throws {
        let rs = [rec("h1", 0, "Them", "[photo] [video] my card is \(card) ok", attach: true)]
        let out = Export.render(records: rs, number: "+1", formats: [.txt], scope: trimScope)
        let result = try #require(out.result)
        #expect(result.highlightMarks.count == 1)
        let mark = try #require(result.highlightMarks.first)
        #expect((result.text as NSString).substring(with: mark.outputRange) == card)
    }

    @Test("trim on: a selection anchors to source offsets, so every output hides it")
    func trimSelectionAnchorsToSource() throws {
        let rs = [rec("t1", 0, "Them", "[photo] call me at 816-555-0123 tonight", attach: true)]
        let shown = Export.render(records: rs, number: "x", formats: [.txt], scope: trimScope)
        let result = try #require(shown.result)
        let selection = (result.text as NSString).range(of: "816-555-0123")
        let reds = result.redactions(forSelectedOutput: selection)
        #expect(reds.map(\.range) == [19..<31])
        var set = RedactionSet()
        for r in reds { set.add(r) }
        let trimmed = Export.render(
            records: rs, number: "x", formats: [.txt, .jsonl], scope: trimScope, redactions: set)
        let untrimmed = Export.render(records: rs, number: "x", formats: [.txt], redactions: set)
        for text in [trimmed.txt, trimmed.jsonl, untrimmed.txt] {
            #expect(!(text ?? "").contains("555"))
        }
        #expect((trimmed.txt ?? "").contains("Them: call me at [redacted] tonight"))
        #expect((untrimmed.txt ?? "").contains("Them: [photo] call me at [redacted] tonight"))
    }

    @Test("the source-offset strip gives the same text as the old string strip")
    func stripMatchesTheOldStrip() {
        func oldStrip(_ s: String) -> String {
            var out = s
            for token in Transcript.placeholderTokens {
                out = out.replacingOccurrences(of: token, with: " ")
            }
            return Extractor.collapseSpaceRuns(out)
                .trimmingCharacters(in: Extractor.pythonWhitespace)
        }
        let samples = [
            "hey [photo]", "[photo]", "[photo] [video]", "  [photo]  hi  there  ", "a[photo]b",
            "[photo]\nnext line", "line one\n[photo] two", "x\t[gif]\ty", "[shared location]",
            "caption [pdf] and [audio] mid", "no tokens here", "two  spaces", "", " ",
            "\u{2028}[photo]\u{2028}", "emoji 🎉[photo]🎉 ok", "[photo][photo]x[photo]",
            "tail space [contact] ", "\n\n[attachment]\n\n",
        ]
        for s in samples {
            #expect(
                Transcript.stripPlaceholders(s) == oldStrip(s), "strip of \(s.debugDescription)")
        }
    }

    // MARK: - F4: scrubbers reach the header, roster, labels, and events

    @Test("phone scrubber on: the 1:1 header does not show the number")
    func scrubberCoversOneToOneHeader() {
        var scope = Export.Scope()
        scope.enabledScrubbers = [.phone, .email]
        let out = Export.render(
            records: [rec("p1", 0, "Them", "call me at 816-555-0123")], number: "+18165550188",
            formats: [.txt, .jsonl], scope: scope)
        let txt = out.txt ?? ""
        #expect(!txt.contains("8165550188") && !txt.contains("555-0123"))
        #expect(txt.contains("# iMessage transcript with [redacted]"))
        #expect(txt.contains("Them = [redacted]"))
        let email = Export.render(
            records: [rec("p2", 0, "Them", "hi")], number: "jane@example.com", formats: [.txt],
            scope: scope)
        #expect(!(email.txt ?? "").contains("jane@"))
        let named = Export.render(
            records: [rec("p3", 0, "Them", "hi")], number: "Sarah Chen", formats: [.txt],
            scope: scope)
        #expect((named.txt ?? "").contains("Them = Sarah Chen"), "a name is not an identifier")
    }

    @Test("phone scrubber on: group roster, labels, reactions, and events use neutral labels")
    func scrubberCoversGroupIdentity() {
        var scope = Export.Scope()
        scope.enabledScrubbers = [.phone, .email]
        scope.showSystemEvents = true
        let number = "(913) 555-0142"
        let group = Transcript.GroupRenderInfo(
            name: "Alice, \(number)", participantLabels: ["Alice", number, "bob@example.com"])
        let records = [
            MessageRecord(
                guid: "g1", date: Fixtures.t0, speaker: number, isTarget: false,
                service: "iMessage", text: "hi all, my email is z@example.com",
                hadAttachment: false, reactions: [Reaction(by: "bob@example.com", emoji: "❤️")]),
            MessageRecord(
                guid: "g2", date: Fixtures.t0.addingTimeInterval(60), speaker: "Alice",
                isTarget: false, service: "iMessage", text: "welcome!", hadAttachment: false,
                reactions: [Reaction(by: number, emoji: "👍")]),
        ]
        let events = [
            Transcript.SystemEvent(
                date: Fixtures.t0.addingTimeInterval(30), line: "Alice added \(number)"),
            Transcript.SystemEvent(
                date: Fixtures.t0.addingTimeInterval(40), line: "Alice removed (844) 399-6927"),
        ]
        let out = Export.render(
            records: records, number: "chat1", formats: [.txt, .jsonl], scope: scope,
            group: group, systemEvents: events)
        let txt = out.txt ?? ""
        let jsonl = out.jsonl ?? ""
        for leak in ["555-0142", "399-6927", "bob@", "z@example"] {
            #expect(!txt.contains(leak), "TXT hides \(leak)")
            #expect(!jsonl.contains(leak), "JSONL hides \(leak)")
        }
        #expect(txt.contains("# iMessage group transcript: \"Alice, Member 1\""))
        #expect(
            txt.contains("# Participants: Me = the account owner · Alice · Member 1 · Member 2"))
        #expect(txt.contains("Member 1: hi all, my email is [redacted]  [Member 2: ❤️]"))
        #expect(txt.contains("Alice: welcome!  [Member 1: 👍]"))
        #expect(txt.contains("— Alice added Member 1"))
        #expect(txt.contains("— Alice removed [redacted]"))
        let pro = Export.preparedRedactedRecords(records, scope: scope, redactions: RedactionSet())
        #expect(pro.map(\.speaker) == ["Member 1", "Alice"])
        #expect(pro.flatMap(\.reactions).map(\.by) == ["Member 2", "Member 1"])
        #expect(
            Export.preparedRecords(records, scope: scope).map(\.speaker) == ["Member 1", "Alice"])
    }

    @Test("scrubbers off: labels and header are unchanged")
    func scrubbersOffKeepIdentity() {
        let out = Export.render(
            records: [rec("p1", 0, "Them", "hi")], number: "+18165550188", formats: [.txt])
        #expect((out.txt ?? "").contains("Them = +18165550188"))
    }

    // MARK: - F5: a flag covers the whole secret

    private func afterRedactAll(_ rs: [MessageRecord]) -> Export.Rendered {
        let first = Export.render(records: rs, number: "x", formats: [.txt])
        return Export.render(
            records: rs, number: "x", formats: [.txt], redactions: redactAll(first.detected))
    }

    @Test("Redact All on a private key hides the whole block")
    func privateKeyBlockIsCovered() {
        let body =
            "MIIEowIBAAKCAQEAu1SU1LfVLPHCozMxH2Mo4lgOEePzNm0tRgeLezV6ffAt0gun\n"
            + "VTLw7onLRnrq0/IzW7yWR7QkrmBL7jTKEn5u+qKhbwKfBstIs+bMY2Zkp18gnTxK"
        let key = "-----BEGIN RSA PRIVATE KEY-----\n\(body)\n-----END RSA PRIVATE KEY-----"
        let pgp = "-----BEGIN PGP PRIVATE KEY BLOCK-----\n\nlQOYBF3abcDEFghiJKL\n=Ab12"
        let after = afterRedactAll([
            rec("k1", 0, "Me", "here: \(key) thanks"), rec("k2", 1, "Me", pgp),
        ])
        let txt = after.txt ?? ""
        #expect(!txt.contains("MIIEow") && !txt.contains("gnTxK") && !txt.contains("END RSA"))
        #expect(!txt.contains("lQOYBF3") && !txt.contains("=Ab12"))
        #expect(txt.contains("Me: here: [redacted] thanks"))
        #expect(after.result?.highlightMarks.isEmpty == true)
    }

    @Test("a private key split over messages is flagged through the END line")
    func splitPrivateKeyIsCovered() {
        let rs = [
            rec("s1", 0, "Me", "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA"),
            rec("s2", 1, "Me", "BG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZWQyNTUxOQ"),
            rec("s3", 2, "Me", "AAAAIOt4jRiJ\n-----END OPENSSH PRIVATE KEY-----\nok that's it"),
            rec("s4", 3, "Me", "unrelated"),
        ]
        let txt = afterRedactAll(rs).txt ?? ""
        for leak in ["b3BlbnNz", "BG5vbmUA", "AAAAIOt4", "END OPENSSH"] {
            #expect(!txt.contains(leak), "hides \(leak)")
        }
        #expect(txt.contains("ok that's it") && txt.contains("unrelated"))
    }

    @Test("Redact All on a password hides the whole value")
    func passwordValueIsCovered() {
        let cases: [(String, String)] = [
            ("password: P@ss.w0rd!", "P@ss.w0rd!"),
            ("password is \"correct horse battery staple\"", "correct horse battery staple"),
            ("password is “correct horse battery staple”", "correct horse battery staple"),
            ("my password's hunter2", "hunter2"),
            ("my password’s hunter2", "hunter2"),
            ("DB_PASSWORD=Hunter2!x", "Hunter2!x"),
            ("password: it'sMine,ok", "it'sMine,ok"),
            ("pw = 'it's mine' ok", "it's mine"),
            ("password is hunter2.", "hunter2."),
        ]
        for (i, (text, value)) in cases.enumerated() {
            let r = rec("w\(i)", i, "Them", text)
            let hits = SecretDetector.detect(in: [r]).filter { $0.category == .password }
            let ns = text as NSString
            let covered = hits.map { ns.substring(with: NSRange($0.range)) }
            #expect(covered.contains { $0.contains(value) }, "\(text) → \(covered)")
            let txt = afterRedactAll([r]).txt ?? ""
            #expect(!txt.contains(value), "\(text) leaks after Redact All")
        }
    }
}
