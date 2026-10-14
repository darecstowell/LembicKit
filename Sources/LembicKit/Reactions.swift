import Foundation

public struct Reaction: Hashable, Sendable {
    public let by: String
    public let emoji: String

    public init(by: String, emoji: String) {
        self.by = by
        self.emoji = emoji
    }
}

/// One reaction, sticker, or vote row before netting.
struct RawReaction {
    let dateNS: Int64
    let sequence: Int  // original row order; keeps the date sort stable
    let targetGUID: String
    var part = 0
    let reactorKey: String  // "me" or "h<handle_id>" — identity for netting
    let reactorLabel: String
    let emoji: String
    let isRemove: Bool
}

enum Reactions {
    /// associated_message_type (add range) → tapback emoji.
    /// 2006 is a custom emoji and is read from associated_message_emoji.
    static let tapback: [Int64: String] = [
        2000: "❤️", 2001: "👍", 2002: "👎", 2003: "😂", 2004: "‼️", 2005: "❓",
    ]

    /// What a row's `associated_message_type` makes it.
    enum Kind: Equatable {
        /// A normal message (0, and the app-message types 2 and 3).
        case message
        /// A tapback (2000 to 2999) or its removal (3000 to 3999); `base` is the add type.
        case tapback(base: Int64, isRemove: Bool)
        /// A sticker placed on a bubble (1000).
        case sticker
        /// A poll vote (4000).
        case vote
        /// A type this engine does not know. Never shown as a message.
        case unknown
    }

    static func kind(of type: Int64) -> Kind {
        switch type {
        case 0, 2, 3: .message
        case 1000: .sticker
        case 2000...2999: .tapback(base: type, isRemove: false)
        case 3000...3999: .tapback(base: type - 1000, isRemove: true)
        case 4000: .vote
        default: .unknown
        }
    }

    /// The emoji for a tapback: the classic set, a sticker (2007), the row's own
    /// emoji (2006 and newer types), else "•".
    static func emoji(base: Int64, custom: String?) -> String {
        if let classic = tapback[base] { return classic }
        if base == 2007 { return "sticker" }
        if let custom, !custom.isEmpty { return custom }
        return "•"
    }

    /// Strip the part-index prefix from associated_message_guid
    /// ("p:0/GUID" or "bp:GUID") so it matches message.guid.
    static func targetGUID(from raw: String) -> String {
        target(from: raw).guid
    }

    /// The target message GUID and part index ("p:2/GUID" is part 2).
    static func target(from raw: String) -> (guid: String, part: Int) {
        if raw.hasPrefix("p:") {
            if let slash = raw.firstIndex(of: "/") {
                let part = Int(raw[raw.index(raw.startIndex, offsetBy: 2)..<slash]) ?? 0
                return (String(raw[raw.index(after: slash)...]), part)
            }
            return (String(raw.dropFirst(2)), 0)
        }
        if raw.hasPrefix("bp:") {
            return (String(raw.dropFirst(3)), 0)
        }
        return (raw, 0)
    }

    /// Net adds minus removes: per (target message, part, reactor) the latest add
    /// wins unless a later remove cleared it.
    static func net(_ raw: [RawReaction]) -> [(targetGUID: String, reaction: Reaction)] {
        struct Key: Hashable {
            let target: String
            let part: Int
            let reactor: String
        }
        let ordered = raw.sorted { ($0.dateNS, $0.sequence) < ($1.dateNS, $1.sequence) }
        var state: [Key: Reaction] = [:]
        var insertionOrder: [Key] = []
        for r in ordered {
            let key = Key(target: r.targetGUID, part: r.part, reactor: r.reactorKey)
            if r.isRemove {
                if state.removeValue(forKey: key) != nil {
                    insertionOrder.removeAll { $0 == key }
                }
            } else {
                if state[key] == nil { insertionOrder.append(key) }
                state[key] = Reaction(by: r.reactorLabel, emoji: r.emoji)
            }
        }
        return insertionOrder.compactMap { key in
            state[key].map { (key.target, $0) }
        }
    }

    /// Display order within one message: Them, Me, then third parties.
    static func displayRank(_ by: String) -> Int {
        by == "Them" ? 0 : by == "Me" ? 1 : 2
    }
}
