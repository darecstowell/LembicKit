import Foundation

/// A detection copy of one message body plus the map back to source UTF-16 offsets.
/// Detectors run on `text`; every hit maps back through `sourceRange`.
struct NormalizedText {
    let text: NSString
    /// For each UTF-16 unit of `text`, the source range it came from. Empty means identity.
    private let map: [Range<Int>]

    init(identity text: NSString) {
        self.text = text
        self.map = []
    }

    init(text: NSString, map: [Range<Int>]) {
        self.text = text
        self.map = map
    }

    var isIdentity: Bool { map.isEmpty }

    func sourceRange(_ r: NSRange) -> Range<Int>? {
        guard r.location != NSNotFound, r.length > 0, r.location + r.length <= text.length else {
            return nil
        }
        guard !map.isEmpty else { return r.location..<(r.location + r.length) }
        return map[r.location].lowerBound..<map[r.location + r.length - 1].upperBound
    }
}

/// Undoes the character changes that hide a value from the detectors: full-width and
/// other Unicode digits, circled and keycap digits, zero-width and bidi marks, soft
/// hyphens, odd spaces and dashes, Cyrillic or Greek lookalikes inside Latin words,
/// and runs of three or more spelled digits ("four six two zero").
enum TextNormalizer {
    private static let dropped: Set<UInt32> = [
        0x00AD, 0x180E, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D,
        0x202E, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0x2066, 0x2067, 0x2068, 0x2069, 0xFE0E,
        0xFE0F, 0xFEFF, 0x20E3,
    ]
    private static let dashes: Set<UInt32> = [
        0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212, 0xFE58, 0xFE63, 0xFF0D,
    ]
    private static let lookalikes: [UInt32: UInt8] = [
        0x0430: 0x61, 0x0435: 0x65, 0x043E: 0x6F, 0x0440: 0x70, 0x0441: 0x63, 0x0443: 0x79,
        0x0445: 0x78, 0x0456: 0x69, 0x0455: 0x73, 0x0458: 0x6A, 0x0410: 0x41, 0x0412: 0x42,
        0x0415: 0x45, 0x041A: 0x4B, 0x041C: 0x4D, 0x041D: 0x48, 0x041E: 0x4F, 0x0420: 0x50,
        0x0421: 0x43, 0x0422: 0x54, 0x0425: 0x58, 0x03BF: 0x6F, 0x039F: 0x4F, 0x03B1: 0x61,
        0x0391: 0x41, 0x0392: 0x42, 0x0395: 0x45, 0x0397: 0x48, 0x0399: 0x49, 0x039A: 0x4B,
        0x039C: 0x4D, 0x039D: 0x4E, 0x03A1: 0x50, 0x03A4: 0x54, 0x03A7: 0x58, 0x03A5: 0x59,
    ]
    /// Letters that case-insensitive matching folds to ASCII; mapped so keyword gates see them.
    private static let foldsToASCII: [UInt32: String] = [
        0x017F: "s", 0x212A: "K", 0x00DF: "ss", 0x1E9E: "SS", 0xFB00: "ff", 0xFB01: "fi",
        0xFB02: "fl", 0xFB03: "ffi", 0xFB04: "ffl", 0xFB05: "st", 0xFB06: "st",
    ]
    private static let numberWord = try! NSRegularExpression(
        pattern:
            #"(?i)(?<![\p{L}])(zero|oh|one|two|three|four|five|six|seven|eight|nine)(?![\p{L}])"#)
    private static let wordDigit: [String: UInt16] = [
        "zero": 0x30, "oh": 0x30, "one": 0x31, "two": 0x32, "three": 0x33, "four": 0x34,
        "five": 0x35, "six": 0x36, "seven": 0x37, "eight": 0x38, "nine": 0x39,
    ]

    static func normalize(_ source: String) -> NormalizedText {
        let (ascii, numberWords) = scan(source.utf16)
        if ascii, numberWords < 3 { return NormalizedText(identity: source as NSString) }
        let stage1 =
            ascii ? NormalizedText(identity: source as NSString) : mapCharacters(source as NSString)
        if !ascii, scan((stage1.text as String).utf16).numberWords < 3 { return stage1 }
        return spellDigits(stage1)
    }

    private static let packedNumberWords: Set<UInt64> = Set(
        wordDigit.keys.map { $0.utf8.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } })

    /// One pass: is the text plain ASCII, and how many words are spelled digits.
    private static func scan(_ units: String.UTF16View) -> (ascii: Bool, numberWords: Int) {
        var ascii = true
        var count = 0
        var packed: UInt64 = 0
        var length = 0
        func endWord() {
            if (2...5).contains(length), packedNumberWords.contains(packed) { count += 1 }
            packed = 0
            length = 0
        }
        for c in units {
            if c >= 0x80 { ascii = false }
            if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) {
                packed = packed << 8 | UInt64(c | 0x20)
                length += 1
            } else if length > 0 {
                endWord()
            }
        }
        endWord()
        return (ascii, count)
    }

    private static func mapCharacters(_ ns: NSString) -> NormalizedText {
        let length = ns.length
        var out: [UInt16] = []
        var map: [Range<Int>] = []
        out.reserveCapacity(length)
        map.reserveCapacity(length)
        var changed = false
        var pendingStart: Int?
        let scalars = Array((ns as String).unicodeScalars)
        var offset = 0
        func isLatin(_ i: Int) -> Bool {
            guard i >= 0, i < scalars.count else { return false }
            let v = scalars[i].value
            return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
        }
        for (i, scalar) in scalars.enumerated() {
            let width = scalar.utf16.count
            let src = (pendingStart ?? offset)..<(offset + width)
            offset += width
            let v = scalar.value
            var emit: [UInt16]
            if dropped.contains(v) {
                changed = true
                if let last = map.last {
                    map[map.count - 1] = last.lowerBound..<src.upperBound
                } else {
                    pendingStart = src.lowerBound
                }
                continue
            } else if v < 0x80 {
                emit = [UInt16(v)]
            } else if let digit = digitValue(scalar) {
                emit = [0x30 + UInt16(digit)]
                changed = true
            } else if v >= 0xFF01 && v <= 0xFF5E {
                emit = [UInt16(v - 0xFEE0)]
                changed = true
            } else if dashes.contains(v) {
                emit = [0x2D]
                changed = true
            } else if scalar.properties.generalCategory == .spaceSeparator {
                emit = [0x20]
                changed = true
            } else if let latin = lookalikes[v], isLatin(i - 1) || isLatin(i + 1) {
                emit = [UInt16(latin)]
                changed = true
            } else if let ascii = foldsToASCII[v] {
                emit = Array(ascii.utf16)
                changed = true
            } else {
                emit = Array(String(scalar).utf16)
            }
            pendingStart = nil
            for unit in emit {
                out.append(unit)
                map.append(src)
            }
        }
        guard changed else { return NormalizedText(identity: ns) }
        return NormalizedText(text: makeString(out), map: map)
    }

    private static func makeString(_ units: [UInt16]) -> NSString {
        units.isEmpty
            ? ""
            : units.withUnsafeBufferPointer {
                NSString(characters: $0.baseAddress!, length: $0.count)
            }
    }

    /// The 0 to 9 value of a Unicode decimal digit, a circled digit, or a math digit.
    private static func digitValue(_ s: Unicode.Scalar) -> Int? {
        let v = s.value
        if v >= 0x2460 && v <= 0x2468 { return Int(v - 0x2460 + 1) }  // ① to ⑨
        if v == 0x24EA || v == 0x24FF { return 0 }  // ⓪ ⓿
        if v >= 0x2776 && v <= 0x277E { return Int(v - 0x2776 + 1) }  // ❶ to ❾
        guard s.properties.numericType == .decimal, let n = s.properties.numericValue,
            n >= 0, n <= 9, n == n.rounded()
        else { return nil }
        return Int(n)
    }

    /// Runs of three or more spelled digits, separated only by spaces, commas, or
    /// dashes, become digits. A run must hold at least two words other than "oh".
    private static func spellDigits(_ input: NormalizedText) -> NormalizedText {
        let ns = input.text
        let whole = NSRange(location: 0, length: ns.length)
        let words = numberWord.matches(in: ns as String, range: whole).map(\.range)
        guard words.count >= 3 else { return input }
        var runs: [[NSRange]] = []
        var current: [NSRange] = []
        func close() {
            let real = current.filter { ns.substring(with: $0).lowercased() != "oh" }
            if current.count >= 3, real.count >= 2 { runs.append(current) }
        }
        for w in words {
            if let last = current.last {
                let gapStart = last.location + last.length
                let gap = ns.substring(
                    with: NSRange(location: gapStart, length: w.location - gapStart))
                if !gap.isEmpty, gap.count <= 3, gap.allSatisfy({ " ,-".contains($0) }) {
                    current.append(w)
                    continue
                }
                close()
            }
            current = [w]
        }
        close()
        guard !runs.isEmpty else { return input }
        var out: [UInt16] = []
        var map: [Range<Int>] = []
        var k = 0
        var runIndex = 0
        while k < ns.length {
            if runIndex < runs.count, k == runs[runIndex][0].location {
                for w in runs[runIndex] {
                    let digit = wordDigit[ns.substring(with: w).lowercased()] ?? 0x30
                    out.append(digit)
                    map.append(
                        input.sourceRange(w)
                            ?? w.location..<(w.location + w.length))
                }
                let last = runs[runIndex].last!
                k = last.location + last.length
                runIndex += 1
                continue
            }
            out.append(ns.character(at: k))
            map.append(input.sourceRange(NSRange(location: k, length: 1)) ?? k..<(k + 1))
            k += 1
        }
        return NormalizedText(text: makeString(out), map: map)
    }
}
