import Foundation

enum ArchiveTarget: String, CaseIterable {
    case folder, zip, tgz, tar

    var ext: String {
        switch self {
        case .folder: return ""
        case .zip: return "zip"
        case .tgz: return "tar.gz"
        case .tar: return "tar"
        }
    }

    var code: String {
        switch self {
        case .folder: return tr("Unpack")
        case .zip: return "ZIP"
        case .tgz: return "TAR.GZ"
        case .tar: return "TAR"
        }
    }
}

/// ditto for ZIP (keeps macOS metadata the way Finder does), bsdtar for everything else,
/// including reading RAR and 7z.
enum ArchiveEngine {
    private static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    private static let tar = URL(fileURLWithPath: "/usr/bin/tar")

    /// "photos.tar.gz" -> "photos".
    static func baseName(_ url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz", ".tbz2", ".txz"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex { name = String(name[..<dot]) }
        return name
    }

    static func isSameFormat(_ url: URL, _ target: ArchiveTarget) -> Bool {
        let name = url.lastPathComponent.lowercased()
        switch target {
        case .zip: return name.hasSuffix(".zip")
        case .tgz: return name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz")
        case .tar: return name.hasSuffix(".tar")
        case .folder: return false
        }
    }

    /// "./name": a file called "--checkpoint-action=…" stays a file name for tar instead of becoming an option.
    static func safeName(_ name: String) -> String { "./" + name }

    static func removeJunk(in folder: URL) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker where [".DS_Store", "__MACOSX"].contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
    }

    /// Unpacks into a folder named after the archive. A single top-level item is lifted out,
    /// the way Archive Utility does it.
    static func extract(_ input: URL, ctx: JobContext, into parent: URL? = nil) async throws -> URL {
        let dest: URL
        if let parent {
            dest = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        } else {
            dest = try ctx.folder(for: input, name: baseName(input))
        }
        do {
            if input.pathExtension.lowercased() == "zip" {
                try await Shell.run(ditto, ["-x", "-k", input.path, dest.path])
            } else {
                try await Shell.run(tar, ["-xf", input.path, "-C", dest.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
            .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }) ?? []
        if parent == nil, items.count == 1 {
            // Park the only item, drop the wrapper folder, then take the name it frees up.
            let fm = FileManager.default
            let parked = dest.deletingLastPathComponent().appendingPathComponent(".krutilka-\(UUID().uuidString)")
            try fm.moveItem(at: items[0], to: parked)
            try? fm.removeItem(at: dest)
            let lifted = Naming.unique(dest.deletingLastPathComponent().appendingPathComponent(items[0].lastPathComponent))
            try fm.moveItem(at: parked, to: lifted)
            return lifted
        }
        return dest
    }

    /// Packs one or more items. Several items become "Archive.zip" next to the first one.
    static func pack(_ inputs: [URL], as target: ArchiveTarget, ctx: JobContext, name: String? = nil) async throws -> URL {
        let first = inputs[0]
        let parent = first.deletingLastPathComponent()
        let base = name ?? (inputs.count == 1 ? first.deletingPathExtension().lastPathComponent : tr("Archive"))
        let dir = ctx.directory(for: first)
        let out = Naming.unique(dir.appendingPathComponent(base + "." + target.ext))
        switch target {
        case .zip:
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: first.path, isDirectory: &isFolder)
            if inputs.count == 1 && !isFolder.boolValue {
                try await Shell.run(ditto, ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", first.path, out.path])
            } else {
                // Clone the items (cheap on APFS) into one folder, drop .DS_Store, zip the folder's contents.
                // File names never reach a command line, where a name like "--option" could be read as one.
                let fm = FileManager.default
                let staging = try ctx.scratch().appendingPathComponent("zip-" + UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                for url in inputs {
                    try fm.copyItem(at: url, to: Naming.unique(staging.appendingPathComponent(url.lastPathComponent)))
                }
                removeJunk(in: staging)
                try await Shell.run(ditto, ["-c", "-k", "--norsrc", "--noextattr", "--noacl", staging.path, out.path])
            }
        case .tgz, .tar:
            let flags = target == .tgz ? "-czf" : "-cf"
            try await Shell.run(tar, [flags, out.path, "--no-mac-metadata", "--exclude", ".DS_Store", "-C", parent.path]
                                + inputs.map { safeName($0.lastPathComponent) })
        case .folder:
            break
        }
        return out
    }

    /// Archive to another archive type: unpack to scratch, pack the contents again.
    static func repack(_ input: URL, as target: ArchiveTarget, ctx: JobContext) async throws -> URL {
        if target == .folder { return try await extract(input, ctx: ctx) }
        let scratch = try ctx.scratch()
        let unpacked = try await extract(input, ctx: ctx, into: scratch)
        ctx.progress(0.5)
        let items = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
        guard !items.isEmpty else { throw KError.nothingToDo(tr("The archive is empty.")) }
        let out = Naming.unique(ctx.directory(for: input).appendingPathComponent(baseName(input) + "." + target.ext))
        let flags = target == .tgz ? "-czf" : "-cf"
        if target == .zip {
            // The names came out of someone else's archive: keep them off the command line.
            try await Shell.run(ditto, ["-c", "-k", "--norsrc", "--noextattr", "--noacl", unpacked.path, out.path])
        } else {
            try await Shell.run(tar, [flags, out.path, "--no-mac-metadata", "-C", unpacked.path] + items.map { safeName($0.lastPathComponent) })
        }
        return out
    }
}

enum SubtitleEngine {
    struct Cue { var start: String; var end: String; var text: String }

    static func convert(_ input: URL, to ext: String, ctx: JobContext) async throws -> URL {
        let source = try String(contentsOf: input, encoding: .utf8)
        let cues = parse(source)
        guard !cues.isEmpty else { throw KError.nothingToDo(tr("No subtitles found in the file.")) }
        let out = ctx.destination(for: input, ext: ext)
        let text: String
        switch ext {
        case "vtt":
            text = "WEBVTT\n\n" + cues.map { "\(stamp($0.start, ms: ".")) --> \(stamp($0.end, ms: "."))\n\($0.text)" }
                .joined(separator: "\n\n") + "\n"
        case "srt":
            text = cues.enumerated().map { i, c in "\(i + 1)\n\(stamp(c.start, ms: ",")) --> \(stamp(c.end, ms: ","))\n\(c.text)" }
                .joined(separator: "\n\n") + "\n"
        default:
            text = cues.map(\.text).joined(separator: "\n") + "\n"
        }
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func parse(_ source: String) -> [Cue] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            let start = parts[0].trimmingCharacters(in: .whitespaces)
            let end = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            let text = lines[(timing + 1)...].joined(separator: "\n")
            cues.append(Cue(start: start, end: end, text: text))
        }
        return cues
    }

    /// "1:02.5" or "00:01:02,500" -> "00:01:02<sep>500".
    private static func stamp(_ raw: String, ms sep: String) -> String {
        let cleaned = raw.replacingOccurrences(of: ",", with: ".")
        var parts = cleaned.split(separator: ":").map(String.init)
        while parts.count < 3 { parts.insert("00", at: 0) }
        let secParts = parts[2].split(separator: ".").map(String.init)
        let seconds = secParts.first ?? "00"
        var millis = secParts.count > 1 ? secParts[1] : "000"
        while millis.count < 3 { millis += "0" }
        func pad(_ s: String) -> String { s.count >= 2 ? s : String(repeating: "0", count: 2 - s.count) + s }
        return "\(pad(parts[0])):\(pad(parts[1])):\(pad(seconds))\(sep)\(millis.prefix(3))"
    }
}
