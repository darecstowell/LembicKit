import Foundation

extension DetectorScan {
    // MARK: - Cards (Luhn, issuer prefix and length, card-like grouping)

    static let cardCandidate = regex(#"(?<![0-9])[0-9](?:[ \t.\-\n]?[0-9]){11,40}(?![0-9])"#)
    static let urlRegex = regex(#"https?://\S+|\bwww\.\S+"#)
    static let cardLabel = regex(#"(?i)(?:cc|card|visa|amex|mc|no)[#:.]?$"#)

    mutating func cards() {
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
}
