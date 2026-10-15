import Foundation
import TypedStream

public enum AttributedBody {
    /// Decode an `attributedBody` typedstream blob to the plain backing string
    /// of its NSAttributedString.
    ///
    /// The message text is the first NSString/NSMutableString object in the
    /// stream; strings after it are attribute keys (`__kIM…`, `NSFont`, …).
    /// We deliberately do NOT use Madrid's `Archivable.stringValue`: its
    /// heuristic filter drops legitimate bodies — emoji-only texts (no
    /// letters/numbers) and any text containing "NS".
    public static func decode(_ data: Data) -> String? {
        parse(data)?.text
    }

    static let fileTransferGUIDKey = "__kIMFileTransferGUIDAttributeName"
    static let audioTranscriptionKey = "IMAudioTranscription"
    static let partKey = "__kIMMessagePartAttributeName"
    static let readKeys: Set<String> = [fileTransferGUIDKey, audioTranscriptionKey, partKey]

    /// A stretch of `text`, in UTF-16 units, and the attributes the engine reads.
    struct Run: Equatable {
        var length: Int
        var attributes: [String: String]
    }

    struct Body: Equatable {
        var text: String
        var runs: [Run]

        /// The attributes on each U+FFFC of `text`, in order.
        var objects: [[String: String]] {
            var objects: [[String: String]] = []
            var offset = 0
            var runIndex = 0
            var runEnd = runs.first?.length ?? 0
            for unit in text.utf16 {
                while runIndex < runs.count, offset >= runEnd {
                    runIndex += 1
                    runEnd += runIndex < runs.count ? runs[runIndex].length : 0
                }
                if unit == 0xFFFC {
                    objects.append(runIndex < runs.count ? runs[runIndex].attributes : [:])
                }
                offset += 1
            }
            return objects
        }

        /// The body without the runs of the given message parts, or nil when no run
        /// names its part, so the parts cannot be found.
        func removingParts(_ parts: Set<Int>) -> Body? {
            guard runs.contains(where: { $0.attributes[partKey] != nil }) else { return nil }
            let source = text as NSString
            var kept = ""
            var keptRuns: [Run] = []
            var offset = 0
            for run in runs {
                let end = min(offset + run.length, source.length)
                let part = run.attributes[partKey].flatMap { Int($0) }
                if offset < end, part.map(parts.contains) != true {
                    kept += source.substring(with: NSRange(location: offset, length: end - offset))
                    keptRuns.append(Run(length: end - offset, attributes: run.attributes))
                }
                offset = end
            }
            if offset < source.length { kept += source.substring(from: offset) }
            return Body(text: kept, runs: keptRuns)
        }
    }

    static func parse(_ data: Data) -> Body? {
        guard let items = try? TypedStreamDecoder.decode(data),
            let start = items.firstIndex(where: { bodyString($0) != nil }),
            let text = bodyString(items[start])
        else { return nil }
        return Body(text: text, runs: attributeRuns(items[(start + 1)...]))
    }

    /// The body string read straight from the bytes, for the common layout: the
    /// first class is `NSString` or `NSMutableString`, then its parent reference and
    /// a `+` UTF-8 run. Nil for any other layout; the full decoder then runs.
    static func plainText(_ data: Data) -> String? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var i = 16
            while i < n {
                let nameLength: Int
                if bytes[i] == 8, i + 9 <= n, matches(bytes, at: i + 1, nsString) {
                    nameLength = 8
                } else if bytes[i] == 15, i + 16 <= n, matches(bytes, at: i + 1, nsMutableString) {
                    nameLength = 15
                } else {
                    i += 1
                    continue
                }
                var j = i + 1 + nameLength + 1  // name, then the class version
                // A parent class written inline (NSMutableString, then NSString) is
                // not the string yet; the scan moves on to the parent's name.
                guard j + 4 <= n, bytes[j] >= 0x92, bytes[j + 1] == 0x84, bytes[j + 2] == 0x01,
                    bytes[j + 3] == 0x2B
                else {
                    i += 1
                    continue
                }
                j += 4
                let length: Int
                switch bytes[j] {
                case 0x81:
                    guard j + 3 <= n else { return nil }
                    length = Int(bytes[j + 1]) | Int(bytes[j + 2]) << 8
                    j += 3
                case 0x82:
                    guard j + 5 <= n else { return nil }
                    length = (0..<4).reduce(0) { $0 | Int(bytes[j + 1 + $1]) << (8 * $1) }
                    j += 5
                case let short where short < 0x80:
                    length = Int(short)
                    j += 1
                default:
                    return nil
                }
                guard j + length <= n else { return nil }
                return String(
                    bytes: UnsafeBufferPointer(rebasing: bytes[j..<(j + length)]), encoding: .utf8)
            }
            return nil
        }
    }

    private static let nsString = Array("NSString".utf8)
    private static let nsMutableString = Array("NSMutableString".utf8)

    private static func matches(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int, _ name: [UInt8])
        -> Bool
    {
        name.indices.allSatisfy { bytes[start + $0] == name[$0] }
    }

    /// The string from a blob the decoder rejects: the bytes after the first
    /// `NSString` class, clamped to the blob and cut at the first invalid UTF-8.
    /// `isComplete` is false when bytes the blob declares are missing.
    static func salvage(_ data: Data) -> (text: String, isComplete: Bool)? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard bytes.count > marker.count,
            let classStart = (0...(bytes.count - marker.count)).first(where: {
                bytes[$0..<($0 + marker.count)].elementsEqual(marker)
            })
        else { return nil }
        let searchEnd = min(bytes.count, classStart + marker.count + 16)
        guard let plus = bytes[(classStart + marker.count)..<searchEnd].firstIndex(of: 0x2B),
            plus + 1 < bytes.count
        else { return nil }
        var start = plus + 2
        let declared: Int
        switch bytes[plus + 1] {
        case 0x81:
            guard plus + 3 < bytes.count else { return nil }
            declared = Int(bytes[plus + 2]) | Int(bytes[plus + 3]) << 8
            start = plus + 4
        case 0x82:
            guard plus + 5 < bytes.count else { return nil }
            declared = (0..<4).reduce(0) { $0 | Int(bytes[plus + 2 + $1]) << (8 * $1) }
            start = plus + 6
        case let length where length < 0x80:
            declared = Int(length)
        default:
            return nil
        }
        var iterator = bytes[start..<min(bytes.count, start + declared)].makeIterator()
        var decoder = UTF8()
        var scalars = String.UnicodeScalarView()
        var consumed = 0
        decoding: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                scalars.append(scalar)
                consumed += UTF8.width(scalar)
            case .emptyInput, .error:
                break decoding
            }
        }
        let text = String(scalars)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, consumed == declared)
    }

    private static func bodyString(_ item: Archivable) -> String? {
        guard case .object(let cls, let objects) = item,
            cls.name == "NSString" || cls.name == "NSMutableString",
            case .string(let text)? = objects.first
        else { return nil }
        return text
    }

    /// Each run is an `(id, UTF-16 length)` pair, then its attribute dictionary.
    /// A run that reuses an earlier dictionary id carries no dictionary.
    private static func attributeRuns(_ items: ArraySlice<Archivable>) -> [Run] {
        var runs: [Run] = []
        var dictionaries: [Int64: [String: String]] = [:]
        var current: Int64?
        var pendingKey: String?
        for item in items {
            if case .data(let values) = item, values.count == 2,
                case .signedInteger(let id) = values[0],
                case .unsignedInteger(let length) = values[1]
            {
                current = id
                pendingKey = nil
                runs.append(Run(length: Int(clamping: length), attributes: dictionaries[id] ?? [:]))
                continue
            }
            guard let id = current, case .object(_, let objects) = item else {
                pendingKey = nil
                continue
            }
            if let key = pendingKey {
                pendingKey = nil
                let value: String? =
                    switch objects.first {
                    case .string(let s)?: s
                    case .signedInteger(let n)?: String(n)
                    case .unsignedInteger(let n)?: String(n)
                    default: nil
                    }
                if let value {
                    runs[runs.count - 1].attributes[key] = value
                    dictionaries[id] = runs[runs.count - 1].attributes
                }
            } else if case .string(let s)? = objects.first, readKeys.contains(s) {
                pendingKey = s
            }
        }
        return runs
    }
}
