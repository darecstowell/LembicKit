import Foundation
import Testing

@testable import LembicKit

@Suite("reaction netting")
struct ReactionTests {
    private func raw(
        _ date: Int64, _ seq: Int, target: String = "G1", reactor: String = "h3",
        label: String = "Them", emoji: String = "❤️", remove: Bool = false
    ) -> RawReaction {
        RawReaction(
            dateNS: date, sequence: seq, targetGUID: target, reactorKey: reactor,
            reactorLabel: label, emoji: emoji, isRemove: remove)
    }

    @Test func targetGUIDStripping() {
        #expect(Reactions.targetGUID(from: "p:0/ABC-123") == "ABC-123", "p:N/ prefix stripped")
        #expect(Reactions.targetGUID(from: "bp:ABC-123") == "ABC-123", "bp: prefix stripped")
        #expect(Reactions.targetGUID(from: "ABC-123") == "ABC-123", "bare guid unchanged")
    }

    @Test func netting() {
        #expect(
            Reactions.net([raw(1, 0), raw(2, 1, remove: true)]).isEmpty,
            "add then remove nets to nothing")

        let readd = Reactions.net([raw(1, 0), raw(2, 1, remove: true), raw(3, 2, emoji: "👍")])
        #expect(
            readd.count == 1 && readd[0].reaction == Reaction(by: "Them", emoji: "👍"),
            "remove then re-add keeps one")

        let latest = Reactions.net([raw(1, 0, emoji: "❤️"), raw(2, 1, emoji: "😂")])
        #expect(
            latest.count == 1 && latest[0].reaction.emoji == "😂", "latest add wins per reactor")

        let independent = Reactions.net([
            raw(1, 0, reactor: "h3", label: "Them"),
            raw(2, 1, reactor: "me", label: "Me", emoji: "👍"),
        ])
        #expect(independent.count == 2, "reactors net independently")
    }

    @Test func displayRank() {
        #expect(
            Reactions.displayRank("Them") == 0 && Reactions.displayRank("Me") == 1
                && Reactions.displayRank("+15551234567") == 2, "display rank Them < Me < others"
        )
    }
}
