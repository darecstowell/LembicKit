import CryptoKit
import Foundation
import Testing

@testable import LembicKit

// A saved redaction must stay on its text when the message changes, or hide the
// whole message. It must never fail open.
@Suite("redaction anchors")
struct RedactionAnchorTests {
    private let key = SymmetricKey(size: .bits256)
    private let original = "meet at 12 Oak Lane after 5"

    private func rec(_ text: String, guid: String = "e1") -> MessageRecord {
        Fixtures.redRec(guid, 0, "Them", text)
    }

    private func savedAnchors() -> [RedactionAnchor] {
        var set = RedactionSet()
        set.add(Redaction(guid: "e1", range: 8..<19))  // "12 Oak Lane"
        set.add(Redaction(guid: "w1", range: nil))
        return set.anchors(in: [rec(original)], key: key)
    }

    private func txt(_ records: [MessageRecord], _ set: RedactionSet) -> String {
        Export.render(records: records, number: "x", formats: [.txt], redactions: set).txt ?? ""
    }

    @Test("a span past the end of the text hides the whole message in every output")
    func staleSpanFailsSafe() {
        var set = RedactionSet()
        set.add(Redaction(guid: "e1", range: 8..<19))
        let shorter = rec("12 Oak Lane")
        let out = Export.render(
            records: [shorter], number: "x", formats: [.txt, .jsonl], redactions: set)
        #expect(!(out.txt ?? "").contains("Oak"))
        #expect((out.txt ?? "").contains("[redacted message]"))
        #expect(!(out.jsonl ?? "").contains("Oak"))
        #expect(Export.preparedRedactedRecords([shorter], scope: .all, redactions: set).isEmpty)
        #expect(Transcript.redactedText(of: shorter, redactions: set) == nil)
    }

    @Test("an unchanged message keeps its anchors")
    func unchangedTextKeepsAnchor() {
        let resolved = RedactionSet.resolve(savedAnchors(), records: [rec(original)], key: key)
        #expect(resolved.moved.isEmpty && resolved.wholeMessage.isEmpty)
        #expect(resolved.redactions.contains(Redaction(guid: "e1", range: 8..<19)))
        #expect(resolved.redactions.contains(Redaction(guid: "w1", range: nil)))
        #expect(txt([rec(original)], resolved.redactions).contains("meet at [redacted] after 5"))
    }

    @Test("an edit that shifts the text moves the anchor onto it")
    func editedTextMovesAnchor() {
        let edited = rec("ok meet at 12 Oak Lane after 5")
        let resolved = RedactionSet.resolve(savedAnchors(), records: [edited], key: key)
        #expect(resolved.moved.map(\.guid) == ["e1"])
        #expect(txt([edited], resolved.redactions).contains("ok meet at [redacted] after 5"))
    }

    @Test("text that now shows twice is hidden in both places")
    func repeatedTextCoversEveryCopy() {
        let edited = rec("12 Oak Lane, yes 12 Oak Lane")
        let resolved = RedactionSet.resolve(savedAnchors(), records: [edited], key: key)
        #expect(txt([edited], resolved.redactions).contains("[redacted], yes [redacted]"))
    }

    @Test("an edit that removes the text hides the whole message and says so")
    func removedTextRedactsWholeMessage() {
        let edited = rec("meet at the cafe after 5")
        let resolved = RedactionSet.resolve(savedAnchors(), records: [edited], key: key)
        #expect(resolved.wholeMessage == ["e1"])
        #expect(txt([edited], resolved.redactions).contains("[redacted message]"))
    }

    @Test("an anchor with no fingerprint and changed text fails safe")
    func missingFingerprintFailsSafe() {
        let anchor = RedactionAnchor(guid: "e1", range: 8..<19, fingerprint: nil)
        let resolved = RedactionSet.resolve([anchor], records: [rec("ok meet")], key: key)
        #expect(resolved.wholeMessage == ["e1"])
    }

    @Test("anchors round-trip through JSON and never hold the text")
    func codableWithoutText() throws {
        let anchors = savedAnchors()
        let data = try JSONEncoder().encode(anchors)
        #expect(!String(decoding: data, as: UTF8.self).contains("Oak"))
        let back = try JSONDecoder().decode([RedactionAnchor].self, from: data)
        #expect(Set(back) == Set(anchors))
        let otherKey = RedactionSet.resolve(
            back, records: [rec(original)], key: SymmetricKey(size: .bits256))
        #expect(otherKey.wholeMessage == ["e1"], "a different key cannot confirm the text")
    }
}
