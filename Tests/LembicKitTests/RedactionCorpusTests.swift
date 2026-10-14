import Foundation
import Testing

@testable import LembicKit

// Labeled corpora for the detectors and scrubbers, stored base64 so no secret-shaped
// literal sits in the repo (decode with `base64 -d`). Sets named `tune-` were used to
// tune the rules. Sets named `heldout-` were never used to tune: they only score.
// Set LEMBIC_CORPUS_REPORT=1 to print the score table.
@Suite("redaction corpus")
struct RedactionCorpusTests {
    struct Case: Decodable {
        let id: String
        let cat: String
        let family: String
        let msgs: [String]
        let expect: [[Value]]

        enum Value: Decodable {
            case int(Int), str(String)
            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if let i = try? c.decode(Int.self) { self = .int(i) } else { self = .str(try c.decode(String.self)) }
            }
        }
    }

    struct Score { var pos = 0, tp = 0, neg = 0, negFP = 0 }

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name, withExtension: "b64", subdirectory: "Fixtures/redaction-corpus"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return try #require(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
    }

    static func cases(_ name: String) throws -> [Case] {
        try JSONDecoder().decode([Case].self, from: fixture("\(name).json"))
    }

    static func category(_ c: String) -> String {
        ["govId", "governmentID", "intlId", "healthId"].contains(c) ? "idNumber" : c
    }

    static let base = Date(timeIntervalSince1970: 1_780_000_000)

    static func records(_ id: String, _ msgs: [String]) -> [MessageRecord] {
        msgs.enumerated().map { i, t in
            MessageRecord(
                guid: "\(id)#\(i)", date: base.addingTimeInterval(Double(i) * 30), speaker: "Them",
                isTarget: true, service: "iMessage", text: t, hadAttachment: false, reactions: [])
        }
    }

    /// Hits as (message index, range, category).
    static func hits(_ c: Case, scrubber: Bool) -> [(Int, Range<Int>, String)] {
        let rs = records(c.id, c.msgs)
        func index(_ guid: String) -> Int { Int(guid.split(separator: "#").last!)! }
        if scrubber {
            return ScrubberCategory.allCases.flatMap { cat in
                SecretScrubber.scrub(in: rs, categories: [cat]).all.compactMap { r in
                    r.range.map { (index(r.guid), $0, cat.rawValue) }
                }
            }
        }
        return SecretDetector.detect(in: rs).map { (index($0.guid), $0.range, $0.category.rawValue) }
    }

    static func score(_ cases: [Case]) -> [String: Score] {
        let scrubberCategories = Set(ScrubberCategory.allCases.map(\.rawValue))
        var table: [String: Score] = [:]
        for c in cases {
            let family = category(c.family)
            let scrubber = scrubberCategories.contains(family)
            let found = hits(c, scrubber: scrubber)
            let expected: [(Int, Range<Int>)] = c.expect.compactMap { e in
                guard case .int(let m) = e[0], case .str(let v) = e[1] else { return nil }
                let r = (c.msgs[m] as NSString).range(of: v)
                return r.location == NSNotFound ? nil : (m, r.location..<(r.location + r.length))
            }
            if c.cat == "none" {
                table[family, default: Score()].neg += 1
                for label in Set(found.map(\.2)) { table[category(label), default: Score()].negFP += 1 }
                continue
            }
            let cat = category(c.cat)
            table[cat, default: Score()].pos += 1
            let full = expected.allSatisfy { m, r in
                var covered = Set<Int>()
                for h in found where h.0 == m && h.1.overlaps(r) { covered.formUnion(h.1) }
                return Set(r).isSubset(of: covered)
            }
            if full, expected.count == c.expect.count { table[cat]!.tp += 1 }
        }
        return table
    }

    /// Per set and category: the least full hits, and the most false flags on lookalikes.
    /// These are the scores when the rules were written; a change may only raise them.
    static let floors: [String: [String: (tp: Int, fp: Int)]] = [
        "tune-audit": [
            "creditCard": (26, 0), "ssn": (13, 0), "bankAccount": (14, 0), "idNumber": (4, 0),
            "apiKey": (37, 0), "password": (32, 0), "standingCode": (21, 0), "seedPhrase": (15, 0),
            "phone": (15, 0), "email": (9, 0), "postalAddress": (13, 0), "otp": (15, 0),
        ],
        "tune-fresh": [
            "creditCard": (9, 0), "ssn": (9, 0), "bankAccount": (9, 0), "idNumber": (9, 0),
            "apiKey": (14, 0), "password": (9, 0), "standingCode": (10, 0), "seedPhrase": (8, 0),
            "phone": (9, 0), "email": (8, 0), "postalAddress": (8, 0), "otp": (10, 0),
        ],
        "heldout-audit": [
            "creditCard": (10, 0), "ssn": (5, 0), "bankAccount": (7, 0), "apiKey": (9, 0),
            "password": (7, 0), "standingCode": (5, 0), "seedPhrase": (5, 0), "phone": (6, 0),
            "email": (2, 0), "postalAddress": (6, 0), "otp": (8, 0),
        ],
        "heldout-extended": [
            "creditCard": (8, 0), "ssn": (4, 0), "bankAccount": (3, 0), "idNumber": (13, 0),
            "recoveryKey": (7, 0), "apiKey": (6, 0), "password": (17, 0), "standingCode": (13, 0),
            "seedPhrase": (1, 0), "phone": (2, 0), "email": (1, 0), "otp": (5, 0),
        ],
        "heldout-extended2": [
            "creditCard": (4, 0), "ssn": (1, 0), "idNumber": (7, 0), "recoveryKey": (4, 0),
            "apiKey": (1, 0), "password": (3, 0), "standingCode": (4, 0), "otp": (2, 0),
        ],
        "heldout-probe": [
            "creditCard": (1, 0), "recoveryKey": (2, 0), "apiKey": (6, 0), "password": (4, 0),
            "standingCode": (2, 0),
        ],
        "heldout-fresh": [
            "creditCard": (8, 0), "ssn": (9, 0), "bankAccount": (9, 0), "idNumber": (5, 0),
            "apiKey": (13, 0), "password": (10, 0), "standingCode": (6, 0), "seedPhrase": (9, 0),
            "phone": (8, 0), "email": (8, 1), "postalAddress": (8, 0), "otp": (7, 0),
        ],
    ]

    @Test("each corpus scores at or above its floor", arguments: Array(floors.keys).sorted())
    func scoresHoldFloor(set: String) throws {
        let table = Self.score(try Self.cases(set))
        if ProcessInfo.processInfo.environment["LEMBIC_CORPUS_REPORT"] != nil {
            print("### \(set)")
            for (cat, s) in table.sorted(by: { $0.key < $1.key }) {
                print("\(cat): \(s.tp)/\(s.pos) full, false flags \(s.negFP)/\(s.neg)")
            }
        }
        for (cat, floor) in Self.floors[set]! {
            let s = table[cat] ?? Score()
            #expect(s.tp >= floor.tp, "\(set) \(cat): \(s.tp) full hits, floor \(floor.tp)")
            #expect(s.negFP <= floor.fp, "\(set) \(cat): \(s.negFP) false flags, ceiling \(floor.fp)")
        }
    }

    @Test("ordinary chat prose raises no detector flag and no scrubber removal")
    func chatProseIsQuiet() throws {
        let text = try #require(String(data: Self.fixture("chat-prose.txt"), encoding: .utf8))
        let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(lines.count >= 2000)
        let rs = lines.enumerated().map { i, t in
            MessageRecord(
                guid: "p#\(i)", date: Self.base.addingTimeInterval(Double(i) * 600),
                speaker: i % 2 == 0 ? "Them" : "Me", isTarget: true, service: "iMessage", text: t,
                hadAttachment: false, reactions: [])
        }
        let flags = SecretDetector.detect(in: rs)
        #expect(flags.isEmpty, "flags on prose: \(flags.map { lines[Int($0.guid.dropFirst(2))!] })")
        let removed = SecretScrubber.scrub(in: rs, categories: [.otp, .email]).all
        #expect(removed.isEmpty, "removed from prose: \(removed.count)")
    }

    @Test("the cheap gates never change a detection or a removal")
    func gatesMatchFullRun() throws {
        var messages: [[String]] = []
        for set in Self.floors.keys { messages += try Self.cases(set).map(\.msgs) }
        let all = Set(SecretCategory.allCases)
        for (n, msgs) in messages.enumerated() {
            let rs = Self.records("g\(n)", msgs)
            #expect(
                SecretDetector.detect(in: rs, enabled: all, gated: true)
                    == SecretDetector.detect(in: rs, enabled: all, gated: false), "\(msgs)")
            for m in msgs {
                let ns = m as NSString
                let cats = Set(ScrubberCategory.allCases)
                #expect(
                    SecretScrubber.ranges(in: ns, categories: cats, gated: true)
                        == SecretScrubber.ranges(in: ns, categories: cats, gated: false), "\(m)")
            }
        }
    }
}
