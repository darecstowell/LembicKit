import Foundation
import Testing

@testable import LembicKit

// E.164 normalization must match the true chat.db handle for non-US numbers,
// or name resolution and the phone+email union silently degrade (issue #9).
@Suite("phone normalization")
struct PhoneNormalizationTests {
    @Test func ukNationalWithRegion() {
        #expect(ContactsMap.normalizePhone("07911 123456", defaultRegion: "GB") == "+447911123456")
    }

    @Test func frenchNationalWithRegion() {
        #expect(ContactsMap.normalizePhone("06 12 34 56 78", defaultRegion: "FR") == "+33612345678")
    }

    @Test func nanpLeadingOneAndPlusBothCollapse() {
        #expect(ContactsMap.normalizePhone("1 503 555 0146") == "+15035550146")
        #expect(ContactsMap.normalizePhone("+1 (503) 555-0146") == "+15035550146")
    }

    @Test func plusPrefixIsAuthoritativeAcrossRegions() {
        #expect(ContactsMap.normalizePhone("+44 7911 123456", defaultRegion: "US") == "+447911123456")
    }

    @Test func bareTenDigitDefaultsToUS() {
        #expect(ContactsMap.normalizePhone("5035550146") == "+15035550146")
    }

    @Test func tooShortIsRejected() {
        #expect(ContactsMap.normalizePhone("123") == nil)
    }
}
