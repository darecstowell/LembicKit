import Foundation

extension Transcript {
    /// The closed set of typed placeholders the renderer emits — the attachment
    /// markers from `AttachmentInfo.placeholder` plus the FindMy `[shared
    /// location]` fallback (`Extractor.renderText`). Kept here because stripping
    /// is a render-layer concern; keep in lockstep if a new marker is added.
    /// Genmoji (`[genmoji: …]`) is stripped by prefix; a voice note's words
    /// (`[audio: "…"]`) are content and stay.
    static let placeholderTokens = [
        "[photo]", "[video]", "[gif]", "[audio]", "[pdf]",
        "[contact]", "[attachment]", "[shared location]", "[sticker]", "[location]",
    ]

    /// Remove placeholder tokens from one already-rendered message body. Caller
    /// gates on `hadAttachment`, so a literally-typed "[pdf]" in a message with
    /// no real attachment is left alone (rare edge, acceptable for a trim).
    static func stripPlaceholders(_ s: String) -> String {
        let source = s as NSString
        return BodySplice.apply(to: source, placeholderStripSubstitutions(source))
    }

    /// The placeholder strip as substitutions in SOURCE offsets, so it composes with
    /// redaction spans and the `OffsetMap` instead of shifting them.
    static func placeholderStripSubstitutions(_ source: NSString) -> [BodySplice.Substitution] {
        let length = source.length
        guard length > 0 else { return [] }
        var isToken = [Bool](repeating: false, count: length)
        for token in placeholderTokens {
            var search = NSRange(location: 0, length: length)
            while search.length > 0 {
                let found = source.range(of: token, options: .literal, range: search)
                if found.location == NSNotFound { break }
                for k in found.location..<(found.location + found.length) { isToken[k] = true }
                let next = found.location + found.length
                search = NSRange(location: next, length: length - next)
            }
        }
        var search = NSRange(location: 0, length: length)
        while search.length > 0 {
            let found = source.range(
                of: #"\[genmoji: [^\]]*\]"#, options: .regularExpression, range: search)
            if found.location == NSNotFound { break }
            for k in found.location..<(found.location + found.length) { isToken[k] = true }
            let next = found.location + found.length
            search = NSRange(location: next, length: length - next)
        }
        func isSpace(_ k: Int) -> Bool {
            let c = source.character(at: k)
            return c == 0x20 || c == 0x09
        }
        func isEdge(_ k: Int) -> Bool {
            if isToken[k] { return true }
            guard let scalar = Unicode.Scalar(source.character(at: k)) else { return false }
            return Extractor.pythonWhitespace.contains(scalar)
        }
        var head = 0
        while head < length, isEdge(head) { head += 1 }
        guard head < length else {
            return [BodySplice.Substitution(range: 0..<length, token: "", isRedaction: false)]
        }
        var tail = length
        while tail > head, isEdge(tail - 1) { tail -= 1 }
        var out: [BodySplice.Substitution] = []
        if head > 0 {
            out.append(BodySplice.Substitution(range: 0..<head, token: "", isRedaction: false))
        }
        var k = head
        while k < tail {
            guard isToken[k] || isSpace(k) else {
                k += 1
                continue
            }
            var end = k
            while end < tail, isToken[end] || isSpace(end) { end += 1 }
            if !(end - k == 1 && source.character(at: k) == 0x20) {
                out.append(BodySplice.Substitution(range: k..<end, token: " ", isRedaction: false))
            }
            k = end
        }
        if tail < length {
            out.append(BodySplice.Substitution(range: tail..<length, token: "", isRedaction: false))
        }
        return out
    }

    /// The legend entries, in a fixed order, for the placeholder kinds that occur
    /// in `bodies`. A voice note with words counts as `[audio]`.
    static func legendTokens(in bodies: [String]) -> [String] {
        let kinds: [(token: String, matches: [String])] = [
            ("[photo]", ["[photo]"]), ("[video]", ["[video]"]), ("[gif]", ["[gif]"]),
            ("[audio]", ["[audio]", "[audio: \""]), ("[pdf]", ["[pdf]"]),
            ("[contact]", ["[contact]"]), ("[location]", ["[location]"]),
            ("[shared location]", ["[shared location]"]), ("[sticker]", ["[sticker]"]),
            ("[genmoji: …]", ["[genmoji: "]), ("[attachment]", ["[attachment]"]),
        ]
        var found = Set<String>()
        for body in bodies where body.utf8.contains(0x5B) {
            for kind in kinds where !found.contains(kind.token) {
                if kind.matches.contains(where: body.contains) { found.insert(kind.token) }
            }
        }
        return kinds.map(\.token).filter(found.contains)
    }
}
