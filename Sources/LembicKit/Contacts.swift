import Contacts
import Foundation

/// Builds a [normalized handle: display name] map by enumerating all contacts
/// once — CNContactStore has no email or compound predicate, so per-handle
/// lookups are not an option.
public enum ContactsMap {
    public enum ContactsError: Error, CustomStringConvertible {
        case accessDenied

        public var description: String {
            "Contacts access denied. Grant access in System Settings → Privacy & Security → Contacts."
        }
    }

    public static func requestAccess() throws -> Bool {
        final class Box: @unchecked Sendable {
            var granted = false
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        CNContactStore().requestAccess(for: .contacts) { granted, _ in
            box.granted = granted
            semaphore.signal()
        }
        semaphore.wait()
        return box.granted
    }

    /// Display names plus optional avatar thumbnails, both keyed by normalized
    /// handle so the caller can match either against a chat.db identifier.
    public struct ContactInfo: Sendable {
        public let names: [String: String]
        public let avatars: [String: Data]
    }

    public static func buildContactInfo() throws -> ContactInfo {
        // Test / fixture override: read contacts from a vCard file instead
        // of the system store, so a fixture gets names + photo avatars
        // without importing anything into Contacts.app (and without a TCC prompt).
        // A normal launch sets no such variable, so the store path is unchanged.
        if let path = ProcessInfo.processInfo.environment["LEMBIC_CONTACTS"],
            !path.isEmpty
        {
            return try buildContactInfo(
                vcardAt: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        // Bundled fallback: if a `DemoData/contacts.vcf` ships with the executable,
        // read names + avatars from it instead of the system store — no Contacts
        // prompt, no address-book access. Absent unless a build bundles one.
        if let demo = Bundle.main.url(
            forResource: "contacts", withExtension: "vcf", subdirectory: "DemoData")
        {
            return try buildContactInfo(vcardAt: demo)
        }

        guard try requestAccess() else { throw ContactsError.accessDenied }

        // Thumbnail (not full-res CNContactImageDataKey) keeps memory to a few KB
        // per contact across the single full enumeration.
        let keys =
            [
                CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
                CNContactThumbnailImageDataKey,
            ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)

        var names: [String: String] = [:]
        var avatars: [String: Data] = [:]
        try CNContactStore().enumerateContacts(with: request) { contact, _ in
            record(contact, photo: contact.thumbnailImageData, into: &names, &avatars)
        }
        return ContactInfo(names: names, avatars: avatars)
    }

    /// Build the same maps from a vCard file instead of the system store — the
    /// `LEMBIC_CONTACTS` path. vCard-parsed contacts carry full PHOTO data rather
    /// than a store-derived thumbnail, so the avatar comes from `imageData`.
    public static func buildContactInfo(vcardAt url: URL) throws -> ContactInfo {
        try buildContactInfo(vcardData: try Data(contentsOf: url))
    }

    public static func buildContactInfo(vcardData data: Data) throws -> ContactInfo {
        let contacts = try CNContactVCardSerialization.contacts(with: data)
        var names: [String: String] = [:]
        var avatars: [String: Data] = [:]
        for contact in contacts {
            let photo = contact.isKeyAvailable(CNContactImageDataKey) ? contact.imageData : nil
            record(contact, photo: photo, into: &names, &avatars)
        }
        return ContactInfo(names: names, avatars: avatars)
    }

    /// Fold one contact's name + photo into the maps under each of its normalized
    /// handles (phone or email). `photo` is supplied by the caller because the
    /// store path uses the thumbnail while the vCard path uses full image data;
    /// otherwise the two paths share this exact name/handle logic.
    private static func record(
        _ contact: CNContact, photo: Data?,
        into names: inout [String: String], _ avatars: inout [String: Data]
    ) {
        let personal = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let name = personal.isEmpty ? contact.organizationName : personal
        guard !name.isEmpty else { return }
        func put(_ key: String) {  // first write wins per handle
            if names[key] == nil { names[key] = name }
            if let photo, avatars[key] == nil { avatars[key] = photo }
        }
        for phone in contact.phoneNumbers {
            if let normalized = normalizePhone(phone.value.stringValue) { put(normalized) }
        }
        for email in contact.emailAddresses {
            put((email.value as String).lowercased())
        }
    }

    /// ISO 3166-1 alpha-2 region whose calling code prefixes a bare national
    /// number. `US` preserves the prior hardcoded behavior, so it is the default.
    public static let defaultRegion = "US"

    /// Calling code for a region; falls back to NANP (`1`) for an unknown code.
    private static let callingCodes: [String: String] = [
        "US": "1", "CA": "1", "GB": "44", "FR": "33", "DE": "49", "AU": "61",
        "IE": "353", "ES": "34", "IT": "39", "NL": "31", "MX": "52", "JP": "81",
    ]

    /// chat.db handle ids are already E.164 phones or lowercase-ish emails;
    /// normalize both sides the same way before matching.
    public static func normalizeHandle(_ handle: String, defaultRegion: String = defaultRegion)
        -> String
    {
        handle.contains("@")
            ? handle.lowercased() : (normalizePhone(handle, defaultRegion: defaultRegion) ?? handle)
    }

    /// Best-effort E.164. A `+` prefix is authoritative (keep its digits). For a
    /// bare national number, strip a single trunk `0` and prepend the default
    /// region's calling code; an 11-digit leading-`1` is treated as NANP,
    /// mirroring `Conversations.displayNumber`.
    public static func normalizePhone(_ raw: String, defaultRegion: String = defaultRegion)
        -> String?
    {
        if raw.contains("@") { return nil }
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        if raw.contains("+") { return "+" + digits }
        if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        let national = digits.hasPrefix("0") ? String(digits.dropFirst()) : digits
        let code = callingCodes[defaultRegion.uppercased()] ?? "1"
        return "+" + code + national
    }

    /// Resolve a chat.db handle map (ROWID → phone/email) to display names
    /// where a contact matches; unmatched handles keep their raw id.
    public static func resolve(
        handleLabels: [Int64: String],
        contacts: [String: String]
    ) -> (resolved: [Int64: String], matched: Int) {
        var out: [Int64: String] = [:]
        var matched = 0
        for (rowid, raw) in handleLabels {
            if let name = contacts[normalizeHandle(raw)] {
                out[rowid] = name
                matched += 1
            } else {
                out[rowid] = raw
            }
        }
        return (out, matched)
    }
}
