import Foundation

/// App messages (`message.balloon_bundle_id`): Apple Pay, polls, Check In,
/// handwriting, Digital Touch, Find My, and third-party apps. Their body is a lone
/// U+FFFC, so each becomes one typed token read from `payload_data`.
enum AppMessage {
    static let urlBalloon = "com.apple.messages.urlballoonprovider"

    /// The token for an app message, or nil when the balloon is a link preview.
    static func token(bundleID: String, payload: Data?) -> String? {
        let bundle = bundleID.lowercased()
        if bundle == urlBalloon { return nil }
        let fields = payload.flatMap(fields(from:)) ?? [:]
        let summary = detail(fields)
        if bundle.contains("handwriting") { return "[handwritten message]" }
        if bundle.contains("digitaltouch") { return "[Digital Touch]" }
        if bundle.contains("findmy") { return "[shared location]" }
        if bundle.contains("peerpayment") || bundle.contains("passbookuiservice") {
            return summary.map { "[Apple Pay: \($0)]" } ?? "[Apple Pay]"
        }
        if bundle.contains("safetymonitor") {
            let state = summary.map { $0.hasPrefix("Check In: ") ? String($0.dropFirst(10)) : $0 }
            return state.map { "[Check In: \($0)]" } ?? "[Check In]"
        }
        if bundle.hasSuffix("com.apple.messages.polls") {
            guard let poll = payload.flatMap(poll(from:)) else { return "[poll]" }
            let options = poll.options.map(\.text).joined(separator: " / ")
            if options.isEmpty { return poll.title.isEmpty ? "[poll]" : "[poll: \(poll.title)]" }
            return poll.title.isEmpty ? "[poll: \(options)]" : "[poll: \(poll.title) (\(options))]"
        }
        guard let name = clean(fields["an"] as? String) else { return "[app message]" }
        return summary.map { "[app: \(name) (\($0))]" } ?? "[app: \(name)]"
    }

    struct PollOption: Equatable, Sendable {
        let id: String
        let text: String
    }

    struct Poll: Equatable, Sendable {
        let title: String
        let options: [PollOption]
    }

    static func poll(from payload: Data) -> Poll? {
        guard let item = json(from: payload)?["item"] as? [String: Any],
            let raw = item["orderedPollOptions"] as? [[String: Any]]
        else { return nil }
        let options = raw.compactMap { option -> PollOption? in
            guard let id = option["optionIdentifier"] as? String,
                let text = clean(option["text"] as? String)
            else { return nil }
            return PollOption(id: id, text: text)
        }
        return Poll(title: clean(item["title"] as? String) ?? "", options: options)
    }

    /// The option identifiers in one vote row (the voter's current choices).
    static func votes(from payload: Data) -> [String] {
        guard let item = json(from: payload)?["item"] as? [String: Any],
            let votes = item["votes"] as? [[String: Any]]
        else { return [] }
        return votes.compactMap { $0["voteOptionIdentifier"] as? String }
    }

    /// The readable summary: `ldtext`, else the accessibility label, else the caption.
    private static func detail(_ fields: [String: Any]) -> String? {
        let userInfo = fields["userInfo"] as? [String: Any]
        return clean(fields["ldtext"] as? String)
            ?? clean(fields["AccessibilityLabel"] as? String)
            ?? clean(userInfo?["caption"] as? String)
    }

    /// One line, at most 200 characters, nil when empty.
    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: \.isNewline).joined(separator: "; ")
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }

    /// The JSON a poll or vote carries in its `data:,<base64>` URL.
    private static func json(from payload: Data) -> [String: Any]? {
        let url: String? =
            switch fields(from: payload)?["URL"] {
            case let url as URL: url.absoluteString
            case let string as String: string
            default: nil
            }
        guard let url, url.hasPrefix("data:,") else { return nil }
        let encoded = url.dropFirst(6).prefix { $0 != "?" }
        guard let data = Data(base64Encoded: String(encoded)),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object as? [String: Any]
    }

    /// The root dictionary of a keyed-archive payload. Classes the engine does not
    /// need (UUIDs, dates, values) decode as placeholders, so one odd value never
    /// loses the rest.
    static func fields(from payload: Data) -> [String: Any]? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: payload) else { return nil }
        unarchiver.requiresSecureCoding = true
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        for name in [
            "NSUUID", "NSDate", "NSValue", "NSAttributedString", "NSMutableAttributedString",
        ] {
            unarchiver.setClass(Placeholder.self, forClassName: name)
        }
        let allowed: [AnyClass] = [
            NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self,
            NSURL.self, Placeholder.self,
        ]
        let root = unarchiver.decodeObject(of: allowed, forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        return root as? [String: Any]
    }

    /// Stands in for an archived object the engine does not read.
    @objc(LembicKitPayloadPlaceholder)
    private final class Placeholder: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        init?(coder: NSCoder) {}
        func encode(with coder: NSCoder) {}
    }
}
