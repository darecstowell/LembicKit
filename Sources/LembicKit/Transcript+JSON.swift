import Foundation

extension Transcript {
    /// One JSON object per message. Redaction-aware AND, under `anonymize`,
    /// in-body name-alias-aware: the `"m"` field is the SAME body the `.txt`
    /// renderer shows — span redactions spliced to `[redacted]` and in-body
    /// participant-name mentions rewritten to their `PN` alias — via the shared
    /// `renderedBody` helper, so the two outputs can never leak differently. An
    /// earlier pass aliased only the SPEAKER here, leaking raw in-body names that
    /// the `.txt` had aliased; routing the body through `renderedBody` closes that.
    ///
    /// Whole-message redactions (an explicit nil-range redaction, or a span
    /// covering the entire text) **omit the object entirely** — jsonl has no
    /// `[N messages removed]` tombstone, so dropping the line is the safe default
    /// (no leak). Note the asymmetry with `.txt`: a consumer reconciling line
    /// counts between the two formats sees fewer jsonl lines than `.txt` rendered
    /// (whose redacted run collapses to a single tombstone token instead).
    ///
    /// Default `redactions: RedactionSet()` + `anonymize: false` keeps the output
    /// byte-identical to the raw, unredacted rendering (`renderedBody` with `[:]`
    /// aliases and no redactions returns the body unchanged).
    public static func jsonLines(
        records: [MessageRecord], redactions: RedactionSet = RedactionSet(),
        anonymize: Bool = false,
        knownNames: [String: [String]] = [:],
        timeZone: TimeZone = .current
    ) -> String {
        let local = LocalClock(timeZone: timeZone)
        // Same speaker → "Person N" map the .txt path uses, so the two outputs
        // label identically. Empty when not anonymizing (lookups fall through).
        let aliases = anonymize ? anonymizationMap(for: records, knownNames: knownNames) : [:]
        let names = anonymize ? NameMatcher(aliases: aliases, knownNames: knownNames) : nil
        var out = ""
        for r in records {
            // Whole-message redaction → omit the object (no jsonl tombstone).
            // `renderedBody` returns nil for it; nil-guid records can never be
            // whole-redacted, so they always render. The body is the SAME unified
            // splice (redactions + in-body aliases) the `.txt` path shows.
            guard
                let body = Self.renderedBody(
                    of: r, redactions: redactions, names: names, stripPlaceholders: false)
            else { continue }
            var fields: [(String, String)] = [
                ("d", jsonString(local.stamp(r.date))),
                ("s", jsonString(aliases[r.speaker] ?? r.speaker)),
                ("m", jsonString(body)),
            ]
            if let svc = r.service.flatMap(serviceLabel) {
                fields.append(("svc", jsonString(svc)))
            }
            if !r.reactions.isEmpty {
                let items = r.reactions
                    .map {
                        "{\"by\": \(jsonString(aliases[$0.by] ?? $0.by)), \"r\": \(jsonString($0.emoji))}"
                    }
                    .joined(separator: ", ")
                fields.append(("reacts", "[\(items)]"))
            }
            out += "{" + fields.map { "\"\($0.0)\": \($0.1)" }.joined(separator: ", ") + "}\n"
        }
        return out
    }

    /// A plain label for `message.service`, or nil for iMessage (the default).
    static func serviceLabel(_ service: String) -> String? {
        switch service {
        case "iMessage", "": nil
        case "iMessageLite": "iMessage via satellite"
        default: service
        }
    }

    /// JSON string literal matching Python json.dumps(ensure_ascii=False):
    /// raw UTF-8, only quotes/backslash/control characters escaped.
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
