import Foundation

extension DetectorScan {
    // MARK: - Passwords

    static let strongTrigger =
        #"passwords?|passwort|passwd|passcode|passphrase|passwrod|pasword|passowrd|paswd|pword|wifi\s+key|wi-fi\s+key|wpa2?\s+key|network\s+key"#
    static let weakTrigger = #"pwd|pw|p/w|pass"#
    static let triggerRegex = regex(
        #"(?i)(?<![A-Za-z])("# + strongTrigger + "|" + weakTrigger + #")(?![A-Za-z])"#)
    static let wifiQR = regex(#"WIFI:[^\n]*?\bP:((?:\\.|[^;\\\n])+);"#)
    static let urlUserinfo = regex(#"(?i)\b[a-z][a-z0-9+.\-]*://[^\s/:@]+:([^\s/@]+)@"#)
    static let urlPasswordParameter = regex(#"(?i)[?&](?:pwd|password|passwd|pass)=([^&\s#]{4,})"#)
    static let valueFirst = regex(
        #"(?i)(?<!\S)(\S{4,64})\s+(?:is|was)\s+(?:the|my|our|your|his|her|their)\s+(?:new\s+)?(?:[\w-]+\s+)?(?:password|passcode|pw)\b"#
    )
    static let userSlashPassword = regex(
        #"(?i)\b(?:login|log\s?in|user(?:name)?|creds|credentials|account|acct)\b[^\n/]{0,40}?\S\s+/\s+(\S{4,64})"#
    )
    static let curlUser = regex(#"(?:^|\s)(?:-u|--user)\s+['"]?[^\s:'"]+:([^\s'"]+)"#)
    static let pgpass = regex(#"(?m)^[A-Za-z0-9.\-*]+:(?:[0-9]{2,5}|\*):[^:\s]+:[^:\s]+:(\S+)$"#)
    static let i18nPassword = regex(
        #"(?i)(contrase(?:ñ|n)a|clave|mot\s+de\s+passe|\bmdp\b|kennwort|senha|wachtwoord|parola\s+d'ordine|пароль)((?:\s+[\p{L}\-]{1,12}){0,2}?)\s*(?:[:=：]|\s(?:es|est|ist|é|è|is|lautet|era|был)\b|\s[-–—]\s)\s*([^\s"'“”]{3,64})"#
    )
    static let cjkPassword = regex(
        #"(?:パスワード|密码|密碼|비밀번호|暗証番号)\s*(?:は|是|为|:|：|는|은)?\s*([A-Za-z0-9!@#$%^&*._\-+=?]{4,64})"#)

    /// Words that follow "password is" in prose but are not a password.
    static let notAValue: Set<String> = [
        "a", "an", "the", "in", "on", "at", "to", "for", "of", "with", "from", "by", "about", "as",
        "into", "like", "after", "over", "under", "before", "below", "above", "behind", "inside",
        "i", "me", "my", "mine", "you", "your", "yours", "he", "him", "his", "she", "her", "hers",
        "it", "its", "it's", "we", "us", "our", "they", "them", "their", "this", "that", "these",
        "those", "what", "which", "who", "where", "when", "why", "how", "is", "are", "was",
        "were", "be", "been", "being", "am", "have", "has", "had", "do", "does", "did", "will",
        "would", "should", "can", "could", "may", "might", "must", "not", "no", "yes", "still",
        "just", "also", "too", "very", "really", "so", "now", "then", "here", "there", "already",
        "always", "never", "again", "only", "even", "same", "different", "wrong", "right",
        "correct", "incorrect", "invalid", "valid", "new", "old", "weak", "strong", "easy",
        "hard", "simple", "long", "short", "good", "bad", "fine", "ok", "okay", "blank", "empty",
        "none", "nothing", "something", "anything", "everything", "missing", "gone", "case",
        "sensitive", "case-sensitive", "required", "needed", "optional", "attached", "somewhere",
        "please", "thanks", "and", "or", "but", "if", "because", "since", "unless", "reset",
        "changed", "expired", "updated", "saved", "stored", "written", "taped", "sent", "shown",
        "hidden", "typed", "entered", "visible", "encrypted", "protected", "locked", "unlocked",
        "set", "taken", "used", "known", "forgotten", "lost", "shared", "printed", "listed",
        "posted", "included", "managed", "generated", "specified", "hashed", "unknown",
        "1password", "lastpass", "bitwarden", "keychain", "dashlane", "keeper", "manager",
        "password", "passwords", "secret", "pass", "passwd", "pwd", "pw", "xxx", "xxxx", "****",
        "<password>", "$password", "changeme", "placeholder", "redacted", "[redacted]", "hint",
        "field", "box", "prompt", "screen", "page", "link", "email", "text", "app", "below:",
        "too", "either", "both", "all", "any", "some", "more", "less", "most", "least",
    ]

    /// A word after the trigger that makes the phrase about the password, not its value.
    static let aboutPassword: Set<String> = [
        "hint", "hints", "manager", "managers", "policy", "policies", "rule", "rules",
        "requirement", "requirements", "strength", "field", "prompt", "screen", "page", "reset",
        "resets", "change", "changes", "expiry", "expiration", "length", "protected",
    ]

    static let fillerAfterValue: Set<String> = [
        "and", "but", "so", "then", "thanks", "thx", "ty", "lol", "ok", "okay", "please", "if",
        "for", "the", "to", "on", "at", "in", "it", "is", "was", "you", "i", "we", "btw", "haha",
        "with", "from", "or", "when", "let", "just",
    ]

    static func plainValue(_ v: String) -> String {
        v.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}>\"'”’`"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "([{<\"'“‘`")).lowercased()
    }

    /// A value with evidence of being a secret: a digit and a letter, a symbol with a
    /// digit or with both cases, or a capital letter after the first character. A path,
    /// a flag, a URL, or a placeholder is not one.
    static func plausibleSecret(_ v: String) -> Bool {
        let core = v.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]\"'”’"))
        guard core.count >= 4, !notAValue.contains(core.lowercased()) else { return false }
        if let first = core.first, "/~-<[{$%(".contains(first) || first.isCurrencySymbol {
            return false
        }
        if core.allSatisfy({ $0.isNumber || ",.%".contains($0) || $0.isCurrencySymbol }) {
            return false
        }
        if core.contains("://") || core.hasPrefix("www.") { return false }
        let hasDigit = core.contains { $0.isNumber }
        let hasLetter = core.contains { $0.isLetter }
        let hasSymbol = core.contains { !$0.isLetter && !$0.isNumber }
        let innerUpper = core.dropFirst().contains { $0.isUppercase }
        let hasLower = core.contains { $0.isLowercase }
        let hasUpper = core.contains { $0.isUppercase }
        return (hasDigit && hasLetter) || (hasSymbol && hasDigit)
            || (hasSymbol && hasUpper && hasLower) || (innerUpper && hasLower)
    }

    mutating func passwords() {
        let p = profile
        let named = p.hasAny(["pas", "pw", "p/w"])
        if named || p.has("key") {
            for m in Self.triggerRegex.all(in: ns) { passwordAfter(trigger: m.range) }
        }
        if p.has("wifi:") {
            for m in Self.wifiQR.all(in: ns) { add(m.range(at: 1), .password) }
        }
        let shaped: [(NSRegularExpression, Bool)] = [
            (Self.urlUserinfo, p.has("://") && p.has("@")),
            (Self.urlPasswordParameter, p.has("=") && p.hasAny(["pass", "pwd"])),
            (Self.curlUser, p.has("-u")), (Self.pgpass, p.colons >= 4),
        ]
        for (rx, gate) in shaped where gate {
            for m in rx.all(in: ns)
            where !Self.notAValue.contains(Self.plainValue(text(m.range(at: 1)))) {
                add(m.range(at: 1), .password)
            }
        }
        if named {
            for m in Self.valueFirst.all(in: ns) where Self.plausibleSecret(text(m.range(at: 1))) {
                add(m.range(at: 1), .password)
            }
        }
        if p.has("/") {
            for m in Self.userSlashPassword.all(in: ns)
            where Self.plausibleSecret(text(m.range(at: 1))) {
                add(m.range(at: 1), .password)
            }
        }
        let i18n: [StaticString] = [
            "contrase", "clave", "passe", "mdp", "kennwort", "senha", "wachtwoord", "parola",
        ]
        if p.hasAny(i18n)
            || (p.nonASCII && ns.range(of: "пароль", options: .caseInsensitive).length > 0)
        {
            i18nPasswords()
        }
        for m in p.nonASCII ? Self.cjkPassword.all(in: ns) : []
        where !Self.notAValue.contains(Self.plainValue(text(m.range(at: 1)))) {
            add(m.range(at: 1), .password)
        }
    }

    private mutating func i18nPasswords() {
        for m in Self.i18nPassword.all(in: ns) {
            let value = text(m.range(at: 3))
            let loose = m.range(at: 2).length > 0 || text(m.range(at: 1)).lowercased() == "clave"
            if loose
                ? Self.plausibleSecret(value) : !Self.notAValue.contains(Self.plainValue(value))
            {
                add(m.range(at: 3), .password)
            }
        }
    }

    /// The value after one trigger word: a quoted value, a value after a separator
    /// (`is`, `was`, `:`, `=`, `'s`, a spaced dash, or a line break), or a value with
    /// no separator when it looks like a secret. Up to four words may sit between the
    /// trigger and the separator ("password for the wifi is ..."). After a weak
    /// trigger (`pw`, `pass`) the value must always look like a secret.
    private mutating func passwordAfter(trigger: NSRange) {
        let weak = ["pwd", "pw", "p/w", "pass"].contains(text(trigger).lowercased())
        let length = ns.length
        var k = trigger.location + trigger.length
        func skip(newlines: Bool) {
            while k < length {
                let c = ns.character(at: k)
                guard c == 0x20 || c == 0x09 || (newlines && (c == 0x0A || c == 0x0D)) else {
                    return
                }
                k += 1
            }
        }
        func word(at i: Int) -> NSRange {
            var e = i
            while e < length, !Self.isSpaceOrBreak(ns.character(at: e)) { e += 1 }
            return NSRange(location: i, length: e - i)
        }
        if k + 1 < length, [0x27, 0x2019].contains(ns.character(at: k)),
            [0x73, 0x53].contains(ns.character(at: k + 1)),
            k + 2 >= length || Self.isSpaceOrBreak(ns.character(at: k + 2))
        {
            k += 2
            skip(newlines: false)
            takeValue(at: k, strict: weak)
            return
        }
        skip(newlines: false)
        guard k < length else { return }
        if [0x0A, 0x0D].contains(ns.character(at: k)) {
            skip(newlines: true)
            let w = word(at: k)
            if w.length > 0, Self.isWholeLine(ns, w) { takeValue(at: k, strict: weak) }
            return
        }
        var fillers = 0
        while k < length {
            skip(newlines: false)
            guard k < length else { return }
            let c = ns.character(at: k)
            if c == 0x3A || c == 0x3D || c == 0xFF1A {
                k += 1
                skip(newlines: true)
                takeValue(at: k, strict: weak)
                return
            }
            if Self.isQuote(c) {
                // A quote glued to the keyword closes a quoted keyword (`url.password`).
                if k > trigger.location + trigger.length { takeValue(at: k, strict: false) }
                return
            }
            if [0x2D, 0x2013, 0x2014].contains(c), k + 1 < length,
                [0x20, 0x09].contains(ns.character(at: k + 1))
            {
                k += 1
                skip(newlines: false)
                takeValue(at: k, strict: weak)
                return
            }
            let w = word(at: k)
            guard w.length > 0 else { return }
            let lowered = text(w).lowercased()
            if lowered == "is" || lowered == "was" {
                k += w.length
                skip(newlines: false)
                if k < length, [0x3A, 0x3D].contains(ns.character(at: k)) {
                    k += 1
                    skip(newlines: false)
                }
                takeValue(at: k, strict: weak)
                return
            }
            if fillers == 0, Self.plausibleSecret(text(w)) {
                add(w, .password)
                return
            }
            guard fillers < 4, lowered.count <= 12,
                lowered.allSatisfy({ $0.isLetter || $0 == "-" }),
                !Self.aboutPassword.contains(lowered)
            else { return }
            fillers += 1
            k += w.length
        }
    }

    static func isWholeLine(_ ns: NSString, _ r: NSRange) -> Bool {
        let end = r.location + r.length
        return end >= ns.length || [0x0A, 0x0D].contains(ns.character(at: end))
    }

    static func isQuote(_ c: unichar) -> Bool {
        [0x22, 0x27, 0x60, 0x201C, 0x201D, 0x2018, 0x2019].contains(c)
    }

    /// Take the value at `k`. A quoted value runs to its closing quote. A bare value runs
    /// to white space; when one or two more words end the line, they are covered too
    /// (an unquoted value with spaces). `strict` asks for a value that looks like a secret.
    private mutating func takeValue(at k: Int, strict: Bool) {
        guard k < ns.length else { return }
        if Self.isQuote(ns.character(at: k)) {
            let v = SecretDetector.quotedValue(ns, openingQuoteAt: k)
            if v.length > 0, !Self.notAValue.contains(Self.plainValue(text(v))) {
                add(v, .password)
            }
            return
        }
        var end = k
        while end < ns.length, !Self.isSpaceOrBreak(ns.character(at: end)) { end += 1 }
        guard end > k else { return }
        let value = text(NSRange(location: k, length: end - k))
        let plain = Self.plainValue(value)
        guard !plain.isEmpty, !Self.notAValue.contains(plain) else { return }
        if strict, !Self.plausibleSecret(value) { return }
        if plain.count < 3, !value.contains(where: \.isNumber) { return }
        var lineEnd = end
        while lineEnd < ns.length, ![0x0A, 0x0D].contains(ns.character(at: lineEnd)) {
            lineEnd += 1
        }
        let rest = text(NSRange(location: end, length: lineEnd - end))
        let more = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let endsSentence = [".", "!", "?", ","].contains { value.hasSuffix($0) }
        if !endsSentence, (1...2).contains(more.count), !rest.hasPrefix("  "),
            !more.contains(where: {
                Self.fillerAfterValue.contains(Self.plainValue($0))
                    || Self.notAValue.contains(Self.plainValue($0)) || $0.count > 24
            })
        {
            let trimmed = rest.trimmingCharacters(in: .whitespaces) as NSString
            let restStart = (rest as NSString).range(of: more[0]).location
            add(NSRange(location: k, length: end - k + restStart + trimmed.length), .password)
            return
        }
        add(NSRange(location: k, length: end - k), .password)
    }

    static func isSpaceOrBreak(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }
}
