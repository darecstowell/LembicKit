import Foundation

extension DetectorScan {
    static func luhn(_ d: [Int]) -> Bool {
        var sum = 0
        for (i, x) in d.reversed().enumerated() {
            if i % 2 == 1 {
                let v = x * 2
                sum += v > 9 ? v - 9 : v
            } else {
                sum += x
            }
        }
        return sum % 10 == 0
    }

    /// Issuer prefix and length table (Visa, Mastercard, Amex, Discover, JCB, Diners,
    /// UnionPay, Maestro, Mir, Troy).
    static func issuerAccepts(_ d: [Int]) -> Bool {
        let n = d.count
        let p2 = d[0] * 10 + d[1]
        let p3 = p2 * 10 + d[2]
        let p4 = p3 * 10 + d[3]
        if d[0] == 4 { return n == 13 || n == 16 || n == 19 }
        if (51...55).contains(p2) || (2221...2720).contains(p4) { return n == 16 }
        if p2 == 34 || p2 == 37 { return n == 15 }
        if p4 == 6011 || (644...649).contains(p3) || p2 == 65 { return (16...19).contains(n) }
        if (3528...3589).contains(p4) { return (16...19).contains(n) }
        if (300...305).contains(p3) || p4 == 3095 || p2 == 36 || p2 == 38 || p2 == 39 {
            return (14...19).contains(n)
        }
        if p2 == 62 || p2 == 81 { return (16...19).contains(n) }
        if [5018, 5020, 5038, 5893, 6304, 6759, 6761, 6762, 6763].contains(p4) {
            return (12...19).contains(n)
        }
        if (2200...2204).contains(p4) { return (16...19).contains(n) }
        if p4 == 9792 { return n == 16 }
        return false
    }

    static func ssnShape(_ area: Int, _ group: Int, _ serial: Int) -> Bool {
        if group == 0 || serial == 0 || area == 0 || area == 666 { return false }
        if area >= 900 {
            return (50...65).contains(group) || (70...88).contains(group)
                || (90...92).contains(group) || (94...99).contains(group)
        }
        return true
    }

    static func mod97(_ v: String) -> Bool {
        var rem = 0
        for ch in (v.dropFirst(4) + v.prefix(4)).unicodeScalars {
            let c = ch.value
            if c >= 0x30 && c <= 0x39 {
                rem = (rem * 10 + Int(c - 0x30)) % 97
            } else if c >= 0x41 && c <= 0x5A {
                rem = (rem * 100 + Int(c) - 55) % 97
            } else {
                return false
            }
        }
        return rem == 1
    }

    static func abaValid(_ d: [Int]) -> Bool {
        guard d.count == 9 else { return false }
        return (3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + d[2] + d[5] + d[8]) % 10
            == 0
    }

    static func tfnValid(_ d: [Int]) -> Bool {
        guard d.count == 9 else { return false }
        return zip(d, [1, 4, 3, 7, 5, 8, 6, 9, 10]).map(*).reduce(0, +) % 11 == 0
    }

    static func cpfValid(_ n: [Int]) -> Bool {
        guard n.count == 11, Set(n).count > 1 else { return false }
        let s1 = zip(n[0..<9], (2...10).reversed()).map(*).reduce(0, +)
        let s2 = zip(n[0..<10], (2...11).reversed()).map(*).reduce(0, +)
        return (s1 * 10 % 11) % 10 == n[9] && (s2 * 10 % 11) % 10 == n[10]
    }

    static func nirValid(_ raw: String) -> Bool {
        let d = raw.replacingOccurrences(of: " ", with: "").uppercased()
            .replacingOccurrences(of: "2A", with: "19").replacingOccurrences(of: "2B", with: "18")
        guard d.count == 15, let body = Int(d.prefix(13)), let key = Int(d.suffix(2)) else {
            return false
        }
        return 97 - body % 97 == key
    }

    static func nhsValid(_ n: [Int]) -> Bool {
        guard n.count == 10 else { return false }
        let s = zip(n[0..<9], (2...10).reversed()).map(*).reduce(0, +)
        let c = 11 - s % 11
        return c != 10 && (c == 11 ? 0 : c) == n[9]
    }

    private static let verhoeffD: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 2, 3, 4, 0, 6, 7, 8, 9, 5],
        [2, 3, 4, 0, 1, 7, 8, 9, 5, 6], [3, 4, 0, 1, 2, 8, 9, 5, 6, 7],
        [4, 0, 1, 2, 3, 9, 5, 6, 7, 8], [5, 9, 8, 7, 6, 0, 4, 3, 2, 1],
        [6, 5, 9, 8, 7, 1, 0, 4, 3, 2], [7, 6, 5, 9, 8, 2, 1, 0, 4, 3],
        [8, 7, 6, 5, 9, 3, 2, 1, 0, 4], [9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
    ]
    private static let verhoeffP: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 5, 7, 6, 2, 8, 3, 0, 9, 4],
        [5, 8, 0, 3, 7, 9, 6, 1, 4, 2], [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
        [9, 4, 5, 3, 1, 2, 6, 8, 7, 0], [4, 2, 8, 6, 5, 7, 3, 9, 0, 1],
        [2, 7, 9, 3, 8, 0, 6, 4, 1, 5], [7, 0, 4, 6, 9, 1, 3, 2, 5, 8],
    ]

    static func verhoeff(_ d: [Int]) -> Bool {
        var c = 0
        for (i, x) in d.reversed().enumerated() { c = verhoeffD[c][verhoeffP[i % 8][x]] }
        return c == 0
    }

    static func codiceFiscaleValid(_ raw: String) -> Bool {
        let s = Array(raw.uppercased().unicodeScalars.map { Int($0.value) })
        guard s.count == 16 else { return false }
        let odd = [
            1, 0, 5, 7, 9, 13, 15, 17, 19, 21, 2, 4, 18, 20, 11, 3, 6, 8, 12, 14, 16, 10, 22, 25,
            24, 23,
        ]
        var sum = 0
        for i in 0..<15 {
            let v = s[i] >= 0x41 ? s[i] - 0x41 : s[i] - 0x30
            sum += i % 2 == 0 ? odd[v] : v
        }
        return s[15] - 0x41 == sum % 26
    }
}
