import Foundation

extension Transcript {
    /// `record.text` with its span redactions spliced to `[redacted]`, or nil when the
    /// whole message is redacted. Same splice as the `.txt` and `.jsonl` outputs.
    public static func redactedText(
        of record: MessageRecord, redactions: RedactionSet
    ) -> String? {
        BodySplice.body(of: record, redactions: redactions, names: nil, stripPlaceholders: false)
    }

    /// `redactedText` plus in-body name mentions rewritten to their `PN` alias from
    /// `aliases` (pass `[:]` to skip). This is the body `.jsonl` shows.
    public static func renderedBody(
        of record: MessageRecord, redactions: RedactionSet, aliases: [String: String]
    ) -> String? {
        BodySplice.body(
            of: record, redactions: redactions,
            names: aliases.isEmpty ? nil : NameMatcher(aliases: aliases), stripPlaceholders: false)
    }

    /// `renderedBody` with a prebuilt name matcher and the optional placeholder strip.
    static func renderedBody(
        of record: MessageRecord, redactions: RedactionSet, names: NameMatcher?,
        stripPlaceholders: Bool
    ) -> String? {
        BodySplice.body(
            of: record, redactions: redactions, names: names, stripPlaceholders: stripPlaceholders)
    }
}
