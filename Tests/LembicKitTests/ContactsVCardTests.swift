import Foundation
import Testing

@testable import LembicKit

// The demo/marketing path reads names + avatars from a vCard instead of the
// system store. Lock the parse + handle-normalization here (in-memory, no store
// access). Photo extraction from PHOTO data is exercised against the real demo
// vcf in demo-data/. `throws` lets a parse error fail the test naturally.
@Suite("contacts vCard override")
struct ContactsVCardTests {
    @Test func vCardOverride() throws {
        let vcf =
            [
                "BEGIN:VCARD", "VERSION:3.0", "N:Thompson;Maya;;;", "FN:Maya Thompson",
                "TEL;TYPE=CELL:+1 (415) 555-0142", "EMAIL;TYPE=INTERNET:Maya@Example.com",
                "END:VCARD",
            ].joined(separator: "\r\n") + "\r\n"
        let info = try ContactsMap.buildContactInfo(vcardData: Data(vcf.utf8))
        #expect(
            info.names["+14155550142"] == "Maya Thompson",
            "vCard phone → name (normalized E.164)")
        #expect(
            info.names["maya@example.com"] == "Maya Thompson",
            "vCard email → name (lowercased)")
        #expect(info.avatars.isEmpty, "no PHOTO line → no avatar")
    }

    // Smoke test: proves the `resources: [.copy("Fixtures")]` wiring makes
    // `Bundle.module` exist and find a bundled file. The redaction-aware render's
    // golden tests rely on this for their golden .txt fixtures. `.copy` of a
    // directory preserves the `Fixtures/` subdir in the bundle, so lookups pass
    // `subdirectory: "Fixtures"` (the path the golden .txt files are read from).
    @Test func bundleModuleResourceLoads() {
        #expect(
            Bundle.module.url(
                forResource: "contacts", withExtension: "vcf", subdirectory: "Fixtures") != nil,
            "Bundle.module finds Fixtures/contacts.vcf (resource bundle works)")
    }
}
