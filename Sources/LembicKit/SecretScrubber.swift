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
            for range in ranges(in: r.text as NSString, categories: categories) {
                set.add(Redaction(guid: guid, range: range))
            }
        }
        return set
    }

    /// The UTF-16 ranges the enabled `categories` remove from one string. Each rule runs
    /// on the normalized text (see `TextNormalizer`) behind a cheap gate.
    static func ranges(
        in source: NSString, categories: Set<ScrubberCategory>, gated: Bool = true
    ) -> [Range<Int>] {
        guard source.length > 0, !categories.isEmpty else { return [] }
        let body = TextNormalizer.normalize(source as String)
        let ns = body.text
        let p = TextProfile(ns, gated: gated)
        var found: [NSRange] = []
        if categories.contains(.phone), p.digits >= 4 { found += phones(ns) }
        if categories.contains(.postalAddress), p.digits >= 1, !gated || mayHoldAddress(ns) {
            found += addresses(ns)
        }
        if categories.contains(.email) { found += emails(ns, p) }
        if categories.contains(.otp), p.digits >= 2 { found += otps(ns, p) }
        let ranges = Set(found.compactMap { body.sourceRange($0) })
        return ranges.filter { r in
            !ranges.contains {
                $0 != r && $0.lowerBound <= r.lowerBound && $0.upperBound >= r.upperBound
            }
        }.sorted { $0.lowerBound < $1.lowerBound }
    }

    private static func digitCount(_ s: String) -> Int {
        s.unicodeScalars.filter { $0.value >= 0x30 && $0.value <= 0x39 }.count
    }

    // MARK: - Phone and postal address (Apple NSDataDetector)

    private static let phoneDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
    private static let addressDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.address.rawValue)

    /// A year range ("1989-2005") or a round range ("1000-3000"), not a phone number.
    private static let numberRange = regex(#"^([0-9]{4}) ?- ?([0-9]{4})$"#)
    /// A label that makes the number an ID, not a phone number ("serial is ...").
    private static let idLabelBefore = regex(
        #"(?i)\b(?:serial|s/n|sn|imei|model|part|sku|isbn|upc|order|invoice|ticket|tracking|confirmation|ref|reference|po)\b[^\n0-9]{0,12}$"#
    )
    /// Two capitals, a dash, and digits ("CA-90210", "PR-12345"): a code, not an address.
    private static let codeLikeAddress = regex(#"^[A-Z]{2}-[0-9]+$"#)

    private static func phones(_ ns: NSString) -> [NSRange] {
        guard let phoneDetector else { return [] }
        return phoneDetector.matches(
            in: ns as String, range: NSRange(location: 0, length: ns.length)
        )
        .map(\.range).filter { r in
            let text = ns.substring(with: r)
            let n = digitCount(text)
            guard n >= 7 || (n >= 4 && text.contains(where: \.isLetter)) else { return false }
            if let m = numberRange.firstMatch(
                in: text, range: NSRange(location: 0, length: (text as NSString).length))
            {
                let a = Int((text as NSString).substring(with: m.range(at: 1))) ?? 0
                let b = Int((text as NSString).substring(with: m.range(at: 2))) ?? 0
                if (1000...2099).contains(a) && (1000...2099).contains(b) { return false }
                if a % 100 == 0 && b % 100 == 0 { return false }
            }
            let before = ns.substring(to: r.location) as NSString
            return !idLabelBefore.found(in: before)
        }
    }

    /// Words that follow a count or a time, not a street number.
    private static let notAfterStreetNumber: Set<String> = [
        "a", "am", "pm", "and", "or", "to", "of", "at", "in", "on", "for", "the", "is", "x", "k",
        "min", "mins", "minute", "minutes", "sec", "secs", "second", "seconds", "hr", "hrs", "hour",
        "hours", "day", "days", "week", "weeks", "month", "months", "yr", "yrs", "year", "years",
        "times", "more", "people", "ppl", "percent", "dollars", "bucks", "pts", "points", "lbs",
        "games", "out", "left", "each", "per", "tickets", "items", "things",
    ]

    /// A cheap gate for the address detector: a number not glued to a letter before it,
    /// with a word after it ("12 Elm St", "221B Baker") or a capitalized word before
    /// it ("Hauptstraße 5"). "week 3" and "RB2" do not pass.
    static func mayHoldAddress(_ ns: NSString) -> Bool {
        let length = ns.length
        func isLetter(_ c: unichar) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || (c >= 0xC0 && c != 0xD7 && c != 0xF7)
        }
        func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
        var k = 0
        while k < length {
            guard isDigit(ns.character(at: k)) else {
                k += 1
                continue
            }
            let start = k
            while k < length, isDigit(ns.character(at: k)) { k += 1 }
            if start > 0, isLetter(ns.character(at: start - 1)) { continue }
            var j = k
            var glued = 0
            while j < length, glued < 2, isLetter(ns.character(at: j)) {
                j += 1
                glued += 1
            }
            var gap = 0
            while j < length, [0x20, 0x2C, 0x2E, 0x0A].contains(ns.character(at: j)) {
                j += 1
                gap += 1
            }
            if gap > 0, j < length, isLetter(ns.character(at: j)) {
                var e = j
                while e < length, isLetter(ns.character(at: e)) { e += 1 }
                let word = ns.substring(with: NSRange(location: j, length: e - j)).lowercased()
                if !notAfterStreetNumber.contains(word) { return true }
            }
            var b = start - 1
            while b >= 0, [0x20, 0x2C].contains(ns.character(at: b)) { b -= 1 }
            if b < start - 1, b >= 0, isLetter(ns.character(at: b)) {
                while b > 0, isLetter(ns.character(at: b - 1)) { b -= 1 }
                let c = ns.character(at: b)
                if (c >= 0x41 && c <= 0x5A) || (c >= 0xC0 && c <= 0xDE) { return true }
            }
        }
        return false
    }

    private static func addresses(_ ns: NSString) -> [NSRange] {
        guard let addressDetector else { return [] }
        return addressDetector.matches(
            in: ns as String, range: NSRange(location: 0, length: ns.length)
        )
        .map(\.range).filter { !codeLikeAddress.found(in: ns.substring(with: $0) as NSString) }
    }

    // MARK: - Email

    // Atomic, length-capped parts so a long `a-a-...` run cannot backtrack. Unicode
    // letters for IDN addresses. Spaces may sit around "@" but not around ".".
    private static let emailRegex = regex(
        #"(?i)(?<![\p{L}\p{N}._%+\-])(?>[\p{L}\p{N}._%+\-]{1,64}) ?(?:@|\(at\)|\[at\]|\{at\}) ?(?:(?>[\p{L}\p{N}](?:[\p{L}\p{N}\-]{0,61}[\p{L}\p{N}])?)(?:\.|\s?\(dot\)\s?|\s?\[dot\]\s?))+\p{L}{2,24}(?![\p{L}\p{N}])"#
    )
    /// "jane at example dot com".
    private static let spokenEmail = regex(
        #"(?i)(?<![\p{L}\p{N}._%+\-])[\p{L}\p{N}._%+\-]{1,64}\s+at\s+(?!(?:the|this|that|a|an|my|your|our|his|her|their|it|home|work|least|most|all|once|last|first)\b)[\p{L}\p{N}\-]{1,63}(?:\s+dot\s+[\p{L}\p{N}\-]{1,63})*\s+dot\s+(?:com|net|org|edu|gov|io|co|us|uk|de|fr|ca|au|me|info|biz|app|dev|ai|mx|es|it|nl|br|in|jp)(?![\p{L}\p{N}])"#
    )

    private static let commonTLDs: Set<String> = [
        "com", "net", "org", "edu", "gov", "io", "co", "us", "uk", "de", "fr", "ca", "au", "me",
        "info", "biz", "app", "dev", "ai", "mx", "es", "it", "nl", "br", "in", "jp", "ch", "se",
    ]

    private static func emails(_ ns: NSString, _ p: TextProfile) -> [NSRange] {
        var out: [NSRange] = []
        if p.hasAny(["@", "(at)", "[at]", "{at}"]) {
            // With a space at "@", only a common TLD counts ("-H @headers.txt" is a flag).
            out += emailRegex.spans(in: ns).filter { r in
                let v = ns.substring(with: r)
                guard v.contains(" @") || v.contains("@ ") else { return true }
                let tld =
                    v.split(whereSeparator: { !$0.isLetter }).last.map { $0.lowercased() } ?? ""
                return commonTLDs.contains(tld) && v.first?.isLetter == true
            }
        }
        if p.has("at"), p.has("dot") { out += spokenEmail.spans(in: ns) }
        return out
    }

    // MARK: - One-time codes
    //
    // These spans are removed with no review, so a code needs a clear cue: a sign-in
    // phrase in the message plus "code", "passcode", "OTP", or "PIN" next to it, a
    // code-first form ("123456 is your Amazon OTP"), "use 123456 to verify", the
    // domain-bound form ("@apple.com #123456"), or Google's "G-123456". A bare digit
    // run, "zip code", "room code", and "promo code" are never removed.

    private static let otpContext = regex(
        #"(?i)verif|v[ée]rif|security|log ?in|sign ?in|one[- ]?time|\b2fa\b|\bmfa\b|\botp\b|do not share|don['’]?t share|never share|not share|never ask|your (?:[\w&'’.\-]+ ){0,3}(?:code|otp|passcode|pin)\b|code is|is your|expires|passcode|confirmation"#
    )
    /// A sign-in template cue; an alphanumeric code needs one (a booking code does not).
    private static let otpStrongContext = regex(
        #"(?i)verif|v[ée]rif|security|log ?in|sign ?in|one[- ]?time|\b2fa\b|\bmfa\b|\botp\b|share|never ask|your (?:[\w&'’.\-]+ ){0,3}code\b|expires|passcode"#
    )
    private static let otpValue = #"([0-9]{3}[- ][0-9]{3}|[0-9]{4,8})(?![0-9])"#
    private static let otpAfterCue = regex(
        #"(?i)\b(?:code|passcode|otp|pin)\b[^0-9\n]{0,20}?"# + otpValue)
    private static let otpAlphanumeric = regex(
        #"(?i)\bcode\s*(?:is|:)\s*((?=[a-z0-9\-]*[0-9][a-z0-9\-]*[0-9])(?=[a-z0-9\-]*[a-z])(?:[a-z0-9]{3}-[a-z0-9]{3}|[a-z0-9]{6,10}))(?![a-z0-9\-])"#
    )
    private static let otpBeforeCue = regex(
        #"(?i)(?<![0-9#])"# + otpValue
            + #"\s+is\s+your\s+(?:[\p{L}\p{N}'’&.\-]+\s+){0,3}?(?:code|otp|passcode|pin|verification|login|security|one[- ]time|2fa)\b"#
    )
    private static let otpUse = regex(
        #"(?i)\buse\s+(?:code\s+)?([0-9]{4,8})\s+(?:to|as|for)\s+(?:verify|log\s?in|sign\s?in|confirm|your)"#
    )
    private static let otpDomainBound = regex(
        #"(?<![\w.])@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\s+#((?=[A-Za-z0-9]*[0-9])[A-Za-z0-9]{4,10})(?![A-Za-z0-9])"#
    )
    private static let otpGoogle = regex(#"(?<![A-Za-z0-9\-])G-[0-9]{5,8}(?![0-9])"#)
    private static let otpI18n: [NSRegularExpression] = [
        #"(?:验证码|驗證碼|認証コード|인증번호|校验码)[^0-9]{0,6}([0-9]{4,8})(?![0-9])"#,
        #"(?i)(?:c[oó]digo|code|codice)(?:\s+de)?\s+(?:verificaci[oó]n|v[ée]rification|verifica[çc][ãa]o|di\s+verifica|seguridad|s[ée]curit[ée])\s*(?:es|est|é|è|:)?\s*([0-9]{4,8})(?![0-9])"#,
        #"(?i)best[äa]tigungscode\s*(?:lautet|ist|:)?\s*([0-9]{4,8})(?![0-9])"#,
    ].map(regex)
    /// A word before "code" that makes it some other code ("zip code", "promo code").
    private static let otherCode = regex(
        #"(?i)\b(?:zip|area|postal|post|promo|promotional|discount|coupon|voucher|gift|referral|invite|invitation|room|error|status|country|dress|source|tax|bar|qr|dial|exit|response|http|zoom|meeting|join|share|game|party|color|colour|product|course|class|flight|booking|tracking|order|reference|cheat|morse|swift|sort|iata|airport)\s+$"#
    )

    private static let otpContextWords: [StaticString] = [
        "verif", "secur", "log", "sign", "one", "2fa", "mfa", "otp", "share", "never", "your",
        "code", "expire", "passcode", "confirm",
    ]

    private static func otps(_ ns: NSString, _ p: TextProfile) -> [NSRange] {
        var out: [NSRange] = []
        func notOtherCode(_ m: NSTextCheckingResult) -> Bool {
            !otherCode.found(in: ns.substring(to: m.range.location) as NSString)
        }
        if p.longestDigitRun >= 3 || p.has("code"), p.nonASCII || p.hasAny(otpContextWords),
            otpContext.found(in: ns)
        {
            for m in otpAfterCue.all(in: ns) where notOtherCode(m) { out.append(m.range(at: 1)) }
            if otpStrongContext.found(in: ns) {
                for m in otpAlphanumeric.all(in: ns) where notOtherCode(m) {
                    out.append(m.range(at: 1))
                }
            }
            for m in otpBeforeCue.all(in: ns) { out.append(m.range(at: 1)) }
        }
        let gated: [(NSRegularExpression, Bool)] =
            [(otpUse, p.has("use")), (otpDomainBound, p.has("@") && p.has("#"))]
            + otpI18n.map { ($0, p.nonASCII || p.hasAny(["codigo", "code", "codice", "best"])) }
        for (rx, gate) in gated where gate {
            for m in rx.all(in: ns) { out.append(m.range(at: 1)) }
        }
        if p.has("g-") { out += otpGoogle.spans(in: ns) }
        return out
    }
}
