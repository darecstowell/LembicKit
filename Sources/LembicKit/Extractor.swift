import Foundation
import GRDB
import os

/// One emitted (non-reaction, non-system) message, reactions attached.
public struct MessageRecord: Sendable {
    public let guid: String?
    public let date: Date
    public let speaker: String
    public let isTarget: Bool
    public let service: String?
    public let text: String
    public let hadAttachment: Bool
    public var reactions: [Reaction]

    /// Public memberwise initializer over every stored property. The extractor
    /// builds records from `chat.db` rows, but a public init also lets callers
    /// (and tests / OSS consumers of the engine) construct synthetic records —
    /// e.g. to render fixtures through `Transcript`/`Export` without a database.
    public init(
        guid: String?,
        date: Date,
        speaker: String,
        isTarget: Bool,
        service: String?,
        text: String,
        hadAttachment: Bool,
        reactions: [Reaction]
    ) {
        self.guid = guid
        self.date = date
        self.speaker = speaker
        self.isTarget = isTarget
        self.service = service
        self.text = text
        self.hadAttachment = hadAttachment
        self.reactions = reactions
    }
}

public struct Extractor: Sendable {
    /// Engine-side diagnostics (the opt-in system-event probe logs here when a
    /// column the default export never touches is absent). `os.Logger` is
    /// `Sendable`, so a static instance is safe to share.
    static let log = Logger(subsystem: "com.textstoai.lembic", category: "extractor")

    /// Handle ROWIDs that belong to the counterparty across services
    /// (iMessage / SMS / RCS rows are separate handles for the same person).
    public let targetHandles: Set<Int64>
    public let handleLabels: [Int64: String]
    /// Handle ROWIDs whose `handleLabels` entry is an **already-resolved
    /// per-thread speaker label** (a roster member, via `Participant.label`) rather
    /// than a raw global name/identifier. A system-event line uses these labels
    /// **verbatim** so a collision-disambiguated member ("Mike R.") renders the same
    /// in the event line as in the message body — no re-first-tokening. Empty for a
    /// 1:1 (and for a group built without per-speaker labels), so the off-roster
    /// first-token / number-format fallback is unchanged there.
    public let rosterHandles: Set<Int64>

    public init(
        targetHandles: Set<Int64>,
        handleLabels: [Int64: String],
        rosterHandles: Set<Int64> = []
    ) {
        self.targetHandles = targetHandles
        self.handleLabels = handleLabels
        self.rosterHandles = rosterHandles
    }

    /// The right `Extractor` for a `Conversation`, branching on `isGroup` (the
    /// label layer) — the single seam every call site should use so 1:1 and group
    /// labeling can never drift:
    ///
    /// - **1:1:** `targetHandles` = the counterparty's handles, so every non-me
    ///   sender labels "Them" (unchanged from the original behavior).
    /// - **Group:** `targetHandles` is left **empty** (the "Them" branch is
    ///   bypassed) and `handleLabels` carries the **per-speaker** label from each
    ///   `Participant.label` — so each member resolves to their own name rather
    ///   than every non-me sender collapsing to "Them". A member whose label is nil
    ///   (a roster built without a Contacts map) falls through to `globalLabels`,
    ///   then to `h<id>`.
    ///
    /// `globalLabels` is the caller's resolved handle-ROWID → name/identifier map (the
    /// 1:1 path's `handleLabels`); for a group it's the nil-label fallback.
    public static func forConversation(
        _ conversation: Conversation,
        globalLabels: [Int64: String]
    ) -> Extractor {
        guard conversation.isGroup else {
            return Extractor(targetHandles: conversation.targetHandles, handleLabels: globalLabels)
        }
        var perSpeaker = globalLabels
        var rosterHandles = Set<Int64>()
        for p in conversation.participants where p.label != nil {
            perSpeaker[p.handleID] = p.label
            rosterHandles.insert(p.handleID)
        }
        return Extractor(targetHandles: [], handleLabels: perSpeaker, rosterHandles: rosterHandles)
    }

    public func label(isFromMe: Bool, handleID: Int64) -> String {
        if isFromMe { return "Me" }
        if targetHandles.contains(handleID) { return "Them" }
        return handleLabels[handleID] ?? "h\(handleID)"
    }

    /// The display label for a *system-event* actor / affected person. Mirrors the
    /// group body's labeling — a roster member resolves to its per-thread speaker
    /// label (first name / `First L.`) via `handleLabels`; "Me" for the account
    /// owner. The one extra job over `label`: an `other_handle` (the person an add /
    /// remove targets) can reference a handle that has since **left the roster**, so
    /// its `handleLabels` entry is the raw phone/email — pretty-print that to a
    /// readable number so a removed member reads "Carla" or "(844) 399-6927", never
    /// a bare `h17`. `handleID == 0` (an actor the row didn't record) → nil, so the
    /// caller can fall back to a subjectless phrasing.
    func systemEventLabel(isFromMe: Bool, handleID: Int64) -> String? {
        if isFromMe { return "Me" }
        guard handleID != 0 else { return nil }
        guard let value = handleLabels[handleID] else { return "h\(handleID)" }
        // A roster member's value is its already-resolved per-thread label
        // (`groupSpeakerLabels`: "Mike", "Mike R.", or a formatted number). Use it
        // VERBATIM so the event line matches the message body exactly — re-first-
        // tokening it would collapse a collision-disambiguated "Mike R." back to
        // "Mike", diverging from the body. Only the *off-roster* fallback case (an
        // add/remove target who has since left the chat, carrying the GLOBAL value)
        // needs shaping: a full contact name → its first token ("Carla", not "Carla
        // Reed"); a bare phone/email → a readable number. `displayNumber` passes a
        // name through unchanged, so first-tokening after it is safe for both.
        if rosterHandles.contains(handleID) { return value }
        let pretty = Conversations.displayNumber(value)
        // Only first-token a name (a phone like "(816) 000-0007" must stay whole).
        if pretty.contains("@") || pretty.contains(where: \.isNumber) { return pretty }
        return pretty.split(separator: " ").first.map(String.init) ?? pretty
    }

    /// All attachments across `chatIDs`, keyed by message ROWID, in join order.
    /// A message reachable from more than one unioned chat would otherwise list
    /// its attachments once per chat, so links are de-duped by maj.ROWID — a
    /// no-op for a single chat, so the byte-validated path stays identical.
    func loadAttachments(_ db: GRDB.Database, chatIDs: [Int64]) throws -> [Int64: [AttachmentInfo]]
    {
        guard !chatIDs.isEmpty else { return [:] }
        var map: [Int64: [AttachmentInfo]] = [:]
        var seenLinks = Set<Int64>()
        let placeholders = Array(repeating: "?", count: chatIDs.count).joined(separator: ",")
        let rows = try Row.fetchCursor(
            db,
            sql: """
                SELECT maj.ROWID majid, maj.message_id mid, at.mime_type, at.uti, at.transfer_name
                FROM chat_message_join cmj
                JOIN message_attachment_join maj ON maj.message_id = cmj.message_id
                JOIN attachment at ON at.ROWID = maj.attachment_id
                WHERE cmj.chat_id IN (\(placeholders))
                ORDER BY maj.message_id, maj.ROWID
                """,
            arguments: StatementArguments(chatIDs))
        while let row = try rows.next() {
            let majid: Int64 = row["majid"]
            guard seenLinks.insert(majid).inserted else { continue }
            let info = AttachmentInfo(
                mimeType: row["mime_type"], uti: row["uti"], transferName: row["transfer_name"])
            map[row["mid"], default: []].append(info)
        }
        return map
    }

    /// Decoded text with attachment placeholders spliced in at U+FFFC marks.
    static func renderText(
        attributedBody: Data?,
        fallbackText: String?,
        balloonBundleID: String?,
        attachments: [AttachmentInfo]
    ) -> (text: String, hadAttachment: Bool) {
        let raw = attributedBody.flatMap(AttributedBody.decode) ?? (fallbackText ?? "")
        let placeholders = attachments.map(\.placeholder)
        var hadAttachment = false

        let parts = raw.components(separatedBy: "\u{FFFC}")
        var out = parts[0]
        var index = 0
        for i in 1..<parts.count {
            let placeholder = index < placeholders.count ? placeholders[index] : nil
            index += 1
            if let placeholder {
                out += " " + placeholder + " "
                hadAttachment = true
            }
            out += parts[i]
        }
        let leftover = placeholders[min(index, placeholders.count)...].compactMap(\.self)
        if !leftover.isEmpty {
            hadAttachment = true
            out += " " + leftover.joined(separator: " ")
        }

        out = normalizeWhitespace(out)
        if out.isEmpty, let bundle = balloonBundleID?.lowercased(), bundle.contains("findmy") {
            out = "[shared location]"
        }
        return (out, hadAttachment)
    }

    /// Per line: collapse runs of space/tab to one space, strip edges; then
    /// strip the whole text. Matches the Python prototype's
    /// `re.sub(r"[ \t]+", " ", ln).strip()` + outer `.strip()`.
    static func normalizeWhitespace(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n").map { line in
            collapseSpaceRuns(line).trimmingCharacters(in: pythonWhitespace)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: pythonWhitespace)
    }

    static func collapseSpaceRuns(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var inRun = false
        for ch in s {
            if ch == " " || ch == "\t" {
                if !inRun {
                    out.append(" ")
                    inRun = true
                }
            } else {
                out.append(ch)
                inRun = false
            }
        }
        return out
    }

    /// Python str.strip() whitespace: Zs + tab (CharacterSet.whitespaces) plus
    /// the control/separator characters str.isspace() also accepts.
    static let pythonWhitespace: CharacterSet = {
        var set = CharacterSet.whitespaces
        set.insert(charactersIn: "\n\r\u{0B}\u{0C}\u{1C}\u{1D}\u{1E}\u{1F}\u{85}\u{2028}\u{2029}")
        return set
    }()

    static let appleEpochOffset: TimeInterval = 978_307_200  // 1970→2001

    /// Ordered emitted records for one chat (reactions netted, attachments
    /// attached) — a single-chat convenience over `extractConversation`.
    public func extractChat(_ db: GRDB.Database, chatID: Int64) throws -> [MessageRecord] {
        try extractConversation(db, chatIDs: [chatID])
    }

    /// Ordered emitted records for a whole conversation — the union of one
    /// contact's 1:1 chat rows. SQLite merge-sorts the rows by date in one
    /// pass; messages reachable from more than one chat are de-duped by ROWID.
    /// A `chatIDs` of a single id reproduces `extractChat` byte-for-byte.
    public func extractConversation(_ db: GRDB.Database, chatIDs: Set<Int64>) throws
        -> [MessageRecord]
    {
        let ids = chatIDs.sorted()
        guard !ids.isEmpty else { return [] }
        let attachmentMap = try loadAttachments(db, chatIDs: ids)

        var emitted: [MessageRecord] = []
        var indexByGUID: [String: Int] = [:]
        var rawReactions: [RawReaction] = []
        var seenROWIDs = Set<Int64>()
        var sequence = 0

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try Row.fetchCursor(
            db,
            sql: """
                SELECT m.ROWID rid, m.guid, m.date, m.is_from_me, m.handle_id, m.service,
                       m.text, m.attributedBody, m.item_type,
                       m.associated_message_type amt, m.associated_message_guid amg,
                       m.associated_message_emoji ame, m.balloon_bundle_id
                FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
                WHERE cmj.chat_id IN (\(placeholders))
                ORDER BY m.date, m.ROWID
                """,
            arguments: StatementArguments(ids))

        while let row = try rows.next() {
            let rowid: Int64 = row["rid"]
            if seenROWIDs.contains(rowid) { continue }
            seenROWIDs.insert(rowid)

            let dateNS: Int64 = row["date"] ?? 0
            let isFromMe = (row["is_from_me"] as Int64? ?? 0) != 0
            let handleID: Int64 = row["handle_id"] ?? 0
            let amt: Int64 = row["amt"] ?? 0

            if (2000...2006).contains(amt) || (3000...3006).contains(amt) {
                let isRemove = amt >= 3000
                let base = isRemove ? amt - 1000 : amt
                let emoji =
                    base == 2006
                    ? (row["ame"] as String? ?? "•")
                    : (Reactions.tapback[base] ?? "•")
                let target = Reactions.targetGUID(from: row["amg"] as String? ?? "")
                rawReactions.append(
                    RawReaction(
                        dateNS: dateNS,
                        sequence: sequence,
                        targetGUID: target,
                        reactorKey: isFromMe ? "me" : "h\(handleID)",
                        reactorLabel: label(isFromMe: isFromMe, handleID: handleID),
                        emoji: emoji,
                        isRemove: isRemove))
                sequence += 1
                continue
            }
            sequence += 1

            if (row["item_type"] as Int64? ?? 0) != 0 { continue }  // system events

            let (text, hadAttachment) = Self.renderText(
                attributedBody: row["attributedBody"],
                fallbackText: row["text"],
                balloonBundleID: row["balloon_bundle_id"],
                attachments: attachmentMap[rowid] ?? [])
            if text.isEmpty { continue }

            let guid: String? = row["guid"]
            // Floor to whole seconds: chat.db dates carry sub-second precision,
            // and DateFormatter rounds fractional seconds up while strftime
            // (the Python reference) truncates them.
            let record = MessageRecord(
                guid: guid,
                date: Date(
                    timeIntervalSince1970: (Double(dateNS) / 1e9 + Self.appleEpochOffset).rounded(
                        .down)),
                speaker: label(isFromMe: isFromMe, handleID: handleID),
                isTarget: !isFromMe && targetHandles.contains(handleID),
                service: row["service"],
                text: text,
                hadAttachment: hadAttachment,
                reactions: [])
            if let guid { indexByGUID[guid] = emitted.count }
            emitted.append(record)
        }

        for (targetGUID, reaction) in Reactions.net(rawReactions) {
            if let i = indexByGUID[targetGUID] {
                emitted[i].reactions.append(reaction)
            }
        }
        for i in emitted.indices {
            emitted[i].reactions.sort {
                (Reactions.displayRank($0.by), $0.by, $0.emoji)
                    < (Reactions.displayRank($1.by), $1.by, $1.emoji)
            }
        }
        return emitted
    }

    /// The opt-in group **system-event** stream for a conversation — participant
    /// added/removed, group renamed, a member leaving.
    /// Off the default path entirely: only the toggle's render calls this, so the
    /// columns it reads (`group_action_type`, `group_title`, `other_handle`) never
    /// touch the default extraction or the schema preflight. Returned as
    /// already-rendered `Transcript.SystemEvent` lines (date + human-readable body),
    /// in `(date, ROWID)` order, ready to interleave into `compactText`.
    ///
    /// Verified `item_type` mapping against the live `chat.db` schema:
    /// - **1** — participant add/remove. `group_action_type` 0 = added, 1 = removed.
    ///   Actor = `handle_id` / `is_from_me`; affected person = `other_handle`.
    /// - **2** — group renamed. New name = `group_title` (empty ⇒ name cleared).
    ///   Actor = `handle_id` / `is_from_me`.
    /// - **3** — a participant left. Actor (the leaver) = `handle_id` / `is_from_me`.
    ///
    /// Each column **value** is read defensively (`row[...] as T?`), so a NULL
    /// degrades to a less-specific phrasing rather than throwing. A *missing
    /// column*, though, throws at statement-prepare time — and these three
    /// (`group_action_type`/`group_title`/`other_handle`) are deliberately NOT in
    /// `requiredSchema` (the default export never reads them). So we **probe** the
    /// `message` table for all three up front (reusing the same `PRAGMA table_info`
    /// introspection the schema guard uses); if a future/older macOS dropped any,
    /// the opt-in stream simply yields `[]` (the toggle shows nothing) rather than
    /// failing-closed a database the default export reads fine.
    public func extractSystemEvents(_ db: GRDB.Database, chatIDs: Set<Int64>) throws
        -> [Transcript.SystemEvent]
    {
        let ids = chatIDs.sorted()
        guard !ids.isEmpty else { return [] }

        // Probe the opt-in-only columns before preparing the SQL: a missing one
        // would throw at prepare time, so degrade to an empty stream instead.
        guard
            try ChatDatabase.hasColumns(
                ["group_action_type", "group_title", "other_handle"], inTable: "message", db: db)
        else {
            Self.log.notice(
                "system events: message table missing group_action_type/group_title/other_handle — yielding none"
            )
            return []
        }

        var events: [Transcript.SystemEvent] = []
        var seenROWIDs = Set<Int64>()
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try Row.fetchCursor(
            db,
            sql: """
                SELECT m.ROWID rid, m.date, m.is_from_me, m.handle_id, m.item_type,
                       m.group_action_type gat, m.group_title gtitle, m.other_handle ohandle
                FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
                WHERE cmj.chat_id IN (\(placeholders))
                  AND m.item_type IN (1, 2, 3)
                ORDER BY m.date, m.ROWID
                """,
            arguments: StatementArguments(ids))

        while let row = try rows.next() {
            let rowid: Int64 = row["rid"]
            if seenROWIDs.contains(rowid) { continue }  // union dedupe (multi-chat)
            seenROWIDs.insert(rowid)

            let itemType: Int64 = row["item_type"] ?? 0
            let isFromMe = (row["is_from_me"] as Int64? ?? 0) != 0
            let handleID: Int64 = row["handle_id"] ?? 0
            let actor = systemEventLabel(isFromMe: isFromMe, handleID: handleID)

            let line: String?
            switch itemType {
            case 1:
                let action: Int64 = row["gat"] ?? 0
                let affected = systemEventLabel(
                    isFromMe: false, handleID: row["ohandle"] ?? 0)
                line = Self.addRemoveLine(actor: actor, affected: affected, added: action == 0)
            case 2:
                let title = (row["gtitle"] as String?)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                line = Self.renameLine(actor: actor, title: title)
            case 3:
                line = Self.leftLine(actor: actor)
            default:
                line = nil
            }

            guard let line else { continue }
            let dateNS: Int64 = row["date"] ?? 0
            events.append(
                Transcript.SystemEvent(
                    date: Date(
                        timeIntervalSince1970: (Double(dateNS) / 1e9 + Self.appleEpochOffset)
                            .rounded(.down)),
                    line: line))
        }
        return events
    }

    /// `<actor> added/removed <affected>` — falling back to a subjectless phrasing
    /// when a side didn't resolve (a row with no recorded actor or target). Returns
    /// nil when neither side is known (nothing legible to say).
    static func addRemoveLine(actor: String?, affected: String?, added: Bool) -> String? {
        let verb = added ? "added" : "removed"
        switch (actor, affected) {
        case (let a?, let t?): return "\(a) \(verb) \(t)"
        case (let a?, nil): return "\(a) \(verb) someone"
        case (nil, let t?): return added ? "\(t) was added" : "\(t) was removed"
        case (nil, nil): return nil
        }
    }

    /// `<actor> named the group "<title>"` (or `cleared the group name` when the
    /// title is empty). Subjectless when the actor didn't resolve.
    static func renameLine(actor: String?, title: String?) -> String? {
        let who = actor ?? "Someone"
        if let title, !title.isEmpty { return "\(who) named the group \"\(title)\"" }
        return "\(who) cleared the group name"
    }

    /// `<actor> left` — nil when the leaver didn't resolve (a degenerate system row
    /// with no handle, which the live DB carries; nothing legible to attribute).
    static func leftLine(actor: String?) -> String? {
        actor.map { "\($0) left" }
    }
}
