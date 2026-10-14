import Foundation

/// SMS and RCS tapbacks arrive as text that quotes the message they react to
/// (`Loved “the code is 4471”`). A redaction on the quoted message must also
/// hide the quote.
enum QuoteReactions {
    static let pattern = try! NSRegularExpression(
        pattern:
            #"^(?:Loved|Liked|Disliked|Laughed at|Emphasized|Emphasised|Questioned|Reacted .{1,32}? to|Removed an? .{1,32}? from) [“"](.+)[”"]$"#,
        options: [.dotMatchesLineSeparators])

    /// `redactions` plus, for each quote reaction, the redactions of every earlier
    /// message with the quoted text moved onto the quote.
    static func carryRedactions(_ redactions: RedactionSet, records: [MessageRecord])
        -> RedactionSet
    {
        guard !redactions.isEmpty else { return redactions }
        var out = redactions
        var earlier: [String: [String]] = [:]
        for (index, r) in records.enumerated() {
            defer { if let guid = r.guid { earlier[r.text, default: []].append(guid) } }
            guard let guid = r.guid else { continue }
            let ns = r.text as NSString
            guard
                let m = pattern.firstMatch(
                    in: r.text, range: NSRange(location: 0, length: ns.length))
            else { continue }
            let quote = m.range(at: 1)
            let quoted = ns.substring(with: quote)
            var sources = earlier[quoted] ?? []
            var visible = (quoted as NSString).length
            if sources.isEmpty, let prefix = truncatedPrefix(quoted) {
                sources = records[Swift.max(0, index - 500)..<index]
                    .filter { $0.text.hasPrefix(prefix) }.compactMap(\.guid)
                visible = (prefix as NSString).length
            }
            for source in sources {
                for red in redactions.redactions(forGuid: source) {
                    guard let range = red.range else {
                        out.add(Redaction(guid: guid, range: nil))
                        continue
                    }
                    let hi = Swift.min(range.upperBound, visible)
                    guard range.lowerBound >= 0, range.lowerBound < hi else { continue }
                    out.add(
                        Redaction(
                            guid: guid,
                            range: (quote.location + range.lowerBound)..<(quote.location + hi)))
                }
            }
        }
        return out
    }

    /// The quoted text before a trailing ellipsis, when long enough to match safely.
    private static func truncatedPrefix(_ quoted: String) -> String? {
        for mark in ["…", "..."] where quoted.hasSuffix(mark) {
            let prefix = String(quoted.dropLast(mark.count))
            return prefix.count >= 8 ? prefix : nil
        }
        return nil
    }
}
