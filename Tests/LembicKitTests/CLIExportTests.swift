import Foundation
import Testing

@testable import LembicKit
@testable import lembic_cli

// The CLI export goes through the listed Conversation and the engine seam, so it
// labels and drops rows the same way the app does.
@Suite("cli export")
struct CLIExportTests {
    /// Runs `lembic-cli export` on `sql` and returns the written `.txt`.
    private func export(_ sql: String, _ args: [String]) throws -> String {
        let db = try Fixtures.writeChatDB(populating: sql)
        let out = db.deletingLastPathComponent()
        var command = try lembic_cli.Export.parse(
            [db.path, "--number", "+15555550199", "--out-dir", out.path] + args)
        try command.run()
        return try String(
            contentsOf: out.appendingPathComponent("messages_5555550199.txt"), encoding: .utf8)
    }

    @Test func noteToSelfDropsEchoes() throws {
        let txt = try export(NoteToSelfTests.sql, ["--chat-id", "1", "--target-handles", "1"])
        #expect(txt.components(separatedBy: "Buy milk and stamps").count == 2)
        #expect(!txt.contains("Them:"))
    }

    @Test func groupChatLabelsEachSpeaker() throws {
        let txt = try export(
            Fixtures.groupSchemaAndData, ["--chat-id", "10", "--target-handles", "3,5"])
        #expect(txt.hasPrefix("# Messages group transcript"))
        #expect(!txt.contains("Them:"))
        #expect(txt.contains("(816) 000-0003: Alice here"))
    }
}

@Suite("export contacts")
struct ExportContactsTests {
    /// Names passed at init label the render; Contacts is not read again.
    @Test func useContactsLabelsTheRender() throws {
        let db = try Fixtures.openChatDB(populating: Fixtures.groupSchemaAndData)
        defer { db.cleanUp() }
        let list = try Conversations.list(from: db, resolvingContacts: false, region: "US")
        let group = try #require(list.first { $0.chatIDs.contains(10) })
        let exporter = LembicKit.Export(database: db, contacts: ["+18160000003": "Alice Tan"])
        let txt = try #require(exporter.render(group, detect: false).txt)
        #expect(txt.contains("Alice Tan: Alice here"))
    }
}
