import Foundation

public struct AttachmentInfo: Sendable {
    public let mimeType: String?
    public let uti: String?
    public let transferName: String?
    /// `attachment.is_sticker`.
    public let isSticker: Bool
    /// A Genmoji's description (`attachment.emoji_image_short_description`).
    public let emojiDescription: String?

    public init(
        mimeType: String?, uti: String?, transferName: String?, isSticker: Bool = false,
        emojiDescription: String? = nil
    ) {
        self.mimeType = mimeType
        self.uti = uti
        self.transferName = transferName
        self.isSticker = isSticker
        self.emojiDescription = emojiDescription
    }

    /// Typed placeholder for this attachment, or nil to omit it.
    /// Rich-link previews are dropped because the URL is already in the text.
    public var placeholder: String? {
        if let tn = transferName, tn.hasSuffix(".pluginPayloadAttachment") {
            return nil
        }
        if let genmoji = emojiDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
            !genmoji.isEmpty
        {
            return "[genmoji: \(genmoji.split(whereSeparator: \.isNewline).joined(separator: " "))]"
        }
        if isSticker { return "[sticker]" }
        let m = (mimeType ?? "").lowercased()
        let u = (uti ?? "").lowercased()
        let tn = (transferName ?? "").lowercased()
        if m.hasPrefix("image/gif") || u == "com.compuserve.gif" { return "[gif]" }
        if m.hasPrefix("image/")
            || ["heic", "jpeg", "png", "image", "camera"].contains(where: u.contains)
        {
            return "[photo]"
        }
        if m.hasPrefix("audio/") { return "[audio]" }
        if m.hasPrefix("video/")
            || ["quicktime", "movie", "video", "mpeg-4"].contains(where: u.contains)
                && !u.contains("audio")
        {
            return "[video]"
        }
        if m == "application/pdf" || u.contains("pdf") { return "[pdf]" }
        if u == "public.vlocation" || tn.hasSuffix(".loc.vcf") { return "[location]" }
        if m == "text/vcard" || u == "public.vcard" || tn.hasSuffix(".vcf") { return "[contact]" }
        if u.contains("audio") || u.contains("coreaudio") {
            return "[audio]"
        }
        return "[attachment]"
    }
}
