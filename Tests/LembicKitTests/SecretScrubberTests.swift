import Foundation
import Testing

@testable import LembicKit

// The opt-in auto-remove scrubbers —
// phone / email / postal address (Apple NSDataDetector + a standard email regex)
// and high-precision OTP forms — plus the default-OFF proof and an `[redacted]`-
// in-output integration test through `Export.render`.
@Suite("secret scrubber")
struct SecretScrubberTests {
    private func detRec(_ guid: String?, _ text: String) -> MessageRecord {
        Fixtures.detRec(guid, text)
    }

    /// The scrubbed substrings (the values that leak), sorted by position, for an
    /// exact-range assertion against the source NSString.
    private func scrubbedSlices(
        _ text: String, _ cats: Set<ScrubberCategory>
    ) -> [String] {
        let rs = SecretScrubber.scrub(in: [detRec("g", text)], categories: cats)
        let ns = text as NSString
        return rs.all.compactMap(\.range)
            .sorted { $0.lowerBound < $1.lowerBound }
            .map { ns.substring(with: NSRange($0)) }
    }

    // MARK: - Default-off proof

    @Test("empty categories scrub nothing (default OFF)")
    func defaultOff() {
        let text = "phone (816) 555-0143, email a@b.com, your code #123456"
        #expect(
            SecretScrubber.scrub(in: [detRec("g", text)], categories: []).isEmpty,
            "scrub(in:, categories: []) returns an empty set — the default is a no-op")
        // A disabled category contributes nothing even when others are on.
        #expect(
            scrubbedSlices(text, [.phone]).allSatisfy { !$0.contains("@") },
            "with only .phone enabled, the email is not scrubbed")
    }

    // MARK: - Phone (NSDataDetector)

    @Test("phone numbers scrubbed with the exact range")
    func phone() {
        let text = "call me at (816) 555-0143 tomorrow"
        let slices = scrubbedSlices(text, [.phone])
        #expect(slices == ["(816) 555-0143"], "the formatted phone number, exact span")
        // A nil-guid record can't be anchored → never scrubbed.
        #expect(
            SecretScrubber.scrub(in: [detRec(nil, text)], categories: [.phone]).isEmpty,
            "nil-guid record is skipped")
    }

    // MARK: - Email (standard regex)

    @Test("emails scrubbed (incl. plus-tag and multi-label TLD)")
    func email() {
        #expect(
            scrubbedSlices("reach me jane.doe+test@example.co.uk ok", [.email])
                == ["jane.doe+test@example.co.uk"],
            "the full address including the +tag and the .co.uk TLD")
        // A bare token with no dotted TLD is not an email.
        #expect(
            scrubbedSlices("user@localhost ok", [.email]).isEmpty,
            "no dotted TLD → not matched")
    }

    // MARK: - Postal address (NSDataDetector)

    @Test("postal addresses scrubbed")
    func postalAddress() {
        let text = "I live at 1600 Pennsylvania Avenue NW, Washington, DC 20500 now"
        let slices = scrubbedSlices(text, [.postalAddress])
        #expect(slices.count == 1, "one address span")
        #expect(
            slices.first?.contains("1600 Pennsylvania Avenue") == true
                && slices.first?.contains("20500") == true,
            "the address span covers the street through the ZIP")
        // A non-address phrase yields nothing.
        #expect(
            scrubbedSlices("meet at the park at 3pm", [.postalAddress]).isEmpty,
            "ordinary prose is not an address")
    }

    // MARK: - OTP precision (the load-bearing guard)

    @Test("OTP: machine-readable + strong-cue forms scrub; bare digits do NOT")
    func otpPrecision() {
        // Machine-readable form — emit the FULL token (incl. the tag).
        #expect(scrubbedSlices("use G-901234 to log in", [.otp]) == ["G-901234"])
        // Strong-cue phrase — emit the CODE value only.
        #expect(
            scrubbedSlices("your verification code is 901234 thanks", [.otp]) == ["901234"])
        #expect(scrubbedSlices("one-time code is 553201", [.otp]) == ["553201"])

        // The bare `#NNNN` form is NOT scrubbed: in chat `#`+digits is
        // overwhelmingly an issue / PR / order / confirmation number, not an OTP,
        // and we're auto-deleting (precision over recall). A real OTP carries the
        // `G-` machine form or a strong-cue phrase, both still caught above.
        #expect(
            scrubbedSlices("see issue #1234 for details", [.otp]).isEmpty,
            "issue #1234 → a GitHub/Jira issue number, NOT an OTP")
        #expect(
            scrubbedSlices("your order #1234567 shipped", [.otp]).isEmpty,
            "order #1234567 → an order number, NOT an OTP")
        #expect(
            scrubbedSlices("your code #123456 ok", [.otp]).isEmpty,
            "a bare # code form is no longer scrubbed (issue/order false positives)")

        // Precision floor: bare digits, a 5-digit ZIP, a 4-digit year are NOT
        // scrubbed (we're auto-deleting — never nuke a year/zip/amount).
        #expect(scrubbedSlices("just 123456 alone", [.otp]).isEmpty, "bare 123456 → not scrubbed")
        #expect(scrubbedSlices("the zip is 90210", [.otp]).isEmpty, "5-digit zip → not scrubbed")
        #expect(scrubbedSlices("see you in 2024", [.otp]).isEmpty, "4-digit year → not scrubbed")
        // A word-hyphen-year (pre-1984 / mid-1990) is NOT the G-NNNNNN form.
        #expect(scrubbedSlices("a pre-1984 model", [.otp]).isEmpty, "pre-1984 → not an OTP")
    }

    // MARK: - Multiple categories at once

    @Test("multiple enabled categories each contribute")
    func multipleCategories() {
        let text = "phone (816) 555-0143 email a@b.com"
        let slices = scrubbedSlices(text, [.phone, .email])
        #expect(slices == ["(816) 555-0143", "a@b.com"], "both the phone and the email")
    }

    // MARK: - Integration through Export.render → [redacted] in BOTH outputs

    @Test("an enabled scrubber redacts the value in BOTH .txt and .jsonl")
    func integrationThroughExportRender() {
        let recs = [
            Fixtures.exportRec(0, "Them", "my email is jane@example.com call me"),
        ]
        var scope = Export.Scope()
        scope.enabledScrubbers = [.email]
        let out = Export.render(
            records: recs, number: "+15551230000", formats: [.txt, .jsonl], scope: scope)

        let txt = try! #require(out.txt)
        let jsonl = try! #require(out.jsonl)
        // The value is gone from BOTH outputs, replaced by the generic [redacted].
        #expect(!txt.contains("jane@example.com"), "scrubbed email never in the .txt")
        #expect(!jsonl.contains("jane@example.com"), "scrubbed email never in the .jsonl")
        #expect(txt.contains("[redacted]"), "the .txt splices the generic [redacted]")
        #expect(jsonl.contains("[redacted]"), "the .jsonl splices the same [redacted]")
        // No scrubber → the value is present (proves the toggle, not always-on).
        let off = Export.render(records: recs, number: "+15551230000", formats: [.txt])
        #expect(off.txt?.contains("jane@example.com") == true, "scrubber off → value preserved")
    }
}
