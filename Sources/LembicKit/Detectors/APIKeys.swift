import Foundation

extension DetectorScan {
    // MARK: - API keys, tokens, and private keys

    static let vendorKeyPatterns: [String] = [
        #"\bsk-(?:proj|svcacct|admin|None)-[A-Za-z0-9_\-]{20,}"#,
        #"\bsk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}\b"#,
        #"\bsk-[A-Za-z0-9]{48}\b"#,
        #"\bsk-ant-[a-z]{3,6}[0-9]{2}-[A-Za-z0-9_\-]{20,}"#,
        #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[0-9A-Z]{16}\b"#,
        #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b"#,
        #"\bgithub_pat_[A-Za-z0-9_]{22,}\b"#,
        #"\bglpat-[A-Za-z0-9_\-]{20,}\b"#,
        #"\bnpm_[A-Za-z0-9]{36}\b"#,
        #"\bhf_[A-Za-z0-9]{30,}\b"#,
        #"\bSG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}\b"#,
        #"\bSK[0-9a-fA-F]{32}\b"#,
        #"\bAIza[0-9A-Za-z_\-]{35}\b"#,
        #"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}\b"#,
        #"\bwhsec_[A-Za-z0-9]{20,}\b"#,
        #"\bxox[abposre]-[A-Za-z0-9\-]{10,}"#,
        #"\bxapp-[0-9]-[A-Za-z0-9\-]{10,}"#,
        #"https://hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9/_+\-]+"#,
        #"https://(?:canary\.|ptb\.)?discord(?:app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_\-]+"#,
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#,
        #"\bkey-[0-9a-f]{32}\b"#,
        #"\bdo[por]_v1_[a-f0-9]{64}\b"#,
        #"\bshp(?:at|ca|pa|ss)_[a-fA-F0-9]{32}\b"#,
        #"\bsq0(?:atp|csp)-[0-9A-Za-z\-_]{22,43}\b"#,
        #"\bATATT[A-Za-z0-9_\-=]{50,}\b"#,
        #"\blin_api_[A-Za-z0-9]{40}\b"#,
        #"\b(?:ntn_[A-Za-z0-9]{40,}|secret_[A-Za-z0-9]{43})\b"#,
        #"\b[0-9]{8,10}:AA[A-Za-z0-9_\-]{33}\b"#,
        #"\bPMAK-[a-f0-9]{24}-[a-f0-9]{34}\b"#,
        #"\bsbp_[a-f0-9]{40}\b"#,
        #"\bdp\.(?:pt|st|sa|ct)\.[A-Za-z0-9]{40,}\b"#,
        #"\bpul-[a-f0-9]{40}\b"#,
        #"\bgsk_[A-Za-z0-9]{48,}\b"#,
        #"\br8_[A-Za-z0-9]{37}\b"#,
        #"\bpplx-[A-Za-z0-9]{48}\b"#,
        #"\bxai-[A-Za-z0-9]{70,}\b"#,
        #"\bya29\.[A-Za-z0-9_\-]{20,}"#,
        #"\bGOCSPX-[A-Za-z0-9_\-]{28}\b"#,
        #"\bAccountKey=[A-Za-z0-9+/]{86}=="#,
        #"\b[xyztuv]prv[1-9A-HJ-NP-Za-km-z]{100,112}\b"#,
        #"https://(?:share\.1password\.com/s#|send\.bitwarden\.com/#/)\S+"#,
    ]
    /// One pass for every vendor format (each is at least 15 characters).
    static let vendorKey = regex(vendorKeyPatterns.map { "(?:\($0))" }.joined(separator: "|"))
    static let awsSecret = regex(#"(?<![A-Za-z0-9/+=])[A-Za-z0-9/+]{40}(?![A-Za-z0-9/+=])"#)
    static let awsKeyword = regex(#"(?i)aws|secret"#)
    static let bearer = regex(#"(?i)\bBearer\s+([A-Za-z0-9\-._~+/]{16,}=*)"#)
    static let basicAuth = regex(#"(?i)\bBasic\s+([A-Za-z0-9+/]{8,}={0,2})(?![A-Za-z0-9+/=])"#)
    static let namedSecret = regex(
        #"(?i)(?<![A-Za-z0-9])(?:[A-Z0-9]+[_\-])*(?:SECRET|TOKEN|API[_\-]?KEY|APIKEY|ACCESS[_\-]?KEY|PRIVATE[_\-]?KEY|AUTH|CREDENTIALS?|CLIENT[_\-]?SECRET|SIGNING[_\-]?KEY|ENCRYPTION[_\-]?KEY)(?:[_\-][A-Z0-9]+)*\s*[:=]\s*["']?([^\s"',;]{8,})"#
    )
    static let namedSecretWords = regex(
        #"(?i)\b(?:api\s+key|access\s+token|auth\s+token|secret\s+key|client\s+secret|bot\s+token|private\s+key|token|secret)\s+(?:is|=|:)\s*["']?([A-Za-z0-9_\-+/=.]{16,})"#
    )
    static let namedSecretBare = regex(
        #"(?i)\b(?:api\s+key|access\s+token|auth\s+token|secret\s+key|client\s+secret|bot\s+token|token|secret|key)\s+([A-Za-z0-9_\-+/=.]{20,})(?![A-Za-z0-9_\-+/=.])"#
    )
    static let urlSecretParameter = regex(
        #"(?i)[?&#](?:token|access_token|refresh_token|id_token|api_?key|apikey|key|sig|signature|x-amz-signature|x-amz-credential|x-amz-security-token|x-goog-signature|secret|client_secret|auth|code|session|sid|otp)=([^&\s#]{8,})"#
    )
    static let hex64 = regex(#"(?<![0-9a-fA-Fx:])(?:0x)?[0-9a-fA-F]{64}(?![0-9a-fA-F])"#)
    static let hexKeyword = regex(#"(?i)priv|private|secret|wallet|\bkey\b"#)
    static let wif = regex(#"\b[5KLc9][1-9A-HJ-NP-Za-km-z]{50,51}\b"#)
    static let byteArray = regex(#"\[\s*[0-9]{1,3}(?:\s*,\s*[0-9]{1,3}){31,63}\s*\]"#)
    static let byteArrayKeyword = regex(
        #"(?i)priv|private|secret|wallet|key|solana|phantom|keypair"#)
    static let cookieHeader = regex(#"(?i)\b(?:set-)?cookie:\s*(\S[^\n]{8,})"#)
    static let authorization = regex(
        #"(?i)\bauthorization:\s*(?:token\s+)?([A-Za-z0-9\-._~+/]{16,}=*)"#)

    mutating func keys() {
        let p = profile
        for token in p.longTokens {
            for m in Self.vendorKey.all(in: ns, range: token) { add(m.range, .apiKey) }
        }
        let awsNear =
            p.longestToken >= 40 && p.hasAny(["aws", "secret"]) ? Self.awsKeyword.spans(in: ns) : []
        if !awsNear.isEmpty {
            for m in Self.awsSecret.all(in: ns) {
                let v = text(m.range)
                if v.contains(where: \.isUppercase), v.contains(where: \.isLowercase),
                    isNear(m.range, awsNear, within: 60)
                {
                    add(m.range, .apiKey)
                }
            }
        }
        let shaped: [(NSRegularExpression, Bool)] = [
            (Self.bearer, p.has("bearer")), (Self.authorization, p.has("authorization")),
            (Self.urlSecretParameter, p.has("=")),
        ]
        for (rx, gate) in shaped where gate {
            for m in rx.all(in: ns) { add(m.range(at: 1), .apiKey) }
        }
        let named = p.hasAny(["secret", "token", "key", "auth", "credential"])
        for rx in named ? [Self.namedSecret, Self.namedSecretWords] : [] {
            for m in rx.all(in: ns) {
                let v = text(m.range(at: 1))
                let mixed = v.contains(where: \.isNumber) && v.contains(where: \.isLetter)
                if mixed || v.count >= 24, !Self.notAValue.contains(Self.plainValue(v)) {
                    add(m.range(at: 1), .apiKey)
                }
            }
        }
        for m in named && p.longestToken >= 20 ? Self.namedSecretBare.all(in: ns) : [] {
            let v = text(m.range(at: 1))
            if v.contains(where: \.isUppercase), v.contains(where: \.isLowercase),
                v.contains(where: \.isNumber)
            {
                add(m.range(at: 1), .apiKey)
            }
        }
        for m in p.has("basic") ? Self.basicAuth.all(in: ns) : [] {
            let v = text(m.range(at: 1))
            if let d = Data(base64Encoded: v), let t = String(data: d, encoding: .utf8),
                t.contains(":")
            {
                add(m.range(at: 1), .apiKey)
            }
        }
        if p.longestToken >= 64, p.hasAny(["priv", "secret", "wallet", "key"]) {
            let hexNear = Self.hexKeyword.spans(in: ns)
            for m in Self.hex64.all(in: ns) where isNear(m.range, hexNear, within: 40) {
                add(m.range, .apiKey)
            }
        }
        for m in p.longestToken >= 51 ? Self.wif.all(in: ns) : []
        where SecretDetector.base58Check(text(m.range)) {
            add(m.range, .apiKey)
        }
        for m in p.digits >= 32 && p.has("[") ? Self.byteArray.all(in: ns) : [] {
            let values = text(m.range).split { !$0.isNumber }.compactMap { Int($0) }
            guard values.allSatisfy({ $0 <= 255 }) else { continue }
            if values.count == 64 || keywordNear(m.range, Self.byteArrayKeyword, within: 60) {
                add(m.range, .apiKey)
            }
        }
        for m in p.has("cookie:") ? Self.cookieHeader.all(in: ns) : [] {
            add(m.range(at: 1), .apiKey)
        }
        if p.has("-----begin") {
            for block in SecretDetector.privateKeyBlocks(ns) { add(block.range, .apiKey) }
        }
    }
}
