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

/// The per-message rules. A scan runs on one normalized body. `context` is the
/// message before it, so a keyword asked there ("what's your SSN?") counts here.
struct DetectorScan {
    let ns: NSString
    let context: NSString?
    let enabled: Set<SecretCategory>
    private(set) var hits: [(range: NSRange, category: SecretCategory)] = []

    let profile: TextProfile
    let contextProfile: TextProfile?

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
    func hereOrBefore(_ needles: [StaticString]) -> Bool {
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

    mutating func add(_ r: NSRange, _ category: SecretCategory) {
        guard r.location != NSNotFound, r.length > 0 else { return }
        hits.append((r, category))
    }

    func keywordNear(_ r: NSRange, _ keyword: NSRegularExpression, within: Int) -> Bool {
        if isNear(r, keyword.spans(in: ns), within: within) { return true }
        if let context, keyword.found(in: context) { return true }
        return false
    }

    func keywordInMessage(_ keyword: NSRegularExpression) -> Bool {
        keyword.found(in: ns) || (context.map { keyword.found(in: $0) } ?? false)
    }

    func text(_ r: NSRange) -> String { ns.substring(with: r) }

    func digitsOf(_ r: NSRange) -> [Int] {
        text(r).unicodeScalars.compactMap { s in
            s.value >= 0x30 && s.value <= 0x39 ? Int(s.value - 0x30) : nil
        }
    }
}
