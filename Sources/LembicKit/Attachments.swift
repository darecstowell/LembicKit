import Foundation

public struct AttachmentInfo: Sendable {
    public let mimeType: String?
    public let uti: String?
    public let transferName: String?

    public init(mimeType: String?, uti: String?, transferName: String?) {
        self.mimeType = mimeType
        self.uti = uti
        self.transferName = transferName
    }

    /// Typed placeholder for this attachment, or nil to omit it.
    /// Rich-link previews are dropped because the URL is already in the text.
    public var placeholder: String? {
        if let tn = transferName, tn.hasSuffix(".pluginPayloadAttachment") {
            return nil
        }
        let m = (mimeType ?? "").lowercased()
        let u = (uti ?? "").lowercased()
        let tn = (transferName ?? "").lowercased()
        if m.hasPrefix("image/gif") || u == "com.compuserve.gif" { return "[gif]" }
        if m.hasPrefix("image/")
            || ["heic", "jpeg", "png", "image", "camera"].contains(where: u.contains)
        {
            return "[photo]"
        }
        if m.hasPrefix("video/")
            || ["quicktime", "movie", "video", "mpeg-4"].contains(where: u.contains)
        {
            return "[video]"
        }
        if m == "application/pdf" || u.contains("pdf") { return "[pdf]" }
        if m == "text/vcard" || u == "public.vcard" || tn.hasSuffix(".vcf") { return "[contact]" }
        if m.hasPrefix("audio/") || u.contains("audio") || u.contains("coreaudio") {
            return "[audio]"
        }
        return "[attachment]"
    }
}
