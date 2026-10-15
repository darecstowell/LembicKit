import Foundation

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
