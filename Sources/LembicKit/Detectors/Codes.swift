import Foundation

extension DetectorScan {
    // MARK: - Door, gate, and PIN codes

    static let codeNegative =
        #"zip|area|error|status|country|promo|postal|post|dial|exit|use|coupon|discount|dress|source|tax|response|http|bar|qr|reference|confirmation|tracking|order|booking|voucher|referral|invite|invitation|gift|verification|security|login|otp|auth|sms|activation|reset|redeem|offer|sale|cheat|morse|machine|postcode|swift|sort|iata|airport|flight|course|class|color|colour|product|discount|room|game|party|meeting|zoom|share|join|uber|lyft|whatsapp|venmo|instagram|google|apple|amazon|your"#
    static let codeValue =
        #"([*#]?[0-9][0-9A-Za-z]{2,7}#?|[A-Za-z][0-9]{3,7}|[0-9](?: [0-9]){3,7}|[0-9]{1,2}(?:-[0-9]{1,2}){2,3})(?![0-9A-Za-z])"#
    static let codeNounForm = regex(
        #"(?i)(?<!\b(?:"# + codeNegative
            + #")\s)\b(?:(?:door|gate|garage|safe|alarm|lock|lockbox|building|entry|entrance|access|keypad|apartment|apt|house|mailbox|front\s+door|back\s+door|elevator|storage|bike\s+lock|padlock)\s+)?(?:code|combination|combo|passcode|pin|keycode|lockbox)(?:\s+(?:number|no\.?|num|#))?(?:(?:\s+[A-Za-z']+){1,4}?\s+(?:is|:)|\s*(?:is\b|[:=])?)\s*"#
            + codeValue)
    static let placeForm = regex(
        #"(?i)\b(?:door|gate|garage|alarm|lockbox|keypad|safe|mailbox|padlock)\s*(?:is|:|=)\s*([*#]?[0-9]{4,8}#?)(?![0-9A-Za-z])"#
    )
    static let casualCodeForms: [NSRegularExpression] = [
        #"(?i)\b(?:door|gate|garage|code|alarm|lockbox|pin|keypad)['’]s\s+([*#]?[0-9]{3,8}#?)(?![0-9])"#,
        #"(?i)\bit['’]?s\s+([0-9]{4,8})#?\s+to\s+(?:get\s+in|open|unlock|enter)"#,
        #"(?i)\b(?:punch(?:\s+in)?|enter|type(?:\s+in)?|hit|press|dial)\s+([*#]?[0-9]{4,8}#?)\s+(?:at|on|into|in)\s+(?:the\s+)?(?:gate|door|keypad|lock|garage|lockbox|panel|box|front\s+door)"#,
        #"(?<![0-9])([0-9]{4,8})#?\s+(?:gets\s+you\s+in|opens\s+(?:it|the))"#,
        #"(?i)\b(?:opens|unlocks)\s+with\s+([0-9]{4,8})"#,
        #"(?i)\b(?:changed|change|set|updated|switched)\b(?:\s+[A-Za-z'’]+){0,4}?\s+(?<!\b(?:"#
            + codeNegative
            + #")\s)(?:code|combo|combination|pin|passcode)\s+(?:to|as)\s+([*#]?[0-9]{4,8}#?)(?![0-9])"#,
    ].map(regex)
    static let i18nCode = regex(
        #"(?i)(?:c[oó]digo|codice|t[üu]rcode|porte|portail|digicode|tor)(?:\s+[\p{L}]+){0,4}?\s*(?:es|est|ist|é|è|lautet|:)\s*([0-9]{3,8})(?![0-9])"#
    )
    static let codeReject = regex(#"(?i)^[0-9]{1,2}(?:am|pm|st|nd|rd|th|h|min|k)$"#)

    /// Words one of which each code rule needs, in the order of `codeRules`. Rules 2
    /// and 3 also run on any text that is not plain ASCII (accents, curly quotes).
    static let codeRuleWords: [[StaticString]] = [
        ["code", "comb", "pin", "lockbox"],
        ["door", "gate", "garage", "alarm", "lockbox", "keypad", "safe", "mailbox", "padlock"],
        ["codigo", "codice", "turcode", "porte", "portail", "digicode", "tor"],
        ["'s"], ["to"], ["punch", "enter", "type", "hit", "press", "dial"], ["gets", "opens"],
        ["with"], ["chang", "set", "updat", "switch"],
    ]
    static let codeRules = [codeNounForm, placeForm, i18nCode] + casualCodeForms

    mutating func codes() {
        for (i, (rx, words)) in zip(Self.codeRules, Self.codeRuleWords).enumerated() {
            guard profile.hasAny(words) || (profile.nonASCII && (i == 2 || i == 3)) else {
                continue
            }
            for m in rx.all(in: ns) {
                let v = m.range(at: 1)
                guard v.location != NSNotFound else { continue }
                if Self.codeReject.found(in: text(v) as NSString) { continue }
                add(v, .standingCode)
            }
        }
    }
}
