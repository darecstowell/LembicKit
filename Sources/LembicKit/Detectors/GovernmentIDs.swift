import Foundation

extension DetectorScan {
    // MARK: - SSN and ITIN

    static let ssnSeparated = regex(
        #"(?<![0-9\-.])([0-9]{3})[ ]?([\-.])[ ]?([0-9]{2})[ ]?\2[ ]?([0-9]{4})(?![0-9\-])"#)
    static let ssnSpaced = regex(#"(?<![0-9\-])([0-9]{3}) ([0-9]{2}) ([0-9]{4})(?![0-9\-])"#)
    static let ssnPlain = regex(#"(?<![0-9\-])([0-9]{3})([0-9]{2})([0-9]{4})(?![0-9\-])"#)
    static let ssnKeyword = regex(
        #"(?i)\bssn\b|\bss\s?#|\bsocial\b|\bsoc\.?\s?sec|\bitin\b|\btax\s?id\b|\btin\b"#)
    static let referenceBefore = regex(
        #"(?i)\b(?:part|sku|order|case|invoice|inv|ticket|model|serial|item|ref|reference|tracking|confirmation|claim|policy|po|lot|batch|docket|file|patent|version|build|account|acct)\b[^\n]{0,14}$"#
    )

    mutating func ssns() {
        func shape(_ m: NSTextCheckingResult, _ groups: [Int]) -> Bool {
            let parts = groups.map { Int(text(m.range(at: $0))) ?? 0 }
            return Self.ssnShape(parts[0], parts[1], parts[2])
        }
        for m in Self.ssnSeparated.all(in: ns) where shape(m, [1, 3, 4]) {
            if !keywordNear(m.range, Self.ssnKeyword, within: 40) {
                let before = ns.substring(to: m.range.location) as NSString
                if Self.referenceBefore.found(in: before) { continue }
            }
            add(m.range, .ssn)
        }
        guard hereOrBefore(["ss", "social", "soc", "itin", "tax", "tin"]) else { return }
        let keywordAnywhere = keywordInMessage(Self.ssnKeyword)
        for m in Self.ssnSpaced.all(in: ns) where keywordAnywhere && shape(m, [1, 2, 3]) {
            add(m.range, .ssn)
        }
        for m in Self.ssnPlain.all(in: ns) where shape(m, [1, 2, 3]) {
            if keywordNear(m.range, Self.ssnKeyword, within: 40) { add(m.range, .ssn) }
        }
    }

    // MARK: - ID numbers (passport, license, national and health IDs)

    static let passportWord =
        #"passports?|pasaporte|passeport|reisepass|passaporto|paspoort"#
    static let licenseWord =
        #"DL|driver'?s?\s+lic(?:en[cs]e)?\.?|driving\s+licen[cs]e|licen[cs]e|licencia(?:\s+de\s+conducir)?|permis\s+de\s+conduire|f[üu]hrerschein"#
    static let idNumberWord = #"number|no\.?|num|nr\.?|#|n[uú]mero|num[ée]ro|nummer"#
    /// Digits with up to two leading letters, a UK licence, 8 or 9 capitals and digits,
    /// or spaced digit groups. `idValueOK` checks the last two forms.
    static let idValue =
        #"([A-Z]{0,2}[0-9]{5,13}|[A-Z]{5}[0-9]{6}[A-Z0-9]{5}|[A-Z0-9]{8,9}|[0-9]{1,4}(?:[ \-][0-9]{2,4}){1,3})(?![A-Za-z0-9])"#
    static let idDocument = regex(
        #"(?i)(?<![A-Za-z])(?:"# + passportWord + "|" + licenseWord + #")(?![A-Za-z])(?:\s+(?:"#
            + idNumberWord + #"))?\s*(?:(?:is|es|est|ist|è)\b|[:#])?\s*#?\s*"# + idValue)
    static let idDocumentFiller = regex(
        #"(?i)(?<![A-Za-z])(?:"# + passportWord + "|" + licenseWord + #")\s+(?:"# + idNumberWord
            + #")(?:\s+[A-Za-z']+){1,4}?\s*:\s*#?\s*"# + idValue)
    static let passportKeyword = regex(#"(?i)(?<![A-Za-z])(?:"# + passportWord + #")(?![A-Za-z])"#)
    static let passportListValue = regex(
        #"(?<![A-Za-z0-9])(?:[A-Z]{1,2}[0-9]{7,8}|[0-9]{9})(?![A-Za-z0-9])"#)

    static func idValueOK(_ v: String) -> Bool {
        let digits = v.filter(\.isNumber).count
        if v.contains(" ") || v.contains("-") { return digits >= 7 }
        let letters = v.filter(\.isLetter)
        if letters.count > 2 || (letters.count > 0 && !(v.first?.isLetter ?? false)) {
            return v == v.uppercased() && digits >= 4 && (8...9).contains(v.count)
        }
        return digits >= 5
    }
    static let nineDigits = regex(#"(?<![0-9])([0-9]{3})([ \-]?)([0-9]{3})\2([0-9]{3})(?![0-9])"#)
    static let sinKeyword = regex(#"(?i)\b(?:SIN|NAS|social insurance)\b"#)
    static let tfnKeyword = regex(#"(?i)\b(?:tfn|tax file)\b"#)
    static let aadhaar = regex(#"(?<![0-9])[2-9][0-9]{3}([ \-]?)[0-9]{4}\1[0-9]{4}(?![0-9])"#)
    static let aadhaarKeyword = regex(#"(?i)\b(?:aadhaa?r|aadhar|uidai)\b"#)
    static let pan = regex(#"(?i)\b[A-Z]{3}[PCHFATBLJG][A-Z][0-9]{4}[A-Z]\b"#)
    static let panKeyword = regex(#"(?i)\bpan\b"#)
    static let cpfFormatted = regex(#"(?<![0-9])[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}(?![0-9])"#)
    static let cpfPlain = regex(#"(?<![0-9])[0-9]{11}(?![0-9])"#)
    static let cpfKeyword = regex(#"(?i)\bcpf\b"#)
    static let nir = regex(
        #"(?<![0-9])[12] ?[0-9]{2} ?[0-9]{2} ?(?:[0-9]{2}|2A|2B) ?[0-9]{3} ?[0-9]{3} ?[0-9]{2}(?![0-9])"#
    )
    static let dni = regex(#"(?i)\b([XYZ]?)([0-9]{7,8})[ \-]?([A-Z])\b"#)
    static let dniKeyword = regex(#"(?i)\b(?:dni|nie|nif)\b"#)
    static let codiceFiscale = regex(
        #"(?i)\b[A-Z]{6}[0-9]{2}[A-EHLMPR-T][0-9]{2}[A-Z][0-9]{3}[A-Z]\b"#)
    static let ukNI = regex(
        #"(?i)\b(?!BG|GB|NK|KN|TN|NT|ZZ)[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z] ?[0-9]{2} ?[0-9]{2} ?[0-9]{2} ?[A-D]\b"#
    )
    static let ukNIKeyword = regex(#"(?i)\b(?:NI|NINO|national insurance)\b"#)
    static let nhs = regex(#"(?<![0-9])[0-9]{3}([ \-]?)[0-9]{3}\1[0-9]{4}(?![0-9])"#)
    static let nhsKeyword = regex(#"(?i)\bnhs\b"#)
    static let mbi = regex(
        #"(?i)\b[1-9][AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y0-9][0-9]-?[AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y0-9][0-9]-?[AC-HJKMNP-RT-Y]{2}[0-9]{2}\b"#
    )
    static let mbiKeyword = regex(#"(?i)\b(?:medicare|mbi|beneficiary)\b"#)
    static let memberID = regex(
        #"(?i)\b(?:(?:member|subscriber|policy|insurance|medicaid|medicare|patient|health\s+plan|group)\s+(?:id|number|no\.?|#)|MRN|medical\s+record(?:\s+number)?)\s*(?:is\b|[:#])?\s*#?\s*([A-Z0-9][A-Z0-9\-]{5,19})\b"#
    )

    mutating func ids() {
        let p = profile
        let passportWords: [StaticString] = [
            "passport", "pasaporte", "passeport", "reisepass", "passaporto", "paspoort",
        ]
        if p.hasAny(passportWords + ["dl", "driv", "licen", "permis", "hrerschein"]) {
            for rx in [Self.idDocument, Self.idDocumentFiller] {
                for m in rx.all(in: ns) where Self.idValueOK(text(m.range(at: 1))) {
                    add(m.range(at: 1), .idNumber)
                }
            }
        }
        if p.hasAny(passportWords), Self.passportKeyword.found(in: ns) {
            for m in Self.passportListValue.all(in: ns) { add(m.range, .idNumber) }
        }
        idNumbers()
    }

    private mutating func idNumbers() {
        let p = profile
        let nineDigits = p.digits >= 9 && hereOrBefore(["sin", "nas", "social", "tfn", "tax"])
        for m in nineDigits ? Self.nineDigits.all(in: ns) : [] {
            let d = digitsOf(m.range)
            if Self.luhn(d), keywordNear(m.range, Self.sinKeyword, within: 40) {
                add(m.range, .idNumber)
            }
            if Self.tfnValid(d), keywordNear(m.range, Self.tfnKeyword, within: 40) {
                add(m.range, .idNumber)
            }
        }
        if hereOrBefore(["aadha", "uidai"]), keywordInMessage(Self.aadhaarKeyword) {
            for m in Self.aadhaar.all(in: ns) where Self.verhoeff(digitsOf(m.range)) {
                add(m.range, .idNumber)
            }
        }
        for m in p.has("pan") ? Self.pan.all(in: ns) : [] {
            let v = text(m.range)
            if v == v.uppercased(), keywordNear(m.range, Self.panKeyword, within: 30) {
                add(m.range, .idNumber)
            }
        }
        if p.digits >= 11 {
            for m in Self.cpfFormatted.all(in: ns) where Self.cpfValid(digitsOf(m.range)) {
                add(m.range, .idNumber)
            }
        }
        if p.digits >= 11, hereOrBefore(["cpf"]) {
            for m in Self.cpfPlain.all(in: ns) where Self.cpfValid(digitsOf(m.range)) {
                if keywordNear(m.range, Self.cpfKeyword, within: 30) { add(m.range, .idNumber) }
            }
        }
        if p.digits >= 13 {
            for m in Self.nir.all(in: ns) where Self.nirValid(text(m.range)) {
                add(m.range, .idNumber)
            }
        }
        for m in hereOrBefore(["dni", "nie", "nif"]) ? Self.dni.all(in: ns) : [] {
            var number = text(m.range(at: 2))
            if let p = ["X": "0", "Y": "1", "Z": "2"][text(m.range(at: 1)).uppercased()] {
                number = p + number
            }
            let table = Array("TRWAGMYFPDXBNJZSQVHLCKE")
            guard let n = Int(number), String(table[n % 23]) == text(m.range(at: 3)).uppercased()
            else { continue }
            if keywordNear(m.range, Self.dniKeyword, within: 30) { add(m.range, .idNumber) }
        }
        if p.longestToken >= 16 {
            for m in Self.codiceFiscale.all(in: ns) where Self.codiceFiscaleValid(text(m.range)) {
                add(m.range, .idNumber)
            }
        }
        if hereOrBefore(["ni", "national insurance"]) {
            for m in Self.ukNI.all(in: ns) where keywordNear(m.range, Self.ukNIKeyword, within: 30)
            {
                add(m.range, .idNumber)
            }
        }
        if p.digits >= 10, hereOrBefore(["nhs"]) {
            for m in Self.nhs.all(in: ns) where Self.nhsValid(digitsOf(m.range)) {
                if keywordNear(m.range, Self.nhsKeyword, within: 30) { add(m.range, .idNumber) }
            }
        }
        if hereOrBefore(["medicare", "mbi", "beneficiary"]) {
            for m in Self.mbi.all(in: ns) where keywordNear(m.range, Self.mbiKeyword, within: 40) {
                add(m.range, .idNumber)
            }
        }
        let memberWords: [StaticString] = [
            "member", "subscriber", "policy", "insurance", "medicaid", "medicare", "patient",
            "health",
            "group", "mrn", "medical",
        ]
        if p.hasAny(memberWords) {
            for m in Self.memberID.all(in: ns) {
                let v = m.range(at: 1)
                if digitsOf(v).count >= 4 { add(v, .idNumber) }
            }
        }
    }
}
