import Foundation
import Testing

@testable import LembicKit

// Non-US contacts resolve: the region reaches every call site, exit codes are
// stripped, and every region has its calling code (lembickit.md F5).
@Suite("contact region")
struct RegionTests {
    @Test func internationalExitCodes() {
        #expect(
            ContactsMap.normalizePhone("0044 7700 900123", defaultRegion: "US") == "+447700900123")
        #expect(
            ContactsMap.normalizePhone("011 44 7700 900123", defaultRegion: "US") == "+447700900123"
        )
        #expect(
            ContactsMap.normalizePhone("0011 44 7700 900123", defaultRegion: "AU")
                == "+447700900123")
        #expect(
            ContactsMap.normalizePhone("010 44 7700 900123", defaultRegion: "JP") == "+447700900123"
        )
        #expect(
            ContactsMap.normalizePhone("00 33 6 12 34 56 78", defaultRegion: "DE") == "+33612345678"
        )
    }

    @Test func callingCodesBeyondTheOldTwelve() {
        #expect(ContactsMap.normalizePhone("021 123 4567", defaultRegion: "ZA") == "+27211234567")
        #expect(
            ContactsMap.normalizePhone("0812 3456 7890", defaultRegion: "ID") == "+6281234567890")
        #expect(ContactsMap.normalizePhone("98765 43210", defaultRegion: "IN") == "+919876543210")
        #expect(
            ContactsMap.normalizePhone("11 91234-5678", defaultRegion: "BR") == "+5511912345678")
    }

    @Test func nationalTrunkPrefixes() {
        #expect(
            ContactsMap.normalizePhone("06 1234 5678", defaultRegion: "IT") == "+390612345678",
            "an Italian landline keeps its 0")
        #expect(
            ContactsMap.normalizePhone("8 916 123-45-67", defaultRegion: "RU") == "+79161234567")
        #expect(ContactsMap.normalizePhone("06 30 123 4567", defaultRegion: "HU") == "+36301234567")
    }

    static let vcf =
        [
            "BEGIN:VCARD", "VERSION:3.0", "N:Brown;Olivia;;;", "FN:Olivia Brown",
            "TEL;TYPE=CELL:07700 900123", "END:VCARD",
            "BEGIN:VCARD", "VERSION:3.0", "N:Ruiz;Ana;;;", "FN:Ana Ruiz",
            "TEL;TYPE=CELL:(555) 555-0101", "END:VCARD",
        ].joined(separator: "\r\n") + "\r\n"

    @Test func ukCardResolvesInTheUK() throws {
        let info = try ContactsMap.buildContactInfo(vcardData: Data(Self.vcf.utf8), region: "GB")
        #expect(info.names["+447700900123"] == "Olivia Brown")
        let labels = ContactsMap.resolve(
            handleLabels: [1: "+447700900123"], contacts: info.names, region: "GB")
        #expect(labels.resolved[1] == "Olivia Brown")
    }

    @Test func foreignNationalCardResolvesFromTheUS() throws {
        // A US user saved a UK friend without +44.
        let info = try ContactsMap.buildContactInfo(vcardData: Data(Self.vcf.utf8), region: "US")
        let labels = ContactsMap.resolve(
            handleLabels: [1: "+447700900123", 2: "+15555550101"], contacts: info.names,
            region: "US")
        #expect(labels.resolved[1] == "Olivia Brown", "the last nine digits match one card")
        #expect(labels.resolved[2] == "Ana Ruiz")
    }

    @Test func sameLastDigitsInOneCountryNeverMatch() throws {
        let info = try ContactsMap.buildContactInfo(vcardData: Data(Self.vcf.utf8), region: "US")
        let labels = ContactsMap.resolve(
            handleLabels: [1: "+16555550101"], contacts: info.names, region: "US")
        #expect(labels.resolved[1] == "+16555550101", "a stranger is never given Ana's name")
    }

    @Test func ambiguousSuffixNeverMatches() {
        let names = ["+17700900123": "Olivia Brown", "+337700900123": "Oscar Petit"]
        let labels = ContactsMap.resolve(
            handleLabels: [1: "+447700900123"], contacts: names, region: "US")
        #expect(labels.resolved[1] == "+447700900123", "two cards match, so neither is used")
    }

    @Test func listUsesTheFallbackToo() throws {
        let sql = """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, style INTEGER, chat_identifier TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER,
                is_from_me INTEGER, handle_id INTEGER, text TEXT);
            INSERT INTO handle VALUES (4,'+447700900123');
            INSERT INTO chat VALUES (3,45,'+447700900123');
            INSERT INTO chat_handle_join VALUES (3,4);
            INSERT INTO message VALUES (1,'m',100,0,4,'Train gets in at 9');
            INSERT INTO chat_message_join VALUES (3,1);
            """
        let db = try Fixtures.openChatDB(populating: sql)
        let info = try ContactsMap.buildContactInfo(vcardData: Data(Self.vcf.utf8), region: "US")
        let list = try Conversations.list(
            from: db, contacts: info.names, contactIDs: info.contactIDs, region: "US")
        #expect(list.first?.displayName == "Olivia Brown")
    }

    @Test func currentRegionIsACountryCode() {
        let region = ContactsMap.currentRegion()
        #expect(region.count == 2 && region == region.uppercased())
    }
}
