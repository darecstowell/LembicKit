import Foundation

/// Finds the known names of each speaker in message text for anonymize: the speaker
/// label, the extra names the caller supplies, and each part of every name
/// ("Sarah Chen", "Sarah", "Chen"). Built once per render.
struct NameMatcher: Sendable {
    /// A name part shared by two speakers maps here, so it is hidden but not misattributed.
    static let sharedNameToken = "[name]"

    private let anyCase: NSRegularExpression?
    private let exactCase: NSRegularExpression?
    private let aliasByLowercased: [String: String]
    private let aliasByExact: [String: String]

    /// Names that are also common words match only as written ("Will", not "will").
    static let commonWordNames: Set<String> = [
        "amber", "angel", "april", "art", "august", "autumn", "baker", "bell", "bill", "bishop",
        "black", "blue", "brook", "brown", "buddy", "carter", "cash", "chance", "chase", "chip",
        "cole", "cooper", "crystal", "daisy", "dawn", "dean", "don", "dot", "drew", "faith",
        "field", "frank", "gene", "ginger", "grace", "gray", "green", "grey", "guy", "hall",
        "harmony", "heather", "hill", "holly", "honey", "hope", "hunter", "iris", "ivy", "jack",
        "jade", "joy", "june", "king", "lane", "lily", "long", "love", "major", "mark", "mason",
        "max", "may", "melody", "member", "miller", "nick", "olive", "page", "parker", "pat",
        "penny", "porter", "price", "prince", "rain", "ray", "reed", "rich", "river", "rob",
        "rose", "ruby", "rusty", "sage", "sandy", "short", "sky", "star", "sterling", "stone",
        "storm", "sue", "summer", "sunny", "tanner", "taylor", "van", "violet", "wade", "white",
        "will", "winter", "wood", "young",
    ]

    init(aliases: [String: String], knownNames: [String: [String]] = [:]) {
        var byLower: [String: String] = [:]
        var byExact: [String: String] = [:]
        func add(_ term: String, _ alias: String, exact: Bool) {
            if exact {
                byExact[term] =
                    byExact[term].map { $0 == alias ? alias : Self.sharedNameToken } ?? alias
            } else {
                let key = term.lowercased()
                byLower[key] =
                    byLower[key].map { $0 == alias ? alias : Self.sharedNameToken } ?? alias
            }
        }
        for (label, alias) in aliases {
            var names = knownNames[label] ?? []
            if Self.isAliasableName(label) { names.insert(label, at: 0) }
            for raw in names {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.filter(\.isLetter).count >= 2 else { continue }
                let parts = name.split(whereSeparator: \.isWhitespace)
                    .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                    .filter { $0.filter(\.isLetter).count >= 2 }
                let single = parts.count == 1 && parts[0] == name
                add(name, alias, exact: single && Self.commonWordNames.contains(name.lowercased()))
                guard !single else { continue }
                for part in parts {
                    add(part, alias, exact: Self.commonWordNames.contains(part.lowercased()))
                }
            }
        }
        aliasByLowercased = byLower
        aliasByExact = byExact
        anyCase = Self.regex(Array(byLower.keys), caseInsensitive: true)
        exactCase = Self.regex(Array(byExact.keys), caseInsensitive: false)
    }

    /// True when a label is a name: not the owner label, not "Them", not a neutral
    /// `Member N`, and not a number (a label with no letter).
    static func isAliasableName(_ label: String) -> Bool {
        if label == Transcript.meLabel || label == Transcript.themLabel { return false }
        if label.hasPrefix("Member "), Int(label.dropFirst(7)) != nil { return false }
        return label.contains { $0.isLetter }
    }

    var isEmpty: Bool { anyCase == nil && exactCase == nil }

    private static func regex(_ terms: [String], caseInsensitive: Bool) -> NSRegularExpression? {
        guard !terms.isEmpty else { return nil }
        // Longest first, so a full name wins over its first name.
        let body = terms.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let pattern =
            (caseInsensitive ? "(?i)" : "") + "(?<![\\p{L}\\p{N}])(?:\(body))(?![\\p{L}\\p{N}])"
        return try? NSRegularExpression(pattern: pattern)
    }

    /// The alias substitutions in one body (overlaps are resolved by the caller).
    func substitutions(in body: NSString) -> [BodySplice.Substitution] {
        guard body.length > 0 else { return [] }
        var out: [BodySplice.Substitution] = []
        let whole = NSRange(location: 0, length: body.length)
        for (regex, exact) in [(anyCase, false), (exactCase, true)] {
            guard let regex else { continue }
            regex.enumerateMatches(in: body as String, range: whole) { match, _, _ in
                guard let match, match.range.length > 0, let range = Range(match.range) else {
                    return
                }
                let text = body.substring(with: match.range)
                guard let alias = exact ? aliasByExact[text] : aliasByLowercased[text.lowercased()]
                else { return }
                out.append(
                    BodySplice.Substitution(range: range, token: alias, isRedaction: false))
            }
        }
        return out.sorted {
            $0.range.lowerBound != $1.range.lowerBound
                ? $0.range.lowerBound < $1.range.lowerBound : $0.range.count > $1.range.count
        }
    }
}
