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
