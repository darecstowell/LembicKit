import CryptoKit
import Foundation

/// On-device detector for high-harm secrets. It flags for review and never removes.
/// Ordinary PII (phone, email, address, names) is never flagged. Each body is normalized
/// first (`TextNormalizer`), and each flag maps back to the source text and covers the whole value.
public enum SecretDetector {
    /// Flag the secrets in `records`. `enabled` selects which categories to run;
    /// a disabled category is never returned. Defaults to every category.
    public static func detect(
        in records: [MessageRecord],
        enabled: Set<SecretCategory> = Set(SecretCategory.allCases)
    ) -> [DetectedSecret] {
        detect(in: records, enabled: enabled, gated: true)
    }

    /// `gated: false` runs every rule on every message (the reference for tests).
    static func detect(
        in records: [MessageRecord], enabled: Set<SecretCategory>, gated: Bool
    ) -> [DetectedSecret] {
        guard !enabled.isEmpty else { return [] }
        let input = DetectorInput(records, gated: gated)
        let all = 0..<records.count
        return input.assemble(
            all, enabled: enabled,
            single: { input.single($0, from: 0, enabled: enabled) },
            joined: { input.joined($0, in: all, enabled: enabled).hits },
            answer: { input.answer($0, enabled: enabled) },
            keyBlock: { input.keyBlock($0, upTo: records.count).hits })
    }

    /// Detection over one string with no message anchor (a group name, a label, an
    /// event line). Ranges are UTF-16 offsets into `text`.
    static func ranges(in text: String, enabled: Set<SecretCategory>) -> [Range<Int>] {
        guard !enabled.isEmpty, !text.isEmpty else { return [] }
        let body = TextNormalizer.normalize(text)
        var scan = DetectorScan(body.text, context: nil, enabled: enabled)
        scan.run()
        return scan.hits.compactMap { body.sourceRange($0.range) }
    }

    // MARK: - Consolidation

    /// Per message: merge overlapping flags of one category, then drop a flag that
    /// another flag already covers, so one secret gives one highlight.
    static func consolidated(_ hits: [DetectedSecret]) -> [DetectedSecret] {
        var byGuid: [String: [DetectedSecret]] = [:]
        var order: [String] = []
        for h in hits {
            if byGuid[h.guid] == nil { order.append(h.guid) }
            byGuid[h.guid, default: []].append(h)
        }
        var out: [DetectedSecret] = []
        for guid in order {
            var merged: [DetectedSecret] = []
            for h in byGuid[guid]!.sorted(by: {
                if $0.range.lowerBound != $1.range.lowerBound {
                    return $0.range.lowerBound < $1.range.lowerBound
                }
                if $0.range.count != $1.range.count { return $0.range.count > $1.range.count }
                return rank($0.category) < rank($1.category)
            }) {
                if let i = merged.lastIndex(where: {
                    $0.category == h.category && $0.range.overlaps(h.range)
                }) {
                    let m = merged[i]
                    let lower = Swift.min(m.range.lowerBound, h.range.lowerBound)
                    let upper = Swift.max(m.range.upperBound, h.range.upperBound)
                    merged[i] = DetectedSecret(
                        guid: guid, range: lower..<upper, category: m.category)
                } else {
                    merged.append(h)
                }
            }
            for (i, h) in merged.enumerated() {
                let covered = merged.enumerated().contains { j, other in
                    j != i && other.range.lowerBound <= h.range.lowerBound
                        && other.range.upperBound >= h.range.upperBound
                        && (other.range.count > h.range.count || j < i)
                }
                if !covered { out.append(h) }
            }
        }
        return out
    }

    /// For two flags on the same text, the more specific category wins.
    private static func rank(_ c: SecretCategory) -> Int {
        let order: [SecretCategory] = [
            .invisibleInk, .creditCard, .ssn, .bankAccount, .idNumber, .recoveryKey, .seedPhrase,
            .apiKey, .standingCode, .password,
        ]
        return order.firstIndex(of: c) ?? order.count
    }

    // MARK: - Secrets split over messages

    // MARK: - An answer to a question about a password or code

    static let question = regex(
        #"(?i)\b(?:password|passcode|pw|pwd|wi-?fi|pin|code|combo|combination)\b"#)
    static let asks = regex(
        #"(?i)\?\s*$|^\s*(?:what(?:'s|’s|s| is| was)?|whats|which|send|text|tell|remind|give|can\s+you|could\s+you|do\s+you|got\s+the|need\s+the)\b"#
    )
    static let codeQuestion = regex(
        #"(?i)\b(?:pin|code|combo|combination|door|gate|garage|lockbox)\b"#)
    static let answer = regex(
        #"^\s*(?:(?:it['’]?s|it\s+is|its|the\s+password\s+is|try)\s+)?([^\s]{3,64})\s*$"#)
    static let codeAnswer = regex(
        #"^\s*(?:(?:it['’]?s|it\s+is|its|try)\s+)?([*#]?[0-9]{4,8}#?(?=[\s,.!]|$)|[*#]?[0-9]{3}#?(?=\s*$))"#
    )

    // MARK: - Quoted values and private key blocks

    /// The value after an opening quote: up to the closing quote (a quote that is not
    /// followed by a letter or digit, so `'it's mine'` stays whole), else to the end
    /// of the line. Capped at 128 UTF-16 units.
    static func quotedValue(_ ns: NSString, openingQuoteAt q: Int) -> NSRange {
        let start = q + 1
        let limit = Swift.min(ns.length, start + 128)
        var k = start
        while k < limit {
            let c = ns.character(at: k)
            if c == 0x0A || c == 0x0D { break }
            if DetectorScan.isQuote(c), k > start {
                let next = k + 1 < ns.length ? ns.character(at: k + 1) : 0x20
                if !isAlphanumeric(next) { return NSRange(location: start, length: k - start) }
            }
            k += 1
        }
        return NSRange(location: start, length: k - start)
    }

    private static func isAlphanumeric(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    // A private key block: BEGIN through the matching END line. With no END line
    // the flag runs to the end of the message (`keyBlockContinuations` follows a
    // key that is split over several messages).
    private static let privateKeyBegin = regex(
        #"-----BEGIN ([A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?)-----"#)

    static func privateKeyBlocks(_ ns: NSString) -> [(range: NSRange, closed: Bool)] {
        var out: [(NSRange, Bool)] = []
        var searchFrom = 0
        while searchFrom < ns.length {
            let rest = NSRange(location: searchFrom, length: ns.length - searchFrom)
            guard let begin = privateKeyBegin.firstMatch(in: ns as String, range: rest)
            else { break }
            let start = begin.range.location
            let after = start + begin.range.length
            let endLine = ns.range(
                of: "-----END ", options: .literal,
                range: NSRange(location: after, length: ns.length - after))
            if endLine.location == NSNotFound {
                out.append((NSRange(location: start, length: ns.length - start), false))
                break
            }
            let tail = endLine.location + endLine.length
            let close = ns.range(
                of: "-----", options: .literal,
                range: NSRange(location: tail, length: ns.length - tail))
            let end = close.location == NSNotFound ? ns.length : close.location + close.length
            out.append(
                (NSRange(location: start, length: end - start), close.location != NSNotFound))
            searchFrom = end
        }
        return out
    }

    // MARK: - Seed phrases (BIP-39)

    /// Valid BIP-39 mnemonic word counts and their checksum bit counts.
    private static let seedLengths: [Int: Int] = [12: 4, 15: 5, 18: 6, 21: 7, 24: 8]

    /// The seed phrases in one body. Words match in any case. A run of BIP-39 words
    /// that passes the checksum is a seed phrase. With a seed keyword nearby, a run of
    /// 11 or more words is one too, even with a bad checksum or one typo in it.
    static func seedRuns(_ ns: NSString, keyword: Bool) -> [NSRange] {
        let tokens = DetectorScan.seedWord.all(in: ns).map {
            (word: ns.substring(with: $0.range).lowercased(), range: $0.range)
        }
        guard tokens.count >= 11 else { return [] }
        var out: [NSRange] = []
        func span(_ a: Int, _ b: Int) -> NSRange {
            let first = tokens[a].range
            let last = tokens[b - 1].range
            return NSRange(
                location: first.location, length: last.location + last.length - first.location)
        }
        var i = 0
        while i < tokens.count {
            guard BIP39.wordSet.contains(tokens[i].word) else {
                i += 1
                continue
            }
            var j = i
            var typo = -1
            while j < tokens.count {
                if BIP39.wordSet.contains(tokens[j].word) {
                    j += 1
                } else if keyword, typo < 0, j + 1 < tokens.count,
                    BIP39.wordSet.contains(tokens[j + 1].word), tokens[j].word.count >= 3
                {
                    typo = j
                    j += 1
                } else {
                    break
                }
            }
            var hit: (Int, Int)?
            if typo < 0 {
                outer: for len in [24, 21, 18, 15, 12] where len <= j - i {
                    for st in i...(j - len)
                    where seedChecksumValid(tokens[st..<(st + len)].map(\.word)) {
                        hit = (st, st + len)
                        break outer
                    }
                }
            }
            if hit == nil, keyword, j - i >= 11 { hit = (i, j) }
            if let (a, b) = hit { out.append(span(a, b)) }
            i = typo >= 0 && hit == nil ? typo + 1 : j
        }
        return out
    }

    /// True when `words` (a 12/15/18/21/24-word BIP-39 run) passes the BIP-39 checksum.
    static func seedChecksumValid(_ words: [String]) -> Bool {
        guard let cs = seedLengths[words.count] else { return false }
        var bits: [Bool] = []
        bits.reserveCapacity(words.count * 11)
        for w in words {
            guard let idx = BIP39.indexOf[w] else { return false }
            for shift in stride(from: 10, through: 0, by: -1) {
                bits.append((idx >> shift) & 1 == 1)
            }
        }
        let entBits = bits.count - cs
        var entropy = [UInt8](repeating: 0, count: entBits / 8)
        for k in 0..<entBits where bits[k] { entropy[k / 8] |= UInt8(1 << (7 - (k % 8))) }
        let hash = Array(SHA256.hash(data: Data(entropy)))
        for k in 0..<cs where ((hash[k / 8] >> (7 - (k % 8))) & 1 == 1) != bits[entBits + k] {
            return false
        }
        return true
    }

    // MARK: - Checksums

    /// Standard Luhn (mod-10) checksum over a digit string.
    static func luhnValid(_ digits: String) -> Bool {
        let d = digits.compactMap(\.wholeNumberValue)
        return d.count == digits.count && DetectorScan.luhn(d)
    }

    static func isValidSSN(area: String, group: String, serial: String) -> Bool {
        guard let a = Int(area), let g = Int(group), let s = Int(serial) else { return false }
        return DetectorScan.ssnShape(a, g, s)
    }

    static func ibanMod97Valid(_ iban: String) -> Bool { DetectorScan.mod97(iban.uppercased()) }

    static func abaRoutingValid(_ digits: String) -> Bool {
        DetectorScan.abaValid(digits.compactMap(\.wholeNumberValue))
    }

    /// Base58Check: the last four bytes are the double SHA-256 prefix of the rest.
    static func base58Check(_ s: String) -> Bool {
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
        var bytes: [UInt8] = [0]
        for ch in s.utf8 {
            guard let v = alphabet.firstIndex(of: ch) else { return false }
            var carry = v
            for i in (0..<bytes.count).reversed() {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }
        guard bytes.count > 4 else { return false }
        let check = Array(bytes.suffix(4))
        let digest = Array(SHA256.hash(data: Data(SHA256.hash(data: Data(bytes.dropLast(4))))))
        return Array(digest.prefix(4)) == check
    }
}
