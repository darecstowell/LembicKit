import Foundation
import Testing

@testable import LembicKit

@Suite("transcript formatting")
struct TranscriptFormattingTests {
    @Test func comma() {
        #expect(Transcript.comma(0) == "0", "comma 0")
        #expect(Transcript.comma(999) == "999", "comma 999")
        #expect(Transcript.comma(1000) == "1,000", "comma 1,000")
        #expect(Transcript.comma(1_234_567) == "1,234,567", "comma 1,234,567")
    }

    @Test func jsonString() {
        #expect(Transcript.jsonString("plain") == "\"plain\"", "json plain")
        #expect(Transcript.jsonString("say \"hi\"") == "\"say \\\"hi\\\"\"", "json quotes")
        #expect(Transcript.jsonString("a\nb") == "\"a\\nb\"", "json newline")
        #expect(Transcript.jsonString("back\\slash") == "\"back\\\\slash\"", "json backslash")
        #expect(Transcript.jsonString("❤️") == "\"❤️\"", "json raw UTF-8 (ensure_ascii=False)")
        #expect(Transcript.jsonString("\u{01}") == "\"\\u0001\"", "json control char")
    }

    @Test func formatReactions() {
        let reactions = [Reaction(by: "Them", emoji: "❤️"), Reaction(by: "Me", emoji: "👍")]
        #expect(
            Transcript.formatReactions(reactions) == "  [Them: ❤️] [Me: 👍]", "reaction suffix")
        #expect(Transcript.formatReactions([]).isEmpty, "no reactions, no suffix")
    }
}
