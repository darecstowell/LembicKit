import Foundation
import Testing

@testable import LembicKit

// A Release Mac app must read the real Contacts store, never a stray vCard.
@Suite("contacts vCard override")
struct ContactsOverrideTests {
    static let env = ["LEMBIC_CONTACTS": "/tmp/fixture.vcf"]

    /// A bundle at `root/<name>` with `DemoData/contacts.vcf` in its resources.
    static func bundle(named name: String) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
        let isApp = name.hasSuffix(".app")
        let resources = isApp ? root.appendingPathComponent("Contents/Resources") : root
        let demo = resources.appendingPathComponent("DemoData")
        try FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true)
        try Data("BEGIN:VCARD\nEND:VCARD\n".utf8)
            .write(to: demo.appendingPathComponent("contacts.vcf"))
        if isApp {
            let plist = ["CFBundleIdentifier": "test.\(UUID().uuidString)", "CFBundleName": "T"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: root.appendingPathComponent("Contents/Info.plist"))
        }
        return try #require(Bundle(url: root))
    }

    @Test func releaseAppIgnoresEnvironmentAndDemoData() throws {
        let app = try Self.bundle(named: "Lembic.app")
        #expect(
            ContactsMap.vcardOverride(environment: Self.env, bundle: app, isDebugBuild: false)
                == nil)
        #expect(
            ContactsMap.vcardOverride(environment: [:], bundle: app, isDebugBuild: false) == nil)
    }

    @Test func releaseCommandLineHonorsEnvironmentOnly() throws {
        let tool = try Self.bundle(named: "bin")
        #expect(
            ContactsMap.vcardOverride(environment: Self.env, bundle: tool, isDebugBuild: false)?
                .path
                == "/tmp/fixture.vcf")
        #expect(
            ContactsMap.vcardOverride(environment: [:], bundle: tool, isDebugBuild: false) == nil)
    }

    @Test func debugAppHonorsEnvironmentThenDemoData() throws {
        let app = try Self.bundle(named: "Lembic.app")
        #expect(
            ContactsMap.vcardOverride(environment: Self.env, bundle: app, isDebugBuild: true)?.path
                == "/tmp/fixture.vcf")
        let demo = ContactsMap.vcardOverride(environment: [:], bundle: app, isDebugBuild: true)
        #expect(demo?.pathComponents.suffix(2) == ["DemoData", "contacts.vcf"])
    }

    @Test func emptyEnvironmentValueIsIgnored() throws {
        let tool = try Self.bundle(named: "bin")
        #expect(
            ContactsMap.vcardOverride(
                environment: ["LEMBIC_CONTACTS": ""], bundle: tool, isDebugBuild: false) == nil)
    }
}
