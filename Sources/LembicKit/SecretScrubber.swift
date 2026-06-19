import Foundation

/// On-device, pure **scrubber** for the opt-in ubiquitous-PII / low-harm
/// categories: phone numbers, email addresses,
/// postal addresses, and high-precision 2FA/OTP codes. Mirrors `SecretDetector`'s
/// shape — `Sendable`, no I/O, iterate records once, ranges produced over the
/// body as an `NSString` so they are already UTF-16 `NSRange`s converted to
/// `Range<Int>` with no re-encoding (the frozen offset convention).
///
/// Unlike the detector, a scrubber's output is a **`RedactionSet`**, not a
/// flag-for-review list: an enabled category's matches become ordinary
/// `Redaction(guid:range:)` spans that the render path splices to the generic
/// `[redacted]` token — the SAME reversible redaction pipeline a manual
/// select-to-redact uses, with no type label and no separate alert. The enabling
/// toggle IS the consent.
///
/// Default-OFF semantics live in the API shape: `scrub` only contributes spans
/// for categories present in `categories`. `scrub(in:, categories: [])` returns
/// an empty set, so the caller's default (no scrubbers) is a no-op.
///
/// Licensing: the email pattern and OTP forms are common-knowledge
/// facts re-derived here (not copied from any curated rule file); phone/address
/// use Apple's system `NSDataDetector`. Nothing from trufflehog (AGPL).
public enum SecretScrubber {
    /// The spans to auto-remove for the enabled `categories` across `records`,
    /// as a `RedactionSet` of `Redaction(guid:range:)` (the leaking VALUE only).
    /// A `nil`-guid record can't be anchored, so it is skipped. A disabled
    /// category contributes nothing; an empty `categories` returns an empty set.
    public static func scrub(
        in records: [MessageRecord], categories: Set<ScrubberCategory>
    ) -> RedactionSet {
        var set = RedactionSet()
        guard !categories.isEmpty else { return set }

        for r in records {
            guard let guid = r.guid else { continue }  // can't anchor a nil-guid message
            let ns = r.text as NSString
            let whole = NSRange(location: 0, length: ns.length)
            guard whole.length > 0 else { continue }

            if categories.contains(.phone) {
                appendDataDetectorMatches(.phoneNumber, ns, whole, guid, into: &set)
            }
            if categories.contains(.postalAddress) {
                appendDataDetectorMatches(.address, ns, whole, guid, into: &set)
            }
            if categories.contains(.email) {
                appendRegexMatches(emailRegex, ns, whole, guid, into: &set)
            }
            if categories.contains(.otp) {
                appendOTPMatches(ns, whole, guid, into: &set)
            }
        }
        return set
    }

    // MARK: - Phone + postal address (Apple NSDataDetector)
    //
    // NSDataDetector is Apple's on-device linguistic data detector (the same one
    // that underlines phone numbers / addresses in Mail). No regex to maintain
    // and it understands real-world formatting variation. We build one detector
    // per checking type, lazily and once (it's reusable + thread-safe for reads).
    private static let phoneDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
    private static let addressDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.address.rawValue)

    private static func detector(
        for type: NSTextCheckingResult.CheckingType
    ) -> NSDataDetector? {
        switch type {
        case .phoneNumber: return phoneDetector
        case .address: return addressDetector
        default: return nil
        }
    }

    private static func appendDataDetectorMatches(
        _ type: NSTextCheckingResult.CheckingType,
        _ ns: NSString, _ whole: NSRange, _ guid: String, into set: inout RedactionSet
    ) {
        guard let detector = detector(for: type) else { return }
        detector.enumerateMatches(in: ns as String, range: whole) { match, _, _ in
            guard let match, match.range.length > 0,
                let range = Range(match.range)
            else { return }
            set.add(Redaction(guid: guid, range: range))
        }
    }

    // MARK: - Email (standard RFC-ish address regex)
    //
    // NSDataDetector does NOT reliably catch bare emails (it leans toward
    // mailto:/link contexts), so emails get their own pattern. A common,
    // well-known address shape: a local part of unquoted atext (letters, digits,
    // and the permitted specials), an `@`, then a dotted domain of label runs
    // each starting/ending alphanumeric, ending in a 2+-letter TLD. This is the
    // ubiquitous "good enough" email regex (a fact, not a curated rule), tuned to
    // avoid trailing-dot / leading-dot domains.
    //
    // ReDoS-hardened: the local part is atomic and length-capped (RFC 5321 ≤ 64)
    // behind a non-local-char lookbehind so the engine can't re-anchor inside a
    // hyphen run, and each domain label is atomic and length-bounded (RFC 1035
    // ≤ 63). A long `a-a-…` token that never reaches a TLD can't backtrack.
    private static let emailRegex = try! NSRegularExpression(
        pattern:
            #"(?i)(?<![A-Z0-9._%+\-])(?>[A-Z0-9._%+\-]{1,64})@(?:(?>[A-Z0-9](?:[A-Z0-9\-]{0,61}[A-Z0-9])?)\.)+[A-Z]{2,24}\b"#
    )

    // MARK: - OTP / 2FA (high-precision forms ONLY)
    //
    // We are AUTO-DELETING, so we accept lower recall for high precision: never
    // match a bare digit run (a year/zip/amount/order-number would be nuked).
    // Two precise forms:
    //   (1) machine-readable: a vendor-style `G-123456` prefix — a 1–2-char alpha
    //       tag, then `-`, then a 5–8-digit code (Google's `G-NNNNNN`); requires
    //       the punctuation cue.
    //   (2) strong-cue phrase: a context word (verification / security / login /
    //       one-time / auth / 2fa / OTP / sign-in) within "… code is NNNNNN" /
    //       "your code: NNNNNN" — the phrase is what disambiguates 6 digits from
    //       a year. The emitted range covers the CODE value only (group 1), never
    //       the cue, mirroring the password detector.
    //
    // The bare `#NNNN` form is DELIBERATELY NOT matched: in chat, `#`+digits is
    // overwhelmingly a GitHub/Jira issue, a PR, or an order/confirmation number
    // (`issue #1234`, `order #1234567`), not an OTP — auto-deleting those is a
    // false positive we can't afford when we're removing without review. Real OTPs
    // are caught by the tight `G-NNNNNN` form and the strong-cue phrase forms,
    // which carry an unambiguous context cue (precision over recall).
    private static let otpPrefixRegex = try! NSRegularExpression(
        // `G-123456` — a 1–2-letter vendor tag, a hyphen, a 5–8-digit code.
        // Deliberately tight: a 1–2-char tag + a ≥5-digit code is the
        // machine-readable OTP shape (Google's `G-NNNNNN`), so an ordinary
        // word-hyphen-year like `pre-1984` / `mid-1990` (3-letter tag, 4-digit
        // number) does NOT match. We're auto-deleting → precision over recall.
        pattern: #"\b[A-Za-z]{1,2}-(\d{5,8})\b"#)
    private static let otpPhraseRegex: NSRegularExpression = {
        let pattern =
            #"(?i)\b(?:verification|security|login|one[- ]?time|auth(?:entication)?|2fa|otp|sign[- ]?in|access)\b"#
            + #"(?:\s+\w+){0,3}?\s+code\b"#  // "… code" within a few words of the cue
            + #"\s*(?:is|:|=)?\s*"#  // separator
            + #"(?:#\s*)?"#  // optional leading hash
            + #"(\d{4,8})\b"#  // 4–8-digit code value
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static func appendOTPMatches(
        _ ns: NSString, _ whole: NSRange, _ guid: String, into set: inout RedactionSet
    ) {
        // Machine-readable prefix form (`G-NNNNNN`) emits the FULL token (incl. the
        // tag) so the scrubbed output leaves nothing partial behind.
        otpPrefixRegex.enumerateMatches(in: ns as String, range: whole) { match, _, _ in
            guard let match, match.range.length > 0,
                let range = Range(match.range)
            else { return }
            set.add(Redaction(guid: guid, range: range))
        }
        // Strong-cue phrase emits the CODE value only (group 1) — the cue is
        // ordinary prose worth keeping, the digits are the secret.
        otpPhraseRegex.enumerateMatches(in: ns as String, range: whole) { match, _, _ in
            guard let match else { return }
            let valueRange = match.range(at: 1)
            guard valueRange.location != NSNotFound, valueRange.length > 0,
                let range = Range(valueRange)
            else { return }
            set.add(Redaction(guid: guid, range: range))
        }
    }

    // MARK: - Generic regex helper

    private static func appendRegexMatches(
        _ regex: NSRegularExpression,
        _ ns: NSString, _ whole: NSRange, _ guid: String, into set: inout RedactionSet
    ) {
        regex.enumerateMatches(in: ns as String, range: whole) { match, _, _ in
            guard let match, match.range.length > 0,
                let range = Range(match.range)
            else { return }
            set.add(Redaction(guid: guid, range: range))
        }
    }
}
