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
        /// Normalized handle to `CNContact.identifier`. Two handles on one card are
        /// one person; two cards with the same name are not.
        public let contactIDs: [String: String]
        /// The owner's own normalized handles, from the Me card. Empty when there is
        /// no Me card (and for vCard input).
        public let ownerIdentifiers: Set<String>
    }

    /// `region` (ISO 3166-1 alpha-2) completes numbers saved without a country code.
    public static func buildContactInfo(region: String = currentRegion()) throws -> ContactInfo {
        if let file = vcardOverride() {
            return try buildContactInfo(vcardAt: file, region: region)
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

        var maps = Maps()
        let store = CNContactStore()
        try store.enumerateContacts(with: request) { contact, _ in
            record(contact, photo: contact.thumbnailImageData, region: region, into: &maps)
        }
        if let me = try? store.unifiedMeContactWithKeys(
            toFetch: [CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor])
        {
            maps.owner = handles(of: me, region: region)
        }
        return maps.info
    }

    /// A vCard to read instead of the system store. `LEMBIC_CONTACTS` counts in a
    /// Debug build or outside an app bundle (the CLI); a bundled
    /// `DemoData/contacts.vcf` counts in a Debug build only.
    static func vcardOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main, isDebugBuild: Bool = isDebugBuild
    ) -> URL? {
        if let path = environment["LEMBIC_CONTACTS"], !path.isEmpty,
            isDebugBuild || bundle.bundleURL.pathExtension != "app"
        {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        guard isDebugBuild else { return nil }
        return bundle.url(forResource: "contacts", withExtension: "vcf", subdirectory: "DemoData")
    }

    #if DEBUG
        static let isDebugBuild = true
    #else
        static let isDebugBuild = false
    #endif

    /// Build the same maps from a vCard file instead of the system store — the
    /// `LEMBIC_CONTACTS` path. vCard-parsed contacts carry full PHOTO data rather
    /// than a store-derived thumbnail, so the avatar comes from `imageData`.
    public static func buildContactInfo(
        vcardAt url: URL, region: String = currentRegion()
    ) throws -> ContactInfo {
        try buildContactInfo(vcardData: try Data(contentsOf: url), region: region)
    }

    public static func buildContactInfo(
        vcardData data: Data, region: String = currentRegion()
    ) throws -> ContactInfo {
        let contacts = try CNContactVCardSerialization.contacts(with: data)
        var maps = Maps()
        for contact in contacts {
            let photo = contact.isKeyAvailable(CNContactImageDataKey) ? contact.imageData : nil
            record(contact, photo: photo, region: region, into: &maps)
        }
        return maps.info
    }

    private struct Maps {
        var names: [String: String] = [:]
        var avatars: [String: Data] = [:]
        var contactIDs: [String: String] = [:]
        var owner = Set<String>()
        var info: ContactInfo {
            ContactInfo(
                names: names, avatars: avatars, contactIDs: contactIDs, ownerIdentifiers: owner)
        }
    }

    private static func handles(of contact: CNContact, region: String) -> Set<String> {
        let normalize = HandleNormalizer(region: region)
        let phones = contact.phoneNumbers.compactMap { normalize.phone($0.value.stringValue) }
        return Set(
            phones + contact.emailAddresses.map { HandleNormalizer.email($0.value as String) })
    }

    /// Fold one contact's name + photo into the maps under each of its normalized
    /// handles (phone or email). `photo` is supplied by the caller because the
    /// store path uses the thumbnail while the vCard path uses full image data;
    /// otherwise the two paths share this exact name/handle logic.
    private static func record(
        _ contact: CNContact, photo: Data?, region: String, into maps: inout Maps
    ) {
        let personal = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let name = personal.isEmpty ? contact.organizationName : personal
        guard !name.isEmpty else { return }
        func put(_ key: String) {  // first write wins per handle
            if maps.names[key] == nil {
                maps.names[key] = name
                maps.contactIDs[key] = contact.identifier
            }
            if let photo, maps.avatars[key] == nil { maps.avatars[key] = photo }
        }
        let normalize = HandleNormalizer(region: region)
        for phone in contact.phoneNumbers {
            if let normalized = normalize.phone(phone.value.stringValue) { put(normalized) }
        }
        for email in contact.emailAddresses {
            put(HandleNormalizer.email(email.value as String))
        }
    }

    /// ISO 3166-1 alpha-2 region the pure normalizers assume when not told. The
    /// pipeline entry points pass `currentRegion()` instead.
    public static let defaultRegion = "US"

    /// The user's region: the Contacts setting, else the system region, else US.
    public static func currentRegion() -> String {
        let contacts = CNContactsUserDefaults.shared().countryCode.uppercased()
        if contacts.count == 2 { return contacts }
        if let system = Locale.current.region?.identifier.uppercased(), system.count == 2 {
            return system
        }
        return defaultRegion
    }

    /// ITU-T E.164 country calling codes by region.
    static let callingCodes: [String: String] = {
        let table = """
            1 US CA AG AI AS BB BM BS DM DO GD GU JM KN KY LC MP MS PR SX TC TT VC VG VI UM
            7 RU KZ|20 EG|27 ZA|30 GR|31 NL|32 BE|33 FR|34 ES|36 HU|39 IT VA|40 RO|41 CH|43 AT
            44 GB GG IM JE|45 DK|46 SE|47 NO SJ|48 PL|49 DE|51 PE|52 MX|53 CU|54 AR|55 BR|56 CL
            57 CO|58 VE|60 MY|61 AU CX CC|62 ID|63 PH|64 NZ|65 SG|66 TH|81 JP|82 KR|84 VN|86 CN
            90 TR|91 IN|92 PK|93 AF|94 LK|95 MM|98 IR|211 SS|212 MA EH|213 DZ|216 TN|218 LY
            220 GM|221 SN|222 MR|223 ML|224 GN|225 CI|226 BF|227 NE|228 TG|229 BJ|230 MU|231 LR
            232 SL|233 GH|234 NG|235 TD|236 CF|237 CM|238 CV|239 ST|240 GQ|241 GA|242 CG|243 CD
            244 AO|245 GW|246 IO|248 SC|249 SD|250 RW|251 ET|252 SO|253 DJ|254 KE|255 TZ|256 UG
            257 BI|258 MZ|260 ZM|261 MG|262 RE YT|263 ZW|264 NA|265 MW|266 LS|267 BW|268 SZ
            269 KM|290 SH|291 ER|297 AW|298 FO|299 GL|350 GI|351 PT|352 LU|353 IE|354 IS|355 AL
            356 MT|357 CY|358 FI AX|359 BG|370 LT|371 LV|372 EE|373 MD|374 AM|375 BY|376 AD
            377 MC|378 SM|380 UA|381 RS|382 ME|383 XK|385 HR|386 SI|387 BA|389 MK|420 CZ|421 SK
            423 LI|500 FK|501 BZ|502 GT|503 SV|504 HN|505 NI|506 CR|507 PA|508 PM|509 HT
            590 GP BL MF|591 BO|592 GY|593 EC|594 GF|595 PY|596 MQ|597 SR|598 UY|599 CW BQ|670 TL
            672 NF|673 BN|674 NR|675 PG|676 TO|677 SB|678 VU|679 FJ|680 PW|681 WF|682 CK|683 NU
            685 WS|686 KI|687 NC|688 TV|689 PF|690 TK|691 FM|692 MH|850 KP|852 HK|853 MO|855 KH
            856 LA|880 BD|886 TW|960 MV|961 LB|962 JO|963 SY|964 IQ|965 KW|966 SA|967 YE|968 OM
            970 PS|971 AE|972 IL|973 BH|974 QA|975 BT|976 MN|977 NP|992 TJ|993 TM|994 AZ|995 GE
            996 KG|998 UZ
            """
        var codes: [String: String] = [:]
        for entry in table.split(whereSeparator: { $0 == "|" || $0 == "\n" }) {
            let parts = entry.split(separator: " ").map(String.init)
            for region in parts.dropFirst() { codes[region] = parts[0] }
        }
        return codes
    }()

    private static let knownCallingCodes = Set(callingCodes.values)

    /// The calling code an E.164 number starts with, when it is a known one.
    static func callingCode(ofE164 number: String) -> String? {
        let digits = number.drop { $0 == "+" }
        return (1...3).lazy.map { String(digits.prefix($0)) }.first(
            where: knownCallingCodes.contains)
    }

    /// chat.db handle ids are already E.164 phones or lowercase-ish emails;
    /// normalize both sides the same way before matching.
    public static func normalizeHandle(_ handle: String, defaultRegion: String = defaultRegion)
        -> String
    {
        HandleNormalizer(region: defaultRegion)(handle)
    }

    /// Best-effort E.164. A `+` prefix is authoritative. An international exit code
    /// (`00`, `011` in North America, `0011` in Australia, `010` in Japan) starts a
    /// full number. A bare national number loses its trunk prefix and gains the
    /// region's calling code; in North America an 11-digit leading-`1` is complete.
    public static func normalizePhone(_ raw: String, defaultRegion: String = defaultRegion)
        -> String?
    {
        if raw.contains("@") { return nil }
        let digits = String(
            raw.compactMap { ch -> Character? in
                guard let value = ch.wholeNumberValue, (0...9).contains(value) else { return nil }
                return Character(String(value))
            })
        guard digits.count >= 7 else { return nil }
        if raw.contains("+") { return "+" + digits }
        let region = defaultRegion.uppercased()
        if let rest = withoutExitCode(digits, region: region), rest.count >= 7 { return "+" + rest }
        let code = callingCodes[region] ?? "1"
        if code == "1", digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
        return "+" + code + withoutTrunkPrefix(digits, region: region)
    }

    private static func withoutExitCode(_ digits: String, region: String) -> String? {
        if region == "AU", digits.hasPrefix("0011") { return String(digits.dropFirst(4)) }
        if region == "JP", digits.hasPrefix("010") { return String(digits.dropFirst(3)) }
        if callingCodes[region] == "1", digits.hasPrefix("011") {
            return String(digits.dropFirst(3))
        }
        if digits.hasPrefix("00") { return String(digits.dropFirst(2)) }
        return nil
    }

    private static func withoutTrunkPrefix(_ digits: String, region: String) -> String {
        switch region {
        case "IT", "SM", "VA": return digits
        case "HU": return digits.hasPrefix("06") ? String(digits.dropFirst(2)) : digits
        case "RU", "KZ":
            return digits.count == 11 && digits.hasPrefix("8") ? String(digits.dropFirst()) : digits
        default: return digits.hasPrefix("0") ? String(digits.dropFirst()) : digits
        }
    }

    /// Adds entries for chat.db numbers that match no card exactly but match a card
    /// saved in national form under the wrong country code: same last nine digits,
    /// a different calling code, and exactly one card. Two numbers in one country
    /// never match this way.
    static func withNationalFallback(
        names: [String: String], contactIDs: [String: String], handles: some Sequence<String>
    ) -> (names: [String: String], contactIDs: [String: String]) {
        func lastNine(_ key: String) -> String? {
            let digits = key.filter(\.isNumber)
            return key.hasPrefix("+") && digits.count >= 9 ? String(digits.suffix(9)) : nil
        }
        var index: [String: [String]] = [:]
        for key in names.keys {
            if let tail = lastNine(key) { index[tail, default: []].append(key) }
        }
        var names = names
        var contactIDs = contactIDs
        for handle in Set(handles) where names[handle] == nil {
            guard let tail = lastNine(handle), let code = callingCode(ofE164: handle) else {
                continue
            }
            let matches = (index[tail] ?? []).filter { callingCode(ofE164: $0) != code }
            let cards = Set(matches.map { contactIDs[$0] ?? "name:" + (names[$0] ?? "") })
            guard cards.count == 1, let match = matches.first else { continue }
            names[handle] = names[match]
            contactIDs[handle] = contactIDs[match]
        }
        return (names, contactIDs)
    }

    /// Resolve a chat.db handle map (ROWID → phone/email) to display names
    /// where a contact matches; unmatched handles keep their raw id.
    public static func resolve(
        handleLabels: [Int64: String],
        contacts: [String: String],
        region: String = currentRegion()
    ) -> (resolved: [Int64: String], matched: Int) {
        let normalized = handleLabels.mapValues(HandleNormalizer(region: region).callAsFunction)
        let names = withNationalFallback(
            names: contacts, contactIDs: [:], handles: normalized.values
        ).names
        var out: [Int64: String] = [:]
        var matched = 0
        for (rowid, raw) in handleLabels {
            if let key = normalized[rowid], let name = names[key] {
                out[rowid] = name
                matched += 1
            } else {
                out[rowid] = raw
            }
        }
        return (out, matched)
    }
}

/// Normalizes chat.db and Contacts handles the same way, for one region.
struct HandleNormalizer: Sendable {
    let region: String

    /// An email lowercased, a phone in best-effort E.164, any other id unchanged.
    func callAsFunction(_ handle: String) -> String {
        if handle.contains("@") { return Self.email(handle) }
        // A business chat (`urn:biz:…`) or any other non-phone id is not a number.
        if handle.contains(":") || handle.contains(where: \.isLetter) { return handle }
        return phone(handle) ?? handle
    }

    func phone(_ raw: String) -> String? {
        ContactsMap.normalizePhone(raw, defaultRegion: region)
    }

    static func email(_ raw: String) -> String { raw.lowercased() }
}
