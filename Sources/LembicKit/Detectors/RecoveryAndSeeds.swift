import Foundation

extension DetectorScan {
    // MARK: - Recovery keys, 2FA backup codes, TOTP secrets

    static let bitLocker = regex(#"(?<![0-9\-])[0-9]{6}(?:-[0-9]{6}){7}(?![0-9\-])"#)
    static let groupedKey = regex(
        #"(?i)(?<![A-Z0-9\-])[A-Z0-9]{4}(?:-[A-Z0-9]{4}){5,7}(?![A-Z0-9\-])"#)
    static let fiveByFive = regex(
        #"(?i)(?<![A-Z0-9\-])[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}(?![A-Z0-9\-])"#)
    static let onePasswordSecretKey = regex(
        #"(?i)\bA3-[A-Z0-9]{6}-(?:[A-Z0-9]{6}-)?[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}\b"#
    )
    static let digitGroups5x6 = regex(#"(?<![0-9])[0-9]{5}(?: [0-9]{5}){5}(?![0-9])"#)
    static let digitGroups4x16 = regex(#"(?<![0-9])[0-9]{4}(?: [0-9]{4}){15}(?![0-9])"#)
    static let recoveryKeyword = regex(
        #"(?i)recovery|filevault|bitlocker|apple\s?id|apple\s+account|backup|product\s+key|license\s+key|activation|\bkey\b"#
    )
    static let backupKeyword = regex(
        #"(?i)(?:backup|recovery|2fa|two[- ]factor|one[- ]time|scratch|emergency|verification)\s+codes?"#
    )
    static let backupCode = regex(
        #"(?<![\w\-])(?:[0-9a-zA-Z]{5}-[0-9a-zA-Z]{5}|[0-9]{4} [0-9]{4}|[0-9]{6,10}|[A-Z0-9]{4}-[A-Z0-9]{4}|[a-z0-9]{10})(?![\w\-])"#
    )
    static let totpKeyword = regex(
        #"(?i)secret|setup\s+key|2fa\s+key|authenticator|totp|otp\s+key|seed\s+key|mfa"#)
    static let base32 = regex(
        #"(?<![A-Za-z0-9])(?:[A-Z2-7]{4}(?: ?[A-Z2-7]{4}){3,15}|[a-z2-7]{4}(?: ?[a-z2-7]{4}){3,15})(?![A-Za-z0-9])"#
    )
    static let totpWords: [StaticString] = [
        "secret", "setup", "2fa", "authenticator", "totp", "otp", "seed", "mfa",
    ]
    static let otpauth = regex(#"otpauth(?:-migration)?://\S+"#)

    mutating func recoveryKeys() {
        let p = profile
        for m in p.digits >= 48 ? Self.bitLocker.all(in: ns) : [] {
            let groups = text(m.range).split(separator: "-").compactMap { Int($0) }
            if groups.allSatisfy({ $0 % 11 == 0 }) { add(m.range, .recoveryKey) }
        }
        let grouped = p.longestToken >= 29 && p.has("-")
        let keywordSpans = grouped ? Self.recoveryKeyword.spans(in: ns) : []
        for rx in grouped ? [Self.groupedKey, Self.fiveByFive] : [] {
            for m in rx.all(in: ns) {
                let v = text(m.range)
                guard v.contains(where: \.isNumber), v.contains(where: \.isLetter) else { continue }
                let upper = v == v.uppercased()
                let grouped4 = rx === Self.groupedKey
                if (upper && grouped4) || isNear(m.range, keywordSpans, within: 60)
                    || (context.map { Self.recoveryKeyword.found(in: $0) } ?? false)
                {
                    add(m.range, .recoveryKey)
                }
            }
        }
        for m in p.has("a3-") ? Self.onePasswordSecretKey.all(in: ns) : [] {
            add(m.range, .recoveryKey)
        }
        for rx in p.digits >= 30 ? [Self.digitGroups5x6, Self.digitGroups4x16] : [] {
            for m in rx.all(in: ns) { add(m.range, .recoveryKey) }
        }
        for k in p.has("code") ? Self.backupKeyword.spans(in: ns) : [] {
            let tail = NSRange(
                location: k.location + k.length, length: ns.length - k.location - k.length)
            for m in Self.backupCode.all(in: ns, range: tail) where !digitsOf(m.range).isEmpty {
                add(m.range, .recoveryKey)
            }
        }
        if p.longestToken >= 4,
            hereOrBefore(Self.totpWords),
            Self.totpKeyword.found(in: ns)
                || (context.map { Self.totpKeyword.found(in: $0) } ?? false)
        {
            for m in Self.base32.all(in: ns) {
                let v = text(m.range).replacingOccurrences(of: " ", with: "")
                if v.count >= 16, v.contains(where: { "234567".contains($0) }),
                    v.contains(where: \.isLetter)
                {
                    add(m.range, .recoveryKey)
                }
            }
        }
        for m in p.has("otpauth") ? Self.otpauth.all(in: ns) : [] { add(m.range, .recoveryKey) }
    }

    // MARK: - Seed phrases (BIP-39)

    static let seedWord = regex(#"[A-Za-z]+"#)
    static let seedKeyword = regex(
        #"(?i)\b(?:seed|recovery\s+phrase|recovery\s+words|mnemonic|secret\s+(?:recovery\s+)?phrase|backup\s+phrase|wallet|metamask|ledger|trezor|phantom|exodus|trust\s+wallet|coinbase|12\s+words|24\s+words|twelve\s+words)\b"#
    )

    mutating func seeds() {
        let keyword =
            Self.seedKeyword.found(in: ns)
            || (context.map { Self.seedKeyword.found(in: $0) } ?? false)
        for run in SecretDetector.seedRuns(ns, keyword: keyword) { add(run, .seedPhrase) }
    }
}
