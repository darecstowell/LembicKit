import Foundation
import Testing

@testable import LembicKit

// The high-harm trio: credit card (Luhn), SSN, password-in-context. Plus the
// alert-fatigue guard (ordinary PII never flagged) and URL false-positive
// suppression from real user testing.
@Suite("secret detector")
struct SecretDetectorTests {
    private func detRec(_ guid: String?, _ text: String) -> MessageRecord {
        Fixtures.detRec(guid, text)
    }

    @Test func creditCardLuhn() {
        // Credit card: Luhn-valid (a known good Visa test number) → one .creditCard.
        let card = SecretDetector.detect(in: [detRec("c1", "card 4111 1111 1111 1111 thanks")])
        #expect(
            card.count == 1 && card.first?.category == .creditCard,
            "Luhn-valid 16-digit card → one .creditCard")
        if let m = card.first {
            let sliced = ("card 4111 1111 1111 1111 thanks" as NSString).substring(
                with: NSRange(m.range))
            #expect(
                sliced == "4111 1111 1111 1111",
                "card range covers the full run incl. separators")
        }
        // Hyphen-separated and unseparated variants also Luhn-validate.
        #expect(
            SecretDetector.detect(in: [detRec("c2", "4111-1111-1111-1111")]).count == 1,
            "hyphen-separated card detected")
        #expect(
            SecretDetector.detect(in: [detRec("c3", "4111111111111111")]).count == 1,
            "unseparated card detected")
        // Luhn-INVALID 16-digit run → none.
        #expect(
            SecretDetector.detect(in: [detRec("c4", "4111 1111 1111 1112")]).isEmpty,
            "Luhn-invalid 16-digit run → none")
    }

    @Test func urlFalsePositives() {
        // URL false positive (from real user testing): a Luhn-passing variant id
        // buried in a tracking URL's query string is NOT a card.
        let avocadoURL =
            "https://www.avocadogreenmattress.com/products/green-pillow?variant=36584399306902&g_acctid=194-914-7998"
        let avocado = SecretDetector.detect(in: [detRec("u1", avocadoURL)])
        #expect(
            avocado.allSatisfy { $0.category != .creditCard },
            "Luhn-passing variant id in tracking URL → zero .creditCard")
        #expect(
            avocado.isEmpty,
            "tracking URL fires nothing at all (194-914-7998 is 3-3-4, not an SSN shape)")
        // Path-embedded number (no query string) is also glued into the URL token.
        #expect(
            SecretDetector.detect(in: [
                detRec("u2", "https://shop.example.com/items/4111111111111111")
            ])
            .allSatisfy { $0.category != .creditCard },
            "card-shaped number in URL path → zero .creditCard")
        // Regression guard: a genuine standalone card in prose still fires exactly once.
        let prose = SecretDetector.detect(in: [detRec("u3", "my card is 4111 1111 1111 1111")])
        #expect(
            prose.filter { $0.category == .creditCard }.count == 1,
            "standalone card in prose still → one .creditCard")
        // Adjacency backstop: a bare query fragment (no scheme) is still suppressed.
        #expect(
            SecretDetector.detect(in: [detRec("u4", "variant=36584399306902&x=1")])
                .allSatisfy { $0.category != .creditCard },
            "bare query fragment (no scheme) → zero .creditCard (adjacency backstop)")
    }

    @Test func ssn() {
        // SSN: valid → one; structurally-invalid area 000 → none.
        let ssn = SecretDetector.detect(in: [detRec("s1", "ssn 123-45-6789 ok")])
        #expect(
            ssn.count == 1 && ssn.first?.category == .ssn, "valid SSN 123-45-6789 → one .ssn")
        #expect(
            SecretDetector.detect(in: [detRec("s2", "000-12-3456")]).isEmpty,
            "invalid SSN area 000 → none")
        #expect(
            SecretDetector.detect(in: [detRec("s3", "666-12-3456")]).isEmpty,
            "invalid SSN area 666 → none")
        #expect(
            SecretDetector.detect(in: [detRec("s4", "123-00-4567")]).isEmpty,
            "invalid SSN group 00 → none")
        // The dashed form is a strong cue: it fires keyword-free.
        #expect(
            SecretDetector.detect(in: [detRec("s5", "123-45-6789")]).count == 1,
            "dashed SSN fires keyword-free")
        // The space form is ambiguous (scores, order numbers, IDs): no keyword → none.
        #expect(
            SecretDetector.detect(in: [detRec("s6", "scores 123 45 6789 ok")]).isEmpty,
            "bare space-grouped 3-2-4 run with no context → none")
        // ...but the space form WITH a nearby keyword still fires.
        #expect(
            SecretDetector.detect(in: [detRec("s7", "ssn 123 45 6789")]).count == 1,
            "space SSN with nearby 'ssn' keyword detected")
        #expect(
            SecretDetector.detect(in: [detRec("s8", "my social security is 123 45 6789")]).count
                == 1,
            "space SSN with nearby 'social security' keyword detected")
    }

    @Test func passwordInContext() {
        // Password-in-context: value-anchored.
        let p1 = SecretDetector.detect(in: [detRec("p1", "password is hunter2")])
        #expect(
            p1.count == 1 && p1.first?.category == .password,
            "password is hunter2 → one .password")
        if let m = p1.first {
            let sliced = ("password is hunter2" as NSString).substring(with: NSRange(m.range))
            #expect(sliced == "hunter2", "password range covers the value, not the keyword")
        }
        let p2 = SecretDetector.detect(in: [detRec("p2", "pw: s3cret")])
        #expect(p2.count == 1, "pw: s3cret → one .password")
        if let m = p2.first {
            #expect(
                ("pw: s3cret" as NSString).substring(with: NSRange(m.range)) == "s3cret",
                "pw value sliced")
        }
        #expect(
            SecretDetector.detect(in: [detRec("p3", "I forgot my password")]).isEmpty,
            "bare 'I forgot my password' (no value) → none")
        // Quoted value with a relaxed separator still fires.
        let p4 = SecretDetector.detect(in: [detRec("p4", #"password "hunter2" please"#)])
            .filter { $0.category == .password }
        #expect(p4.count == 1, "quoted value with relaxed separator → one .password")
        if let m = p4.first {
            #expect(
                (#"password "hunter2" please"# as NSString).substring(with: NSRange(m.range))
                    == "hunter2",
                "quoted password value sliced")
        }

        // FALSE-POSITIVE GUARD: trigger keyword + a bare prose word with NO real
        // separator must NOT fire (the next word is not the value).
        func noPw(_ text: String, _ label: String) {
            #expect(
                SecretDetector.detect(in: [detRec("pn", text)]).filter {
                    $0.category == .password
                }.isEmpty,
                "\(label) → no .password (prose, no separator)")
        }
        noPw("password please", "password please")
        noPw("password reset link", "password reset link")
    }

    @Test func alertFatigueGuard() {
        // THE ALERT-FATIGUE GUARD: ordinary PII must never be flagged.
        let pii = SecretDetector.detect(in: [
            detRec("pii", "Call John Smith at (555) 123-4567 or a@b.com")
        ])
        #expect(pii.isEmpty, "phone + email + name → ZERO detections (alert-fatigue guard)")

        // nil-guid record is skipped (can't be anchored).
        #expect(
            SecretDetector.detect(in: [detRec(nil, "password is leakme")]).isEmpty,
            "nil-guid record skipped")
    }

    // MARK: - Long-tail detectors

    @Test func seedPhrase() {
        // A valid checksummed 12-word BIP-39 mnemonic (the canonical zero-entropy
        // vector: `abandon ×11 about`) → exactly one .seedPhrase spanning the
        // whole run.
        let valid = "abandon abandon abandon abandon abandon abandon "
            + "abandon abandon abandon abandon abandon about"
        let s = SecretDetector.detect(in: [detRec("sp1", "seed: \(valid)")])
        #expect(
            s.count == 1 && s.first?.category == .seedPhrase,
            "valid 12-word mnemonic → one .seedPhrase")
        if let m = s.first {
            let sliced = ("seed: \(valid)" as NSString).substring(with: NSRange(m.range))
            #expect(sliced == valid, "seed-phrase range spans the full mnemonic")
        }
        // A different valid 12-word mnemonic (non-trivial entropy).
        let valid2 = "abandon math mimic master filter design "
            + "carbon crystal rookie group knife young"
        #expect(
            SecretDetector.detect(in: [detRec("sp2", valid2)]).filter {
                $0.category == .seedPhrase
            }.count == 1,
            "second valid 12-word mnemonic → one .seedPhrase")
        // A valid 24-word mnemonic (zero-entropy vector ends in `art`).
        let valid24 = String(repeating: "abandon ", count: 23) + "art"
        #expect(
            SecretDetector.detect(in: [detRec("sp3", valid24)]).filter {
                $0.category == .seedPhrase
            }.count == 1,
            "valid 24-word mnemonic → one .seedPhrase")
        // A valid 15-word mnemonic (length coverage for the non-12/24 windows).
        // Checksum-valid: derived from fixed 20-byte entropy and verified against
        // the BIP-39 checksum before being pasted here — not hand-fabricated.
        let valid15 = "abandon amount liar amount expire adjust cage candy "
            + "arch gather drum bullet absurd math exhibit"
        #expect(
            SecretDetector.detect(in: [detRec("sp3b", valid15)]).filter {
                $0.category == .seedPhrase
            }.count == 1,
            "valid 15-word mnemonic → one .seedPhrase")
        // Same 12 words but a BAD checksum (last word swapped to `zoo`) → none.
        let bad = "abandon abandon abandon abandon abandon abandon "
            + "abandon abandon abandon abandon abandon zoo"
        #expect(
            SecretDetector.detect(in: [detRec("sp4", bad)]).filter { $0.category == .seedPhrase }
                .isEmpty,
            "12-word run with a bad checksum → no .seedPhrase")
        // 11 BIP-39 words (too short) → none.
        let eleven = String(repeating: "abandon ", count: 10) + "abandon"
        #expect(
            SecretDetector.detect(in: [detRec("sp5", eleven)]).filter {
                $0.category == .seedPhrase
            }.isEmpty,
            "11 BIP-39 words → no .seedPhrase (wrong length)")
        // 13 identical BIP-39 words (`abandon` ×13) → none. NOTE: this is NOT
        // because 13 is structurally rejected — the detector deliberately slides a
        // valid-length window (12, then shorter) inside a longer uninterrupted
        // BIP-39 run, so a valid 12-word mnemonic embedded in a 13-word run WOULD
        // fire. This run yields nothing because none of its length-12 windows
        // (`abandon` ×12) is checksum-valid — `abandon ×11 about` is the valid
        // zero-entropy vector, not `abandon ×12`. So the real reason is "no
        // checksum-valid window", not "13 is an invalid length".
        let thirteen = String(repeating: "abandon ", count: 13).trimmingCharacters(in: .whitespaces)
        #expect(
            SecretDetector.detect(in: [detRec("sp6", thirteen)]).filter {
                $0.category == .seedPhrase
            }.isEmpty,
            "13 `abandon` words → no .seedPhrase (no checksum-valid window in the run)")
    }

    @Test func apiKeys() {
        // One positive per vendor family → exactly one .apiKey each.
        func one(_ text: String, _ label: String) {
            let hits = SecretDetector.detect(in: [detRec("k", text)]).filter {
                $0.category == .apiKey
            }
            #expect(hits.count == 1, "\(label) → one .apiKey")
        }
        one("aws key AKIAIOSFODNN7EXAMPLE here", "AWS AKIA")
        one("token ghp_1234567890abcdefghijklmnopqrstuvwxyz done", "GitHub ghp_")
        one("key AIzaSyD-1234567890abcdefghijklmnopqrstu end", "Google AIza")
        one("sk-ant-api03-abcDEF123456789_-xyzABCDEFGH", "Anthropic sk-ant-api03")
        one(
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N",
            "JWT 3-part")
        // A full canonical 3-part JWT (jwt.io HS256 vector) still fires.
        one(
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
                + ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ"
                + ".dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "JWT full vector")
        one("-----BEGIN RSA PRIVATE KEY----- MIIE...", "PEM private key")
        one(
            "ping https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX now",
            "Slack webhook")
        one(
            "hook https://discord.com/api/webhooks/123456789012345678/abcDEF-ghiJKL_mnoPQR here",
            "Discord webhook")
        // A bare eyJ-prefixed base64 blob (NOT a 3-part JWT) → none (structural guard).
        #expect(
            SecretDetector.detect(in: [detRec("k2", "eyJhbGciOiJIUzI1NiJ9base64blob")]).filter {
                $0.category == .apiKey
            }.isEmpty,
            "bare eyJ-prefixed base64 (no dots) → no .apiKey (structural guard)")
        // Trivially-short dotted eyJ tokens are NOT real JWTs → none (length guard).
        #expect(
            SecretDetector.detect(in: [detRec("k3", "config eyJfoo.bar.baz here")]).filter {
                $0.category == .apiKey
            }.isEmpty,
            "short dotted eyJ token 'eyJfoo.bar.baz' → no .apiKey (segment-length guard)")
        #expect(
            SecretDetector.detect(in: [detRec("k4", "eyJa.b.c")]).filter {
                $0.category == .apiKey
            }.isEmpty,
            "tiny dotted eyJ token 'eyJa.b.c' → no .apiKey (segment-length guard)")
    }

    @Test func standingCodes() {
        // "garage code is 4042" → one .standingCode whose range is the value 4042.
        let g = SecretDetector.detect(in: [detRec("sc1", "the garage code is 4042 ok")])
            .filter { $0.category == .standingCode }
        #expect(g.count == 1, "garage code is 4042 → one .standingCode")
        if let m = g.first {
            let sliced = ("the garage code is 4042 ok" as NSString).substring(with: NSRange(m.range))
            #expect(sliced == "4042", "standing-code range covers the value, not the keyword")
        }
        #expect(
            SecretDetector.detect(in: [detRec("sc2", "door pin: 9981")]).filter {
                $0.category == .standingCode
            }.count == 1,
            "door pin: 9981 → one .standingCode")
        // A keyword-ish phrase with NO code → none.
        #expect(
            SecretDetector.detect(in: [detRec("sc3", "the code of conduct is clear")]).filter {
                $0.category == .standingCode
            }.isEmpty,
            "'code of conduct' (no numeric code) → no .standingCode")

        // MUST still fire — code-noun standalone or qualifying a place word. Each
        // emits the value, not the keyword.
        func code(_ text: String, _ value: String, _ label: String) {
            let hits = SecretDetector.detect(in: [detRec("scf", text)]).filter {
                $0.category == .standingCode
            }
            #expect(hits.count == 1, "\(label) → one .standingCode")
            if let m = hits.first {
                #expect(
                    (text as NSString).substring(with: NSRange(m.range)) == value,
                    "\(label) → value \(value)")
            }
        }
        code("gate code: 1234", "1234", "gate code: 1234")
        code("the safe combination is 4242", "4242", "safe combination is 4242")
        code("PIN is 4321", "4321", "PIN is 4321")
        code("my passcode is 8675309", "8675309", "passcode is 8675309")
        code("alarm code 9999", "9999", "alarm code 9999")
        code("keypad code 5567", "5567", "keypad code 5567")

        // THE LEAK GUARD — a bare PLACE word + number is a gate/unit/lock number,
        // NOT a standing code. None of these may fire (alert-fatigue floor).
        func noFire(_ text: String, _ label: String) {
            #expect(
                SecretDetector.detect(in: [detRec("scn", text)]).filter {
                    $0.category == .standingCode
                }.isEmpty,
                "\(label) → no .standingCode (bare place word + number)")
        }
        noFire("meet me at gate 22B for boarding", "boarding gate 22B")
        noFire("gate 5", "gate 5")
        noFire("lock 5", "lock 5")
        noFire("door 3", "door 3")
        noFire("garage 1234", "garage 1234")

        // THE PROSE GUARD — a negative qualifier before `code` makes it an
        // ordinary noun (zip/area/error/status/promo code), not a standing code.
        // An area code is itself ordinary PII, doubly forbidden.
        noFire("zip code 90210", "zip code 90210")
        noFire("area code 415", "area code 415")
        noFire("error code 500", "error code 500")
        noFire("status code 200", "status code 200")
        noFire("promo code 20OFF", "promo code 20OFF")
    }

    @Test func ibanAndRouting() {
        // A documented test IBAN (mod-97 valid) → one .bankAccount.
        let iban = SecretDetector.detect(in: [detRec("b1", "pay to GB82WEST12345698765432 thanks")])
            .filter { $0.category == .bankAccount }
        #expect(iban.count == 1, "valid IBAN GB82WEST12345698765432 → one .bankAccount")
        if let m = iban.first {
            let sliced = ("pay to GB82WEST12345698765432 thanks" as NSString).substring(
                with: NSRange(m.range))
            #expect(sliced == "GB82WEST12345698765432", "IBAN range covers the full IBAN")
        }
        // An IBAN with a broken mod-97 → none.
        #expect(
            SecretDetector.detect(in: [detRec("b2", "GB82WEST12345698765431")]).filter {
                $0.category == .bankAccount
            }.isEmpty,
            "broken mod-97 IBAN → no .bankAccount")
        // A real ABA-valid routing number WITH a context keyword → one.
        #expect(
            SecretDetector.detect(in: [detRec("b3", "routing number 021000021")]).filter {
                $0.category == .bankAccount
            }.count == 1,
            "ABA-valid routing + context keyword → one .bankAccount")
        // A bare ABA-passing 9-digit with NO context keyword → none (context guard).
        #expect(
            SecretDetector.detect(in: [detRec("b4", "call me at 011000015 later")]).filter {
                $0.category == .bankAccount
            }.isEmpty,
            "bare ABA-passing 9-digit, no context → no .bankAccount (context guard)")
        // An ABA-FAILING 9-digit WITH context → none (checksum guard).
        #expect(
            SecretDetector.detect(in: [detRec("b5", "routing number 021000020")]).filter {
                $0.category == .bankAccount
            }.isEmpty,
            "ABA-failing 9-digit even with context → no .bankAccount (checksum guard)")
    }

    // MARK: - Per-category enablement

    @Test("default `enabled` runs every category — behavior unchanged")
    func enabledDefaultIsAllCategories() {
        // A body carrying a password, an SSN, and a card → all three fire by
        // default (the existing all-on behavior, preserved).
        let text = "password: hunter2 my ssn is 123-45-6789 card 4111 1111 1111 1111"
        let cats = Set(SecretDetector.detect(in: [detRec("e0", text)]).map(\.category))
        #expect(
            cats == [.password, .ssn, .creditCard],
            "the default run flags password + ssn + creditCard, exactly as before")
    }

    @Test("a disabled detector category is never returned")
    func disabledCategoryNotReturned() {
        let text = "password: hunter2 my ssn is 123-45-6789 card 4111 1111 1111 1111"
        // Exclude .ssn — the password and card still fire, the SSN does not.
        let withoutSSN = SecretDetector.detect(
            in: [detRec("e1", text)],
            enabled: Set(SecretCategory.allCases).subtracting([.ssn]))
        #expect(
            !withoutSSN.contains { $0.category == .ssn },
            "the excluded .ssn category produces no hit")
        #expect(
            withoutSSN.contains { $0.category == .password }
                && withoutSSN.contains { $0.category == .creditCard },
            "the enabled categories still fire")
        // A single-category enable runs ONLY that category.
        let onlyCard = SecretDetector.detect(in: [detRec("e2", text)], enabled: [.creditCard])
        #expect(
            onlyCard.allSatisfy { $0.category == .creditCard } && !onlyCard.isEmpty,
            "enabled: [.creditCard] returns creditCard hits only")
        // An empty enable set returns nothing.
        #expect(
            SecretDetector.detect(in: [detRec("e3", text)], enabled: []).isEmpty,
            "enabled: [] returns no detections")
    }
}
