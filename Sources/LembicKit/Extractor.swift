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
    /// What kept this row from reading as a normal message. Empty for most rows.
    public var flags: Flags

    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Part of the body could not be read. The text ends with a marker.
        public static let incomplete = Flags(rawValue: 1 << 0)
        /// No body could be read. The text is a marker only.
        public static let unreadable = Flags(rawValue: 1 << 1)
        /// An `item_type` the engine does not know. The text ends with a marker.
        public static let unknownType = Flags(rawValue: 1 << 2)
        /// A message the owner sent that failed (`error` is not 0).
        public static let notDelivered = Flags(rawValue: 1 << 3)
        /// A Send Later message that has not gone out yet.
        public static let scheduled = Flags(rawValue: 1 << 4)
    }

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
        reactions: [Reaction],
        flags: Flags = []
    ) {
        self.guid = guid
        self.date = date
        self.speaker = speaker
        self.isTarget = isTarget
        self.service = service
        self.text = text
        self.hadAttachment = hadAttachment
        self.reactions = reactions
        self.flags = flags
    }
}

/// A row the extractor read but did not emit, so callers can count what is missing.
public struct SkippedMessage: Sendable, Equatable {
    public enum Reason: String, Sendable {
        /// No text, attachment, or app content.
        case emptyBody
        /// An `item_type` the engine does not know, with no text.
        case unknownType
        /// An `associated_message_type` the engine does not know.
        case unknownReaction
        /// A `date` the engine cannot read (zero, negative, or missing).
        case invalidDate
    }

    public let date: Date?
    public let reason: Reason

    public init(date: Date?, reason: Reason) {
        self.date = date
        self.reason = reason
    }
}

/// One conversation's messages and the rows that were not shown.
public struct Extraction: Sendable {
    public var records: [MessageRecord]
    public var skipped: [SkippedMessage]
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
            for handle in p.handleIDs {
                perSpeaker[handle] = p.label
                rosterHandles.insert(handle)
            }
        }
        for handle in conversation.ownerHandles {
            perSpeaker[handle] = "Me"
            rosterHandles.insert(handle)
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
    func loadAttachments(
        _ db: GRDB.Database, chatIDs: [Int64], schema cols: SchemaColumns
    ) throws -> [Int64: [AttachmentInfo]] {
        guard !chatIDs.isEmpty,
            cols.has("message_attachment_join", "message_id"),
            cols.has("message_attachment_join", "attachment_id"),
            cols.hasTable("attachment")
        else { return [:] }
        var map: [Int64: [AttachmentInfo]] = [:]
        var seenLinks = Set<Int64>()
        let placeholders = Array(repeating: "?", count: chatIDs.count).joined(separator: ",")
        let rows = try Row.fetchCursor(
            db,
            sql: """
                SELECT maj.ROWID majid, maj.message_id mid,
                       \(cols.column("at", "attachment", "mime_type")) mime_type,
                       \(cols.column("at", "attachment", "uti")) uti,
                       \(cols.column("at", "attachment", "transfer_name")) transfer_name,
                       \(cols.column("at", "attachment", "is_sticker")) is_sticker,
                       \(cols.column("at", "attachment", "emoji_image_short_description")) genmoji
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
                mimeType: row["mime_type"], uti: row["uti"], transferName: row["transfer_name"],
                isSticker: (row["is_sticker"] as Int64? ?? 0) != 0, emojiDescription: row["genmoji"]
            )
            map[row["mid"], default: []].append(info)
        }
        return map
    }

    /// Decoded text with attachment placeholders spliced in at U+FFFC marks.
    /// A body that does not decode cleanly is marked in the text and in `flags`.
    static func renderText(
        attributedBody: Data?,
        fallbackText: String?,
        balloonBundleID: String?,
        attachments: [AttachmentInfo],
        payload: Data? = nil
    ) -> (text: String, hadAttachment: Bool, flags: MessageRecord.Flags) {
        let (raw, objects, flags) = readBody(attributedBody, fallbackText: fallbackText)
        let isAppMessage = !(balloonBundleID ?? "").isEmpty
        let placeholders = attachments.map(\.placeholder)
        var hadAttachment = false

        let parts = raw.components(separatedBy: "\u{FFFC}")
        var out = parts[0]
        var index = 0
        for i in 1..<parts.count {
            var placeholder = index < placeholders.count ? placeholders[index] : nil
            if index < objects.count,
                let words = transcription(objects[index][AttributedBody.audioTranscriptionKey])
            {
                placeholder = "[audio: \"\(words)\"]"
            } else if index >= placeholders.count, !isAppMessage {
                placeholder = "[attachment]"
            }
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
        if let bundle = balloonBundleID, !bundle.isEmpty,
            let token = AppMessage.token(bundleID: bundle, payload: payload)
        {
            out = out.isEmpty ? token : out + " " + token
        }
        if flags.contains(.unreadable) {
            out = out.isEmpty ? unreadableMarker : out + " " + incompleteMarker
        } else if flags.contains(.incomplete) {
            out += " " + incompleteMarker
        }
        return (out, hadAttachment, flags)
    }

    static let unreadableMarker = "[message could not be read]"
    static let incompleteMarker = "[message may be incomplete]"
    static let unknownTypeMarker = "[unknown message type]"
    static let notDeliveredMarker = "[not delivered]"
    static let scheduledMarker = "[scheduled, not sent]"

    /// A Send Later row (`schedule_type` 2) that has not been sent.
    static func isPendingScheduled(scheduleType: Int64?, isSent: Int64?) -> Bool {
        scheduleType == 2 && (isSent ?? 0) == 0
    }

    /// The body text and per-U+FFFC attributes. `attributedBody` wins when it
    /// decodes; otherwise the text column or a salvaged prefix is used and flagged.
    static func readBody(_ blob: Data?, fallbackText: String?) -> (
        text: String, objects: [[String: String]], flags: MessageRecord.Flags
    ) {
        let fallback = fallbackText ?? ""
        guard let blob, !blob.isEmpty else { return (fallback, [], []) }
        if let body = AttributedBody.parse(blob) {
            if !body.text.isEmpty { return (body.text, body.objects, []) }
            return (fallback, [], fallback.isEmpty ? [] : .incomplete)
        }
        let salvaged = AttributedBody.salvage(blob)
        if let salvaged, salvaged.isComplete { return (salvaged.text, [], []) }
        if !fallback.isEmpty { return (fallback, [], .incomplete) }
        if let salvaged { return (salvaged.text, [], .incomplete) }
        return ("", [], .unreadable)
    }

    /// A voice note's transcription on one line, or nil when there is none.
    static func transcription(_ words: String?) -> String? {
        guard let words else { return nil }
        let line = collapseSpaceRuns(
            words.split(whereSeparator: \.isNewline).joined(separator: " ")
        ).trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
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
        try extract(db, chatIDs: chatIDs).records
    }

    /// `extractConversation` plus the rows it read but did not show.
    public func extract(_ db: GRDB.Database, chatIDs: Set<Int64>) throws -> Extraction {
        let ids = chatIDs.sorted()
        guard !ids.isEmpty else { return Extraction(records: [], skipped: []) }
        let cols = try SchemaColumns.load(db)
        let attachmentMap = try loadAttachments(db, chatIDs: ids, schema: cols)
        func m(_ column: String) -> String { cols.column("m", "message", column) }

        var emitted: [MessageRecord] = []
        var skipped: [SkippedMessage] = []
        var indexByGUID: [String: Int] = [:]
        var rawReactions: [RawReaction] = []
        var seenROWIDs = Set<Int64>()
        var sequence = 0
        var pollOptions: [String: [String: String]] = [:]

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try Row.fetchCursor(
            db,
            sql: """
                SELECT m.ROWID rid, m.guid, m.date, m.is_from_me, m.handle_id,
                       \(m("service")) service, \(m("text")) text,
                       \(m("attributedBody")) attributedBody, \(m("item_type")) item_type,
                       \(m("associated_message_type")) amt, \(m("associated_message_guid")) amg,
                       \(m("associated_message_emoji")) ame,
                       \(m("balloon_bundle_id")) balloon_bundle_id,
                       \(m("date_retracted")) date_retracted, \(m("payload_data")) payload_data,
                       \(m("error")) error, \(m("is_sent")) is_sent,
                       \(m("schedule_type")) schedule_type
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
            // Floor to whole seconds: chat.db dates carry sub-second precision,
            // and DateFormatter rounds fractional seconds up while strftime
            // (the Python reference) truncates them.
            let date = Date(
                timeIntervalSince1970: (Double(dateNS) / 1e9 + Self.appleEpochOffset).rounded(.down)
            )

            let kind = Reactions.kind(of: amt)
            if kind != .message {
                let reactor = isFromMe ? "me" : "h\(handleID)"
                let (target, part) = Reactions.target(from: row["amg"] as String? ?? "")
                let key: String
                let emoji: String
                var isRemove = false
                switch kind {
                case .tapback(let base, let remove):
                    key = (base == 2007 ? "sticker-tapback:" : "tapback:") + reactor
                    emoji = Reactions.emoji(base: base, custom: row["ame"])
                    isRemove = remove
                case .sticker:
                    key = "sticker:\(rowid)"
                    emoji = "sticker"
                case .vote:
                    let options = pollOptions[target] ?? [:]
                    let chosen = (row["payload_data"] as Data?).map(AppMessage.votes(from:)) ?? []
                    let texts = chosen.compactMap { options[$0] }
                    key = "vote:" + reactor
                    emoji = texts.isEmpty ? "voted" : "voted " + texts.joined(separator: ", ")
                case .message, .unknown:
                    Self.log.notice("skipped a row with associated_message_type \(amt)")
                    skipped.append(SkippedMessage(date: date, reason: .unknownReaction))
                    sequence += 1
                    continue
                }
                rawReactions.append(
                    RawReaction(
                        dateNS: dateNS,
                        sequence: sequence,
                        targetGUID: target,
                        part: part,
                        reactorKey: key,
                        reactorLabel: label(isFromMe: isFromMe, handleID: handleID),
                        emoji: emoji,
                        isRemove: isRemove))
                sequence += 1
                continue
            }
            sequence += 1

            let itemType: Int64 = row["item_type"] ?? 0
            if Self.systemItemTypes.contains(itemType) { continue }
            if (row["date_retracted"] as Int64? ?? 0) != 0 { continue }  // unsent

            let payload: Data? = row["payload_data"]
            var (text, hadAttachment, flags) = Self.renderText(
                attributedBody: row["attributedBody"],
                fallbackText: row["text"],
                balloonBundleID: row["balloon_bundle_id"],
                attachments: attachmentMap[rowid] ?? [],
                payload: payload)
            if itemType != 0 {
                guard !text.isEmpty, text != Self.unreadableMarker else {
                    skipped.append(SkippedMessage(date: date, reason: .unknownType))
                    continue
                }
                text += " " + Self.unknownTypeMarker
                flags.insert(.unknownType)
            }
            if text.isEmpty {
                skipped.append(SkippedMessage(date: date, reason: .emptyBody))
                continue
            }
            if isFromMe, (row["error"] as Int64? ?? 0) != 0 {
                text += " " + Self.notDeliveredMarker
                flags.insert(.notDelivered)
            } else if isFromMe,
                Self.isPendingScheduled(
                    scheduleType: row["schedule_type"], isSent: row["is_sent"])
            {
                text += " " + Self.scheduledMarker
                flags.insert(.scheduled)
            }

            let guid: String? = row["guid"]
            if let guid, let payload, let poll = AppMessage.poll(from: payload) {
                pollOptions[guid] = Dictionary(
                    poll.options.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
            }
            let record = MessageRecord(
                guid: guid,
                date: date,
                speaker: label(isFromMe: isFromMe, handleID: handleID),
                isTarget: !isFromMe && targetHandles.contains(handleID),
                service: row["service"],
                text: text,
                hadAttachment: hadAttachment,
                reactions: [],
                flags: flags)
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
        return Extraction(records: emitted, skipped: skipped)
    }

    /// `item_type` values for group and system events, which the event stream reads.
    static let systemItemTypes: Set<Int64> = [1, 2, 3, 4, 5, 6]

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
    /// - **3** — by `group_action_type`: 0 left, 1/2 group photo changed/removed,
    ///   4/6 chat background changed/removed. Actor = `handle_id` / `is_from_me`.
    /// - An add whose `other_handle` is the actor is a phone-number change. Unknown
    ///   action values are skipped, never guessed.
    ///
    /// Each column value is read defensively, so a NULL degrades to a less
    /// specific phrasing. The event columns are in `optionalSchema`, so they are
    /// probed first: if one is missing, the stream is `[]` instead of an error.
    public func extractSystemEvents(_ db: GRDB.Database, chatIDs: Set<Int64>) throws
        -> [Transcript.SystemEvent]
    {
        let ids = chatIDs.sorted()
        guard !ids.isEmpty else { return [] }

        // Probe the opt-in-only columns before preparing the SQL: a missing one
        // would throw at prepare time, so degrade to an empty stream instead.
        guard
            try ChatDatabase.hasColumns(
                ["item_type", "group_action_type", "group_title", "other_handle"],
                inTable: "message", db: db)
        else {
            Self.log.notice("system events: message table lacks the event columns, yielding none")
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
            let action: Int64 = row["gat"] ?? 0
            switch itemType {
            case 1:
                let other: Int64 = row["ohandle"] ?? 0
                let affected = systemEventLabel(isFromMe: false, handleID: other)
                if action == 0, other != 0, other == handleID, !isFromMe {
                    line = actor.map { "\($0) changed their phone number" }
                } else if action == 0 || action == 1 {
                    line = Self.addRemoveLine(actor: actor, affected: affected, added: action == 0)
                } else {
                    line = nil
                }
            case 2:
                let title = (row["gtitle"] as String?)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                line = Self.renameLine(actor: actor, title: title)
            case 3:
                line = Self.groupChangeLine(actor: actor, action: action)
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

    /// An `item_type` 3 row by `group_action_type`: 0 left, 1 and 2 the group
    /// photo, 4 and 6 the chat background. Nil for an unknown action or no actor.
    static func groupChangeLine(actor: String?, action: Int64) -> String? {
        let verb: String? =
            switch action {
            case 0: "left"
            case 1: "changed the group photo"
            case 2: "removed the group photo"
            case 4: "changed the chat background"
            case 6: "removed the chat background"
            default: nil
            }
        guard let actor, let verb else { return nil }
        return "\(actor) \(verb)"
    }
}
