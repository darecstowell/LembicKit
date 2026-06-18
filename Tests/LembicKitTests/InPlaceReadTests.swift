import Foundation
import GRDB
import Testing

@testable import LembicKit

// The in-place, read-only open replaces the old temp-copy path. These tests are
// deterministic and need NO running Messages.app:
//
//  1. WAL-read-in-place — the key de-risk: a `ChatDatabase` opened read-only on a
//     live, still-open writer's file sees rows the writer committed but has NOT
//     checkpointed, proving we read uncheckpointed WAL frames in place (not a
//     stale snapshot, not a copy).
//  2. Retry classification + the bounded-retry loop (`isTransient` / `withRetry`),
//     so the best-effort-live contract is unit-tested without a contended DB.
//  3. The O(1) `messageWatermark()` the app polls for new activity.
@Suite("in-place read")
struct InPlaceReadTests {
    /// Open a writer, go WAL, write rows, then open a SECOND read-only connection
    /// via `ChatDatabase(at:)` against the SAME file WHILE the writer is still
    /// open and has NOT checkpointed. The reader must see the newly-inserted rows,
    /// proving it reads live, uncheckpointed WAL frames in place.
    @Test func readsLiveUncheckpointedWAL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lembic-inplace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("chat.db")

        // Keep the writer OPEN for the whole test so nothing closes/checkpoints
        // the WAL out from under us.
        let writer = try DatabaseQueue(path: path.path)
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "CREATE TABLE t (id INTEGER)")
        }
        try writer.write { db in
            for i in 1...3 { try db.execute(sql: "INSERT INTO t (id) VALUES (?)", arguments: [i]) }
        }

        // Second connection: read-only, in place — exactly the production open.
        let cdb = try ChatDatabase(at: path)
        let before = try cdb.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM t") }
        #expect(before == 3, "the in-place reader sees the writer's first batch")

        // More rows, NO explicit checkpoint. Only a handful, so SQLite's automatic
        // WAL checkpoint (1000 pages) does not fire — the frames stay in the WAL.
        try writer.write { db in
            for i in 4...7 { try db.execute(sql: "INSERT INTO t (id) VALUES (?)", arguments: [i]) }
        }
        let after = try cdb.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM t") }
        #expect(after == 7, "the in-place reader sees uncheckpointed WAL frames — reads live")
    }

    /// `isTransient` retries only the torn-read family (busy/locked/I-O/corrupt/
    /// not-a-DB); a genuine logic error (`.SQLITE_ERROR`) and a non-SQLite error
    /// fall straight through.
    @Test func transientClassification() {
        #expect(ChatDatabase.isTransient(DatabaseError(resultCode: .SQLITE_BUSY)))
        #expect(ChatDatabase.isTransient(DatabaseError(resultCode: .SQLITE_LOCKED)))
        #expect(ChatDatabase.isTransient(DatabaseError(resultCode: .SQLITE_IOERR)))
        #expect(ChatDatabase.isTransient(DatabaseError(resultCode: .SQLITE_CORRUPT)))
        #expect(ChatDatabase.isTransient(DatabaseError(resultCode: .SQLITE_NOTADB)))
        #expect(!ChatDatabase.isTransient(DatabaseError(resultCode: .SQLITE_ERROR)))
        struct Other: Error {}
        #expect(!ChatDatabase.isTransient(Other()))
    }

    /// The loop retries past transient failures and returns the eventual value,
    /// but rethrows a non-transient error on the first try (no wasted retries).
    @Test func retryLoop() throws {
        var calls = 0
        let value = try ChatDatabase.withRetry(attempts: 3, backoff: 0) { () throws -> Int in
            calls += 1
            if calls < 3 { throw DatabaseError(resultCode: .SQLITE_BUSY) }
            return 42
        }
        #expect(value == 42, "returns the value once a retry succeeds")
        #expect(calls == 3, "two transient throws then success = three attempts")

        struct Fatal: Error {}
        var fatalCalls = 0
        #expect(throws: Fatal.self) {
            try ChatDatabase.withRetry(attempts: 3, backoff: 0) { () throws -> Int in
                fatalCalls += 1
                throw Fatal()
            }
        }
        #expect(fatalCalls == 1, "a non-transient error rethrows immediately, no retry")
    }

    /// `messageWatermark()` returns MAX(ROWID) over `message` — the value the app
    /// polls to detect new activity.
    @Test func watermarkIsMaxRowID() throws {
        let db = try Fixtures.openChatDB(populating: Fixtures.groupSchemaAndData)
        // The group fixture's highest message ROWID is 112 (the `se2` leave event).
        #expect(try db.messageWatermark() == 112, "watermark = MAX(ROWID) over message")
    }
}
