import Foundation
import GRDB
import Testing

@testable import LembicKit

// `messageDateBounds()` is the O7 (PRD §16.11.1) completeness probe: the oldest
// and newest *real* message timestamps in `message`, the app-side classifier's
// signal for a sparse (incomplete) local store. These pin the cheap stat read —
// the `date > 0` sentinel filter, the Apple-epoch conversion, and the empty case
// — without a running Messages.app, mirroring the `messageWatermark()` test.
@Suite("message date bounds")
struct MessageDateBoundsTests {
    /// The group fixture's real messages span date 50 (the earliest, the `se0`
    /// rename event) to 700 (`gm6`). The bounds come back as Apple-epoch Dates, so
    /// each value is `ns / 1e9 + 978_307_200` seconds since 1970.
    @Test func boundsSpanTheRealMessages() throws {
        let db = try Fixtures.openChatDB(populating: Fixtures.groupSchemaAndData)
        let bounds = try db.messageDateBounds()
        let offset = Extractor.appleEpochOffset
        #expect(bounds.oldest == Date(timeIntervalSince1970: 50.0 / 1e9 + offset))
        #expect(bounds.newest == Date(timeIntervalSince1970: 700.0 / 1e9 + offset))
    }

    /// An empty `message` table (and the `date = 0` sentinel filter) yields
    /// `(nil, nil)` — the classifier reads this as "no data," never a false sparse.
    @Test func emptyMessageTableIsNilNil() throws {
        // The full schema with NO message rows inserted.
        let db = try Fixtures.openChatDB(populating: Fixtures.fullSchema)
        let bounds = try db.messageDateBounds()
        #expect(bounds.oldest == nil)
        #expect(bounds.newest == nil)
    }

    /// Rows whose `date` is the `0` sentinel are filtered out, so the floor is a
    /// real message: with one real row at date 500 plus two sentinel rows, both
    /// bounds land on 500.
    @Test func sentinelRowsAreExcluded() throws {
        let sql =
            Fixtures.fullSchema + """
                INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, service, text) VALUES
                    (1,'a',0,0,0,'iMessage','sentinel'),
                    (2,'b',500,0,0,'iMessage','real'),
                    (3,'c',0,0,0,'iMessage','sentinel');
                """
        let db = try Fixtures.openChatDB(populating: sql)
        let bounds = try db.messageDateBounds()
        let offset = Extractor.appleEpochOffset
        #expect(bounds.oldest == Date(timeIntervalSince1970: 500.0 / 1e9 + offset))
        #expect(bounds.newest == Date(timeIntervalSince1970: 500.0 / 1e9 + offset))
    }
}
