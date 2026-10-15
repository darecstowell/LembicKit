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
    /// Sent with the Invisible Ink effect; the detector flags the whole message.
    public let isInvisibleInk: Bool
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
        /// The sender unsent the message. The text is a marker only.
        public static let unsent = Flags(rawValue: 1 << 5)
        /// The sender unsent part of the message. That part is not shown.
        public static let partlyUnsent = Flags(rawValue: 1 << 6)
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
        flags: Flags = [],
        isInvisibleInk: Bool = false
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
        self.isInvisibleInk = isInvisibleInk
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
        /// In a note to self, the incoming copy of a message the owner sent. Not lost.
        case echo
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
    /// A chat with the owner's own address: every row is "Me", and the incoming
    /// copy of each sent message is dropped.
    public let isNoteToSelf: Bool

    public init(
        targetHandles: Set<Int64>,
        handleLabels: [Int64: String],
        rosterHandles: Set<Int64> = [],
        isNoteToSelf: Bool = false
    ) {
        self.targetHandles = targetHandles
        self.handleLabels = handleLabels
        self.rosterHandles = rosterHandles
        self.isNoteToSelf = isNoteToSelf
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
            return Extractor(
                targetHandles: conversation.targetHandles, handleLabels: globalLabels,
                isNoteToSelf: conversation.isNoteToSelf)
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
            perSpeaker[handle] = Transcript.meLabel
            rosterHandles.insert(handle)
        }
        return Extractor(targetHandles: [], handleLabels: perSpeaker, rosterHandles: rosterHandles)
    }

    /// "Me", "Them" for any other sender in a 1:1, else the member's label. A
    /// group row whose handle is missing or unknown is "Unknown sender".
    public func label(isFromMe: Bool, handleID: Int64) -> String {
        if isFromMe || isNoteToSelf { return Transcript.meLabel }
        if isOneToOne { return Transcript.themLabel }
        guard handleID > 0, let label = handleLabels[handleID] else { return "Unknown sender" }
        return label
    }

    /// A 1:1 extractor carries the counterparty's handles; a group's is empty.
    var isOneToOne: Bool { !targetHandles.isEmpty }

    /// The display label for a *system-event* actor / affected person. Mirrors the
    /// group body's labeling — a roster member resolves to its per-thread speaker
    /// label (first name / `First L.`) via `handleLabels`; "Me" for the account
    /// owner. The one extra job over `label`: an `other_handle` (the person an add /
    /// remove targets) can reference a handle that has since **left the roster**, so
    /// its `handleLabels` entry is the raw phone/email — pretty-print that to a
    /// readable number so a removed member reads "Carla" or "(844) 399-6927", never
    /// a bare `h17`. `handleID == 0` (an actor the row didn't record) or a handle
    /// with no row → nil, so the caller can fall back to a subjectless phrasing.
    func systemEventLabel(isFromMe: Bool, handleID: Int64) -> String? {
        if isFromMe { return Transcript.meLabel }
        guard handleID != 0 else { return nil }
        guard let value = handleLabels[handleID] else { return nil }
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
        _ db: GRDB.Database, chatIDs: [Int64], schema cols: SchemaSnapshot
    ) throws -> [Int64: [AttachmentInfo]] {
        guard !chatIDs.isEmpty, cols.has(ChatDatabase.attachmentLinkColumns),
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
                       \(cols.column("at", "attachment", "emoji_image_short_description")) genmoji,
                       \(cols.column("at", "attachment", "guid")) aguid
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
                isSticker: (row["is_sticker"] as Int64? ?? 0) != 0,
                emojiDescription: row["genmoji"],
                guid: row["aguid"])
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
        payload: Data? = nil,
        unsentParts: Set<Int> = []
    ) -> (text: String, hadAttachment: Bool, flags: MessageRecord.Flags) {
        let (raw, objects, flags) = readBody(
            attributedBody, fallbackText: fallbackText, unsentParts: unsentParts)
        if flags.contains(.unsent) { return (unsentMarker, false, flags) }
        let isAppMessage = !(balloonBundleID ?? "").isEmpty
        var unused = Array(attachments.indices)
        var hadAttachment = false

        let parts = hasObjectMark(raw) ? raw.components(separatedBy: "\u{FFFC}") : [raw]
        var out = parts[0]
        for i in 1..<parts.count {
            let attributes = i - 1 < objects.count ? objects[i - 1] : [:]
            // The attachment this mark names, else the next one in join order.
            let named = attributes[AttributedBody.fileTransferGUIDKey].flatMap { guid in
                unused.firstIndex { attachments[$0].matches(transferGUID: guid) }
            }
            let slot = named ?? (unused.isEmpty ? nil : 0)
            var placeholder = slot.flatMap { attachments[unused.remove(at: $0)].placeholder }
            if let words = transcription(attributes[AttributedBody.audioTranscriptionKey]) {
                placeholder = "[audio: \"\(words)\"]"
            } else if slot == nil, !isAppMessage {
                placeholder = "[attachment]"
            }
            if let placeholder {
                out += " " + placeholder + " "
                hadAttachment = true
            }
            out += parts[i]
        }
        let leftover =
            flags.contains(.partlyUnsent) ? [] : unused.compactMap { attachments[$0].placeholder }
        if !leftover.isEmpty {
            hadAttachment = true
            out += " " + leftover.joined(separator: " ")
        }

        out = normalizeWhitespace(normalizeLineBreaks(out))
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
        if flags.contains(.partlyUnsent) { out += " " + partlyUnsentMarker }
        return (out, hadAttachment, flags)
    }

    /// True when `text` holds a U+FFFC (UTF-8 EF BF BC), checked on raw bytes.
    static func hasObjectMark(_ text: String) -> Bool {
        var view = text.utf8.makeIterator()
        var state = 0
        while let byte = view.next() {
            switch (state, byte) {
            case (_, 0xEF): state = 1
            case (1, 0xBF): state = 2
            case (2, 0xBC): return true
            default: state = 0
            }
        }
        return false
    }

    static let unreadableMarker = "[message could not be read]"
    static let incompleteMarker = "[message may be incomplete]"
    static let unknownTypeMarker = "[unknown message type]"
    static let notDeliveredMarker = "[not delivered]"
    static let scheduledMarker = "[scheduled, not sent]"
    static let unsentMarker = "[unsent a message]"
    static let partlyUnsentMarker = "[part of this message was unsent]"

    /// The part indexes `message_summary_info` lists as unsent (its `rp` key).
    static func unsentParts(_ summaryInfo: Data?) -> Set<Int> {
        guard let summaryInfo, summaryInfo.range(of: Data("rp".utf8)) != nil,
            let plist = try? PropertyListSerialization.propertyList(from: summaryInfo, format: nil),
            let parts = (plist as? [String: Any])?["rp"] as? [Any]
        else { return [] }
        return Set(parts.compactMap { ($0 as? NSNumber)?.intValue })
    }

    /// A Send Later row (`schedule_type` 2) that has not been sent.
    static func isPendingScheduled(scheduleType: Int64?, isSent: Int64?) -> Bool {
        scheduleType == 2 && (isSent ?? 0) == 0
    }

    /// The body text and per-U+FFFC attributes. `attributedBody` wins when it
    /// decodes; otherwise the text column or a salvaged prefix is used and flagged.
    static func readBody(_ blob: Data?, fallbackText: String?, unsentParts: Set<Int> = []) -> (
        text: String, objects: [[String: String]], flags: MessageRecord.Flags
    ) {
        if !unsentParts.isEmpty {
            // Without part runs the unsent text cannot be found, so nothing is shown.
            guard let blob, let body = AttributedBody.parse(blob)?.removingParts(unsentParts),
                !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return ("", [], .unsent) }
            return (body.text, body.objects, .partlyUnsent)
        }
        let fallback = fallbackText ?? ""
        guard let blob, !blob.isEmpty else { return (fallback, [], []) }
        // Most bodies are one plain string with no object marks, so no runs are needed.
        if let text = AttributedBody.plainText(blob), !text.isEmpty, !hasObjectMark(text) {
            return (text, [], [])
        }
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

    /// Every line break (`\r\n`, `\r`, U+2028, U+2029, U+0085) becomes `\n`, and
    /// every other C0 control except tab becomes a space.
    static func normalizeLineBreaks(_ s: String) -> String {
        let needsWork = s.utf8.contains { (byte: UInt8) -> Bool in
            if byte == 0xE2 || byte == 0xC2 { return true }
            return byte < 0x20 && byte != 0x0A && byte != 0x09
        }
        guard needsWork else { return s }
        var out = String.UnicodeScalarView()
        var afterCR = false
        for scalar in s.unicodeScalars {
            defer { afterCR = scalar == "\r" }
            switch scalar.value {
            case 0x0A where afterCR: continue
            case 0x0D, 0x2028, 0x2029, 0x85: out.append("\n")
            case 0x0A, 0x09: out.append(scalar)
            case 0x00..<0x20: out.append(" ")
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// Per line: collapse runs of space/tab to one space, strip edges; then
    /// strip the whole text. Matches the Python prototype's
    /// `re.sub(r"[ \t]+", " ", ln).strip()` + outer `.strip()`.
    static func normalizeWhitespace(_ s: String) -> String {
        if isNormalized(s) { return s }
        let lines = s.components(separatedBy: "\n").map { line in
            collapseSpaceRuns(line).trimmingCharacters(in: pythonWhitespace)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: pythonWhitespace)
    }

    /// True when `normalizeWhitespace` would return `s` unchanged: one line, no
    /// tab, no double space, and no whitespace at either end.
    static func isNormalized(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, let last = s.unicodeScalars.last,
            !pythonWhitespace.contains(first), !pythonWhitespace.contains(last)
        else { return s.isEmpty }
        var previous: UInt8 = 0
        for byte in s.utf8 {
            if byte == 0x0A || byte == 0x09 || (byte == 0x20 && previous == 0x20) { return false }
            previous = byte
        }
        return true
    }

    static let invisibleInkEffect = "com.apple.MobileSMS.expressivesend.invisibleink"

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

    /// A raw `message.date` in nanoseconds since 2001. Old rows store seconds, so a
    /// value below 10^12 is scaled up. Nil for 0, NULL, negative values, and
    /// seconds too large to scale.
    static func nanoseconds(_ raw: Int64?) -> Int64? {
        guard let raw, raw > 0 else { return nil }
        if raw >= 1_000_000_000_000 { return raw }
        return raw <= maxSeconds ? raw * 1_000_000_000 : nil
    }

    /// The largest seconds-era `message.date` that fits in Int64 nanoseconds.
    static let maxSeconds: Int64 = 9_223_372_036

    /// SQL true when `column` holds a known date; the twin of `nanoseconds`.
    static func knownDate(_ column: String) -> String {
        "(\(column) > 0 AND (\(column) <= \(maxSeconds) OR \(column) >= 1000000000000))"
    }

    /// A raw `message.date` as a `Date`, or nil when it is unknown.
    static func appleDate(_ raw: Int64?) -> Date? {
        nanoseconds(raw).map { Date(timeIntervalSince1970: Double($0) / 1e9 + appleEpochOffset) }
    }

    /// `m.date` in nanoseconds for `ORDER BY`, so seconds-era rows sort by time.
    /// Seconds too large to scale sort as 0, like other unknown dates.
    static let sortableDate =
        "CASE WHEN m.date >= 1000000000000 THEN m.date WHEN m.date > \(maxSeconds) THEN 0"
        + " ELSE m.date * 1000000000 END"

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
        let schema = try SchemaSnapshot.load(db)
        let attachments = try loadAttachments(db, chatIDs: ids, schema: schema)
        var state = ExtractionState()
        try fetchRows(db, chatIDs: ids, schema: schema) { row, sequence in
            classify(row, sequence: sequence, attachments: attachments, into: &state)
        }
        if isNoteToSelf { applyNoteToSelf(&state) }
        attachReactions(&state)
        return Extraction(records: state.emitted, skipped: state.skipped)
    }

    /// What `extract` has built so far, carried through its stages.
    struct ExtractionState {
        var emitted: [MessageRecord] = []
        var incoming: [Bool] = []
        var skipped: [SkippedMessage] = []
        var indexByGUID: [String: Int] = [:]
        var rawReactions: [RawReaction] = []
        var pollOptions: [String: [String: String]] = [:]
    }

    /// Streams each message row once, in date order, with its index among the de-duped rows.
    func fetchRows(
        _ db: GRDB.Database, chatIDs ids: [Int64], schema: SchemaSnapshot,
        _ body: (MessageRow, Int) throws -> Void
    ) throws {
        var seenROWIDs = Set<Int64>()
        var sequence = 0
        let rows = try Row.fetchCursor(
            db, sql: MessageRow.query(schema, chatCount: ids.count),
            arguments: StatementArguments(ids))
        while let row = try rows.next() {
            guard seenROWIDs.insert(MessageRow.rowid(row)).inserted else { continue }
            try body(MessageRow(row), sequence)
            sequence += 1
        }
    }

    /// Routes a row to the reactions, the skipped list, or the emitted records.
    func classify(
        _ row: MessageRow, sequence: Int, attachments: [Int64: [AttachmentInfo]],
        into state: inout ExtractionState
    ) {
        let kind = Reactions.kind(of: row.associatedType)
        if kind != .message {
            routeReaction(row, kind: kind, sequence: sequence, into: &state)
            return
        }
        if Self.systemItemTypes.contains(row.itemType) { return }
        switch buildRecord(row, attachments: attachments[row.rowid] ?? []) {
        case .skipped(let skip):
            state.skipped.append(skip)
        case .record(let record, let payload):
            if let guid = record.guid, let payload, let poll = AppMessage.poll(from: payload) {
                state.pollOptions[guid] = Dictionary(
                    poll.options.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
            }
            if let guid = record.guid { state.indexByGUID[guid] = state.emitted.count }
            state.emitted.append(record)
            state.incoming.append(!row.isFromMe)
        }
    }

    func routeReaction(
        _ row: MessageRow, kind: Reactions.Kind, sequence: Int, into state: inout ExtractionState
    ) {
        let reactor =
            row.isFromMe || isNoteToSelf ? "me" : isOneToOne ? "them" : "h\(row.handleID)"
        let (target, part) = Reactions.target(from: row.associatedGUID ?? "")
        let key: String
        let emoji: String
        var isRemove = false
        switch kind {
        case .tapback(let base, let remove):
            key = (base == 2007 ? "sticker-tapback:" : "tapback:") + reactor
            emoji = Reactions.emoji(base: base, custom: row.associatedEmoji)
            isRemove = remove
        case .sticker:
            key = "sticker:\(row.rowid)"
            emoji = "sticker"
        case .vote:
            let options = state.pollOptions[target] ?? [:]
            let chosen = row.payload.map(AppMessage.votes(from:)) ?? []
            let texts = chosen.compactMap { options[$0] }
            key = "vote:" + reactor
            emoji = texts.isEmpty ? "voted" : "voted " + texts.joined(separator: ", ")
        case .message, .unknown:
            Self.log.notice("skipped a row with associated_message_type \(row.associatedType)")
            state.skipped.append(SkippedMessage(date: row.knownDate, reason: .unknownReaction))
            return
        }
        state.rawReactions.append(
            RawReaction(
                dateNS: row.dateNS,
                sequence: sequence,
                targetGUID: target,
                part: part,
                reactorKey: key,
                reactorLabel: label(isFromMe: row.isFromMe, handleID: row.handleID),
                emoji: emoji,
                isRemove: isRemove))
    }

    enum Built {
        /// The record, and the app payload a poll's options are read from.
        case record(MessageRecord, payload: Data?)
        case skipped(SkippedMessage)
    }

    /// The body, markers, and flags for one message row, or why it is not shown.
    func buildRecord(_ row: MessageRow, attachments: [AttachmentInfo]) -> Built {
        let payload = row.isRetracted ? nil : row.payload
        var (text, hadAttachment, flags) =
            row.isRetracted
            ? (Self.unsentMarker, false, MessageRecord.Flags.unsent)
            : Self.renderText(
                attributedBody: row.attributedBody,
                fallbackText: row.text.map { String(decoding: $0, as: UTF8.self) },
                balloonBundleID: row.balloonBundleID,
                attachments: attachments,
                payload: payload, unsentParts: Self.unsentParts(row.summaryInfo))
        if row.itemType != 0 {
            guard !text.isEmpty, text != Self.unreadableMarker else {
                return .skipped(SkippedMessage(date: row.knownDate, reason: .unknownType))
            }
            text += " " + Self.unknownTypeMarker
            flags.insert(.unknownType)
        }
        if text.isEmpty {
            return .skipped(SkippedMessage(date: row.knownDate, reason: .emptyBody))
        }
        guard let date = row.knownDate else {
            return .skipped(SkippedMessage(date: nil, reason: .invalidDate))
        }
        let canMark = row.isFromMe && !flags.contains(.unsent)
        if canMark, row.hasError {
            text += " " + Self.notDeliveredMarker
            flags.insert(.notDelivered)
        } else if canMark,
            Self.isPendingScheduled(scheduleType: row.scheduleType, isSent: row.isSent)
        {
            text += " " + Self.scheduledMarker
            flags.insert(.scheduled)
        }
        let record = MessageRecord(
            guid: row.guid,
            date: date,
            speaker: label(isFromMe: row.isFromMe, handleID: row.handleID),
            isTarget: !row.isFromMe && isOneToOne && !isNoteToSelf,
            service: row.service,
            text: text,
            hadAttachment: hadAttachment,
            reactions: [],
            flags: flags,
            isInvisibleInk: row.effect == Self.invisibleInkEffect)
        return .record(record, payload: payload)
    }

    /// Drops the incoming echo of each sent note and points its reactions at the sent row.
    func applyNoteToSelf(_ state: inout ExtractionState) {
        let echoes = Self.echoes(in: state.emitted, incoming: state.incoming)
        for (echo, sent) in echoes {
            if let guid = state.emitted[echo].guid { state.indexByGUID[guid] = sent }
            state.skipped.append(SkippedMessage(date: state.emitted[echo].date, reason: .echo))
        }
        let kept = state.emitted.indices.filter { echoes[$0] == nil }
        let newIndex = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })
        state.indexByGUID = state.indexByGUID.compactMapValues { newIndex[$0] }
        state.emitted = kept.map { state.emitted[$0] }
    }

    /// Nets the reactions and attaches each to its target, in display order.
    func attachReactions(_ state: inout ExtractionState) {
        for (targetGUID, reaction) in Reactions.net(state.rawReactions) {
            if let i = state.indexByGUID[targetGUID] {
                state.emitted[i].reactions.append(reaction)
            }
        }
        for i in state.emitted.indices {
            state.emitted[i].reactions.sort {
                (Reactions.displayRank($0.by), $0.by, $0.emoji)
                    < (Reactions.displayRank($1.by), $1.by, $1.emoji)
            }
        }
    }

    /// In a note to self, each incoming row that repeats a sent row's text within a
    /// minute, mapped to that sent row's index. Each sent row pairs once.
    static func echoes(in records: [MessageRecord], incoming: [Bool]) -> [Int: Int] {
        var sentByText: [String: [Int]] = [:]
        for i in records.indices where !incoming[i] {
            sentByText[records[i].text, default: []].append(i)
        }
        var pairs: [Int: Int] = [:]
        for i in records.indices where incoming[i] {
            guard var candidates = sentByText[records[i].text],
                let match = candidates.firstIndex(where: {
                    abs(records[$0].date.timeIntervalSince(records[i].date)) <= 60
                })
            else { continue }
            pairs[i] = candidates.remove(at: match)
            sentByText[records[i].text] = candidates
        }
        return pairs
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
        let columns = ChatDatabase.systemEventColumns
        guard try SchemaSnapshot.load(db, tables: [columns.table]).has(columns) else {
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
                ORDER BY \(Self.sortableDate), m.ROWID
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

            guard let line, let date = Self.appleDate(row["date"]) else { continue }
            events.append(
                Transcript.SystemEvent(
                    date: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)),
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

/// One `message` row as `Extractor.extract` reads it. `query` and `init` read the
/// columns by position (a name lookup costs a string compare per column per row),
/// so keep the SELECT order and the indexes in step.
struct MessageRow {
    let rowid: Int64
    let guid: String?
    let rawDate: Int64?
    let isFromMe: Bool
    let handleID: Int64
    let service: String?
    let text: Data?
    let attributedBody: Data?
    let itemType: Int64
    let associatedType: Int64
    let associatedGUID: String?
    let associatedEmoji: String?
    let balloonBundleID: String?
    let isRetracted: Bool
    let payload: Data?
    let hasError: Bool
    let isSent: Int64?
    let scheduleType: Int64?
    let summaryInfo: Data?
    let effect: String?

    static func query(_ schema: SchemaSnapshot, chatCount: Int) -> String {
        func m(_ column: String) -> String { schema.column("m", "message", column) }
        let placeholders = Array(repeating: "?", count: chatCount).joined(separator: ",")
        return """
            SELECT m.ROWID rid, m.guid, m.date, m.is_from_me, m.handle_id,
                   \(m("service")) service, CAST(\(m("text")) AS BLOB) text,
                   \(m("attributedBody")) attributedBody, \(m("item_type")) item_type,
                   \(m("associated_message_type")) amt, \(m("associated_message_guid")) amg,
                   \(m("associated_message_emoji")) ame,
                   \(m("balloon_bundle_id")) balloon_bundle_id,
                   \(m("date_retracted")) date_retracted, \(m("payload_data")) payload_data,
                   \(m("error")) error, \(m("is_sent")) is_sent,
                   \(m("schedule_type")) schedule_type,
                   \(m("message_summary_info")) msi,
                   \(m("expressive_send_style_id")) effect
            FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id IN (\(placeholders))
            ORDER BY \(Extractor.sortableDate), m.ROWID
            """
    }

    static func rowid(_ row: Row) -> Int64 { row[0] }

    init(_ row: Row) {
        rowid = row[0]
        guid = row[1]
        rawDate = row[2]
        isFromMe = (row[3] as Int64? ?? 0) != 0
        handleID = row[4] ?? 0
        service = row[5]
        text = row[6]
        attributedBody = row[7]
        itemType = row[8] ?? 0
        associatedType = row[9] ?? 0
        associatedGUID = row[10]
        associatedEmoji = row[11]
        balloonBundleID = row[12]
        isRetracted = (row[13] as Int64? ?? 0) != 0
        payload = row[14]
        hasError = (row[15] as Int64? ?? 0) != 0
        isSent = row[16]
        scheduleType = row[17]
        summaryInfo = row[18]
        effect = row[19]
    }

    var dateNS: Int64 { Extractor.nanoseconds(rawDate) ?? 0 }

    /// The date floored to whole seconds: DateFormatter rounds fractional seconds
    /// up, while strftime (the Python reference) truncates them. Nil when unknown.
    var knownDate: Date? {
        Extractor.appleDate(rawDate).map {
            Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down))
        }
    }
}
