import ArgumentParser
import Foundation
import LembicKit

@main
struct LembicCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lembic-cli",
        abstract: "Export iMessage 1:1 threads from chat.db as compact .txt + .jsonl for LLMs.",
        subcommands: [Export.self, ConversationsCommand.self],
        // `Export` is the default so `lembic-cli <db> …` keeps exporting exactly
        // as before the subcommand split (docs/scripts don't break).
        defaultSubcommand: Export.self
    )
}

/// Export a thread (or a contact's unioned threads) to compact .txt + .jsonl.
/// The default subcommand, so `lembic-cli <db>` runs this.
struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export an iMessage 1:1 thread from chat.db as compact .txt + .jsonl for LLMs."
    )

    @Argument(help: "Path to chat.db. It is copied to a private temp dir before reading.")
    var databasePath: String

    @Option(name: .customLong("chat-id"), help: "ROWID of the chat to export.")
    var chatID: Int64 = 32

    @Option(help: "Counterparty phone number, used in transcript headers and file names.")
    var number: String = "+15551234567"

    @Option(
        name: .customLong("target-handles"),
        help: "Comma-separated handle ROWIDs belonging to the counterparty (iMessage/SMS/RCS).")
    var targetHandles: String = "3,73,1248"

    @Option(
        name: .customLong("out-dir"), help: "Directory to write messages_<number>.txt/.jsonl into.")
    var outDir: String = "."

    @Option(help: "Print the first N rendered messages instead of writing files (eyeball mode).")
    var sample: Int?

    @Flag(help: "Also resolve handles to names via the Contacts framework (triggers a TCC prompt).")
    var contacts = false

    @Flag(
        help:
            "Union all of --target-handles' 1:1 chats into one contact-centric export.")
    var union = false

    @Flag(
        name: .customLong("redact-detected"),
        help: "Redact every auto-detected secret (passwords/SSNs/cards) in the exported .txt.")
    var redactDetected = false

    @Flag(
        name: .customLong("anonymize"),
        help:
            "Relabel speakers as Person 1, Person 2, … and scrub the number/name from the header (de-bias)."
    )
    var anonymize = false

    mutating func run() throws {
        let handles = Set(
            targetHandles.split(separator: ",").compactMap {
                Int64($0.trimmingCharacters(in: .whitespaces))
            })
        guard !handles.isEmpty else {
            throw ValidationError("--target-handles must contain at least one handle ROWID")
        }

        // Route through the engine seam: this copies, PREFLIGHTS (the schema
        // guard the old CLI skipped), and owns the temp db for the run.
        let exporter = try LembicKit.Export(chatDBAt: URL(fileURLWithPath: databasePath))
        defer { exporter.close() }
        let db = exporter.database

        let counts = try db.counts()
        print(
            "[db] \(Transcript.comma(counts.messages)) messages · \(Transcript.comma(counts.handles)) handles · \(Transcript.comma(counts.chats)) chats"
        )

        let handleLabels = try db.handleLabels()
        let extractor = Extractor(targetHandles: handles, handleLabels: handleLabels)

        if union {
            try runUnion(exporter: exporter, extractor: extractor, handles: handles)
            return
        }

        if let sample {
            let records = try db.queue.read { try extractor.extractChat($0, chatID: chatID) }
            for r in records.prefix(sample) {
                print("\(r.date) \(r.speaker): \(r.text)")
            }
            print(
                "[sample] showed \(min(sample, records.count)) of \(Transcript.comma(records.count)) messages"
            )
            return
        }

        if contacts {
            let names = try ContactsMap.buildContactInfo().names
            let (_, matched) = ContactsMap.resolve(handleLabels: handleLabels, contacts: names)
            print(
                "[contacts] \(Transcript.comma(names.count)) handles in Contacts · matched \(matched)/\(handleLabels.count) chat.db handles"
            )
        }

        // The gated direct export takes explicit ROWIDs by design,
        // so synthesize a minimal Conversation from the flags for the seam.
        let conv = Conversation(
            id: number, displayName: number, chatIDs: [chatID], targetHandles: handles,
            identifiers: [number], lastMessageDate: .distantPast, messageCount: 0,
            primaryIdentifier: number, isContact: false)

        // First render to detect; if --redact-detected, build redactions from the
        // detected secrets and re-render the .txt with them applied.
        let scope = LembicKit.Export.Scope(anonymizeSpeakers: anonymize)
        var out = try exporter.render(
            conv, formats: [.txt, .jsonl], scope: scope, redactions: RedactionSet(), detect: true,
            resolveContacts: contacts)
        if redactDetected, !out.detected.isEmpty {
            var redactions = RedactionSet()
            for d in out.detected { redactions.add(Redaction(guid: d.guid, range: d.range)) }
            out = try exporter.render(
                conv, formats: [.txt, .jsonl], scope: scope, redactions: redactions, detect: true,
                resolveContacts: contacts)
        }

        var digits = number.filter(\.isNumber)
        if digits.count == 11, digits.hasPrefix("1") { digits = String(digits.dropFirst()) }
        let base = URL(fileURLWithPath: outDir, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let txtURL = base.appendingPathComponent("messages_\(digits).txt")
        let jsonlURL = base.appendingPathComponent("messages_\(digits).jsonl")

        try (out.txt ?? "").write(to: txtURL, atomically: true, encoding: .utf8)
        try (out.jsonl ?? "").write(to: jsonlURL, atomically: true, encoding: .utf8)

        let stillVisible = out.result?.highlightMarks.count ?? 0
        print(
            "[direct]  \(Transcript.comma(out.messageCount)) msgs · "
                + "\(Transcript.comma(out.detected.count)) secrets flagged "
                + "(\(Transcript.comma(stillVisible)) still visible"
                + (redactDetected ? ", redacted in .txt" : "")
                + ") -> \(txtURL.path)/.jsonl")
    }

    /// Conversation-union path. Resolve --target-handles to all of
    /// the contact's 1:1 chats, export their union, and print a reconciliation
    /// (Σ per-chat vs union, de-dupes, per-service split) since there is no
    /// byte-for-byte reference for this path.
    private func runUnion(
        exporter: LembicKit.Export, extractor: Extractor, handles: Set<Int64>
    ) throws {
        let db = exporter.database
        let chats = try db.oneToOneChats(forHandles: handles)
        guard !chats.isEmpty else {
            print("[union] no 1:1 (style=45) chats found for handles \(handles.sorted())")
            return
        }
        let ids = Set(chats.map(\.chatID))
        let records = try db.queue.read { try extractor.extractConversation($0, chatIDs: ids) }

        print("[union] handles \(handles.sorted()) → \(chats.count) one-to-one chat(s):")
        var sumIndividual = 0
        var biggest = (id: Int64(0), count: -1)
        for c in chats {
            let n = try db.queue.read { try extractor.extractChat($0, chatID: c.chatID).count }
            sumIndividual += n
            if n > biggest.count { biggest = (c.chatID, n) }
            print(
                "        chat \(c.chatID)  \(c.identifier ?? "?")  \(c.service ?? "?")  \(Transcript.comma(n)) msgs"
            )
        }
        let stats = Transcript.stats(for: records)
        let dupes = sumIndividual - records.count
        print(
            "[union] \(Transcript.comma(records.count)) messages after union "
                + "(Σ per-chat \(Transcript.comma(sumIndividual)), \(Transcript.comma(dupes)) de-duped, "
                + "\(Transcript.comma(stats.reactions)) reactions)")

        var byService: [String: Int] = [:]
        for r in records { byService[r.service ?? "—", default: 0] += 1 }
        let svc = byService.sorted { $0.value > $1.value }
            .map { "\($0.key) \(Transcript.comma($0.value))" }.joined(separator: " · ")
        print("[union] by service: \(svc)")
        print(
            "[union] recovered \(Transcript.comma(records.count - max(biggest.count, 0))) message(s) "
                + "beyond the largest single chat (chat \(biggest.id), \(Transcript.comma(max(biggest.count, 0)))) — the green-bubble half"
        )

        let other = records.filter { ($0.service ?? "iMessage") != "iMessage" }.prefix(3)
        if !other.isEmpty {
            print("[union] sample non-iMessage messages (your own data, local only):")
            for r in other {
                print("        \(r.date) \(r.speaker) [\(r.service ?? "?")]: \(r.text.prefix(64))")
            }
        }

        var digits = number.filter(\.isNumber)
        if digits.count == 11, digits.hasPrefix("1") { digits = String(digits.dropFirst()) }
        let base = URL(fileURLWithPath: outDir, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // Route the file writes through the redaction-aware seam (the diagnostic
        // prints above stay on the raw extractor). The union's chat ROWIDs feed a
        // synthesized Conversation so detection + optional --redact-detected apply.
        let conv = Conversation(
            id: number, displayName: number, chatIDs: ids, targetHandles: handles,
            identifiers: [number], lastMessageDate: .distantPast, messageCount: 0,
            primaryIdentifier: number, isContact: false)
        let scope = LembicKit.Export.Scope(anonymizeSpeakers: anonymize)
        var out = try exporter.render(
            conv, formats: [.txt, .jsonl], scope: scope, redactions: RedactionSet(), detect: true,
            resolveContacts: contacts)
        if redactDetected, !out.detected.isEmpty {
            var redactions = RedactionSet()
            for d in out.detected { redactions.add(Redaction(guid: d.guid, range: d.range)) }
            out = try exporter.render(
                conv, formats: [.txt, .jsonl], scope: scope, redactions: redactions, detect: true,
                resolveContacts: contacts)
        }
        try (out.txt ?? "").write(
            to: base.appendingPathComponent("union_\(digits).txt"), atomically: true,
            encoding: .utf8)
        try (out.jsonl ?? "").write(
            to: base.appendingPathComponent("union_\(digits).jsonl"), atomically: true,
            encoding: .utf8)
        print(
            "[union] wrote union_\(digits).txt/.jsonl to \(base.path) · "
                + "\(Transcript.comma(out.detected.count)) secrets flagged"
                + (redactDetected ? " (redacted in .txt)" : ""))
    }
}

/// List the people in a chat.db — one line per contact-centric conversation, with
/// the chatIDs + handle ROWIDs the export args need, so a stranger can discover
/// them instead of hand-querying. Read-only convenience.
struct ConversationsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "conversations",
        abstract: "List the 1:1 conversations (people) in a chat.db, newest first."
    )

    @Argument(help: "Path to chat.db. It is copied to a private temp dir before reading.")
    var databasePath: String

    @Flag(
        help: "Resolve handles to contact names via the Contacts framework (triggers a TCC prompt)."
    )
    var contacts = false

    func run() throws {
        let people = try LembicKit.Conversations.list(
            copying: URL(fileURLWithPath: databasePath), resolvingContacts: contacts)

        guard !people.isEmpty else {
            print("[conversations] no 1:1 (style=45) conversations found")
            return
        }

        print("[conversations] \(Transcript.comma(people.count)) people (newest first):")
        for c in people {
            let last = c.lastMessageDate.formatted(date: .abbreviated, time: .omitted)
            let chats = c.chatIDs.sorted().map(String.init).joined(separator: ",")
            let handles = c.targetHandles.sorted().map(String.init).joined(separator: ",")
            print(
                "  \(c.displayName)  ·  \(Transcript.comma(c.messageCount)) msgs  ·  \(last)"
                    + "  ·  chat-id \(chats)  ·  target-handles \(handles)")
        }
    }
}
