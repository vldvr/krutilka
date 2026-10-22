import AppKit

/// Settings a job needs, copied on the main thread when the job starts so engines never touch
/// the live preferences from a background thread.
struct JobSettings {
    var imageQuality: Double
    var compressQuality: Double
    var targetSizeMB: Double
    var pdfDPI: Int
    var videoQuality: VideoQuality
    var audioBitrate: Int
    var outputPlace: OutputPlace
    var outputFolder: URL

    @MainActor static func snapshot() -> JobSettings {
        let p = Prefs.shared
        return JobSettings(imageQuality: p.imageQuality, compressQuality: p.compressQuality,
                           targetSizeMB: p.targetSizeMB, pdfDPI: p.pdfDPI, videoQuality: p.videoQuality,
                           audioBitrate: p.audioBitrate, outputPlace: p.outputPlace,
                           outputFolder: URL(fileURLWithPath: p.outputFolder, isDirectory: true))
    }
}

/// Everything an operation gets: its inputs, settings, a progress callback and output naming.
final class JobContext {
    let inputs: [URL]
    let settings: JobSettings
    private let report: (Double) -> Void
    private let lock = NSLock()
    private var _note: String?
    private var temp: URL?
    /// Set by `redirected(to:)`: results go next to this file instead of next to the input.
    private var fixedDirectory: URL?

    init(inputs: [URL], settings: JobSettings, report: @escaping (Double) -> Void) {
        self.inputs = inputs
        self.settings = settings
        self.report = report
    }

    var input: URL { inputs[0] }

    func progress(_ value: Double) { report(min(max(value, 0), 1)) }

    /// A short result shown in the HUD instead of (or next to) files: a QR payload, a hash, a word count.
    var note: String? {
        get { lock.lock(); defer { lock.unlock() }; return _note }
        set { lock.lock(); _note = newValue; lock.unlock() }
    }

    func directory(for input: URL) -> URL {
        if let fixedDirectory { return fixedDirectory }
        let fm = FileManager.default
        if settings.outputPlace == .folder {
            try? fm.createDirectory(at: settings.outputFolder, withIntermediateDirectories: true)
            return settings.outputFolder
        }
        let dir = input.deletingLastPathComponent()
        if fm.isWritableFile(atPath: dir.path) { return dir }
        return fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// `photo.heic` + `png` -> `photo.png`, or `photo 2.png` if that exists. Never overwrites.
    func destination(for input: URL, ext: String, suffix: String? = nil) -> URL {
        let base = input.deletingPathExtension().lastPathComponent + (suffix.map { " (\($0))" } ?? "")
        return Naming.unique(directory(for: input).appendingPathComponent(base).appendingPathExtension(ext))
    }

    /// A new folder next to the input, for results with many files (pages of a PDF, an extracted archive).
    func folder(for input: URL, name: String? = nil, suffix: String? = nil) throws -> URL {
        let base = name ?? (input.deletingPathExtension().lastPathComponent + (suffix.map { " (\($0))" } ?? ""))
        let url = Naming.unique(directory(for: input).appendingPathComponent(base, isDirectory: true))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Scratch space for this job, removed when the job ends.
    func scratch() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        if let temp { return temp }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Krutilka", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temp = url
        return url
    }

    /// A context for an intermediate file in scratch whose results belong next to `original`.
    func redirected(to original: URL) -> JobContext {
        let copy = JobContext(inputs: inputs, settings: settings, report: report)
        copy.fixedDirectory = directory(for: original)
        copy.temp = try? scratch()
        copy.ownsTemp = false
        return copy
    }

    private var ownsTemp = true

    func cleanUp() {
        guard ownsTemp else { return }
        if let temp { try? FileManager.default.removeItem(at: temp) }
    }
}

enum Naming {
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let full = url.lastPathComponent
        var base = url.deletingPathExtension().lastPathComponent
        var ext = url.pathExtension
        // "photos.tar.gz" -> "photos 2.tar.gz", not "photos.tar 2.gz".
        for double in ["tar.gz", "tar.bz2", "tar.xz"] where full.lowercased().hasSuffix("." + double) {
            ext = String(full.suffix(double.count))
            base = String(full.dropLast(double.count + 1))
        }
        var n = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(n)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Sorted the way Finder sorts names, so "scan 2" comes before "scan 10".
    static func finderOrder(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
