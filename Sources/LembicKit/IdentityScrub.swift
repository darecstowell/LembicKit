import Foundation

/// Carries the enabled scrubbers past the message bodies: the header identifier,
/// the group name, the roster, speaker labels, reaction authors, and event lines.
/// A label that is an identifier becomes a neutral `Member N`.
struct IdentityScrub: Sendable {
    let categories: Set<ScrubberCategory>
    private let labelMap: [String: String]

    init(categories: Set<ScrubberCategory>, labels: [String]) {
        self.categories = categories
        var map: [String: String] = [:]
        guard !categories.isEmpty else {
            labelMap = map
            return
        }
        let taken = Set(labels)
        var next = 1
        for label in labels where map[label] == nil {
            guard label != Transcript.meLabel, label != "Them",
                Self.isIdentifier(label, categories)
            else { continue }
            while taken.contains("Member \(next)") { next += 1 }
            map[label] = "Member \(next)"
            next += 1
        }
        labelMap = map
    }

    /// Speakers and reaction authors by first appearance, then the rest of the
    /// roster, so every output format numbers `Member N` the same way.
    init(
        categories: Set<ScrubberCategory>, records: [MessageRecord],
        group: Transcript.GroupRenderInfo? = nil
    ) {
        var labels: [String] = []
        if !categories.isEmpty {
            for r in records {
                labels.append(r.speaker)
                labels.append(contentsOf: r.reactions.map(\.by))
            }
            labels.append(contentsOf: group?.participantLabels ?? [])
        }
        self.init(categories: categories, labels: labels)
    }

    var isActive: Bool { !categories.isEmpty }

    static func isIdentifier(_ s: String, _ categories: Set<ScrubberCategory>) -> Bool {
        if categories.contains(.phone), !s.contains(where: \.isLetter),
            s.unicodeScalars.filter({ CharacterSet.decimalDigits.contains($0) }).count >= 3
        {
            return true
        }
        if categories.contains(.email), s.contains("@") { return true }
        return !SecretScrubber.ranges(in: s as NSString, categories: categories).isEmpty
    }

    func label(_ s: String) -> String { labelMap[s] ?? s }

    /// The header identifier reads `[redacted]` when it holds anything a scrubber removes.
    func identifier(_ s: String) -> String {
        isActive && Self.isIdentifier(s, categories) ? "[redacted]" : s
    }

    /// Free text: known identifier labels become their neutral label, then every
    /// remaining scrubber match reads `[redacted]`.
    func text(_ s: String) -> String {
        guard isActive else { return s }
        var out = s
        for (label, neutral) in labelMap.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: label, with: neutral)
        }
        let ns = out as NSString
        let reps = Transcript.mergedRedactionSubstitutions(
            SecretScrubber.ranges(in: ns, categories: categories))
        return Transcript.applyReplacements(to: ns, reps)
    }

    func records(_ rs: [MessageRecord]) -> [MessageRecord] {
        guard !labelMap.isEmpty else { return rs }
        return rs.map { r in
            let speaker = label(r.speaker)
            let reactions = r.reactions.map { Reaction(by: label($0.by), emoji: $0.emoji) }
            if speaker == r.speaker, reactions == r.reactions { return r }
            return MessageRecord(
                guid: r.guid, date: r.date, speaker: speaker, isTarget: r.isTarget,
                service: r.service, text: r.text, hadAttachment: r.hadAttachment,
                reactions: reactions, isInvisibleInk: r.isInvisibleInk)
        }
    }

    func knownNames(_ names: [String: [String]]) -> [String: [String]] {
        guard !labelMap.isEmpty else { return names }
        var out: [String: [String]] = [:]
        for (key, value) in names { out[label(key), default: []].append(contentsOf: value) }
        return out
    }

    func group(_ g: Transcript.GroupRenderInfo?) -> Transcript.GroupRenderInfo? {
        guard isActive, let g else { return g }
        return Transcript.GroupRenderInfo(
            name: text(g.name), participantLabels: g.participantLabels.map(label))
    }

    func events(_ es: [Transcript.SystemEvent]) -> [Transcript.SystemEvent] {
        guard isActive else { return es }
        return es.map { Transcript.SystemEvent(date: $0.date, line: text($0.line)) }
    }
}
