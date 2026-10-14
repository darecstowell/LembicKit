import CryptoKit
import Foundation

/// A saved redaction plus a keyed fingerprint of the text it covered, so a later
/// load can tell when the message text changed under it (an edit, a late attachment
/// row, a new text normalization). The fingerprint never stores the text itself.
public struct RedactionAnchor: Codable, Hashable, Sendable {
    public let guid: String
    /// UTF-16 offsets into the message text; nil redacts the whole message.
    public let range: Range<Int>?
    /// HMAC-SHA256 of the covered UTF-16 text (hex); nil for a whole-message anchor.
    public let fingerprint: String?

    public init(guid: String, range: Range<Int>?, fingerprint: String?) {
        self.guid = guid
        self.range = range
        self.fingerprint = fingerprint
    }

    public var redaction: Redaction { Redaction(guid: guid, range: range) }
}

extension RedactionSet {
    /// What `resolve` did to keep each saved redaction on its text.
    public struct AnchorResolution: Sendable {
        /// The redactions to render.
        public let redactions: RedactionSet
        /// Anchors whose text moved; they now cover every place the same text is found.
        public let moved: [RedactionAnchor]
        /// Guids whose redacted text is gone; the whole message is now redacted.
        public let wholeMessage: [String]
    }

    /// Anchors for this set, fingerprinted with `key` against the text of `records`.
    /// A redaction whose message is not in `records` is skipped (it has no text to bind).
    public func anchors(in records: [MessageRecord], key: SymmetricKey) -> [RedactionAnchor] {
        var text: [String: NSString] = [:]
        for r in records { if let guid = r.guid { text[guid] = r.text as NSString } }
        return all.compactMap { red in
            guard let range = red.range else {
                return RedactionAnchor(guid: red.guid, range: nil, fingerprint: nil)
            }
            guard let ns = text[red.guid], range.lowerBound >= 0, range.upperBound <= ns.length
            else { return nil }
            return RedactionAnchor(
                guid: red.guid, range: range,
                fingerprint: Self.fingerprint(ns, range, key: key))
        }
    }

    /// Rebuild a set from saved anchors and the current `records`. An anchor whose
    /// text still matches is kept. One whose text moved covers every place in the
    /// message where the same text is found. One whose text is gone, or that has no
    /// fingerprint, redacts the whole message. It never fails open.
    public static func resolve(
        _ anchors: [RedactionAnchor], records: [MessageRecord], key: SymmetricKey
    ) -> AnchorResolution {
        var text: [String: NSString] = [:]
        for r in records { if let guid = r.guid { text[guid] = r.text as NSString } }
        var set = RedactionSet()
        var moved: [RedactionAnchor] = []
        var whole: [String] = []
        for anchor in anchors {
            guard let range = anchor.range, let ns = text[anchor.guid] else {
                set.add(anchor.redaction)
                continue
            }
            if let print = anchor.fingerprint, range.lowerBound >= 0, range.upperBound <= ns.length,
                fingerprint(ns, range, key: key) == print
            {
                set.add(anchor.redaction)
                continue
            }
            let width = range.count
            var found: [Range<Int>] = []
            if let print = anchor.fingerprint, width > 0, width <= ns.length {
                for start in 0...(ns.length - width)
                where fingerprint(ns, start..<(start + width), key: key) == print {
                    found.append(start..<(start + width))
                }
            }
            if found.isEmpty {
                set.add(Redaction(guid: anchor.guid, range: nil))
                whole.append(anchor.guid)
            } else {
                for r in found { set.add(Redaction(guid: anchor.guid, range: r)) }
                moved.append(anchor)
            }
        }
        return AnchorResolution(redactions: set, moved: moved, wholeMessage: whole)
    }

    static func fingerprint(_ ns: NSString, _ range: Range<Int>, key: SymmetricKey) -> String {
        var units = [UInt16](repeating: 0, count: range.count)
        ns.getCharacters(&units, range: NSRange(location: range.lowerBound, length: range.count))
        let data = units.withUnsafeBufferPointer { Data(buffer: $0) }
        return HMAC<SHA256>.authenticationCode(for: data, using: key)
            .map { String(format: "%02x", $0) }.joined()
    }
}
