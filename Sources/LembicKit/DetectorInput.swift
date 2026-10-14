import Foundation

/// The detector's per-record inputs and its four pieces. Each piece takes the bounds
/// it runs in, so a piece found over the whole thread can be reused for a scope.
struct DetectorInput: @unchecked Sendable {
    let records: [MessageRecord]
    let bodies: [NormalizedText?]
    let profiles: [TextProfile?]
    let gated: Bool

    init(_ records: [MessageRecord], gated: Bool) {
        self.records = records
        self.gated = gated
        var bodies: [NormalizedText?] = []
        var profiles: [TextProfile?] = []
        bodies.reserveCapacity(records.count)
        profiles.reserveCapacity(records.count)
        for r in records {
            guard r.guid != nil else {
                bodies.append(nil)
                profiles.append(nil)
                continue
            }
            let body = TextNormalizer.normalize(r.text)
            bodies.append(body)
            profiles.append(TextProfile(body.text, gated: gated))
        }
        self.bodies = bodies
        self.profiles = profiles
    }

    init(
        records: [MessageRecord], bodies: [NormalizedText?], profiles: [TextProfile?],
        gated: Bool
    ) {
        self.records = records
        self.bodies = bodies
        self.profiles = profiles
        self.gated = gated
    }

    /// The flags in `bounds`, in the order the detector has always emitted them.
    func assemble(
        _ bounds: Range<Int>, enabled: Set<SecretCategory>,
        single: (Int) -> [DetectedSecret],
        joined: (Int) -> [DetectedSecret],
        answer: (Int) -> DetectedSecret?,
        keyBlock: (Int) -> [DetectedSecret]
    ) -> [DetectedSecret] {
        guard !enabled.isEmpty, !bounds.isEmpty else { return [] }
        var out: [DetectedSecret] = []
        for i in bounds { out += single(i) }
        let pairs = bounds.lowerBound..<(bounds.upperBound - 1)
        if bounds.count > 1, !Self.joinRules(enabled).isEmpty {
            for start in pairs { out += joined(start) }
        }
        if bounds.count > 1, enabled.contains(.password) || enabled.contains(.standingCode) {
            for i in pairs { if let hit = answer(i) { out.append(hit) } }
        }
        if enabled.contains(.apiKey) { for i in bounds { out += keyBlock(i) } }
        return SecretDetector.consolidated(out)
    }

    static func joinRules(_ enabled: Set<SecretCategory>) -> Set<SecretCategory> {
        enabled.intersection([.creditCard, .ssn, .bankAccount, .seedPhrase])
    }

    // MARK: - One message

    /// The rules over record `i`; the message before counts when it is at or after `lo`.
    func single(_ i: Int, from lo: Int, enabled: Set<SecretCategory>) -> [DetectedSecret] {
        let r = records[i]
        guard let guid = r.guid, let body = bodies[i] else { return [] }
        var out: [DetectedSecret] = []
        var context: NSString?
        var contextProfile: TextProfile?
        if i > lo, let previous = bodies[i - 1],
            r.date.timeIntervalSince(records[i - 1].date) <= 900
        {
            context = previous.text
            contextProfile = profiles[i - 1]
        }
        var scan = DetectorScan(
            body.text, context: context, enabled: enabled, profile: profiles[i],
            contextProfile: contextProfile)
        scan.run()
        for hit in scan.hits {
            if let range = body.sourceRange(hit.range) {
                out.append(DetectedSecret(guid: guid, range: range, category: hit.category))
            }
        }
        if enabled.contains(.invisibleInk), r.isInvisibleInk {
            let length = (r.text as NSString).length
            if length > 0 {
                out.append(DetectedSecret(guid: guid, range: 0..<length, category: .invisibleInk))
            }
        }
        return out
    }

    // MARK: - Secrets split over messages

    /// Up to four messages in a row from one sender, each within five minutes of the
    /// one before, are joined with a space, and the card, SSN, IBAN, and seed rules run
    /// on the joined text. A hit maps back to every message it touches. `end` is one
    /// past the last record the join read.
    func joined(_ start: Int, in bounds: Range<Int>, enabled: Set<SecretCategory>)
        -> (end: Int, hits: [DetectedSecret])
    {
        let rules = Self.joinRules(enabled)
        guard let first = bodies[start], first.text.length <= 200 else { return (start + 1, []) }
        var count = 1
        var digits = profiles[start]?.digits ?? 0
        var bip = profiles[start]?.bipWords ?? 0
        while start + count < bounds.upperBound, count < 4 {
            let end = start + count
            guard let next = bodies[end], next.text.length <= 200,
                records[end].speaker == records[start].speaker,
                records[end].date.timeIntervalSince(records[end - 1].date) <= 300
            else { break }
            digits += profiles[end]?.digits ?? 0
            bip += profiles[end]?.bipWords ?? 0
            count += 1
        }
        let end = start + count
        guard count > 1, digits >= 6 || bip >= 10 else { return (end, []) }
        var parts: [(index: Int, offset: Int, body: NormalizedText)] = [(start, 0, first)]
        var joined = first.text as String
        for next in (start + 1)..<end {
            guard let body = bodies[next] else { break }
            joined += " "
            parts.append((next, (joined as NSString).length, body))
            joined += body.text as String
        }
        let ns = joined as NSString
        var context: NSString?
        if start > bounds.lowerBound, let previous = bodies[start - 1],
            records[start].date.timeIntervalSince(records[start - 1].date) <= 900
        {
            context = previous.text
        }
        var scan = DetectorScan(
            ns, context: context, enabled: rules,
            profile: TextProfile(ns, gated: gated),
            contextProfile: context == nil ? nil : profiles[start - 1])
        scan.run()
        var out: [DetectedSecret] = []
        for hit in scan.hits {
            let lo = hit.range.location
            let hi = hit.range.location + hit.range.length
            let touched = parts.filter { part in
                lo < part.offset + part.body.text.length && hi > part.offset
            }
            guard touched.count > 1 else { continue }
            for part in touched {
                let a = Swift.max(lo, part.offset) - part.offset
                let b = Swift.min(hi, part.offset + part.body.text.length) - part.offset
                guard b > a, let guid = records[part.index].guid,
                    let range = part.body.sourceRange(NSRange(location: a, length: b - a))
                else { continue }
                out.append(DetectedSecret(guid: guid, range: range, category: hit.category))
            }
        }
        return (end, out)
    }

    // MARK: - An answer to a question about a password or code

    /// Record `i + 1` when it answers a question about a password or code in record `i`.
    func answer(_ i: Int, enabled: Set<SecretCategory>) -> DetectedSecret? {
        typealias D = SecretDetector
        let words: [StaticString] = ["pas", "pw", "wifi", "wi-fi", "pin", "code", "comb"]
        guard let q = bodies[i], q.text.length <= 200, profiles[i]?.hasAny(words) ?? false,
            D.question.found(in: q.text),
            D.asks.found(in: q.text), let a = bodies[i + 1], let guid = records[i + 1].guid,
            records[i + 1].date.timeIntervalSince(records[i].date) <= 1800
        else { return nil }
        let whole = NSRange(location: 0, length: a.text.length)
        let category: SecretCategory
        let v: NSRange
        if D.codeQuestion.found(in: q.text),
            let m = D.codeAnswer.firstMatch(in: a.text as String, range: whole)
        {
            category = .standingCode
            v = m.range(at: 1)
        } else if let m = D.answer.firstMatch(in: a.text as String, range: whole),
            DetectorScan.plausibleSecret(a.text.substring(with: m.range(at: 1)))
        {
            v = m.range(at: 1)
            category = .password
        } else {
            return nil
        }
        guard enabled.contains(category), let range = a.sourceRange(v) else { return nil }
        return DetectedSecret(guid: guid, range: range, category: category)
    }

    // MARK: - Private key blocks split over messages

    /// A private key whose END line is not in the BEGIN message: flag the next
    /// messages from the same sender, whole, through the one with the END line
    /// (at most 20 messages, each within 10 minutes of the one before). `last` is
    /// the last record read.
    func keyBlock(_ i: Int, upTo hi: Int) -> (last: Int, hits: [DetectedSecret]) {
        let r = records[i]
        guard profiles[i]?.has("-----begin") ?? false,
            let block = SecretDetector.privateKeyBlocks(TextNormalizer.normalize(r.text).text).last,
            !block.closed
        else { return (i, []) }
        var out: [DetectedSecret] = []
        var previous = r
        var last = i
        for k in (i + 1)..<Swift.max(i + 1, Swift.min(hi, i + 21)) {
            let next = records[k]
            last = k
            guard next.speaker == r.speaker,
                next.date.timeIntervalSince(previous.date) <= 600, let guid = next.guid
            else { break }
            let body = next.text as NSString
            let endLine = body.range(of: "-----END ", options: .literal)
            if endLine.location == NSNotFound {
                out.append(DetectedSecret(guid: guid, range: 0..<body.length, category: .apiKey))
                previous = next
                continue
            }
            let tail = endLine.location + endLine.length
            let close = body.range(
                of: "-----", options: .literal,
                range: NSRange(location: tail, length: body.length - tail))
            let end = close.location == NSNotFound ? body.length : close.location + close.length
            out.append(DetectedSecret(guid: guid, range: 0..<end, category: .apiKey))
            break
        }
        return (last, out)
    }
}
