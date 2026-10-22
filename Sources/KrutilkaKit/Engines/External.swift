import Foundation

/// Errors a job can end with. The message is shown in the HUD, so it says what happened and what to do.
enum KError: LocalizedError {
    case unreadable(String)
    case failed(String)
    case tool(String, String)
    case needsTool(String)
    case nothingToDo(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return trf("Can't read %@.", name)
        case .failed(let why): return why
        case .tool(let name, let tail):
            let line = tail.split(separator: "\n").last.map(String.init) ?? ""
            return line.isEmpty ? trf("%@ stopped with an error.", name) : "\(name): \(line)"
        case .needsTool(let name): return trf("This needs %@. Install it with Homebrew.", name)
        case .nothingToDo(let why): return why
        }
    }
}

/// Optional command-line helpers. When one is installed, the formats it adds appear on the wheel;
/// when it is not, those segments are simply not there.
final class ExternalTools {
    enum Tool: String, CaseIterable, Identifiable {
        case ffmpeg, ffprobe, cwebp, gif2webp, magick, soffice, pandoc, lame
        var id: String { rawValue }

        var purpose: String {
            switch self {
            case .ffmpeg: return tr("MP3, OGG, WebM, MKV, AVI and better GIFs")
            case .ffprobe: return tr("Video length for accurate progress")
            case .cwebp: return tr("Saving images as WebP")
            case .gif2webp: return tr("Animated GIF to WebP")
            case .magick: return tr("Fallback for rare image formats and SVG")
            case .soffice: return tr("Slides, spreadsheets, Pages, Keynote, Numbers, and Word to PDF")
            case .pandoc: return tr("EPUB and better Markdown")
            case .lame: return tr("MP3 when ffmpeg is missing")
            }
        }

        var brewFormula: String {
            switch self {
            case .ffmpeg, .ffprobe: return "ffmpeg"
            case .cwebp, .gif2webp: return "webp"
            case .magick: return "imagemagick"
            case .soffice: return "--cask libreoffice"
            case .pandoc: return "pandoc"
            case .lame: return "lame"
            }
        }
    }

    static let shared = ExternalTools()
    private let lock = NSLock()
    private var found: [Tool: URL] = [:]

    private static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    init() { refresh() }

    func refresh() {
        var map: [Tool: URL] = [:]
        let fm = FileManager.default
        for tool in Tool.allCases {
            var candidates = Self.searchDirs.map { "\($0)/\(tool.rawValue)" }
            if tool == .soffice {
                candidates.insert("/Applications/LibreOffice.app/Contents/MacOS/soffice", at: 0)
            }
            if let path = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
                map[tool] = URL(fileURLWithPath: path)
            }
        }
        lock.lock(); found = map; lock.unlock()
    }

    func url(_ tool: Tool) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return found[tool]
    }

    func has(_ tool: Tool) -> Bool { url(tool) != nil }

    func require(_ tool: Tool) throws -> URL {
        guard let u = url(tool) else { throw KError.needsTool(tool.rawValue) }
        return u
    }
}

/// Runs a command-line tool off the main thread. Cancelling the Swift task terminates the process.
enum Shell {
    @discardableResult
    static func run(_ executable: URL, _ args: [String], cwd: URL? = nil,
                    onLine: ((String) -> Void)? = nil) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collected = LockedBuffer(), errors = LockedBuffer()
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            collected.append(data)
            if let onLine, let text = String(data: data, encoding: .utf8) {
                text.split(whereSeparator: \.isNewline).forEach { onLine(String($0)) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if !data.isEmpty { errors.append(data) }
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        // Drain anything left after the handlers were removed.
        collected.append(out.fileHandleForReading.readDataToEndOfFile())
        errors.append(err.fileHandleForReading.readDataToEndOfFile())

        try Task.checkCancellation()
        guard status == 0 else {
            throw KError.tool(executable.lastPathComponent, errors.string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return collected.string
    }
}

final class LockedBuffer {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// Hands a value that isn't Sendable across a concurrency boundary we know is safe
/// (AppKit and AVFoundation objects used from one place at a time).
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}
