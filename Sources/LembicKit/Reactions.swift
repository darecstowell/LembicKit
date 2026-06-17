import Foundation

public struct Reaction: Hashable, Sendable {
    public let by: String
    public let emoji: String

    public init(by: String, emoji: String) {
        self.by = by
        self.emoji = emoji
    }
}

/// One reaction/tapback row before netting (associated_message_type 2000–3006).
struct RawReaction {
    let dateNS: Int64
    let sequence: Int  // original row order; keeps the date sort stable
    let targetGUID: String
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

    /// Strip the part-index prefix from associated_message_guid
    /// ("p:0/GUID" or "bp:GUID") so it matches message.guid.
    static func targetGUID(from raw: String) -> String {
        if raw.hasPrefix("p:") {
            if let slash = raw.firstIndex(of: "/") {
                return String(raw[raw.index(after: slash)...])
            }
            return String(raw.dropFirst(2))
        }
        if raw.hasPrefix("bp:") {
            return String(raw.dropFirst(3))
        }
        return raw
    }

    /// Net adds minus removes: per (target message, reactor) the latest add
    /// wins unless a later remove cleared it.
    static func net(_ raw: [RawReaction]) -> [(targetGUID: String, reaction: Reaction)] {
        struct Key: Hashable {
            let target: String
            let reactor: String
        }
        let ordered = raw.sorted { ($0.dateNS, $0.sequence) < ($1.dateNS, $1.sequence) }
        var state: [Key: Reaction] = [:]
        var insertionOrder: [Key] = []
        for r in ordered {
            let key = Key(target: r.targetGUID, reactor: r.reactorKey)
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
