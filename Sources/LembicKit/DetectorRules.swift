import Foundation

func regex(_ pattern: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern)
}

extension NSRegularExpression {
    func all(in ns: NSString, range: NSRange? = nil) -> [NSTextCheckingResult] {
        matches(in: ns as String, range: range ?? NSRange(location: 0, length: ns.length))
    }

    func spans(in ns: NSString) -> [NSRange] { all(in: ns).map(\.range) }

    func found(in ns: NSString) -> Bool {
        firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length)) != nil
    }
}

/// True when `r` overlaps a span or sits within `window` UTF-16 units of one.
func isNear(_ r: NSRange, _ spans: [NSRange], within window: Int) -> Bool {
    spans.contains { s in
        if NSIntersectionRange(r, s).length > 0 { return true }
        let gapBefore = r.location - (s.location + s.length)
        let gapAfter = s.location - (r.location + r.length)
        return (gapBefore >= 0 && gapBefore <= window) || (gapAfter >= 0 && gapAfter <= window)
    }
}

/// One pass over a normalized body: the counts the rule gates use, and an ASCII
/// lower-case copy for fast keyword checks. A gate only skips a rule that cannot match.
struct TextProfile {
    let digits: Int
    let bipWords: Int
    /// The most BIP-39 words in a row, allowing one other word inside the run.
    let bipRun: Int
    let longestToken: Int
    /// Runs of 15 or more characters with no white space (where a vendor key can be).
    let longTokens: [NSRange]
    let nonASCII: Bool
    let colons: Int
    let longestDigitRun: Int
    private let lower: [UInt8]
    /// Every gate passes. Tests use this to prove the gates never change a result.
    private let open: Bool

    private static let bipPacked: Set<UInt64> = Set(BIP39.words.map { pack(Array($0.utf8)) })

    private static func pack(_ bytes: some Collection<UInt8>) -> UInt64 {
        bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    init(_ ns: NSString, gated: Bool = true) {
        guard gated else {
            let n = Int.max / 4
            (digits, bipWords, bipRun, longestToken, colons, longestDigitRun) = (n, n, n, n, n, n)
            longTokens = [NSRange(location: 0, length: ns.length)]
            nonASCII = true
            lower = []
            open = true
            return
        }
        open = false
        let length = ns.length
        var units = [UInt16](repeating: 0, count: length)
        ns.getCharacters(&units, range: NSRange(location: 0, length: length))
        var lower = [UInt8](repeating: 0x80, count: length)
        var digits = 0
        var bip = 0
        var run = 0
        var runBeforeOther = 0
        var bestRun = 0
        var lastWasOther = false
        var longest = 0
        var token = 0
        var longTokens: [NSRange] = []
        var wordStart = -1
        var nonASCII = false
        var colons = 0
        var digitRun = 0
        var longestDigitRun = 0
        func endWord(_ k: Int) {
            guard wordStart >= 0 else { return }
            if (3...8).contains(k - wordStart),
                Self.bipPacked.contains(Self.pack(lower[wordStart..<k]))
            {
                bip += 1
                run += 1
                bestRun = Swift.max(bestRun, runBeforeOther + run)
                lastWasOther = false
            } else {
                runBeforeOther = lastWasOther ? 0 : run
                run = 0
                lastWasOther = true
            }
            wordStart = -1
        }
        for k in 0..<length {
            let c = units[k]
            if c >= 0x80 {
                nonASCII = true
            } else {
                lower[k] = c >= 0x41 && c <= 0x5A ? UInt8(c + 0x20) : UInt8(c)
            }
            if c >= 0x30 && c <= 0x39 {
                digits += 1
                digitRun += 1
                longestDigitRun = Swift.max(longestDigitRun, digitRun)
            } else {
                digitRun = 0
            }
            if c == 0x3A { colons += 1 }
            let isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            if isLetter {
                if wordStart < 0 { wordStart = k }
            } else {
                endWord(k)
            }
            if c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D {
                if token >= 15 { longTokens.append(NSRange(location: k - token, length: token)) }
                token = 0
            } else {
                token += 1
                longest = Swift.max(longest, token)
            }
        }
        endWord(length)
        if token >= 15 { longTokens.append(NSRange(location: length - token, length: token)) }
        self.digits = digits
        self.bipWords = bip
        self.bipRun = bestRun
        self.longestToken = longest
        self.longTokens = longTokens
        self.nonASCII = nonASCII
        self.colons = colons
        self.longestDigitRun = longestDigitRun
        self.lower = lower
    }

    /// True when the text holds `needle` (lower-case ASCII), in any case.
    func has(_ needle: StaticString) -> Bool {
        if open { return true }
        let count = needle.utf8CodeUnitCount
        guard count > 0, count <= lower.count else { return false }
        return lower.withUnsafeBytes { hay in
            memmem(hay.baseAddress, hay.count, needle.utf8Start, count) != nil
        }
    }

    func hasAny(_ needles: [StaticString]) -> Bool { needles.contains { has($0) } }
}

/// The per-message rules. A scan runs on one normalized body. `context` is the
/// message before it, so a keyword asked there ("what's your SSN?") counts here.
struct DetectorScan {
    let ns: NSString
    let context: NSString?
    let enabled: Set<SecretCategory>
    private(set) var hits: [(range: NSRange, category: SecretCategory)] = []

    private let profile: TextProfile
    private let contextProfile: TextProfile?

    init(
        _ ns: NSString, context: NSString?, enabled: Set<SecretCategory>,
        profile: TextProfile? = nil, contextProfile: TextProfile? = nil
    ) {
        self.ns = ns
        self.context = context
        self.enabled = enabled
        self.profile = profile ?? TextProfile(ns)
        self.contextProfile =
            context == nil ? nil : (contextProfile ?? context.map { TextProfile($0) })
    }

    /// True when this message or the one before holds one of `needles`.
    private func hereOrBefore(_ needles: [StaticString]) -> Bool {
        profile.hasAny(needles) || (contextProfile?.hasAny(needles) ?? false)
    }

    mutating func run() {
        let p = profile
        if enabled.contains(.creditCard), p.digits >= 12 { cards() }
        if enabled.contains(.ssn), p.digits >= 9 { ssns() }
        if enabled.contains(.bankAccount), p.digits >= 6 { bank() }
        if enabled.contains(.idNumber), p.digits >= 4 { ids() }
        if enabled.contains(.password) { passwords() }
        if enabled.contains(.apiKey), p.longestToken >= 12 || p.has("-----begin") { keys() }
        if enabled.contains(.recoveryKey),
            p.digits >= 4 || p.longestToken >= 16 || (p.digits >= 1 && hereOrBefore(Self.totpWords))
        {
            recoveryKeys()
        }
        if enabled.contains(.seedPhrase), p.bipRun >= 10 { seeds() }
        if enabled.contains(.standingCode), p.digits >= 3 { codes() }
    }

    private mutating func add(_ r: NSRange, _ category: SecretCategory) {
        guard r.location != NSNotFound, r.length > 0 else { return }
        hits.append((r, category))
    }

    private func keywordNear(_ r: NSRange, _ keyword: NSRegularExpression, within: Int) -> Bool {
        if isNear(r, keyword.spans(in: ns), within: within) { return true }
        if let context, keyword.found(in: context) { return true }
        return false
    }

    private func keywordInMessage(_ keyword: NSRegularExpression) -> Bool {
        keyword.found(in: ns) || (context.map { keyword.found(in: $0) } ?? false)
    }

    private func text(_ r: NSRange) -> String { ns.substring(with: r) }

    private func digitsOf(_ r: NSRange) -> [Int] {
        text(r).unicodeScalars.compactMap { s in
            s.value >= 0x30 && s.value <= 0x39 ? Int(s.value - 0x30) : nil
        }
    }

    // MARK: - Cards (Luhn, issuer prefix and length, card-like grouping)

    static let cardCandidate = regex(#"(?<![0-9])[0-9](?:[ \t.\-\n]?[0-9]){11,40}(?![0-9])"#)
    static let urlRegex = regex(#"https?://\S+|\bwww\.\S+"#)
    static let cardLabel = regex(#"(?i)(?:cc|card|visa|amex|mc|no)[#:.]?$"#)

    private mutating func cards() {
        let candidates = Self.cardCandidate.all(in: ns)
        guard !candidates.isEmpty else { return }
        let urls = profile.hasAny(["://", "www."]) ? Self.urlRegex.spans(in: ns) : []
        for m in candidates {
            let r = m.range
            if urls.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
            if r.location > 0 {
                let c = ns.character(at: r.location - 1)
                if c == 0x3D || c == 0x2F { continue }  // = /
                if Self.isASCIILetter(c) {
                    let lo = Swift.max(0, r.location - 6)
                    let before = ns.substring(with: NSRange(location: lo, length: r.location - lo))
                    if !Self.cardLabel.found(in: before as NSString) { continue }
                }
            }
            let end = r.location + r.length
            if end < ns.length {
                let c = ns.character(at: end)
                if Self.isASCIILetter(c) || c == 0x3D || c == 0x26 { continue }
            }
            for window in Self.cardWindows(ns, r) { add(window, .creditCard) }
        }
    }

    static func isASCIILetter(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    /// Windows of a digit run that start and end on group boundaries, keep the
    /// card grouping (every group but the last has 4 or more digits), and pass Luhn
    /// and the issuer table. The longest one wins at each start.
    static func cardWindows(_ ns: NSString, _ r: NSRange) -> [NSRange] {
        var groups: [(start: Int, end: Int, digits: [Int])] = []
        var current: [Int] = []
        var groupStart = r.location
        for k in r.location..<(r.location + r.length) {
            let c = ns.character(at: k)
            if c >= 0x30 && c <= 0x39 {
                if current.isEmpty { groupStart = k }
                current.append(Int(c - 0x30))
            } else if !current.isEmpty {
                groups.append((groupStart, k, current))
                current = []
            }
        }
        if !current.isEmpty { groups.append((groupStart, r.location + r.length, current)) }
        var out: [NSRange] = []
        var g = 0
        while g < groups.count {
            var best: Int?
            var digits: [Int] = []
            for e in g..<groups.count {
                if e > g, groups[e - 1].digits.count < 4 { break }
                digits += groups[e].digits
                if digits.count > 19 { break }
                if digits.count >= 12, luhn(digits), issuerAccepts(digits) { best = e }
            }
            if let e = best {
                out.append(
                    NSRange(location: groups[g].start, length: groups[e].end - groups[g].start))
                g = e + 1
            } else {
                g += 1
            }
        }
        return out
    }

    static func luhn(_ d: [Int]) -> Bool {
        var sum = 0
        for (i, x) in d.reversed().enumerated() {
            if i % 2 == 1 {
                let v = x * 2
                sum += v > 9 ? v - 9 : v
            } else {
                sum += x
            }
        }
        return sum % 10 == 0
    }

    /// Issuer prefix and length table (Visa, Mastercard, Amex, Discover, JCB, Diners,
    /// UnionPay, Maestro, Mir, Troy).
    static func issuerAccepts(_ d: [Int]) -> Bool {
        let n = d.count
        let p2 = d[0] * 10 + d[1]
        let p3 = p2 * 10 + d[2]
        let p4 = p3 * 10 + d[3]
        if d[0] == 4 { return n == 13 || n == 16 || n == 19 }
        if (51...55).contains(p2) || (2221...2720).contains(p4) { return n == 16 }
        if p2 == 34 || p2 == 37 { return n == 15 }
        if p4 == 6011 || (644...649).contains(p3) || p2 == 65 { return (16...19).contains(n) }
        if (3528...3589).contains(p4) { return (16...19).contains(n) }
        if (300...305).contains(p3) || p4 == 3095 || p2 == 36 || p2 == 38 || p2 == 39 {
            return (14...19).contains(n)
        }
        if p2 == 62 || p2 == 81 { return (16...19).contains(n) }
        if [5018, 5020, 5038, 5893, 6304, 6759, 6761, 6762, 6763].contains(p4) {
            return (12...19).contains(n)
        }
        if (2200...2204).contains(p4) { return (16...19).contains(n) }
        if p4 == 9792 { return n == 16 }
        return false
    }

    // MARK: - SSN and ITIN

    static let ssnSeparated = regex(
        #"(?<![0-9\-.])([0-9]{3})[ ]?([\-.])[ ]?([0-9]{2})[ ]?\2[ ]?([0-9]{4})(?![0-9\-])"#)
    static let ssnSpaced = regex(#"(?<![0-9\-])([0-9]{3}) ([0-9]{2}) ([0-9]{4})(?![0-9\-])"#)
    static let ssnPlain = regex(#"(?<![0-9\-])([0-9]{3})([0-9]{2})([0-9]{4})(?![0-9\-])"#)
    static let ssnKeyword = regex(
        #"(?i)\bssn\b|\bss\s?#|\bsocial\b|\bsoc\.?\s?sec|\bitin\b|\btax\s?id\b|\btin\b"#)
    static let referenceBefore = regex(
        #"(?i)\b(?:part|sku|order|case|invoice|inv|ticket|model|serial|item|ref|reference|tracking|confirmation|claim|policy|po|lot|batch|docket|file|patent|version|build|account|acct)\b[^\n]{0,14}$"#
    )

    static func ssnShape(_ area: Int, _ group: Int, _ serial: Int) -> Bool {
        if group == 0 || serial == 0 || area == 0 || area == 666 { return false }
        if area >= 900 {
            return (50...65).contains(group) || (70...88).contains(group)
                || (90...92).contains(group) || (94...99).contains(group)
        }
        return true
    }

    private mutating func ssns() {
        func shape(_ m: NSTextCheckingResult, _ groups: [Int]) -> Bool {
            let parts = groups.map { Int(text(m.range(at: $0))) ?? 0 }
            return Self.ssnShape(parts[0], parts[1], parts[2])
        }
        for m in Self.ssnSeparated.all(in: ns) where shape(m, [1, 3, 4]) {
            if !keywordNear(m.range, Self.ssnKeyword, within: 40) {
                let before = ns.substring(to: m.range.location) as NSString
                if Self.referenceBefore.found(in: before) { continue }
            }
            add(m.range, .ssn)
        }
        guard hereOrBefore(["ss", "social", "soc", "itin", "tax", "tin"]) else { return }
        let keywordAnywhere = keywordInMessage(Self.ssnKeyword)
        for m in Self.ssnSpaced.all(in: ns) where keywordAnywhere && shape(m, [1, 2, 3]) {
            add(m.range, .ssn)
        }
        for m in Self.ssnPlain.all(in: ns) where shape(m, [1, 2, 3]) {
            if keywordNear(m.range, Self.ssnKeyword, within: 40) { add(m.range, .ssn) }
        }
    }

    // MARK: - Bank: IBAN, routing number, account number

    static let ibanCandidate = regex(
        #"(?i)(?<![A-Z0-9])[A-Z]{2}[0-9]{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,4})?(?![A-Z0-9])"#
    )
    static let ibanLengths: [String: Int] = [
        "AD": 24, "AE": 23, "AL": 28, "AT": 20, "AZ": 28, "BA": 20, "BE": 16, "BG": 22, "BH": 22,
        "BR": 29, "BY": 28, "CH": 21, "CR": 22, "CY": 28, "CZ": 24, "DE": 22, "DK": 18, "DO": 28,
        "EE": 20, "EG": 29, "ES": 24, "FI": 18, "FO": 18, "FR": 27, "GB": 22, "GE": 22, "GI": 23,
        "GL": 18, "GR": 27, "GT": 28, "HR": 21, "HU": 28, "IE": 22, "IL": 23, "IQ": 23, "IS": 26,
        "IT": 27, "JO": 30, "KW": 30, "KZ": 20, "LB": 28, "LC": 32, "LI": 21, "LT": 20, "LU": 20,
        "LV": 21, "LY": 25, "MC": 27, "MD": 24, "ME": 22, "MK": 19, "MR": 27, "MT": 31, "MU": 30,
        "NL": 18, "NO": 15, "PK": 24, "PL": 28, "PS": 29, "PT": 25, "QA": 29, "RO": 24, "RS": 22,
        "SA": 24, "SC": 31, "SD": 18, "SE": 24, "SI": 19, "SK": 24, "SM": 27, "SV": 28, "TL": 23,
        "TN": 24, "TR": 26, "UA": 29, "VA": 22, "VG": 24, "XK": 20,
    ]
    static let routingCandidate = regex(#"(?<![0-9])[0-9]{9}(?![0-9])"#)
    static let routingKeyword = regex(
        #"(?i)\b(?:routing|aba|rtn|r/t|rt|wire|transit|ach|bank)\b"#)
    static let accountNumber = regex(
        #"(?i)\b(?:bank\s+account|account|acct|acc|a/c|checking|savings|chequing)\.?(?:\s+(?:number|no\.?|num|#))?\s*(?:is\b|was\b|[:#=])?\s*#?\s*([0-9](?:[0-9 \-]{4,22})[0-9])(?![0-9])"#
    )
    static let sortCode = regex(
        #"(?i)\bsort\s*code\s*(?:is\b|[:=])?\s*([0-9]{2}[\- ]?[0-9]{2}[\- ]?[0-9]{2})(?![0-9])"#)

    private mutating func bank() {
        for m in Self.ibanCandidate.all(in: ns) {
            if let r = Self.validIBANPrefix(ns, m.range) { add(r, .bankAccount) }
        }
        for m in profile.digits >= 9 ? Self.routingCandidate.all(in: ns) : []
        where Self.abaValid(digitsOf(m.range)) {
            if keywordNear(m.range, Self.routingKeyword, within: 40) { add(m.range, .bankAccount) }
        }
        if profile.hasAny(["acc", "a/c", "checking", "savings", "chequing"]) {
            for m in Self.accountNumber.all(in: ns) {
                let v = m.range(at: 1)
                let n = digitsOf(v).count
                if (6...17).contains(n) { add(v, .bankAccount) }
            }
        }
        if profile.has("sort") {
            for m in Self.sortCode.all(in: ns) { add(m.range(at: 1), .bankAccount) }
        }
    }

    /// The longest prefix of a candidate that is a whole IBAN: known country length,
    /// mod-97, and one case (mixed case is base64, not an IBAN).
    static func validIBANPrefix(_ ns: NSString, _ r: NSRange) -> NSRange? {
        let raw = ns.substring(with: r) as NSString
        var length = raw.length
        while length >= 15 {
            let candidate = raw.substring(to: length)
            if !candidate.hasSuffix(" ") {
                let compact = candidate.replacingOccurrences(of: " ", with: "")
                let upper = compact.uppercased()
                let oneCase = compact == upper || compact == compact.lowercased()
                if oneCase, ibanLengths[String(upper.prefix(2))] == upper.count, mod97(upper) {
                    return NSRange(location: r.location, length: length)
                }
            }
            length -= 1
        }
        return nil
    }

    static func mod97(_ v: String) -> Bool {
        var rem = 0
        for ch in (v.dropFirst(4) + v.prefix(4)).unicodeScalars {
            let c = ch.value
            if c >= 0x30 && c <= 0x39 {
                rem = (rem * 10 + Int(c - 0x30)) % 97
            } else if c >= 0x41 && c <= 0x5A {
                rem = (rem * 100 + Int(c) - 55) % 97
            } else {
                return false
            }
        }
        return rem == 1
    }

    static func abaValid(_ d: [Int]) -> Bool {
        guard d.count == 9 else { return false }
        return (3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + d[2] + d[5] + d[8]) % 10
            == 0
    }

    // MARK: - ID numbers (passport, license, national and health IDs)

    static let passportWord =
        #"passports?|pasaporte|passeport|reisepass|passaporto|paspoort"#
    static let licenseWord =
        #"DL|driver'?s?\s+lic(?:en[cs]e)?\.?|driving\s+licen[cs]e|licen[cs]e|licencia(?:\s+de\s+conducir)?|permis\s+de\s+conduire|f[üu]hrerschein"#
    static let idNumberWord = #"number|no\.?|num|nr\.?|#|n[uú]mero|num[ée]ro|nummer"#
    /// Digits with up to two leading letters, a UK licence, 8 or 9 capitals and digits,
    /// or spaced digit groups. `idValueOK` checks the last two forms.
    static let idValue =
        #"([A-Z]{0,2}[0-9]{5,13}|[A-Z]{5}[0-9]{6}[A-Z0-9]{5}|[A-Z0-9]{8,9}|[0-9]{1,4}(?:[ \-][0-9]{2,4}){1,3})(?![A-Za-z0-9])"#
    static let idDocument = regex(
        #"(?i)(?<![A-Za-z])(?:"# + passportWord + "|" + licenseWord + #")(?![A-Za-z])(?:\s+(?:"#
            + idNumberWord + #"))?\s*(?:(?:is|es|est|ist|è)\b|[:#])?\s*#?\s*"# + idValue)
    static let idDocumentFiller = regex(
        #"(?i)(?<![A-Za-z])(?:"# + passportWord + "|" + licenseWord + #")\s+(?:"# + idNumberWord
            + #")(?:\s+[A-Za-z']+){1,4}?\s*:\s*#?\s*"# + idValue)
    static let passportKeyword = regex(#"(?i)(?<![A-Za-z])(?:"# + passportWord + #")(?![A-Za-z])"#)
    static let passportListValue = regex(
        #"(?<![A-Za-z0-9])(?:[A-Z]{1,2}[0-9]{7,8}|[0-9]{9})(?![A-Za-z0-9])"#)

    static func idValueOK(_ v: String) -> Bool {
        let digits = v.filter(\.isNumber).count
        if v.contains(" ") || v.contains("-") { return digits >= 7 }
        let letters = v.filter(\.isLetter)
        if letters.count > 2 || (letters.count > 0 && !(v.first?.isLetter ?? false)) {
            return v == v.uppercased() && digits >= 4 && (8...9).contains(v.count)
        }
        return digits >= 5
    }
    static let nineDigits = regex(#"(?<![0-9])([0-9]{3})([ \-]?)([0-9]{3})\2([0-9]{3})(?![0-9])"#)
    static let sinKeyword = regex(#"(?i)\b(?:SIN|NAS|social insurance)\b"#)
    static let tfnKeyword = regex(#"(?i)\b(?:tfn|tax file)\b"#)
    static let aadhaar = regex(#"(?<![0-9])[2-9][0-9]{3}([ \-]?)[0-9]{4}\1[0-9]{4}(?![0-9])"#)
    static let aadhaarKeyword = regex(#"(?i)\b(?:aadhaa?r|aadhar|uidai)\b"#)
    static let pan = regex(#"(?i)\b[A-Z]{3}[PCHFATBLJG][A-Z][0-9]{4}[A-Z]\b"#)
    static let panKeyword = regex(#"(?i)\bpan\b"#)
    static let cpfFormatted = regex(#"(?<![0-9])[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}(?![0-9])"#)
    static let cpfPlain = regex(#"(?<![0-9])[0-9]{11}(?![0-9])"#)
    static let cpfKeyword = regex(#"(?i)\bcpf\b"#)
    static let nir = regex(
        #"(?<![0-9])[12] ?[0-9]{2} ?[0-9]{2} ?(?:[0-9]{2}|2A|2B) ?[0-9]{3} ?[0-9]{3} ?[0-9]{2}(?![0-9])"#
    )
    static let dni = regex(#"(?i)\b([XYZ]?)([0-9]{7,8})[ \-]?([A-Z])\b"#)
    static let dniKeyword = regex(#"(?i)\b(?:dni|nie|nif)\b"#)
    static let codiceFiscale = regex(
        #"(?i)\b[A-Z]{6}[0-9]{2}[A-EHLMPR-T][0-9]{2}[A-Z][0-9]{3}[A-Z]\b"#)
    static let ukNI = regex(
        #"(?i)\b(?!BG|GB|NK|KN|TN|NT|ZZ)[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z] ?[0-9]{2} ?[0-9]{2} ?[0-9]{2} ?[A-D]\b"#
    )
    static let ukNIKeyword = regex(#"(?i)\b(?:NI|NINO|national insurance)\b"#)
    static let nhs = regex(#"(?<![0-9])[0-9]{3}([ \-]?)[0-9]{3}\1[0-9]{4}(?![0-9])"#)
    static let nhsKeyword = regex(#"(?i)\bnhs\b"#)
    static let mbi = regex(
        #"(?i)\b[1-9][AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y0-9][0-9]-?[AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y0-9][0-9]-?[AC-HJKMNP-RT-Y]{2}[0-9]{2}\b"#
    )
    static let mbiKeyword = regex(#"(?i)\b(?:medicare|mbi|beneficiary)\b"#)
    static let memberID = regex(
        #"(?i)\b(?:(?:member|subscriber|policy|insurance|medicaid|medicare|patient|health\s+plan|group)\s+(?:id|number|no\.?|#)|MRN|medical\s+record(?:\s+number)?)\s*(?:is\b|[:#])?\s*#?\s*([A-Z0-9][A-Z0-9\-]{5,19})\b"#
    )

    private mutating func ids() {
        let p = profile
        let passportWords: [StaticString] = [
            "passport", "pasaporte", "passeport", "reisepass", "passaporto", "paspoort",
        ]
        if p.hasAny(passportWords + ["dl", "driv", "licen", "permis", "hrerschein"]) {
            for rx in [Self.idDocument, Self.idDocumentFiller] {
                for m in rx.all(in: ns) where Self.idValueOK(text(m.range(at: 1))) {
                    add(m.range(at: 1), .idNumber)
                }
            }
        }
        if p.hasAny(passportWords), Self.passportKeyword.found(in: ns) {
            for m in Self.passportListValue.all(in: ns) { add(m.range, .idNumber) }
        }
        idNumbers()
    }

    private mutating func idNumbers() {
        let p = profile
        let nineDigits = p.digits >= 9 && hereOrBefore(["sin", "nas", "social", "tfn", "tax"])
        for m in nineDigits ? Self.nineDigits.all(in: ns) : [] {
            let d = digitsOf(m.range)
            if Self.luhn(d), keywordNear(m.range, Self.sinKeyword, within: 40) {
                add(m.range, .idNumber)
            }
            if Self.tfnValid(d), keywordNear(m.range, Self.tfnKeyword, within: 40) {
                add(m.range, .idNumber)
            }
        }
        if hereOrBefore(["aadha", "uidai"]), keywordInMessage(Self.aadhaarKeyword) {
            for m in Self.aadhaar.all(in: ns) where Self.verhoeff(digitsOf(m.range)) {
                add(m.range, .idNumber)
            }
        }
        for m in p.has("pan") ? Self.pan.all(in: ns) : [] {
            let v = text(m.range)
            if v == v.uppercased(), keywordNear(m.range, Self.panKeyword, within: 30) {
                add(m.range, .idNumber)
            }
        }
        if p.digits >= 11 {
            for m in Self.cpfFormatted.all(in: ns) where Self.cpfValid(digitsOf(m.range)) {
                add(m.range, .idNumber)
            }
        }
        if p.digits >= 11, hereOrBefore(["cpf"]) {
            for m in Self.cpfPlain.all(in: ns) where Self.cpfValid(digitsOf(m.range)) {
                if keywordNear(m.range, Self.cpfKeyword, within: 30) { add(m.range, .idNumber) }
            }
        }
        if p.digits >= 13 {
            for m in Self.nir.all(in: ns) where Self.nirValid(text(m.range)) {
                add(m.range, .idNumber)
            }
        }
        for m in hereOrBefore(["dni", "nie", "nif"]) ? Self.dni.all(in: ns) : [] {
            var number = text(m.range(at: 2))
            if let p = ["X": "0", "Y": "1", "Z": "2"][text(m.range(at: 1)).uppercased()] {
                number = p + number
            }
            let table = Array("TRWAGMYFPDXBNJZSQVHLCKE")
            guard let n = Int(number), String(table[n % 23]) == text(m.range(at: 3)).uppercased()
            else { continue }
            if keywordNear(m.range, Self.dniKeyword, within: 30) { add(m.range, .idNumber) }
        }
        if p.longestToken >= 16 {
            for m in Self.codiceFiscale.all(in: ns) where Self.codiceFiscaleValid(text(m.range)) {
                add(m.range, .idNumber)
            }
        }
        if hereOrBefore(["ni", "national insurance"]) {
            for m in Self.ukNI.all(in: ns) where keywordNear(m.range, Self.ukNIKeyword, within: 30)
            {
                add(m.range, .idNumber)
            }
        }
        if p.digits >= 10, hereOrBefore(["nhs"]) {
            for m in Self.nhs.all(in: ns) where Self.nhsValid(digitsOf(m.range)) {
                if keywordNear(m.range, Self.nhsKeyword, within: 30) { add(m.range, .idNumber) }
            }
        }
        if hereOrBefore(["medicare", "mbi", "beneficiary"]) {
            for m in Self.mbi.all(in: ns) where keywordNear(m.range, Self.mbiKeyword, within: 40) {
                add(m.range, .idNumber)
            }
        }
        let memberWords: [StaticString] = [
            "member", "subscriber", "policy", "insurance", "medicaid", "medicare", "patient",
            "health",
            "group", "mrn", "medical",
        ]
        if p.hasAny(memberWords) {
            for m in Self.memberID.all(in: ns) {
                let v = m.range(at: 1)
                if digitsOf(v).count >= 4 { add(v, .idNumber) }
            }
        }
    }

    static func tfnValid(_ d: [Int]) -> Bool {
        guard d.count == 9 else { return false }
        return zip(d, [1, 4, 3, 7, 5, 8, 6, 9, 10]).map(*).reduce(0, +) % 11 == 0
    }

    static func cpfValid(_ n: [Int]) -> Bool {
        guard n.count == 11, Set(n).count > 1 else { return false }
        let s1 = zip(n[0..<9], (2...10).reversed()).map(*).reduce(0, +)
        let s2 = zip(n[0..<10], (2...11).reversed()).map(*).reduce(0, +)
        return (s1 * 10 % 11) % 10 == n[9] && (s2 * 10 % 11) % 10 == n[10]
    }

    static func nirValid(_ raw: String) -> Bool {
        let d = raw.replacingOccurrences(of: " ", with: "").uppercased()
            .replacingOccurrences(of: "2A", with: "19").replacingOccurrences(of: "2B", with: "18")
        guard d.count == 15, let body = Int(d.prefix(13)), let key = Int(d.suffix(2)) else {
            return false
        }
        return 97 - body % 97 == key
    }

    static func nhsValid(_ n: [Int]) -> Bool {
        guard n.count == 10 else { return false }
        let s = zip(n[0..<9], (2...10).reversed()).map(*).reduce(0, +)
        let c = 11 - s % 11
        return c != 10 && (c == 11 ? 0 : c) == n[9]
    }

    private static let verhoeffD: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 2, 3, 4, 0, 6, 7, 8, 9, 5],
        [2, 3, 4, 0, 1, 7, 8, 9, 5, 6], [3, 4, 0, 1, 2, 8, 9, 5, 6, 7],
        [4, 0, 1, 2, 3, 9, 5, 6, 7, 8], [5, 9, 8, 7, 6, 0, 4, 3, 2, 1],
        [6, 5, 9, 8, 7, 1, 0, 4, 3, 2], [7, 6, 5, 9, 8, 2, 1, 0, 4, 3],
        [8, 7, 6, 5, 9, 3, 2, 1, 0, 4], [9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
    ]
    private static let verhoeffP: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 5, 7, 6, 2, 8, 3, 0, 9, 4],
        [5, 8, 0, 3, 7, 9, 6, 1, 4, 2], [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
        [9, 4, 5, 3, 1, 2, 6, 8, 7, 0], [4, 2, 8, 6, 5, 7, 3, 9, 0, 1],
        [2, 7, 9, 3, 8, 0, 6, 4, 1, 5], [7, 0, 4, 6, 9, 1, 3, 2, 5, 8],
    ]

    static func verhoeff(_ d: [Int]) -> Bool {
        var c = 0
        for (i, x) in d.reversed().enumerated() { c = verhoeffD[c][verhoeffP[i % 8][x]] }
        return c == 0
    }

    static func codiceFiscaleValid(_ raw: String) -> Bool {
        let s = Array(raw.uppercased().unicodeScalars.map { Int($0.value) })
        guard s.count == 16 else { return false }
        let odd = [
            1, 0, 5, 7, 9, 13, 15, 17, 19, 21, 2, 4, 18, 20, 11, 3, 6, 8, 12, 14, 16, 10, 22, 25,
            24, 23,
        ]
        var sum = 0
        for i in 0..<15 {
            let v = s[i] >= 0x41 ? s[i] - 0x41 : s[i] - 0x30
            sum += i % 2 == 0 ? odd[v] : v
        }
        return s[15] - 0x41 == sum % 26
    }

    // MARK: - Passwords

    static let strongTrigger =
        #"passwords?|passwort|passwd|passcode|passphrase|passwrod|pasword|passowrd|paswd|pword|wifi\s+key|wi-fi\s+key|wpa2?\s+key|network\s+key"#
    static let weakTrigger = #"pwd|pw|p/w|pass"#
    static let triggerRegex = regex(
        #"(?i)(?<![A-Za-z])("# + strongTrigger + "|" + weakTrigger + #")(?![A-Za-z])"#)
    static let wifiQR = regex(#"WIFI:[^\n]*?\bP:((?:\\.|[^;\\\n])+);"#)
    static let urlUserinfo = regex(#"(?i)\b[a-z][a-z0-9+.\-]*://[^\s/:@]+:([^\s/@]+)@"#)
    static let urlPasswordParameter = regex(#"(?i)[?&](?:pwd|password|passwd|pass)=([^&\s#]{4,})"#)
    static let valueFirst = regex(
        #"(?i)(?<!\S)(\S{4,64})\s+(?:is|was)\s+(?:the|my|our|your|his|her|their)\s+(?:new\s+)?(?:[\w-]+\s+)?(?:password|passcode|pw)\b"#
    )
    static let userSlashPassword = regex(
        #"(?i)\b(?:login|log\s?in|user(?:name)?|creds|credentials|account|acct)\b[^\n/]{0,40}?\S\s+/\s+(\S{4,64})"#
    )
    static let curlUser = regex(#"(?:^|\s)(?:-u|--user)\s+['"]?[^\s:'"]+:([^\s'"]+)"#)
    static let pgpass = regex(#"(?m)^[A-Za-z0-9.\-*]+:(?:[0-9]{2,5}|\*):[^:\s]+:[^:\s]+:(\S+)$"#)
    static let i18nPassword = regex(
        #"(?i)(contrase(?:ñ|n)a|clave|mot\s+de\s+passe|\bmdp\b|kennwort|senha|wachtwoord|parola\s+d'ordine|пароль)((?:\s+[\p{L}\-]{1,12}){0,2}?)\s*(?:[:=：]|\s(?:es|est|ist|é|è|is|lautet|era|был)\b|\s[-–—]\s)\s*([^\s"'“”]{3,64})"#
    )
    static let cjkPassword = regex(
        #"(?:パスワード|密码|密碼|비밀번호|暗証番号)\s*(?:は|是|为|:|：|는|은)?\s*([A-Za-z0-9!@#$%^&*._\-+=?]{4,64})"#)

    /// Words that follow "password is" in prose but are not a password.
    static let notAValue: Set<String> = [
        "a", "an", "the", "in", "on", "at", "to", "for", "of", "with", "from", "by", "about", "as",
        "into", "like", "after", "over", "under", "before", "below", "above", "behind", "inside",
        "i", "me", "my", "mine", "you", "your", "yours", "he", "him", "his", "she", "her", "hers",
        "it", "its", "it's", "we", "us", "our", "they", "them", "their", "this", "that", "these",
        "those", "what", "which", "who", "where", "when", "why", "how", "is", "are", "was",
        "were", "be", "been", "being", "am", "have", "has", "had", "do", "does", "did", "will",
        "would", "should", "can", "could", "may", "might", "must", "not", "no", "yes", "still",
        "just", "also", "too", "very", "really", "so", "now", "then", "here", "there", "already",
        "always", "never", "again", "only", "even", "same", "different", "wrong", "right",
        "correct", "incorrect", "invalid", "valid", "new", "old", "weak", "strong", "easy",
        "hard", "simple", "long", "short", "good", "bad", "fine", "ok", "okay", "blank", "empty",
        "none", "nothing", "something", "anything", "everything", "missing", "gone", "case",
        "sensitive", "case-sensitive", "required", "needed", "optional", "attached", "somewhere",
        "please", "thanks", "and", "or", "but", "if", "because", "since", "unless", "reset",
        "changed", "expired", "updated", "saved", "stored", "written", "taped", "sent", "shown",
        "hidden", "typed", "entered", "visible", "encrypted", "protected", "locked", "unlocked",
        "set", "taken", "used", "known", "forgotten", "lost", "shared", "printed", "listed",
        "posted", "included", "managed", "generated", "specified", "hashed", "unknown",
        "1password", "lastpass", "bitwarden", "keychain", "dashlane", "keeper", "manager",
        "password", "passwords", "secret", "pass", "passwd", "pwd", "pw", "xxx", "xxxx", "****",
        "<password>", "$password", "changeme", "placeholder", "redacted", "[redacted]", "hint",
        "field", "box", "prompt", "screen", "page", "link", "email", "text", "app", "below:",
        "too", "either", "both", "all", "any", "some", "more", "less", "most", "least",
    ]

    /// A word after the trigger that makes the phrase about the password, not its value.
    static let aboutPassword: Set<String> = [
        "hint", "hints", "manager", "managers", "policy", "policies", "rule", "rules",
        "requirement", "requirements", "strength", "field", "prompt", "screen", "page", "reset",
        "resets", "change", "changes", "expiry", "expiration", "length", "protected",
    ]

    static let fillerAfterValue: Set<String> = [
        "and", "but", "so", "then", "thanks", "thx", "ty", "lol", "ok", "okay", "please", "if",
        "for", "the", "to", "on", "at", "in", "it", "is", "was", "you", "i", "we", "btw", "haha",
        "with", "from", "or", "when", "let", "just",
    ]

    static func plainValue(_ v: String) -> String {
        v.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}>\"'”’`"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "([{<\"'“‘`")).lowercased()
    }

    /// A value with evidence of being a secret: a digit and a letter, a symbol with a
    /// digit or with both cases, or a capital letter after the first character. A path,
    /// a flag, a URL, or a placeholder is not one.
    static func plausibleSecret(_ v: String) -> Bool {
        let core = v.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]\"'”’"))
        guard core.count >= 4, !notAValue.contains(core.lowercased()) else { return false }
        if let first = core.first, "/~-<[{$%(".contains(first) || first.isCurrencySymbol {
            return false
        }
        if core.allSatisfy({ $0.isNumber || ",.%".contains($0) || $0.isCurrencySymbol }) {
            return false
        }
        if core.contains("://") || core.hasPrefix("www.") { return false }
        let hasDigit = core.contains { $0.isNumber }
        let hasLetter = core.contains { $0.isLetter }
        let hasSymbol = core.contains { !$0.isLetter && !$0.isNumber }
        let innerUpper = core.dropFirst().contains { $0.isUppercase }
        let hasLower = core.contains { $0.isLowercase }
        let hasUpper = core.contains { $0.isUppercase }
        return (hasDigit && hasLetter) || (hasSymbol && hasDigit)
            || (hasSymbol && hasUpper && hasLower) || (innerUpper && hasLower)
    }

    private mutating func passwords() {
        let p = profile
        let named = p.hasAny(["pas", "pw", "p/w"])
        if named || p.has("key") {
            for m in Self.triggerRegex.all(in: ns) { passwordAfter(trigger: m.range) }
        }
        if p.has("wifi:") {
            for m in Self.wifiQR.all(in: ns) { add(m.range(at: 1), .password) }
        }
        let shaped: [(NSRegularExpression, Bool)] = [
            (Self.urlUserinfo, p.has("://") && p.has("@")),
            (Self.urlPasswordParameter, p.has("=") && p.hasAny(["pass", "pwd"])),
            (Self.curlUser, p.has("-u")), (Self.pgpass, p.colons >= 4),
        ]
        for (rx, gate) in shaped where gate {
            for m in rx.all(in: ns)
            where !Self.notAValue.contains(Self.plainValue(text(m.range(at: 1)))) {
                add(m.range(at: 1), .password)
            }
        }
        if named {
            for m in Self.valueFirst.all(in: ns) where Self.plausibleSecret(text(m.range(at: 1))) {
                add(m.range(at: 1), .password)
            }
        }
        if p.has("/") {
            for m in Self.userSlashPassword.all(in: ns)
            where Self.plausibleSecret(text(m.range(at: 1))) {
                add(m.range(at: 1), .password)
            }
        }
        let i18n: [StaticString] = [
            "contrase", "clave", "passe", "mdp", "kennwort", "senha", "wachtwoord", "parola",
        ]
        if p.hasAny(i18n)
            || (p.nonASCII && ns.range(of: "пароль", options: .caseInsensitive).length > 0)
        {
            i18nPasswords()
        }
        for m in p.nonASCII ? Self.cjkPassword.all(in: ns) : []
        where !Self.notAValue.contains(Self.plainValue(text(m.range(at: 1)))) {
            add(m.range(at: 1), .password)
        }
    }

    private mutating func i18nPasswords() {
        for m in Self.i18nPassword.all(in: ns) {
            let value = text(m.range(at: 3))
            let loose = m.range(at: 2).length > 0 || text(m.range(at: 1)).lowercased() == "clave"
            if loose
                ? Self.plausibleSecret(value) : !Self.notAValue.contains(Self.plainValue(value))
            {
                add(m.range(at: 3), .password)
            }
        }
    }

    /// The value after one trigger word: a quoted value, a value after a separator
    /// (`is`, `was`, `:`, `=`, `'s`, a spaced dash, or a line break), or a value with
    /// no separator when it looks like a secret. Up to four words may sit between the
    /// trigger and the separator ("password for the wifi is ..."). After a weak
    /// trigger (`pw`, `pass`) the value must always look like a secret.
    private mutating func passwordAfter(trigger: NSRange) {
        let weak = ["pwd", "pw", "p/w", "pass"].contains(text(trigger).lowercased())
        let length = ns.length
        var k = trigger.location + trigger.length
        func skip(newlines: Bool) {
            while k < length {
                let c = ns.character(at: k)
                guard c == 0x20 || c == 0x09 || (newlines && (c == 0x0A || c == 0x0D)) else {
                    return
                }
                k += 1
            }
        }
        func word(at i: Int) -> NSRange {
            var e = i
            while e < length, !Self.isSpaceOrBreak(ns.character(at: e)) { e += 1 }
            return NSRange(location: i, length: e - i)
        }
        if k + 1 < length, [0x27, 0x2019].contains(ns.character(at: k)),
            [0x73, 0x53].contains(ns.character(at: k + 1)),
            k + 2 >= length || Self.isSpaceOrBreak(ns.character(at: k + 2))
        {
            k += 2
            skip(newlines: false)
            takeValue(at: k, strict: weak)
            return
        }
        skip(newlines: false)
        guard k < length else { return }
        if [0x0A, 0x0D].contains(ns.character(at: k)) {
            skip(newlines: true)
            let w = word(at: k)
            if w.length > 0, Self.isWholeLine(ns, w) { takeValue(at: k, strict: weak) }
            return
        }
        var fillers = 0
        while k < length {
            skip(newlines: false)
            guard k < length else { return }
            let c = ns.character(at: k)
            if c == 0x3A || c == 0x3D || c == 0xFF1A {
                k += 1
                skip(newlines: true)
                takeValue(at: k, strict: weak)
                return
            }
            if Self.isQuote(c) {
                // A quote glued to the keyword closes a quoted keyword (`url.password`).
                if k > trigger.location + trigger.length { takeValue(at: k, strict: false) }
                return
            }
            if [0x2D, 0x2013, 0x2014].contains(c), k + 1 < length,
                [0x20, 0x09].contains(ns.character(at: k + 1))
            {
                k += 1
                skip(newlines: false)
                takeValue(at: k, strict: weak)
                return
            }
            let w = word(at: k)
            guard w.length > 0 else { return }
            let lowered = text(w).lowercased()
            if lowered == "is" || lowered == "was" {
                k += w.length
                skip(newlines: false)
                if k < length, [0x3A, 0x3D].contains(ns.character(at: k)) {
                    k += 1
                    skip(newlines: false)
                }
                takeValue(at: k, strict: weak)
                return
            }
            if fillers == 0, Self.plausibleSecret(text(w)) {
                add(w, .password)
                return
            }
            guard fillers < 4, lowered.count <= 12,
                lowered.allSatisfy({ $0.isLetter || $0 == "-" }),
                !Self.aboutPassword.contains(lowered)
            else { return }
            fillers += 1
            k += w.length
        }
    }

    static func isWholeLine(_ ns: NSString, _ r: NSRange) -> Bool {
        let end = r.location + r.length
        return end >= ns.length || [0x0A, 0x0D].contains(ns.character(at: end))
    }

    static func isQuote(_ c: unichar) -> Bool {
        [0x22, 0x27, 0x60, 0x201C, 0x201D, 0x2018, 0x2019].contains(c)
    }

    /// Take the value at `k`. A quoted value runs to its closing quote. A bare value runs
    /// to white space; when one or two more words end the line, they are covered too
    /// (an unquoted value with spaces). `strict` asks for a value that looks like a secret.
    private mutating func takeValue(at k: Int, strict: Bool) {
        guard k < ns.length else { return }
        if Self.isQuote(ns.character(at: k)) {
            let v = SecretDetector.quotedValue(ns, openingQuoteAt: k)
            if v.length > 0, !Self.notAValue.contains(Self.plainValue(text(v))) {
                add(v, .password)
            }
            return
        }
        var end = k
        while end < ns.length, !Self.isSpaceOrBreak(ns.character(at: end)) { end += 1 }
        guard end > k else { return }
        let value = text(NSRange(location: k, length: end - k))
        let plain = Self.plainValue(value)
        guard !plain.isEmpty, !Self.notAValue.contains(plain) else { return }
        if strict, !Self.plausibleSecret(value) { return }
        if plain.count < 3, !value.contains(where: \.isNumber) { return }
        var lineEnd = end
        while lineEnd < ns.length, ![0x0A, 0x0D].contains(ns.character(at: lineEnd)) {
            lineEnd += 1
        }
        let rest = text(NSRange(location: end, length: lineEnd - end))
        let more = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let endsSentence = [".", "!", "?", ","].contains { value.hasSuffix($0) }
        if !endsSentence, (1...2).contains(more.count), !rest.hasPrefix("  "),
            !more.contains(where: {
                Self.fillerAfterValue.contains(Self.plainValue($0))
                    || Self.notAValue.contains(Self.plainValue($0)) || $0.count > 24
            })
        {
            let trimmed = rest.trimmingCharacters(in: .whitespaces) as NSString
            let restStart = (rest as NSString).range(of: more[0]).location
            add(NSRange(location: k, length: end - k + restStart + trimmed.length), .password)
            return
        }
        add(NSRange(location: k, length: end - k), .password)
    }

    static func isSpaceOrBreak(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    // MARK: - API keys, tokens, and private keys

    static let vendorKeyPatterns: [String] = [
        #"\bsk-(?:proj|svcacct|admin|None)-[A-Za-z0-9_\-]{20,}"#,
        #"\bsk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}\b"#,
        #"\bsk-[A-Za-z0-9]{48}\b"#,
        #"\bsk-ant-[a-z]{3,6}[0-9]{2}-[A-Za-z0-9_\-]{20,}"#,
        #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[0-9A-Z]{16}\b"#,
        #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b"#,
        #"\bgithub_pat_[A-Za-z0-9_]{22,}\b"#,
        #"\bglpat-[A-Za-z0-9_\-]{20,}\b"#,
        #"\bnpm_[A-Za-z0-9]{36}\b"#,
        #"\bhf_[A-Za-z0-9]{30,}\b"#,
        #"\bSG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}\b"#,
        #"\bSK[0-9a-fA-F]{32}\b"#,
        #"\bAIza[0-9A-Za-z_\-]{35}\b"#,
        #"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}\b"#,
        #"\bwhsec_[A-Za-z0-9]{20,}\b"#,
        #"\bxox[abposre]-[A-Za-z0-9\-]{10,}"#,
        #"\bxapp-[0-9]-[A-Za-z0-9\-]{10,}"#,
        #"https://hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9/_+\-]+"#,
        #"https://(?:canary\.|ptb\.)?discord(?:app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_\-]+"#,
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#,
        #"\bkey-[0-9a-f]{32}\b"#,
        #"\bdo[por]_v1_[a-f0-9]{64}\b"#,
        #"\bshp(?:at|ca|pa|ss)_[a-fA-F0-9]{32}\b"#,
        #"\bsq0(?:atp|csp)-[0-9A-Za-z\-_]{22,43}\b"#,
        #"\bATATT[A-Za-z0-9_\-=]{50,}\b"#,
        #"\blin_api_[A-Za-z0-9]{40}\b"#,
        #"\b(?:ntn_[A-Za-z0-9]{40,}|secret_[A-Za-z0-9]{43})\b"#,
        #"\b[0-9]{8,10}:AA[A-Za-z0-9_\-]{33}\b"#,
        #"\bPMAK-[a-f0-9]{24}-[a-f0-9]{34}\b"#,
        #"\bsbp_[a-f0-9]{40}\b"#,
        #"\bdp\.(?:pt|st|sa|ct)\.[A-Za-z0-9]{40,}\b"#,
        #"\bpul-[a-f0-9]{40}\b"#,
        #"\bgsk_[A-Za-z0-9]{48,}\b"#,
        #"\br8_[A-Za-z0-9]{37}\b"#,
        #"\bpplx-[A-Za-z0-9]{48}\b"#,
        #"\bxai-[A-Za-z0-9]{70,}\b"#,
        #"\bya29\.[A-Za-z0-9_\-]{20,}"#,
        #"\bGOCSPX-[A-Za-z0-9_\-]{28}\b"#,
        #"\bAccountKey=[A-Za-z0-9+/]{86}=="#,
        #"\b[xyztuv]prv[1-9A-HJ-NP-Za-km-z]{100,112}\b"#,
        #"https://(?:share\.1password\.com/s#|send\.bitwarden\.com/#/)\S+"#,
    ]
    /// One pass for every vendor format (each is at least 15 characters).
    static let vendorKey = regex(vendorKeyPatterns.map { "(?:\($0))" }.joined(separator: "|"))
    static let awsSecret = regex(#"(?<![A-Za-z0-9/+=])[A-Za-z0-9/+]{40}(?![A-Za-z0-9/+=])"#)
    static let awsKeyword = regex(#"(?i)aws|secret"#)
    static let bearer = regex(#"(?i)\bBearer\s+([A-Za-z0-9\-._~+/]{16,}=*)"#)
    static let basicAuth = regex(#"(?i)\bBasic\s+([A-Za-z0-9+/]{8,}={0,2})(?![A-Za-z0-9+/=])"#)
    static let namedSecret = regex(
        #"(?i)(?<![A-Za-z0-9])(?:[A-Z0-9]+[_\-])*(?:SECRET|TOKEN|API[_\-]?KEY|APIKEY|ACCESS[_\-]?KEY|PRIVATE[_\-]?KEY|AUTH|CREDENTIALS?|CLIENT[_\-]?SECRET|SIGNING[_\-]?KEY|ENCRYPTION[_\-]?KEY)(?:[_\-][A-Z0-9]+)*\s*[:=]\s*["']?([^\s"',;]{8,})"#
    )
    static let namedSecretWords = regex(
        #"(?i)\b(?:api\s+key|access\s+token|auth\s+token|secret\s+key|client\s+secret|bot\s+token|private\s+key|token|secret)\s+(?:is|=|:)\s*["']?([A-Za-z0-9_\-+/=.]{16,})"#
    )
    static let namedSecretBare = regex(
        #"(?i)\b(?:api\s+key|access\s+token|auth\s+token|secret\s+key|client\s+secret|bot\s+token|token|secret|key)\s+([A-Za-z0-9_\-+/=.]{20,})(?![A-Za-z0-9_\-+/=.])"#
    )
    static let urlSecretParameter = regex(
        #"(?i)[?&#](?:token|access_token|refresh_token|id_token|api_?key|apikey|key|sig|signature|x-amz-signature|x-amz-credential|x-amz-security-token|x-goog-signature|secret|client_secret|auth|code|session|sid|otp)=([^&\s#]{8,})"#
    )
    static let hex64 = regex(#"(?<![0-9a-fA-Fx:])(?:0x)?[0-9a-fA-F]{64}(?![0-9a-fA-F])"#)
    static let hexKeyword = regex(#"(?i)priv|private|secret|wallet|\bkey\b"#)
    static let wif = regex(#"\b[5KLc9][1-9A-HJ-NP-Za-km-z]{50,51}\b"#)
    static let byteArray = regex(#"\[\s*[0-9]{1,3}(?:\s*,\s*[0-9]{1,3}){31,63}\s*\]"#)
    static let byteArrayKeyword = regex(
        #"(?i)priv|private|secret|wallet|key|solana|phantom|keypair"#)
    static let cookieHeader = regex(#"(?i)\b(?:set-)?cookie:\s*(\S[^\n]{8,})"#)
    static let authorization = regex(
        #"(?i)\bauthorization:\s*(?:token\s+)?([A-Za-z0-9\-._~+/]{16,}=*)"#)

    private mutating func keys() {
        let p = profile
        for token in p.longTokens {
            for m in Self.vendorKey.all(in: ns, range: token) { add(m.range, .apiKey) }
        }
        let awsNear =
            p.longestToken >= 40 && p.hasAny(["aws", "secret"]) ? Self.awsKeyword.spans(in: ns) : []
        if !awsNear.isEmpty {
            for m in Self.awsSecret.all(in: ns) {
                let v = text(m.range)
                if v.contains(where: \.isUppercase), v.contains(where: \.isLowercase),
                    isNear(m.range, awsNear, within: 60)
                {
                    add(m.range, .apiKey)
                }
            }
        }
        let shaped: [(NSRegularExpression, Bool)] = [
            (Self.bearer, p.has("bearer")), (Self.authorization, p.has("authorization")),
            (Self.urlSecretParameter, p.has("=")),
        ]
        for (rx, gate) in shaped where gate {
            for m in rx.all(in: ns) { add(m.range(at: 1), .apiKey) }
        }
        let named = p.hasAny(["secret", "token", "key", "auth", "credential"])
        for rx in named ? [Self.namedSecret, Self.namedSecretWords] : [] {
            for m in rx.all(in: ns) {
                let v = text(m.range(at: 1))
                let mixed = v.contains(where: \.isNumber) && v.contains(where: \.isLetter)
                if mixed || v.count >= 24, !Self.notAValue.contains(Self.plainValue(v)) {
                    add(m.range(at: 1), .apiKey)
                }
            }
        }
        for m in named && p.longestToken >= 20 ? Self.namedSecretBare.all(in: ns) : [] {
            let v = text(m.range(at: 1))
            if v.contains(where: \.isUppercase), v.contains(where: \.isLowercase),
                v.contains(where: \.isNumber)
            {
                add(m.range(at: 1), .apiKey)
            }
        }
        for m in p.has("basic") ? Self.basicAuth.all(in: ns) : [] {
            let v = text(m.range(at: 1))
            if let d = Data(base64Encoded: v), let t = String(data: d, encoding: .utf8),
                t.contains(":")
            {
                add(m.range(at: 1), .apiKey)
            }
        }
        if p.longestToken >= 64, p.hasAny(["priv", "secret", "wallet", "key"]) {
            let hexNear = Self.hexKeyword.spans(in: ns)
            for m in Self.hex64.all(in: ns) where isNear(m.range, hexNear, within: 40) {
                add(m.range, .apiKey)
            }
        }
        for m in p.longestToken >= 51 ? Self.wif.all(in: ns) : []
        where SecretDetector.base58Check(text(m.range)) {
            add(m.range, .apiKey)
        }
        for m in p.digits >= 32 && p.has("[") ? Self.byteArray.all(in: ns) : [] {
            let values = text(m.range).split { !$0.isNumber }.compactMap { Int($0) }
            guard values.allSatisfy({ $0 <= 255 }) else { continue }
            if values.count == 64 || keywordNear(m.range, Self.byteArrayKeyword, within: 60) {
                add(m.range, .apiKey)
            }
        }
        for m in p.has("cookie:") ? Self.cookieHeader.all(in: ns) : [] {
            add(m.range(at: 1), .apiKey)
        }
        if p.has("-----begin") {
            for block in SecretDetector.privateKeyBlocks(ns) { add(block.range, .apiKey) }
        }
    }

    // MARK: - Recovery keys, 2FA backup codes, TOTP secrets

    static let bitLocker = regex(#"(?<![0-9\-])[0-9]{6}(?:-[0-9]{6}){7}(?![0-9\-])"#)
    static let groupedKey = regex(
        #"(?i)(?<![A-Z0-9\-])[A-Z0-9]{4}(?:-[A-Z0-9]{4}){5,7}(?![A-Z0-9\-])"#)
    static let fiveByFive = regex(
        #"(?i)(?<![A-Z0-9\-])[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}(?![A-Z0-9\-])"#)
    static let onePasswordSecretKey = regex(
        #"(?i)\bA3-[A-Z0-9]{6}-(?:[A-Z0-9]{6}-)?[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}\b"#
    )
    static let digitGroups5x6 = regex(#"(?<![0-9])[0-9]{5}(?: [0-9]{5}){5}(?![0-9])"#)
    static let digitGroups4x16 = regex(#"(?<![0-9])[0-9]{4}(?: [0-9]{4}){15}(?![0-9])"#)
    static let recoveryKeyword = regex(
        #"(?i)recovery|filevault|bitlocker|apple\s?id|apple\s+account|backup|product\s+key|license\s+key|activation|\bkey\b"#
    )
    static let backupKeyword = regex(
        #"(?i)(?:backup|recovery|2fa|two[- ]factor|one[- ]time|scratch|emergency|verification)\s+codes?"#
    )
    static let backupCode = regex(
        #"(?<![\w\-])(?:[0-9a-zA-Z]{5}-[0-9a-zA-Z]{5}|[0-9]{4} [0-9]{4}|[0-9]{6,10}|[A-Z0-9]{4}-[A-Z0-9]{4}|[a-z0-9]{10})(?![\w\-])"#
    )
    static let totpKeyword = regex(
        #"(?i)secret|setup\s+key|2fa\s+key|authenticator|totp|otp\s+key|seed\s+key|mfa"#)
    static let base32 = regex(
        #"(?<![A-Za-z0-9])(?:[A-Z2-7]{4}(?: ?[A-Z2-7]{4}){3,15}|[a-z2-7]{4}(?: ?[a-z2-7]{4}){3,15})(?![A-Za-z0-9])"#
    )
    static let totpWords: [StaticString] = [
        "secret", "setup", "2fa", "authenticator", "totp", "otp", "seed", "mfa",
    ]
    static let otpauth = regex(#"otpauth(?:-migration)?://\S+"#)

    private mutating func recoveryKeys() {
        let p = profile
        for m in p.digits >= 48 ? Self.bitLocker.all(in: ns) : [] {
            let groups = text(m.range).split(separator: "-").compactMap { Int($0) }
            if groups.allSatisfy({ $0 % 11 == 0 }) { add(m.range, .recoveryKey) }
        }
        let grouped = p.longestToken >= 29 && p.has("-")
        let keywordSpans = grouped ? Self.recoveryKeyword.spans(in: ns) : []
        for rx in grouped ? [Self.groupedKey, Self.fiveByFive] : [] {
            for m in rx.all(in: ns) {
                let v = text(m.range)
                guard v.contains(where: \.isNumber), v.contains(where: \.isLetter) else { continue }
                let upper = v == v.uppercased()
                let grouped4 = rx === Self.groupedKey
                if (upper && grouped4) || isNear(m.range, keywordSpans, within: 60)
                    || (context.map { Self.recoveryKeyword.found(in: $0) } ?? false)
                {
                    add(m.range, .recoveryKey)
                }
            }
        }
        for m in p.has("a3-") ? Self.onePasswordSecretKey.all(in: ns) : [] {
            add(m.range, .recoveryKey)
        }
        for rx in p.digits >= 30 ? [Self.digitGroups5x6, Self.digitGroups4x16] : [] {
            for m in rx.all(in: ns) { add(m.range, .recoveryKey) }
        }
        for k in p.has("code") ? Self.backupKeyword.spans(in: ns) : [] {
            let tail = NSRange(
                location: k.location + k.length, length: ns.length - k.location - k.length)
            for m in Self.backupCode.all(in: ns, range: tail) where !digitsOf(m.range).isEmpty {
                add(m.range, .recoveryKey)
            }
        }
        if p.longestToken >= 4,
            hereOrBefore(Self.totpWords),
            Self.totpKeyword.found(in: ns)
                || (context.map { Self.totpKeyword.found(in: $0) } ?? false)
        {
            for m in Self.base32.all(in: ns) {
                let v = text(m.range).replacingOccurrences(of: " ", with: "")
                if v.count >= 16, v.contains(where: { "234567".contains($0) }),
                    v.contains(where: \.isLetter)
                {
                    add(m.range, .recoveryKey)
                }
            }
        }
        for m in p.has("otpauth") ? Self.otpauth.all(in: ns) : [] { add(m.range, .recoveryKey) }
    }

    // MARK: - Seed phrases (BIP-39)

    static let seedWord = regex(#"[A-Za-z]+"#)
    static let seedKeyword = regex(
        #"(?i)\b(?:seed|recovery\s+phrase|recovery\s+words|mnemonic|secret\s+(?:recovery\s+)?phrase|backup\s+phrase|wallet|metamask|ledger|trezor|phantom|exodus|trust\s+wallet|coinbase|12\s+words|24\s+words|twelve\s+words)\b"#
    )

    private mutating func seeds() {
        let keyword =
            Self.seedKeyword.found(in: ns)
            || (context.map { Self.seedKeyword.found(in: $0) } ?? false)
        for run in SecretDetector.seedRuns(ns, keyword: keyword) { add(run, .seedPhrase) }
    }

    // MARK: - Door, gate, and PIN codes

    static let codeNegative =
        #"zip|area|error|status|country|promo|postal|post|dial|exit|use|coupon|discount|dress|source|tax|response|http|bar|qr|reference|confirmation|tracking|order|booking|voucher|referral|invite|invitation|gift|verification|security|login|otp|auth|sms|activation|reset|redeem|offer|sale|cheat|morse|machine|postcode|swift|sort|iata|airport|flight|course|class|color|colour|product|discount|room|game|party|meeting|zoom|share|join|uber|lyft|whatsapp|venmo|instagram|google|apple|amazon|your"#
    static let codeValue =
        #"([*#]?[0-9][0-9A-Za-z]{2,7}#?|[A-Za-z][0-9]{3,7}|[0-9](?: [0-9]){3,7}|[0-9]{1,2}(?:-[0-9]{1,2}){2,3})(?![0-9A-Za-z])"#
    static let codeNounForm = regex(
        #"(?i)(?<!\b(?:"# + codeNegative
            + #")\s)\b(?:(?:door|gate|garage|safe|alarm|lock|lockbox|building|entry|entrance|access|keypad|apartment|apt|house|mailbox|front\s+door|back\s+door|elevator|storage|bike\s+lock|padlock)\s+)?(?:code|combination|combo|passcode|pin|keycode|lockbox)(?:\s+(?:number|no\.?|num|#))?(?:(?:\s+[A-Za-z']+){1,4}?\s+(?:is|:)|\s*(?:is\b|[:=])?)\s*"#
            + codeValue)
    static let placeForm = regex(
        #"(?i)\b(?:door|gate|garage|alarm|lockbox|keypad|safe|mailbox|padlock)\s*(?:is|:|=)\s*([*#]?[0-9]{4,8}#?)(?![0-9A-Za-z])"#
    )
    static let casualCodeForms: [NSRegularExpression] = [
        #"(?i)\b(?:door|gate|garage|code|alarm|lockbox|pin|keypad)['’]s\s+([*#]?[0-9]{3,8}#?)(?![0-9])"#,
        #"(?i)\bit['’]?s\s+([0-9]{4,8})#?\s+to\s+(?:get\s+in|open|unlock|enter)"#,
        #"(?i)\b(?:punch(?:\s+in)?|enter|type(?:\s+in)?|hit|press|dial)\s+([*#]?[0-9]{4,8}#?)\s+(?:at|on|into|in)\s+(?:the\s+)?(?:gate|door|keypad|lock|garage|lockbox|panel|box|front\s+door)"#,
        #"(?<![0-9])([0-9]{4,8})#?\s+(?:gets\s+you\s+in|opens\s+(?:it|the))"#,
        #"(?i)\b(?:opens|unlocks)\s+with\s+([0-9]{4,8})"#,
        #"(?i)\b(?:changed|change|set|updated|switched)\b(?:\s+[A-Za-z'’]+){0,4}?\s+(?<!\b(?:"#
            + codeNegative
            + #")\s)(?:code|combo|combination|pin|passcode)\s+(?:to|as)\s+([*#]?[0-9]{4,8}#?)(?![0-9])"#,
    ].map(regex)
    static let i18nCode = regex(
        #"(?i)(?:c[oó]digo|codice|t[üu]rcode|porte|portail|digicode|tor)(?:\s+[\p{L}]+){0,4}?\s*(?:es|est|ist|é|è|lautet|:)\s*([0-9]{3,8})(?![0-9])"#
    )
    static let codeReject = regex(#"(?i)^[0-9]{1,2}(?:am|pm|st|nd|rd|th|h|min|k)$"#)

    /// Words one of which each code rule needs, in the order of `codeRules`. Rules 2
    /// and 3 also run on any text that is not plain ASCII (accents, curly quotes).
    static let codeRuleWords: [[StaticString]] = [
        ["code", "comb", "pin", "lockbox"],
        ["door", "gate", "garage", "alarm", "lockbox", "keypad", "safe", "mailbox", "padlock"],
        ["codigo", "codice", "turcode", "porte", "portail", "digicode", "tor"],
        ["'s"], ["to"], ["punch", "enter", "type", "hit", "press", "dial"], ["gets", "opens"],
        ["with"], ["chang", "set", "updat", "switch"],
    ]
    static let codeRules = [codeNounForm, placeForm, i18nCode] + casualCodeForms

    private mutating func codes() {
        for (i, (rx, words)) in zip(Self.codeRules, Self.codeRuleWords).enumerated() {
            guard profile.hasAny(words) || (profile.nonASCII && (i == 2 || i == 3)) else {
                continue
            }
            for m in rx.all(in: ns) {
                let v = m.range(at: 1)
                guard v.location != NSNotFound else { continue }
                if Self.codeReject.found(in: text(v) as NSString) { continue }
                add(v, .standingCode)
            }
        }
    }
}
