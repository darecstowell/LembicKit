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
        guard let archivables = try? TypedStreamDecoder.decode(data) else { return nil }
        for archivable in archivables {
            if case .object(let cls, let objects) = archivable,
                cls.name == "NSString" || cls.name == "NSMutableString",
                case .string(let text)? = objects.first
            {
                return text
            }
        }
        return nil
    }
}
