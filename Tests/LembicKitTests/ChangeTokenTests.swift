import Foundation
import GRDB
import Testing

@testable import LembicKit

// An edit, unsend, or delete changes no ROWID, but the change token still moves
// (lembickit.md F20).
@Suite("change token")
struct ChangeTokenTests {
    @Test func editsMoveTheTokenButNotTheWatermark() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lembic-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("chat.db").path
        let writer = try DatabaseQueue(path: path)
        try writer.write {
            try $0.execute(
                sql: """
                    CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT);
                    INSERT INTO message VALUES (1, 'hello'), (2, 'secret');
                    """)
        }
        let db = try ChatDatabase(at: URL(fileURLWithPath: path))
        defer { db.cleanUp() }

        let before = try db.changeToken()
        try writer.write {
            try $0.execute(sql: "UPDATE message SET text = 'edited' WHERE ROWID = 2")
        }
        let afterEdit = try db.changeToken()
        #expect(afterEdit.messageWatermark == before.messageWatermark)
        #expect(afterEdit != before)

        try writer.write { try $0.execute(sql: "DELETE FROM message WHERE ROWID = 1") }
        let afterDelete = try db.changeToken()
        #expect(afterDelete != afterEdit)
        #expect(try db.changeToken() == afterDelete, "no change, same token")
    }
}
