import Foundation
import UniformTypeIdentifiers

/// What a dropped file is, for picking which segments the wheel shows.
enum FileKind: String, CaseIterable {
    case image, svg, pdf, document, markdown, slides, sheet, table, json, audio, video, archive, subtitle, folder, other

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
           !["rtfd", "pages", "key", "numbers", "app"].contains(ext) {
            return .folder
        }
        if let kind = byExtension[ext] { return kind }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .svg) { return .svg }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .plainText) { return .document }
        return .other
    }

    private static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func put(_ kind: FileKind, _ exts: [String]) { exts.forEach { map[$0] = kind } }
        put(.image, ["jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "tif", "tiff", "gif", "bmp", "ico",
                     "icns", "jp2", "jxl", "tga", "psd", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "exr"])
        put(.svg, ["svg"])
        put(.pdf, ["pdf"])
        put(.document, ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "txt", "text", "webarchive", "pages", "epub"])
        put(.markdown, ["md", "markdown"])
        put(.slides, ["ppt", "pptx", "key", "odp"])
        put(.sheet, ["xlsx", "xls", "ods", "numbers"])
        put(.table, ["csv", "tsv"])
        put(.json, ["json"])
        put(.audio, ["mp3", "m4a", "wav", "aiff", "aif", "aifc", "flac", "ogg", "oga", "opus", "wma", "aac", "caf", "m4b", "amr"])
        put(.video, ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "3gp", "mts", "m2ts", "mpg", "mpeg", "ts", "ogv"])
        put(.archive, ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "rar", "7z", "iso", "cpio"])
        put(.subtitle, ["srt", "vtt"])
        return map
    }()

    /// The format code shown in the hub ("HEIC", "DOCX"). Folders show nothing.
    static func code(of url: URL) -> String {
        let ext = url.pathExtension.uppercased()
        switch ext {
        case "JPEG": return "JPG"
        case "TIF": return "TIFF"
        case "HTM": return "HTML"
        default: return ext
        }
    }
}
