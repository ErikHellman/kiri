import Foundation

/// A file Kiri shows in a read-only viewer instead of the editor: a
/// picture, a video (or a sound), or the list of what an archive holds.
///
/// Told from the file's first bytes (`headLength` of them), which say what
/// a file is whatever it is called; the name only decides for formats whose
/// first bytes say little (a `.bmp`, a `.tar.gz`, an old `.tar`). A file
/// that is text is never media: SVG, which is text, opens in the editor
/// and has a preview of its own.
public enum MediaKind: Equatable, Hashable, Sendable {
    /// A picture ImageIO reads; the name is the format's, for the status
    /// bar ("PNG", "JPEG", "HEIC").
    case image(String)
    /// A movie or a sound, for AVFoundation; the name as for an image
    /// ("MPEG-4", "QuickTime", "MPEG").
    case video(String)
    case archive(ArchiveFormat)

    public enum ArchiveFormat: String, Hashable, Sendable {
        case zip, tar, tarGzip

        /// "ZIP", "TAR", "TAR.GZ".
        public var name: String {
            switch self {
            case .zip: "ZIP"
            case .tar: "TAR"
            case .tarGzip: "TAR.GZ"
            }
        }
    }

    /// How many bytes from the start of a file `detect` looks at.
    public static let headLength = 512

    /// The format's name, for the status bar.
    public var name: String {
        switch self {
        case .image(let name), .video(let name): name
        case .archive(let format): format.name
        }
    }

    /// "image", "video" or "archive", for telemetry.
    public var family: String {
        switch self {
        case .image: "image"
        case .video: "video"
        case .archive: "archive"
        }
    }

    /// What a file named `fileName` that starts with `head` is, or nil
    /// for a file the editor opens (text, or a binary file Kiri has no
    /// viewer for).
    public static func detect(fileName: String, head: Data) -> MediaKind? {
        let bytes = [UInt8](head.prefix(headLength))
        let name = fileName.lowercased()
        let ext = (name as NSString).pathExtension
        if let kind = sniff(bytes, ext: ext, name: name) { return kind }
        // Nothing in the first bytes says what it is: the name decides,
        // for a file that isn't text.
        guard bytes.contains(0) else { return nil }
        if let image = imageExtensions[ext] { return .image(image) }
        if let video = videoExtensions[ext] { return .video(video) }
        return nil
    }

    // MARK: First bytes

    private static func sniff(_ b: [UInt8], ext: String, name: String) -> MediaKind? {
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            b.count >= offset + prefix.count && Array(b[offset..<offset + prefix.count]) == prefix
        }
        func ascii(_ s: String, at offset: Int = 0) -> Bool { starts(Array(s.utf8), at: offset) }

        // Pictures.
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .image(isAnimatedPNG(b) ? "APNG" : "PNG") }
        if starts([0xFF, 0xD8, 0xFF]) { return .image("JPEG") }
        if ascii("GIF87a") || ascii("GIF89a") { return .image("GIF") }
        if ascii("RIFF"), ascii("WEBP", at: 8) { return .image("WebP") }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) {
            // Camera raw files are TIFF inside.
            return .image(rawExtensions.contains(ext) ? ext.uppercased() : "TIFF")
        }
        if ascii("icns") { return .image("ICNS") }
        if ascii("8BPS") { return .image("PSD") }
        if starts([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20]) { return .image("JPEG 2000") }
        if ascii("BM"), ext == "bmp" || ext == "dib" { return .image("BMP") }
        if starts([0x00, 0x00, 0x01, 0x00]), ext == "ico" { return .image("ICO") }
        if starts([0x00, 0x00, 0x02, 0x00]), ext == "cur" { return .image("CUR") }

        // ISO base media (MP4, QuickTime, HEIF): the brands in its `ftyp` box.
        if ascii("ftyp", at: 4) {
            let brands = isoBrands(b)
            if brands.contains(where: { avifBrands.contains($0) }) { return .image("AVIF") }
            if brands.contains(where: { heifBrands.contains($0) }) { return .image("HEIC") }
            if brands.first == "qt  " { return .video("QuickTime") }
            if brands.first.map({ $0.hasPrefix("3g") }) == true { return .video("3GPP") }
            if brands.first.map({ audioBrands.contains($0) }) == true { return .video("MPEG-4 Audio") }
            return .video("MPEG-4")
        }
        // An older QuickTime movie starts with another atom.
        if ["moov", "mdat", "wide", "pnot"].contains(where: { ascii($0, at: 4) }) { return .video("QuickTime") }
        // MPEG-1 and MPEG-2: a program stream, a video stream, a transport stream.
        if starts([0x00, 0x00, 0x01, 0xBA]) || starts([0x00, 0x00, 0x01, 0xB3]) { return .video("MPEG") }
        if b.count > 376, b[0] == 0x47, b[188] == 0x47, b[376] == 0x47 { return .video("MPEG-TS") }
        if starts([0x1A, 0x45, 0xDF, 0xA3]) { return .video(ext == "webm" ? "WebM" : "Matroska") }
        if ascii("RIFF"), ascii("AVI ", at: 8) { return .video("AVI") }
        // Sounds play in the same player.
        if ascii("RIFF"), ascii("WAVE", at: 8) { return .video("WAVE") }
        if ascii("FORM"), ascii("AIFF", at: 8) || ascii("AIFC", at: 8) { return .video("AIFF") }
        if ascii("fLaC") { return .video("FLAC") }
        if ascii("caff") { return .video("CAF") }
        if ascii("ID3") || (b.count > 1 && b[0] == 0xFF && b[1] & 0xE0 == 0xE0 && ext == "mp3") { return .video("MP3") }

        // Archives.
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) || starts([0x50, 0x4B, 0x07, 0x08]) {
            return .archive(.zip)
        }
        if starts([0x1F, 0x8B]), ext == "tgz" || name.hasSuffix(".tar.gz") { return .archive(.tarGzip) }
        if ascii("ustar", at: 257) { return .archive(.tar) }
        if ext == "tar", b.contains(0), TarHeader.checksumIsValid(b) { return .archive(.tar) }
        return nil
    }

    /// An animated PNG has an `acTL` chunk before its first `IDAT`.
    private static func isAnimatedPNG(_ b: [UInt8]) -> Bool {
        var i = 8
        while i + 8 <= b.count {
            let length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            let type = String(decoding: b[i + 4..<i + 8], as: UTF8.self)
            if type == "acTL" { return true }
            if type == "IDAT" { return false }
            i += 12 + length
        }
        return false
    }

    /// The major brand, then the compatible ones, of an `ftyp` box.
    private static func isoBrands(_ b: [UInt8]) -> [String] {
        guard b.count >= 12 else { return [] }
        let size = min(b.count, max(16, Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])))
        var brands = [String(decoding: b[8..<12], as: UTF8.self)]
        var i = 16
        while i + 4 <= size {
            brands.append(String(decoding: b[i..<i + 4], as: UTF8.self))
            i += 4
        }
        return brands
    }

    private static let heifBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"]
    private static let avifBrands: Set<String> = ["avif", "avis"]
    private static let audioBrands: Set<String> = ["M4A ", "M4B ", "M4P ", "F4A "]
    private static let rawExtensions: Set<String> = ["dng", "nef", "cr2", "arw", "orf", "rw2", "pef", "srw", "raf"]

    // MARK: Names

    /// Formats told by their name when their first bytes say nothing.
    private static let imageExtensions: [String: String] = [
        "png": "PNG", "apng": "APNG", "jpg": "JPEG", "jpeg": "JPEG", "gif": "GIF", "webp": "WebP", "heic": "HEIC",
        "heif": "HEIC", "avif": "AVIF", "tif": "TIFF", "tiff": "TIFF", "bmp": "BMP", "ico": "ICO", "icns": "ICNS",
        "tga": "TGA", "exr": "OpenEXR", "jp2": "JPEG 2000",
    ]
    private static let videoExtensions: [String: String] = [
        "mov": "QuickTime", "qt": "QuickTime", "mp4": "MPEG-4", "m4v": "MPEG-4", "mpg": "MPEG", "mpeg": "MPEG",
        "mpe": "MPEG", "m1v": "MPEG", "m2v": "MPEG", "ts": "MPEG-TS", "mts": "MPEG-TS", "m2ts": "MPEG-TS",
        "3gp": "3GPP", "3g2": "3GPP", "m4a": "MPEG-4 Audio", "mp3": "MP3", "wav": "WAVE", "aif": "AIFF", "aiff": "AIFF",
    ]

    /// The file names the folder sidebar marks as pictures, videos and
    /// archives (`FileIcon`), from the name alone.
    public static func guess(fileName: String) -> MediaKind? {
        let name = fileName.lowercased()
        let ext = (name as NSString).pathExtension
        if let image = imageExtensions[ext] { return .image(image) }
        // (A `.ts` file is far more often TypeScript than a transport stream.)
        if let video = videoExtensions[ext], ext != "ts" { return .video(video) }
        if ext == "zip" || ext == "jar" || ext == "aar" || ext == "apk" || ext == "ipa" || ext == "war" { return .archive(.zip) }
        if ext == "tgz" || name.hasSuffix(".tar.gz") { return .archive(.tarGzip) }
        if ext == "tar" { return .archive(.tar) }
        return nil
    }
}

/// How the viewers' status bar puts sizes and lengths.
public enum MediaText {
    /// "1920 × 1080".
    public static func dimensions(_ width: Int, _ height: Int) -> String { "\(width) × \(height)" }

    /// "0:07", "2:31", "1:02:03": a length of time, as players show it.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1 file", "142 files".
    public static func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }
}
