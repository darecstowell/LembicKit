import CryptoKit
import Foundation

/// On-device, pure detector for the high-harm secret buckets: the core trio
/// (passwords-in-context, US SSNs, credit-card numbers) plus the
/// long-tail — crypto seed phrases, API keys & tokens, standing
/// codes & PINs, and bank routing/IBAN numbers. No I/O, no allocation beyond the
/// match scan, cheap enough to run on every render — the same budget as the
/// existing substring haystack scan over a thread. (All compiled regexes, the
/// BIP-39 word Set/index, etc. are built once as `static let`.)
///
/// Design stance: HIGH RECALL within the three buckets (a user can dismiss a
/// false positive; a missed secret leaks), but a HARD FLOOR against ordinary
/// PII. Bare phone numbers, emails, names, and street addresses are NEVER
/// flagged — auto-highlighting ubiquitous PII would bury the one real secret
/// in noise, which is the entire point of the feature. The phone/email guard
/// is load-bearing and asserted by the `swift test` suite.
///
/// All match ranges are produced by `NSRegularExpression` over the body as an
/// `NSString`, so they are already UTF-16 `NSRange`s — we convert straight to
/// `Range<Int>` with no re-encoding (the frozen offset convention).
public enum SecretDetector {
    /// Flag the high-harm secrets in `records`. `enabled` selects which
    /// categories to run — a disabled category is skipped entirely (its matches
    /// are never produced), so the caller can honor a per-category "flag for review"
    /// toggle. Defaults to ALL categories, so every existing
    /// call site keeps today's behavior (all detectors on) unchanged.
    public static func detect(
        in records: [MessageRecord],
        enabled: Set<SecretCategory> = Set(SecretCategory.allCases)
    ) -> [DetectedSecret] {
        guard !enabled.isEmpty else { return [] }
        var out: [DetectedSecret] = []
        for r in records {
            guard let guid = r.guid else { continue }  // can't anchor a nil-guid message
            let ns = r.text as NSString
            let whole = NSRange(location: 0, length: ns.length)
            if enabled.contains(.password) { detectPasswords(ns, whole, guid, into: &out) }
            if enabled.contains(.ssn) { detectSSNs(ns, whole, guid, into: &out) }
            if enabled.contains(.creditCard) { detectCards(ns, whole, guid, into: &out) }
            if enabled.contains(.seedPhrase) { detectSeedPhrases(ns, whole, guid, into: &out) }
            if enabled.contains(.apiKey) { detectAPIKeys(ns, whole, guid, into: &out) }
            if enabled.contains(.standingCode) { detectStandingCodes(ns, whole, guid, into: &out) }
            if enabled.contains(.bankAccount) { detectBankNumbers(ns, whole, guid, into: &out) }
        }
        return out
    }

    // MARK: - Password-in-context
    //
    // Trigger lexicon (case-insensitive, word-boundaried): password, passwd,
    // pwd, pw, passcode, passphrase.
    //
    // Separator: a quoted value may use a relaxed/optional separator, but a BARE
    // value REQUIRES a real separator (`is`, `:`, or `=`) gluing it to the
    // trigger — otherwise the next prose word ("password please") would leak.
    //
    // Value rule: a run of non-whitespace characters, optionally wrapped in
    // matching quotes/backticks, that stops at whitespace or sentence
    // punctuation (`.` `,` `;` `!` `?`) — these are not plausible inside a typed
    // secret token and usually end the sentence. A trailing quote/backtick is
    // not part of the value. The emitted range covers the VALUE only (the thing
    // that leaks), never the keyword.
    private static let passwordRegex: NSRegularExpression = {
        // Group 2: quoted value (no closing quote captured). Group 3: bare value.
        let pattern =
            #"(?i)\b(?:password|passwd|passcode|passphrase|pwd|pw)\b"#  // trigger
            + #"(?:(?:\s*(?:is\b\s*)?[:=]?\s*)(["'`])([^"'`\s]+)"#  // relaxed sep + quoted value
            + #"|(?:\s+is\b\s*[:=]?|\s*[:=])\s*([^\s.,;!?'"`]+))"#  // required sep + bare value
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static func detectPasswords(
        _ ns: NSString, _ whole: NSRange, _ guid: String, into out: inout [DetectedSecret]
    ) {
        passwordRegex.enumerateMatches(in: ns as String, range: whole) { match, _, _ in
            guard let match else { return }
            // Prefer the quoted-value capture (group 2), else the bare value (group 3).
            let valueRange =
                match.range(at: 2).location != NSNotFound
                ? match.range(at: 2)
                : match.range(at: 3)
            guard valueRange.location != NSNotFound, valueRange.length > 0 else { return }
            out.append(
                DetectedSecret(
                    guid: guid, range: Range(valueRange)!, category: .password))
        }
    }

    // MARK: - US SSN
    //
    // `AAA-GG-SSSS` and the space-separated `AAA GG SSSS`, word-boundaried so it
    // never fires mid-digit-run. Structurally-invalid SSNs are rejected to trim
    // noise while keeping recall: area 000 / 666 / 900–999, group 00, serial
    // 0000 are all impossible real SSNs. A phone number is 3-3-4 grouped, never
    // 3-2-4, so it cannot match this shape.
    //
    // The dashed form is a strong cue and fires keyword-free. The space form
    // (`123 45 6789`) is far more ambiguous in chat (order numbers, scores,
    // IDs), so it ALSO requires a nearby `ssn` / `social security` keyword,
    // mirroring the routing-number proximity guard in `detectBankNumbers`.
    private static let ssnDashRegex = try! NSRegularExpression(
        pattern: #"\b(\d{3})-(\d{2})-(\d{4})\b"#)

    private static let ssnSpaceRegex = try! NSRegularExpression(
        pattern: #"\b(\d{3}) (\d{2}) (\d{4})\b"#)

    private static let ssnContextRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:ssn|social security)\b"#)

    private static func detectSSNs(
        _ ns: NSString, _ whole: NSRange, _ guid: String, into out: inout [DetectedSecret]
    ) {
        ssnDashRegex.enumerateMatches(in: ns as String, range: whole) { match, _, _ in
            guard let match, validSSNMatch(ns, match) else { return }
            out.append(
                DetectedSecret(guid: guid, range: Range(match.range)!, category: .ssn))
        }

        var contextSpans: [NSRange] = []
        ssnContextRegex.enumerateMatches(in: ns as String, range: whole) { m, _, _ in
            if let m { contextSpans.append(m.range) }
        }
        guard !contextSpans.isEmpty else { return }
        ssnSpaceRegex.enumerateMatches(in: ns as String, range: whole) { match, _, _ in
            guard let match, validSSNMatch(ns, match) else { return }
            let r = match.range
            let near = contextSpans.contains { span in
                let gapBefore = r.location - (span.location + span.length)
                let gapAfter = span.location - (r.location + r.length)
                return (gapBefore >= 0 && gapBefore <= 24) || (gapAfter >= 0 && gapAfter <= 24)
            }
            guard near else { return }
            out.append(
                DetectedSecret(guid: guid, range: Range(r)!, category: .ssn))
        }
    }

    private static func validSSNMatch(_ ns: NSString, _ match: NSTextCheckingResult) -> Bool {
        let area = ns.substring(with: match.range(at: 1))
        let group = ns.substring(with: match.range(at: 2))
        let serial = ns.substring(with: match.range(at: 3))
        return isValidSSN(area: area, group: group, serial: serial)
    }

    static func isValidSSN(area: String, group: String, serial: String) -> Bool {
        guard let a = Int(area) else { return false }
        if a == 0 || a == 666 || a >= 900 { return false }  // 000, 666, 900–999 never issued
        if group == "00" { return false }
        if serial == "0000" { return false }
        return true
    }

    // MARK: - Credit card
    //
    // A run of 13–19 digits, optionally split by single spaces or hyphens
    // (`4111 1111 1111 1111`, `4111-1111-1111-1111`, `4111111111111111`). We
    // match the candidate run, strip separators, and accept ONLY if the Luhn
    // checksum passes — that single gate is what keeps a 10-digit phone number
    // (wrong length AND won't Luhn) out. The emitted range covers the full run
    // including its internal separators. `\b`-anchored so it never starts or
    // ends mid-digit; a leading/trailing separator is not consumed.
    private static let cardRegex = try! NSRegularExpression(
        pattern: #"\b\d(?:[ -]?\d){12,18}\b"#)

    // URL spans, used ONLY to suppress card false positives. A URL has no
    // spaces, so `\S+` swallows the whole thing — scheme, path, AND query
    // string. The `=` and `&` that delimit query-param values are `\b` word
    // boundaries, so a Luhn-passing variant/tracking id like
    // `...?variant=36584399306902&...` would otherwise match cardRegex. Real
    // cards people paste into a chat stand alone, not buried in a query string.
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"https?://\S+|\bwww\.\S+"#)

    private static func detectCards(
        _ ns: NSString, _ whole: NSRange, _ guid: String, into out: inout [DetectedSecret]
    ) {
        // Pre-compute URL spans so we can reject any card candidate buried in a
        // URL / query string (a variant/tracking id, not a card).
        var urlSpans: [NSRange] = []
        urlRegex.enumerateMatches(in: ns as String, range: whole) { m, _, _ in
            if let m { urlSpans.append(m.range) }
        }

        cardRegex.enumerateMatches(in: ns as String, range: whole) { match, _, _ in
            guard let match else { return }
            let r = match.range
            // Rule: a card candidate is suppressed when it is NOT standing on
            // its own but glued into a larger token —
            //   (a) its range intersects a URL span, OR
            //   (b) the char immediately before it is `=`, `/`, or an ASCII
            //       letter, OR the char immediately after it is `=`, `&`, or an
            //       ASCII letter (a backstop for a bare query fragment with no
            //       leading scheme, e.g. `variant=...&x=1`).
            // A standalone card (start/whitespace before, end/whitespace/
            // punctuation after) is unaffected, preserving high recall.
            if urlSpans.contains(where: { NSIntersectionRange($0, r).length > 0 }) { return }
            let before = r.location - 1
            if before >= 0, isGlueChar(ns.character(at: before), leading: true) { return }
            let end = r.location + r.length
            if end < ns.length, isGlueChar(ns.character(at: end), leading: false) { return }

            let run = ns.substring(with: r)
            let digits = run.filter(\.isNumber)
            guard digits.count >= 13, digits.count <= 19, luhnValid(digits) else { return }
            out.append(
                DetectedSecret(
                    guid: guid, range: Range(r)!, category: .creditCard))
        }
    }

    /// True when a UTF-16 unit, sitting immediately beside a digit run, marks
    /// that run as a glued-in token rather than a standalone card. `leading`
    /// selects the preceding-char set (`=` `/` letter) vs the following-char
    /// set (`=` `&` letter). ASCII letters are A–Z / a–z.
    private static func isGlueChar(_ u: unichar, leading: Bool) -> Bool {
        if (u >= 65 && u <= 90) || (u >= 97 && u <= 122) { return true }  // A–Z / a–z
        if u == 0x3D { return true }  // '='
        return leading ? (u == 0x2F) : (u == 0x26)  // '/' lead, '&' follow
    }

    /// Standard Luhn (mod-10) checksum over a digit string.
    static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        var double = false
        for ch in digits.reversed() {
            guard let d = ch.wholeNumberValue else { return false }
            if double {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
            double.toggle()
        }
        return sum % 10 == 0
    }

    // MARK: - Crypto seed phrase (BIP-39)
    //
    // A run of 12 / 15 / 18 / 21 / 24 consecutive lowercase words that are ALL
    // in the BIP-39 English wordlist AND together satisfy the BIP-39 checksum.
    // The checksum gate is what makes this ~zero-FP: an arbitrary run of 12
    // common words ("the of and to ...") would almost never have its last
    // ENT/32 bits match the SHA-256 prefix, so prose can't trip it. (Source:
    // BIP-39 spec + bitcoin/bips english.txt, both MIT — license-clean.)
    //
    // We tokenize on whitespace once, find every maximal run of in-wordlist
    // words, then for each window of a valid length check the checksum. The
    // emitted range spans the FULL mnemonic (first word start → last word end).
    //
    // BY DESIGN: within a single uninterrupted BIP-39-word run we emit only the
    // FIRST checksum-valid window per length (longest first, then we stop sliding
    // that length). So two valid mnemonics concatenated back-to-back with no
    // non-BIP-39 separator yield ONE hit, not two — acceptable for a
    // flag-for-review feature (the user still sees that run is a
    // secret). A non-BIP-39 word between them splits the run and both fire.

    /// Word-token boundaries within the body: `(word, NSRange)` for every
    /// whitespace-delimited run of lowercase ASCII letters. Built per call (cheap
    /// — one linear scan), then filtered against `BIP39.wordSet`.
    private static let seedTokenRegex = try! NSRegularExpression(
        pattern: #"[a-z]+"#)

    /// Valid BIP-39 mnemonic word counts and how many checksum bits each carries
    /// (CS = wordCount * 11 / 33).
    private static let seedLengths: [Int: Int] = [12: 4, 15: 5, 18: 6, 21: 7, 24: 8]

    private static func detectSeedPhrases(
        _ ns: NSString, _ whole: NSRange, _ guid: String, into out: inout [DetectedSecret]
    ) {
        // Collect lowercase-letter tokens with their ranges.
        var tokens: [(word: String, range: NSRange)] = []
        seedTokenRegex.enumerateMatches(in: ns as String, range: whole) { m, _, _ in
            guard let m else { return }
            tokens.append((ns.substring(with: m.range), m.range))
        }
        guard tokens.count >= 12 else { return }

        // Find maximal runs of consecutive BIP-39 words.
        var i = 0
        while i < tokens.count {
            guard BIP39.wordSet.contains(tokens[i].word) else {
                i += 1
                continue
            }
            var j = i
            while j < tokens.count, BIP39.wordSet.contains(tokens[j].word) { j += 1 }
            // Run is tokens[i ..< j]. Slide every valid-length window across it,
            // longest first so the fullest mnemonic wins.
            let runLen = j - i
            var matched = false
            for len in [24, 21, 18, 15, 12] where len <= runLen && !matched {
                var start = i
                while start + len <= j {
                    let words = tokens[start..<(start + len)].map { $0.word }
                    if seedChecksumValid(words) {
                        let first = tokens[start].range
                        let last = tokens[start + len - 1].range
                        let span = NSRange(
                            location: first.location,
                            length: (last.location + last.length) - first.location)
                        out.append(
                            DetectedSecret(guid: guid, range: Range(span)!, category: .seedPhrase))
                        matched = true
                        break
                    }
                    start += 1
                }
            }
            i = j
        }
    }

    /// True when `words` (a 12/15/18/21/24-length BIP-39 word run) satisfies the
    /// BIP-39 checksum: concat each word's 11-bit index → ENT entropy bits + CS
    /// checksum bits; the first CS bits of SHA-256(entropy-bytes) must equal the
    /// CS checksum bits.
    static func seedChecksumValid(_ words: [String]) -> Bool {
        guard let cs = seedLengths[words.count] else { return false }
        // Build the full bit string (words.count * 11 bits) as an array of bits.
        var bits: [Bool] = []
        bits.reserveCapacity(words.count * 11)
        for w in words {
            guard let idx = BIP39.indexOf[w] else { return false }
            // 11 bits, most-significant first.
            for shift in stride(from: 10, through: 0, by: -1) {
                bits.append((idx >> shift) & 1 == 1)
            }
        }
        let totalBits = bits.count
        let entBits = totalBits - cs  // entropy bit count (divisible by 8)
        guard entBits % 8 == 0 else { return false }

        // Pack the entropy bits into bytes.
        var entropy = [UInt8](repeating: 0, count: entBits / 8)
        for k in 0..<entBits where bits[k] {
            entropy[k / 8] |= UInt8(1 << (7 - (k % 8)))
        }
        // SHA-256 of the entropy; the first `cs` bits must equal the trailing
        // `cs` checksum bits of the mnemonic.
        let digest = SHA256.hash(data: Data(entropy))
        let hashBytes = Array(digest)
        for k in 0..<cs {
            let hashBit = (hashBytes[k / 8] >> (7 - (k % 8))) & 1 == 1
            if hashBit != bits[entBits + k] { return false }
        }
        return true
    }

    // MARK: - API keys & tokens
    //
    // ~12 curated, high-precision prefixed token FORMATS. These are public,
    // well-known shapes (not copyrightable); re-derived from format knowledge /
    // gitleaks (MIT) — NOT copied from any trufflehog (AGPL) rule file. Each
    // pattern requires a literal vendor prefix/infix or a structural shape, so no
    // context keyword is needed. The emitted range covers the full token.
    private static let apiKeyRegexes: [NSRegularExpression] = {
        let patterns: [String] = [
            // OpenAI classic secret key: sk- + base62 with the T3BlbkFJ infix.
            #"\bsk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}\b"#,
            // OpenAI project key: sk-proj-<long base62url run>.
            #"\bsk-proj-[A-Za-z0-9_-]{20,}\b"#,
            // Anthropic API key: sk-ant-api03-<long run>.
            #"\bsk-ant-api03-[A-Za-z0-9_-]{20,}\b"#,
            // AWS access key id: AKIA/ASIA + 16 uppercase base36.
            #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
            // GitHub classic / fine-grained PATs.
            #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b"#,
            #"\bgithub_pat_[A-Za-z0-9_]{22,}\b"#,
            // Google API key: AIza + 35 base64url chars.
            #"\bAIza[0-9A-Za-z_-]{35}\b"#,
            // Stripe secret / restricted live keys + webhook signing secret.
            #"\b(?:sk|rk)_live_[A-Za-z0-9]{20,}\b"#,
            #"\bwhsec_[A-Za-z0-9]{20,}\b"#,
            // Slack incoming webhook URL.
            #"https://hooks\.slack\.com/services/[A-Za-z0-9/_+-]+"#,
            // Discord webhook URL (discord.com or discordapp.com).
            #"https://discord(?:app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+"#,
            // JWT: REQUIRE the 3-part header.payload.signature structure (not just
            // the eyJ prefix) AND a realistic minimum length per segment, so a
            // bare base64 "eyJ…" blob does NOT fire and a trivially-short dotted
            // token like "eyJfoo.bar.baz" / "eyJa.b.c" is rejected. A genuine JWT
            // header is ≥18 base64url chars (`eyJ` + ≥15) and the payload &
            // signature are long too; the real-vector test JWTs sit well above
            // these floors (header tail 17/33, payload 27/46, signature 22/43).
            #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#,
            // PEM private-key header (any key type).
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        ]
        return patterns.map { try! NSRegularExpression(pattern: $0) }
    }()

    private static func detectAPIKeys(
        _ ns: NSString, _ whole: NSRange, _ guid: String, into out: inout [DetectedSecret]
    ) {
        for regex in apiKeyRegexes {
            regex.enumerateMatches(in: ns as String, range: whole) { match, _, _ in
                guard let match, match.range.length > 0 else { return }
                out.append(
                    DetectedSecret(guid: guid, range: Range(match.range)!, category: .apiKey))
            }
        }
    }

    // MARK: - Standing codes & PINs
    //
    // A lexicon extension of the password-in-context engine (detect-secrets-style
    // keyword grammar, Apache-2.0 — re-derived, not copied): a CODE-NOUN
    // (`code`/`combination`/`passcode`/`pin`/`keypad`) + a separator
    // (`is`/`:`/`=`/whitespace) + a 3–8-char numeric or alphanumeric code. A
    // code-noun is what makes it a standing code — a bare PLACE word
    // (`door`/`gate`/`garage`/`safe`/`alarm`/`lock`) may only QUALIFY a code-noun
    // (`garage code`, `safe combination`), never fire on its own. That guard is
    // load-bearing: `meet me at gate 22B` (a boarding gate) and `garage 1234` (a
    // unit number) are extremely common in chat and must NOT trip the detector.
    // Requiring the code-noun + separator + a short code also keeps bare prose
    // ("the code of conduct") from firing. A negative-qualifier list before
    // `code` (zip/area/error/status/promo/...) keeps ordinary phrases like
    // `area code 415` (itself bare PII) from firing. The emitted range covers
    // the CODE value only (not the keyword), mirroring the password detector.
    private static let standingCodeRegex: NSRegularExpression = {
        let pattern =
            #"(?i)(?:\b(?:door|gate|garage|safe|alarm|lock)\s+)?"#  // optional place qualifier
            + #"(?<!\bzip )(?<!\barea )(?<!\berror )(?<!\bstatus )(?<!\bcountry )"#
            + #"(?<!\bpromo )(?<!\bpostal )(?<!\bdial )(?<!\bexit )"#  // negative qualifiers
            + #"\b(?:code|combination|passcode|pin|keypad)\b"#  // required code-noun
            + #"\s*(?:is\b\s*)?[:=]?\s*"#  // separator
            + #"(?:#\s*)?"#  // optional leading hash (e.g. "PIN #1234")
            + #"([0-9][0-9A-Za-z]{2,7})\b"#  // 3–8-char code starting with a digit
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static func detectStandingCodes(
        _ ns: NSString, _ whole: NSRange, _ guid: String, into out: inout [DetectedSecret]
    ) {
        standingCodeRegex.enumerateMatches(in: ns as String, range: whole) { match, _, _ in
            guard let match else { return }
            let valueRange = match.range(at: 1)
            guard valueRange.location != NSNotFound, valueRange.length > 0 else { return }
            out.append(
                DetectedSecret(guid: guid, range: Range(valueRange)!, category: .standingCode))
        }
    }

    // MARK: - IBAN + US bank routing
    //
    // IBAN: a country-code + 2 check digits + 11–30 alphanumerics, gated by the
    // mod-97 checksum (move the first 4 chars to the end, map A=10…Z=35, the big
    // integer mod 97 must be 1). Self-validating → no context keyword needed;
    // emits the full IBAN.
    //
    // US routing (ABA): 9 digits passing the ABA weighted checksum. A bare
    // ABA-passing 9-digit number is far too common in chat, so we ALSO require a
    // context keyword (routing / ABA / wire / transit) nearby; emits the digits.
    // (Both checksum algorithms are public facts.)
    private static let ibanRegex = try! NSRegularExpression(
        pattern: #"\b[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\b"#)

    /// Per-country canonical IBAN length (total characters). A documented subset;
    /// any country not listed falls back to the structural-length + mod-97 gate.
    /// KNOWN TRADE-OFF: an IBAN whose country code is NOT in this table rides on
    /// the mod-97 check alone — ~1% of random IBAN-shaped strings pass mod-97 by
    /// chance, so a non-table country code is the weakest gate. Bounded and
    /// accepted: real IBANs people paste are overwhelmingly from listed countries,
    /// and a flagged false positive is dismissable (a flag-for-review feature).
    private static let ibanCountryLengths: [String: Int] = [
        "AD": 24, "AE": 23, "AT": 20, "BE": 16, "BG": 22, "CH": 21, "CY": 28,
        "CZ": 24, "DE": 22, "DK": 18, "EE": 20, "ES": 24, "FI": 18, "FR": 27,
        "GB": 22, "GR": 27, "HR": 21, "HU": 28, "IE": 22, "IL": 23, "IS": 26,
        "IT": 27, "LI": 21, "LT": 20, "LU": 20, "LV": 21, "MC": 27, "MT": 31,
        "NL": 18, "NO": 15, "PL": 28, "PT": 25, "RO": 24, "SE": 24, "SI": 19,
        "SK": 24, "SM": 27, "TR": 26,
    ]

    /// 9-digit ABA routing candidates, word-boundaried.
    private static let routingRegex = try! NSRegularExpression(
        pattern: #"\b\d{9}\b"#)

    /// Context keywords that must sit near a routing-number candidate.
    private static let routingContextRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:routing|aba|wire|transit)\b"#)

    private static func detectBankNumbers(
        _ ns: NSString, _ whole: NSRange, _ guid: String, into out: inout [DetectedSecret]
    ) {
        // IBAN — mod-97 self-validating.
        ibanRegex.enumerateMatches(in: ns as String, range: whole) { match, _, _ in
            guard let match else { return }
            let iban = ns.substring(with: match.range)
            let country = String(iban.prefix(2))
            // If we know the country's canonical length, enforce it; otherwise the
            // structural length range + mod-97 are the gate.
            if let want = ibanCountryLengths[country], iban.count != want { return }
            guard ibanMod97Valid(iban) else { return }
            out.append(
                DetectedSecret(guid: guid, range: Range(match.range)!, category: .bankAccount))
        }

        // US routing — ABA checksum AND a nearby context keyword.
        var contextSpans: [NSRange] = []
        routingContextRegex.enumerateMatches(in: ns as String, range: whole) { m, _, _ in
            if let m { contextSpans.append(m.range) }
        }
        guard !contextSpans.isEmpty else { return }
        routingRegex.enumerateMatches(in: ns as String, range: whole) { match, _, _ in
            guard let match else { return }
            let digits = ns.substring(with: match.range)
            guard abaRoutingValid(digits) else { return }
            // Require a context keyword within 24 UTF-16 units on either side.
            let r = match.range
            let near = contextSpans.contains { span in
                let gapBefore = r.location - (span.location + span.length)
                let gapAfter = span.location - (r.location + r.length)
                return (gapBefore >= 0 && gapBefore <= 24) || (gapAfter >= 0 && gapAfter <= 24)
            }
            guard near else { return }
            out.append(
                DetectedSecret(guid: guid, range: Range(r)!, category: .bankAccount))
        }
    }

    /// IBAN mod-97 validation: move the first 4 chars to the end, map letters
    /// A=10…Z=35, the resulting big integer mod 97 must equal 1. Computed
    /// digit-streaming so no big-integer type is needed.
    static func ibanMod97Valid(_ iban: String) -> Bool {
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for ch in rearranged {
            let piece: String
            if let d = ch.wholeNumberValue, ch.isNumber {
                piece = String(d)
            } else if ch.isLetter, let ascii = ch.asciiValue, ascii >= 65, ascii <= 90 {
                piece = String(Int(ascii) - 55)  // A=10 … Z=35
            } else {
                return false
            }
            for p in piece {
                remainder = (remainder * 10 + p.wholeNumberValue!) % 97
            }
        }
        return remainder == 1
    }

    /// ABA routing-number checksum over a 9-digit string:
    /// 3·(d1+d4+d7) + 7·(d2+d5+d8) + (d3+d6+d9) ≡ 0 (mod 10).
    static func abaRoutingValid(_ digits: String) -> Bool {
        guard digits.count == 9 else { return false }
        let d = digits.compactMap(\.wholeNumberValue)
        guard d.count == 9 else { return false }
        let sum =
            3 * (d[0] + d[3] + d[6])
            + 7 * (d[1] + d[4] + d[7])
            + (d[2] + d[5] + d[8])
        return sum % 10 == 0
    }
}
