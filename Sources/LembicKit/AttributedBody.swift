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
    static let readKeys: Set<String> = [fileTransferGUIDKey, audioTranscriptionKey]

    struct Body: Equatable {
        var text: String
        /// The attributes on each U+FFFC of `text`, in order.
        var objects: [[String: String]]
    }

    static func parse(_ data: Data) -> Body? {
        guard let items = try? TypedStreamDecoder.decode(data),
            let start = items.firstIndex(where: { bodyString($0) != nil }),
            let text = bodyString(items[start])
        else { return nil }
        let runs = attributeRuns(items[(start + 1)...])
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
        return Body(text: text, objects: objects)
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
    private static func attributeRuns(_ items: ArraySlice<Archivable>) -> [(
        length: Int, attributes: [String: String]
    )] {
        var runs: [(length: Int, attributes: [String: String])] = []
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
                runs.append((Int(clamping: length), dictionaries[id] ?? [:]))
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
