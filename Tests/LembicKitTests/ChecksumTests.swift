import Foundation
import Testing

@testable import LembicKit

// Direct checks of the pure validators in Detectors/Checksums.swift, with public test values.
@Suite("checksums")
struct ChecksumTests {
    private func digits(_ s: String) -> [Int] { s.compactMap(\.wholeNumberValue) }

    @Test func luhn() {
        #expect(DetectorScan.luhn(digits("4111111111111111")))
        #expect(DetectorScan.luhn(digits("378282246310005")))
        #expect(!DetectorScan.luhn(digits("4111111111111112")))
    }

    @Test func issuerTable() {
        #expect(DetectorScan.issuerAccepts(digits("4111111111111111")))
        #expect(DetectorScan.issuerAccepts(digits("378282246310005")))
        #expect(DetectorScan.issuerAccepts(digits("5555555555554444")))
        #expect(!DetectorScan.issuerAccepts(digits("411111111111111")))
        #expect(!DetectorScan.issuerAccepts(digits("3782822463100050")))
        #expect(!DetectorScan.issuerAccepts(digits("1234567812345678")))
    }

    @Test func ssnShape() {
        #expect(DetectorScan.ssnShape(123, 45, 6789))
        #expect(DetectorScan.ssnShape(900, 70, 1234))
        #expect(!DetectorScan.ssnShape(666, 12, 3456))
        #expect(!DetectorScan.ssnShape(0, 12, 3456))
        #expect(!DetectorScan.ssnShape(123, 0, 3456))
        #expect(!DetectorScan.ssnShape(123, 45, 0))
        #expect(!DetectorScan.ssnShape(900, 10, 1234))
    }

    @Test func ibanMod97() {
        #expect(DetectorScan.mod97("GB82WEST12345698765432"))
        #expect(DetectorScan.mod97("DE89370400440532013000"))
        #expect(!DetectorScan.mod97("GB82WEST12345698765431"))
        #expect(!DetectorScan.mod97("gb82west12345698765432"))
    }

    @Test func abaRouting() {
        #expect(DetectorScan.abaValid(digits("021000021")))
        #expect(DetectorScan.abaValid(digits("011000015")))
        #expect(!DetectorScan.abaValid(digits("021000022")))
        #expect(!DetectorScan.abaValid(digits("02100002")))
    }

    @Test func australianTFN() {
        #expect(DetectorScan.tfnValid(digits("123456782")))
        #expect(!DetectorScan.tfnValid(digits("123456789")))
        #expect(!DetectorScan.tfnValid(digits("12345678")))
    }

    @Test func brazilianCPF() {
        #expect(DetectorScan.cpfValid(digits("52998224725")))
        #expect(!DetectorScan.cpfValid(digits("52998224726")))
        #expect(!DetectorScan.cpfValid(digits("11111111111")))
        #expect(!DetectorScan.cpfValid(digits("5299822472")))
    }

    @Test func frenchNIR() {
        #expect(DetectorScan.nirValid("2 55 08 14 168 025 38"))
        #expect(DetectorScan.nirValid("185052A12345633"))
        #expect(!DetectorScan.nirValid("255081416802539"))
        #expect(!DetectorScan.nirValid("25508141680253"))
    }

    @Test func ukNHS() {
        #expect(DetectorScan.nhsValid(digits("9434765919")))
        #expect(!DetectorScan.nhsValid(digits("9434765918")))
        #expect(!DetectorScan.nhsValid(digits("943476591")))
    }

    @Test func verhoeff() {
        #expect(DetectorScan.verhoeff(digits("2363")))
        #expect(DetectorScan.verhoeff(digits("234123412346")))
        #expect(!DetectorScan.verhoeff(digits("2364")))
        #expect(!DetectorScan.verhoeff(digits("234123412345")))
    }

    @Test func italianCodiceFiscale() {
        #expect(DetectorScan.codiceFiscaleValid("RSSMRA85T10A562S"))
        #expect(DetectorScan.codiceFiscaleValid("rssmra85t10a562s"))
        #expect(!DetectorScan.codiceFiscaleValid("RSSMRA85T10A562T"))
        #expect(!DetectorScan.codiceFiscaleValid("RSSMRA85T10A562"))
    }
}
