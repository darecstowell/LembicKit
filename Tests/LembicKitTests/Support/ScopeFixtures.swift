import Foundation

@testable import LembicKit

/// A varied thread for the scope parity tests: several speakers (two of them
/// identifiers), attachments, reactions, quote tapbacks, nil guids, scrubber bait,
/// and the redaction corpus messages, with gaps that cross every detector window.
enum ScopeFixtures {
    static let base = Date(timeIntervalSince1970: 1_780_000_000)
    static let speakers = ["Me", "Them", "Alice", "+1 (555) 201-3344", "bob@example.com"]
    static let gaps: [Double] = [0, 20, 30, 200, 299, 301, 600, 899, 901, 1799, 1801, 4000, 90_000]

    static let filler = [
        "hey are we still on for tonight", "call me at 555-201-3344 when you land",
        "my email is sam.lee@example.com", "send it to 1 Infinite Loop, Cupertino, CA 95014",
        "your code is 482913", "what's the wifi password?", "hunter2hunter2",
        "tell Sarah I said hi", "look at this [photo]", "[photo]", "line one\nline two",
        "Loved “tell Sarah I said hi”", "4111 1111", "1111 1111", "123-45-6789",
        "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA", "MIIEowIBAAKCAQEAx",
        "-----END RSA PRIVATE KEY-----",
        "what's the door code", "4471#", "ok 👍", "",
    ]

    /// `count` records, deterministic for a given `seed`. Dates never go backwards.
    static func thread(count: Int, seed: UInt64 = 1, corpus: [String] = []) -> [MessageRecord] {
        var rng = SplitMix(seed: seed)
        var date = base
        var out: [MessageRecord] = []
        out.reserveCapacity(count)
        var c = 0
        for i in 0..<count {
            date = date.addingTimeInterval(gaps[Int(rng.next() % UInt64(gaps.count))])
            let speaker = speakers[Int(rng.next() % UInt64(rng.next() % 3 == 0 ? 5 : 2))]
            let text: String
            if !corpus.isEmpty, rng.next() % 2 == 0 {
                text = corpus[c % corpus.count]
                c += 1
            } else {
                text = filler[Int(rng.next() % UInt64(filler.count))]
            }
            let attach = text.contains("[photo]")
            var reacts: [Reaction] = []
            if rng.next() % 7 == 0 {
                reacts.append(Reaction(by: speakers[Int(rng.next() % 5)], emoji: "❤️"))
            }
            out.append(
                MessageRecord(
                    guid: rng.next() % 41 == 0 ? nil : "s\(seed)-\(i)", date: date,
                    speaker: speaker, isTarget: speaker == "Them", service: "iMessage",
                    text: text, hadAttachment: attach, reactions: reacts,
                    isInvisibleInk: rng.next() % 97 == 0))
        }
        return out
    }

    /// Every message of the redaction corpus, in file order.
    static func corpusMessages() throws -> [String] {
        let names = [
            "tune-audit", "tune-fresh", "heldout-audit", "heldout-extended", "heldout-extended2",
            "heldout-fresh", "heldout-probe",
        ]
        return try names.flatMap { try RedactionCorpusTests.cases($0).flatMap(\.msgs) }
    }

    /// Manual redactions over some records: spans, whole messages, and a stale span.
    static func redactions(for records: [MessageRecord], seed: UInt64 = 7) -> RedactionSet {
        var rng = SplitMix(seed: seed)
        var set = RedactionSet()
        for r in records {
            guard let guid = r.guid, rng.next() % 11 == 0 else { continue }
            let length = (r.text as NSString).length
            switch rng.next() % 3 {
            case 0: set.add(Redaction(guid: guid, range: nil))
            case 1 where length > 2: set.add(Redaction(guid: guid, range: 1..<(length - 1)))
            default: set.add(Redaction(guid: guid, range: 0..<(length + 5)))
            }
        }
        return set
    }

    /// Every field of each record, so two record lists compare exactly.
    static func dump(_ records: [MessageRecord]) -> [String] {
        records.map { r in
            let reactions = r.reactions.map { "\($0.by)=\($0.emoji)" }.joined(separator: ",")
            return [
                r.guid ?? "nil", "\(r.date.timeIntervalSince1970)", r.speaker, "\(r.isTarget)",
                r.service ?? "nil", r.text, "\(r.hadAttachment)", reactions,
                "\(r.flags.rawValue)", "\(r.isInvisibleInk)",
            ].joined(separator: "|")
        }
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
