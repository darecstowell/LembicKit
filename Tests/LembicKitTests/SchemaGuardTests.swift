import Foundation
import GRDB
import Testing

@testable import LembicKit

// The guard must pass on the full schema the engine reads and
// pinpoint exactly what a future/older macOS would have dropped or renamed.
//
// DB-backed: calls the *instance* `db.schemaProblems()` over a real
// `ChatDatabase` (the folded database surface). Each former `do { … } catch` block is
// now its own `throws` test — a fixture throw fails the test with the real error.
@Suite("schema guard")
struct SchemaGuardTests {
    @Test func fullSchemaClean() throws {
        let db = try Fixtures.openChatDB(populating: Fixtures.fullSchema)
        let problems = try db.schemaProblems()
        #expect(problems.isEmpty, "full schema → no problems")
    }

    @Test func missingColumnNamedExactly() throws {
        let sql = Fixtures.fullSchema.replacingOccurrences(of: "is_from_me INTEGER,", with: "")
        let db = try Fixtures.openChatDB(populating: sql)
        let problems = try db.schemaProblems()
        #expect(
            problems == [SchemaProblem(table: "message", column: "is_from_me")],
            "missing core column reported by exact (table, column)")
    }

    @Test func missingTableReportedWithNilColumn() throws {
        let noJoin =
            Fixtures.fullSchema
            .components(separatedBy: "\n")
            .filter { !$0.contains("CREATE TABLE chat_message_join ") }
            .joined(separator: "\n")
        let db = try Fixtures.openChatDB(populating: noJoin)
        let problems = try db.schemaProblems()
        #expect(
            problems.contains(SchemaProblem(table: "chat_message_join", column: nil)),
            "missing core table reported with column = nil")
    }

    @Test func missingOptionalTableIsNotAProblem() throws {
        let noAttachment =
            Fixtures.fullSchema
            .components(separatedBy: "\n")
            .filter { !$0.contains("CREATE TABLE attachment ") }
            .joined(separator: "\n")
        let db = try Fixtures.openChatDB(populating: noAttachment)
        #expect(try db.schemaProblems().isEmpty, "attachments are optional")
        let gaps = try db.missingOptionalColumns()
        #expect(
            gaps.contains(SchemaProblem(table: "attachment", column: nil)),
            "the missing optional table is listed for diagnostics")
    }
}
