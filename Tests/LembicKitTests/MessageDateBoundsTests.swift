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
    /// rename event) to 700 (`gm6`). Values below 10^12 are seconds-era rows, so
    /// each bound is `raw + 978_307_200` seconds since 1970.
    @Test func boundsSpanTheRealMessages() throws {
        let db = try Fixtures.openChatDB(populating: Fixtures.groupSchemaAndData)
        let bounds = try db.messageDateBounds()
        let offset = Extractor.appleEpochOffset
        #expect(bounds.oldest == Date(timeIntervalSince1970: 50 + offset))
        #expect(bounds.newest == Date(timeIntervalSince1970: 700 + offset))
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
        #expect(bounds.oldest == Date(timeIntervalSince1970: 500 + offset))
        #expect(bounds.newest == Date(timeIntervalSince1970: 500 + offset))
    }

    /// Old rows store seconds, newer rows nanoseconds. Both read as real dates.
    @Test func secondsAndNanosecondsBothRead() throws {
        let sql =
            Fixtures.fullSchema + """
                INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, service, text) VALUES
                    (1,'a',486498600,0,0,'iMessage','2016, in seconds'),
                    (2,'b',788918400000000000,0,0,'iMessage','2026, in nanoseconds'),
                    (3,'c',-5,0,0,'iMessage','unknown');
                """
        let db = try Fixtures.openChatDB(populating: sql)
        let bounds = try db.messageDateBounds()
        let offset = Extractor.appleEpochOffset
        #expect(bounds.oldest == Date(timeIntervalSince1970: 486_498_600 + offset))
        #expect(bounds.newest == Date(timeIntervalSince1970: 788_918_400 + offset))
        #expect(Extractor.appleDate(0) == nil)
        #expect(Extractor.appleDate(-5) == nil)
        #expect(Extractor.appleDate(nil) == nil)
    }

    /// Seconds too big to scale to nanoseconds are unknown, never a wrapped date.
    @Test func secondsThatOverflowAreUnknown() {
        for raw: Int64 in [9_223_372_037, 100_000_000_000, 999_999_999_999] {
            #expect(Extractor.nanoseconds(raw) == nil)
            #expect(Extractor.appleDate(raw) == nil)
        }
        #expect(Extractor.nanoseconds(9_223_372_036) == 9_223_372_036_000_000_000)
        #expect(Extractor.nanoseconds(1_000_000_000_000) == 1_000_000_000_000)
    }

    @Test func overflowingRowIsNotABound() throws {
        let sql =
            Fixtures.fullSchema + """
                INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, service, text) VALUES
                    (1,'a',500,0,0,'iMessage','real'),
                    (2,'b',300000000000,0,0,'iMessage','overflow');
                """
        let bounds = try Fixtures.openChatDB(populating: sql).messageDateBounds()
        let real = Date(timeIntervalSince1970: 500 + Extractor.appleEpochOffset)
        #expect(bounds.oldest == real)
        #expect(bounds.newest == real)
    }

    /// The SQL sort key agrees with the Swift date: an overflowing row sorts with
    /// the unknown dates, not as a huge REAL after every real message.
    @Test func overflowingRowSortsLikeAnUnknownDate() throws {
        let sql =
            Fixtures.fullSchema + """
                INSERT INTO chat (ROWID, style, chat_identifier, service_name) VALUES (1,45,'+15551230000','iMessage');
                INSERT INTO handle (ROWID, id) VALUES (1,'+15551230000');
                INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1,1);
                INSERT INTO message (ROWID, guid, date, is_from_me, handle_id, service, text) VALUES
                    (1,'real',500,0,1,'iMessage','real'),
                    (2,'big',300000000000,0,1,'iMessage','overflow'),
                    (3,'zero',0,0,1,'iMessage','unknown');
                INSERT INTO chat_message_join (chat_id, message_id) VALUES (1,1),(1,2),(1,3);
                """
        let db = try Fixtures.openChatDB(populating: sql)
        let order = try db.read {
            try String.fetchAll(
                $0, sql: "SELECT m.guid FROM message m ORDER BY \(Extractor.sortableDate), m.ROWID")
        }
        #expect(order == ["big", "zero", "real"])
        let extraction = try db.read {
            try Extractor(targetHandles: [1], handleLabels: [:]).extract($0, chatIDs: [1])
        }
        #expect(extraction.records.map(\.guid) == ["real"])
        #expect(extraction.skipped.map(\.reason) == [.invalidDate, .invalidDate])
        let real = Date(timeIntervalSince1970: 500 + Extractor.appleEpochOffset)
        #expect(try db.conversationSummaries().map(\.lastMessageDate) == [real])
    }
}
