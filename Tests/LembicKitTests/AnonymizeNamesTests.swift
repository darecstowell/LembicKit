import Foundation
import Testing

@testable import LembicKit

// Anonymize must hide the names Lembic knows: the counterparty, the owner, each
// group member, and every part of their names.
@Suite("anonymize names")
struct AnonymizeNamesTests {
    private func rec(_ guid: String, _ s: Int, _ speaker: String, _ text: String) -> MessageRecord {
        Fixtures.redRec(guid, s, speaker, text)
    }

    private func scope(_ names: [String: [String]]) -> Export.Scope {
        var scope = Export.Scope()
        scope.anonymizeSpeakers = true
        scope.knownNames = names
        return scope
    }

    private func bodies(_ txt: String) -> [String] {
        txt.split(separator: "\n").filter { $0.first?.isNumber == true }.map {
            String($0.split(separator: " ", maxSplits: 1)[1])
        }
    }

    @Test("1:1: the counterparty and owner names and their parts become aliases")
    func oneToOneNames() {
        let rs = [
            rec("n1", 0, "Them", "Thanks Darec! Tell Mike Chen I said hi"),
            rec("n2", 1, "Me", "will do Sarah, see you Friday. Stowell out"),
        ]
        let sc = scope(["Them": ["Sarah Chen"], "Me": ["Darec Stowell"]])
        let out = Export.render(
            records: rs, number: "+18165550188", formats: [.txt, .jsonl], scope: sc)
        let txt = out.txt ?? ""
        #expect(
            bodies(txt) == [
                "P2: Thanks P1! Tell Mike P2 I said hi", "P1: will do P2, see you Friday. P1 out",
            ])
        for name in ["Darec", "Sarah", "Chen", "Stowell"] {
            #expect(!txt.contains(name) && !(out.jsonl ?? "").contains(name), "hides \(name)")
        }
        let pro = Export.preparedRedactedRecords(rs, scope: sc, redactions: RedactionSet())
        #expect(
            pro.map(\.text) == [
                "Thanks P1! Tell Mike P2 I said hi", "will do P2, see you Friday. P1 out",
            ])
    }

    @Test("group: full names, first names, labels that end in a period, quiet members")
    func groupNames() {
        let rs = [
            rec("g1", 0, "Mike R.", "hey Sarah Chen, ask Carla about it"),
            rec("g2", 1, "Sarah", "ok Mike R. and mike, and rogers too"),
        ]
        let sc = scope([
            "Mike R.": ["Mike Rogers"], "Sarah": ["Sarah Chen"], "Carla": ["Carla Diaz"],
        ])
        let txt = Export.render(records: rs, number: "x", formats: [.txt], scope: sc).txt ?? ""
        #expect(bodies(txt) == ["P1: hey P2, ask P3 about it", "P2: ok P1 and P1, and P1 too"])
        #expect(txt.contains("Person 3 (P3)"), "a quiet member still gets an alias")
    }

    @Test("a name shared by two people is hidden without picking one of them")
    func sharedFirstName() {
        let rs = [rec("s1", 0, "Mike R.", "Mike said hi"), rec("s2", 1, "Mike S.", "Mike S. too")]
        let sc = scope(["Mike R.": ["Mike Rogers"], "Mike S.": ["Mike Smith"]])
        let txt = Export.render(records: rs, number: "x", formats: [.txt], scope: sc).txt ?? ""
        #expect(bodies(txt) == ["P1: [name] said hi", "P2: P2 too"])
    }

    @Test("a name that is also a common word matches only as written")
    func commonWordName() {
        let rs = [rec("w1", 0, "Will", "I will call Will at noon, and Hope will too")]
        let sc = scope(["Will": ["Will Hope"]])
        let txt = Export.render(records: rs, number: "x", formats: [.txt], scope: sc).txt ?? ""
        #expect(bodies(txt) == ["P1: I will call P1 at noon, and P1 will too"])
    }

    @Test("without anonymize, known names change nothing")
    func knownNamesIgnoredWhenOff() {
        let rs = [rec("o1", 0, "Them", "hi Sarah")]
        var sc = Export.Scope()
        sc.knownNames = ["Them": ["Sarah Chen"]]
        let txt = Export.render(records: rs, number: "x", formats: [.txt], scope: sc).txt ?? ""
        #expect(txt == Export.render(records: rs, number: "x", formats: [.txt]).txt)
    }

    @Test("knownNames(for:) takes the 1:1 contact name and each member's full name")
    func knownNamesFromConversation() {
        let one = Conversation(
            id: "Sarah Chen", displayName: "Sarah Chen", chatIDs: [1], targetHandles: [7],
            identifiers: ["+18165550188"], lastMessageDate: Fixtures.t0, messageCount: 1,
            primaryIdentifier: "+18165550188", isContact: true)
        #expect(Export.knownNames(for: one, labels: [7: "Sarah Chen"]) == ["Them": ["Sarah Chen"]])
        let numberOnly = Conversation(
            id: "+18165550188", displayName: "+18165550188", chatIDs: [1], targetHandles: [7],
            identifiers: ["+18165550188"], lastMessageDate: Fixtures.t0, messageCount: 1,
            primaryIdentifier: "+18165550188", isContact: false)
        #expect(Export.knownNames(for: numberOnly, labels: [7: "+18165550188"]).isEmpty)
        let group = Conversation(
            id: "g", displayName: "Trip", chatIDs: [2], targetHandles: [],
            identifiers: [], lastMessageDate: Fixtures.t0, messageCount: 1,
            primaryIdentifier: "chat2", isContact: false, isGroup: true,
            participants: [
                Participant(handleID: 1, identifier: "+18165550101", label: "Mike R."),
                Participant(handleID: 2, identifier: "+18165550102", label: "Carla"),
                Participant(handleID: 3, identifier: "+18165550103", label: "(816) 555-0103"),
            ])
        let names = Export.knownNames(
            for: group,
            labels: [1: "Mike Rogers", 2: "Carla Diaz", 3: "+18165550103"],
            adding: ["Me": ["Darec Stowell"]])
        #expect(
            names == [
                "Mike R.": ["Mike Rogers"], "Carla": ["Carla Diaz"], "Me": ["Darec Stowell"],
            ])
    }
}
