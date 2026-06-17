import Foundation

// MARK: - Offset convention (frozen)
//
// Every character range in the redaction feature is a UTF-16 code-unit offset
// (i.e. `NSRange`-compatible) into a message's decoded `text`. A typical AppKit
// caller is uniformly UTF-16 (`NSTextView` selection, `NSAttributedString`
// attribute ranges, and a line colorizer all walk `NSString`), so anchoring to
// UTF-16 makes the caller↔engine handoff a zero-re-encoding `NSRange`↔`Range<Int>`
// conversion. Anything that slices or replaces inside a body MUST do so via
// `NSString`/`NSRange`, never `String.Index`, so offsets stay consistent.

/// A single user-applied redaction, anchored to one message by its `guid`.
///
/// `range` is a half-open UTF-16 code-unit range (`NSRange`-compatible) into
/// that message's decoded `text`. `range == nil` means "redact the whole
/// message" — the renderer replaces the body with a tombstone instead of an
/// inline `[redacted]` token.
///
/// A message whose `guid` is `nil` cannot be anchored, so it is never the
/// subject of a `Redaction`.
public struct Redaction: Hashable, Sendable {
    public let guid: String
    /// UTF-16 offsets into the message's `text`; `nil` redacts the whole message.
    public let range: Range<Int>?

    public init(guid: String, range: Range<Int>?) {
        self.guid = guid
        self.range = range
    }
}

/// A per-conversation set of redactions. Value-typed and `Sendable` so it can
/// cross the main-actor boundary freely (the caller mutates it; the engine reads
/// it during render).
///
/// Semantics: a whole-message redaction (`range == nil`) for a guid supersedes
/// every span redaction for that same guid — the message is fully dropped, so
/// the spans are moot. `contains`, `all`, and `redactions(forGuid:)` reflect
/// that absorption so callers never see redundant spans behind a tombstone.
public struct RedactionSet: Sendable, Equatable {
    private var items: Set<Redaction>

    public init() { items = [] }

    /// Insert a redaction. Adding a whole-message redaction drops any existing
    /// span redactions for the same guid (they are now absorbed by the tombstone).
    public mutating func add(_ redaction: Redaction) {
        if redaction.range == nil {
            // Whole-message redaction absorbs the guid's spans.
            items = items.filter { $0.guid != redaction.guid }
        } else if items.contains(Redaction(guid: redaction.guid, range: nil)) {
            // A whole-message redaction already covers this guid — span is moot.
            return
        }
        items.insert(redaction)
    }

    public mutating func remove(_ redaction: Redaction) {
        items.remove(redaction)
    }

    public func contains(_ redaction: Redaction) -> Bool {
        // A whole-message redaction implicitly contains any span for its guid.
        if redaction.range != nil, items.contains(Redaction(guid: redaction.guid, range: nil)) {
            return true
        }
        return items.contains(redaction)
    }

    public var isEmpty: Bool { items.isEmpty }

    public var all: [Redaction] { Array(items) }

    /// The redactions anchored to `guid`. If a whole-message redaction exists
    /// for the guid it is returned alone (it absorbs the spans).
    public func redactions(forGuid guid: String) -> [Redaction] {
        let whole = Redaction(guid: guid, range: nil)
        if items.contains(whole) { return [whole] }
        return items.filter { $0.guid == guid }
    }
}

/// The high-harm secret categories the detector flags. Deliberately a curated
/// set — auto-flagging ubiquitous PII (phones, emails, names, addresses) would
/// bury the real secret in alert fatigue, which defeats the purpose.
///
/// The first trio is `password`, `ssn`, `creditCard`. Four more high-harm
/// "flag for review" detectors round out the set:
/// `seedPhrase` (BIP-39 checksum), `apiKey` (curated prefixed token formats),
/// `standingCode` (door/gate/PIN keyword-proximity), and `bankAccount` (IBAN
/// mod-97 + US ABA routing). 2FA/OTP codes and PII are handled separately
/// (they ship as opt-in auto-remove *scrubbers*, not flag-for-review
/// detectors).
public enum SecretCategory: String, Sendable, CaseIterable, Hashable {
    case password
    case ssn
    case creditCard
    case seedPhrase
    case apiKey
    case standingCode
    case bankAccount
}

/// The opt-in **scrubber** categories. Unlike
/// `SecretCategory` detectors — which only FLAG for review and never auto-remove
/// — a scrubber **bulk auto-removes** its category's values when its toggle is
/// ON. The deliberate toggle IS the consent (default OFF), the removal is
/// reversible (it produces ordinary `Redaction` spans), and there is NO separate
/// export alert for scrubbed content (the user already opted in). These are the
/// ubiquitous-PII / low-harm categories deliberately kept OUT of the detector
/// bucket so they never bury a real secret in alert fatigue.
///
/// `phone` and `postalAddress` ride Apple's on-device `NSDataDetector`; `email`
/// uses a standard RFC-ish address regex (NSDataDetector misses bare emails);
/// `otp` matches only high-precision 2FA forms (machine-readable `#123456` /
/// `G-123456`, or a strong-cue "verification/security/login code is NNNNNN"
/// phrase) — bare digit runs are deliberately NOT scrubbed (a year/zip/amount
/// would be nuked). Name-anonymization is NOT a scrubber category — it rides the
/// existing `anonymizeSpeakers` transform (output = a `PN` alias, not
/// `[redacted]`).
public enum ScrubberCategory: String, Sendable, CaseIterable, Hashable {
    case phone
    case email
    case postalAddress
    case otp
}

/// A secret the detector found in a message body, anchored by `guid` to a
/// half-open UTF-16 range (`NSRange`-compatible) into that message's `text`.
public struct DetectedSecret: Hashable, Sendable {
    public let guid: String
    /// UTF-16 offsets into the message's `text`.
    public let range: Range<Int>
    public let category: SecretCategory

    public init(guid: String, range: Range<Int>, category: SecretCategory) {
        self.guid = guid
        self.range = range
        self.category = category
    }
}
