import Foundation
import Testing

@testable import LembicKit

// Values are joined at run time so no secret-shaped literal sits in the source.
@Suite("detector coverage")
struct DetectorCoverageTests {
    static let card = ["4111", "1111", "1111", "1111"]

    static func recs(_ texts: [String], speaker: String = "Them", gap: Double = 20) -> [MessageRecord] {
        texts.enumerated().map { i, t in
            MessageRecord(
                guid: "m\(i)", date: Date(timeIntervalSince1970: 1_780_000_000 + Double(i) * gap),
                speaker: speaker, isTarget: true, service: "iMessage", text: t, hadAttachment: false,
                reactions: [])
        }
    }

    /// The flagged text of each hit, in message order.
    static func flagged(_ texts: [String], _ category: SecretCategory) -> [String] {
        SecretDetector.detect(in: recs(texts)).filter { $0.category == category }.map { d in
            let i = Int(d.guid.dropFirst())!
            return (texts[i] as NSString).substring(with: NSRange(d.range))
        }
    }

    @Test("F30: changed characters do not hide a card, and the flag maps to the source text")
    func normalization() {
        let fullWidth = Self.card.joined(separator: " ").map { c -> String in
            guard let d = c.wholeNumberValue else { return String(c) }
            return String(UnicodeScalar(0xFF10 + d)!)
        }.joined()
        #expect(Self.flagged(["card " + fullWidth], .creditCard) == [fullWidth])
        let zeroWidth = Self.card.joined(separator: "\u{200B}")
        #expect(Self.flagged(["number " + zeroWidth + " thanks"], .creditCard) == [zeroWidth])
        let spelled = "four one one one one one one one one one one one one one one one"
        #expect(Self.flagged(["card is " + spelled], .creditCard) == [spelled])
    }

    @Test("F28: a card in four messages and a wifi answer with no question mark")
    func splitMessages() {
        #expect(Self.flagged(Self.card, .creditCard) == Self.card)
        let answer = "Sunflower" + "2024"
        #expect(Self.flagged(["whats the wifi password", answer], .password) == [answer])
    }

    @Test("F29: recovery keys, TOTP secrets, and Basic auth")
    func recoveryKeys() {
        let bitLocker = (1...8).map { _ in "123453" }.joined(separator: "-")
        #expect(Self.flagged(["recovery " + bitLocker], .recoveryKey) == [bitLocker])
        let totp = ["JBSW", "Y3DP", "EHPK", "3PXP"].joined(separator: " ")
        #expect(Self.flagged(["2FA setup key: " + totp], .recoveryKey) == [totp])
        let basic = Data("user:pa55word".utf8).base64EncodedString()
        #expect(Self.flagged(["Authorization: Basic " + basic], .apiKey) == [basic])
    }

    @Test("F31: IDs with a keyword are flagged; a bare 12-digit tracking number is not")
    func idNumbers() {
        let passport = "G" + "38291055"
        #expect(Self.flagged(["Mi pasaporte es " + passport], .idNumber) == [passport])
        #expect(Self.flagged(["FedEx 7749 1234 5678 should arrive Thursday"], .idNumber).isEmpty)
    }

    @Test("prose about a password is not a password")
    func passwordNegatives() {
        #expect(Self.flagged(["The password hint just says 'first dog'"], .password).isEmpty)
        #expect(Self.flagged(["JR pass is ¥50,000 now, not worth it"], .password).isEmpty)
        #expect(Self.flagged(["-u, --user <user:password>"], .password).isEmpty)
    }

    @Test("F27: a string that is not a message body is scanned too")
    func nonBodyStrings() {
        let name = "Lake house gate 4471# wifi pw " + "Hunter2!x"
        #expect(!SecretDetector.ranges(in: name, enabled: Set(SecretCategory.allCases)).isEmpty)
    }
}
