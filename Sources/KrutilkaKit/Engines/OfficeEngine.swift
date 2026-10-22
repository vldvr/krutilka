import Foundation

/// A FIFO lock for async code. LibreOffice can only run one conversion per profile at a time.
final class AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    func acquire() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if locked { waiters.append(cont); lock.unlock() }
            else { locked = true; lock.unlock(); cont.resume() }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty { locked = false; lock.unlock() }
        else { let next = waiters.removeFirst(); lock.unlock(); next.resume() }
    }
}

/// LibreOffice in headless mode: slides, spreadsheets, Pages / Keynote / Numbers, faithful Word to PDF.
enum OfficeEngine {
    private static let gate = AsyncLock()

    static var available: Bool { ExternalTools.shared.has(.soffice) }

    private static var profile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Krutilka/LibreOffice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Converts into the job's scratch folder and returns the produced file.
    /// `filter` is a LibreOffice target such as `pdf`, `docx`, `csv:Text - txt - csv (StarCalc):44,34,76`.
    static func convert(_ input: URL, filter: String, ext: String, ctx: JobContext) async throws -> URL {
        let soffice = try ExternalTools.shared.require(.soffice)
        let outDir = try ctx.scratch().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        await gate.acquire()
        defer { gate.release() }
        try Task.checkCancellation()
        try await Shell.run(soffice, [
            "--headless", "--norestore", "--nologo", "--nodefault",
            "-env:UserInstallation=\(profile.absoluteString)",
            "--convert-to", filter, "--outdir", outDir.path, input.path,
        ])
        let produced = outDir.appendingPathComponent(input.deletingPathExtension().lastPathComponent).appendingPathExtension(ext)
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw KError.failed(tr("LibreOffice couldn't convert this file."))
        }
        return produced
    }

    /// Converts and moves the result next to the input.
    static func convertBeside(_ input: URL, filter: String, ext: String, ctx: JobContext) async throws -> URL {
        let produced = try await convert(input, filter: filter, ext: ext, ctx: ctx)
        let out = ctx.destination(for: input, ext: ext)
        try FileManager.default.moveItem(at: produced, to: out)
        return out
    }

    static let csvFilter = "csv:Text - txt - csv (StarCalc):44,34,76,1"
}
