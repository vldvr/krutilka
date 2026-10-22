import AppKit
import Combine

/// One running or finished job as the HUD shows it.
@MainActor
final class JobRecord: ObservableObject, Identifiable {
    enum State: Equatable { case running, done, failed(String) }

    let id = UUID()
    let title: String
    let detail: String
    let symbol: String?
    let code: String?
    @Published var progress: Double = 0
    @Published var state: State = .running
    @Published var outputs: [URL] = []
    @Published var note: String?
    var task: Task<Void, Never>?
    var finishedAt: Date?

    init(title: String, detail: String, symbol: String?, code: String?) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.code = code
    }

    func cancel() { task?.cancel() }
}

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var title: String
    var detail: String
    var date: Date
    var inputs: [String]
    var outputs: [String]
    var failed: Bool
    var undone = false

    var outputURLs: [URL] { outputs.map { URL(fileURLWithPath: $0) } }
    var canUndo: Bool { !undone && !failed && outputURLs.contains { FileManager.default.fileExists(atPath: $0.path) } }
}

/// Runs operations, reports progress to the HUD, keeps the history for undo.
@MainActor
final class JobCenter: ObservableObject {
    static let shared = JobCenter()

    @Published private(set) var records: [JobRecord] = []
    @Published private(set) var history: [HistoryEntry] = []

    private let historyURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Krutilka", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: historyURL),
           let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = list
        }
    }

    var isBusy: Bool { records.contains { $0.state == .running } }

    // MARK: Start

    func start(_ op: Operation, files: [URL]) {
        if op.batch == .immediate {
            op.perform(files)
            return
        }
        let detail = files.count == 1 ? files[0].lastPathComponent : filesCount(files.count)
        let title: String
        if op.wheel == .convert, op.symbol == nil {
            let codes = Set(files.map { FileKind.code(of: $0) })
            title = codes.count == 1 ? "\(codes.first!) → \(op.title)" : "→ \(op.title)"
        } else {
            title = op.title
        }
        let record = JobRecord(title: title, detail: detail, symbol: op.symbol, code: op.symbol == nil ? op.title : nil)
        records.append(record)
        HUDController.shared.update()

        let settings = JobSettings.snapshot()
        let trashOriginals = Prefs.shared.trashOriginals && op.wheel == .convert
        record.task = Task { [weak self] in
            let started = Date()
            var outputs: [URL] = []
            var errors: [Error] = []
            var notes: [String] = []

            switch op.batch {
            case .all:
                let ctx = JobContext(inputs: files, settings: settings, report: Self.reporter(record, slot: 0, of: 1))
                do { outputs = try await op.run(ctx) } catch { errors.append(error) }
                if let note = ctx.note { notes.append(note) }
                ctx.cleanUp()
            case .each, .immediate:
                let progress = ProgressBox(count: files.count)
                await withTaskGroup(of: (URL, [URL], Error?, String?).self) { group in
                    var next = 0
                    func add(_ i: Int) {
                        let file = files[i]
                        group.addTask {
                            let ctx = JobContext(inputs: [file], settings: settings) { value in
                                let total = progress.set(i, value)
                                Task { @MainActor in record.progress = total }
                            }
                            defer { ctx.cleanUp() }
                            do {
                                let produced = try await op.run(ctx)
                                return (file, produced, nil, ctx.note)
                            } catch {
                                return (file, [], error, ctx.note)
                            }
                        }
                    }
                    // A few at a time: video and LibreOffice are heavy, images are quick anyway.
                    let width = min(3, files.count)
                    while next < width { add(next); next += 1 }
                    for await (file, produced, error, note) in group {
                        outputs += produced
                        if let error { errors.append(error) }
                        if let note { notes.append(note) }
                        if trashOriginals, error == nil, !produced.isEmpty {
                            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
                        }
                        if next < files.count { add(next); next += 1 }
                    }
                }
            }
            self?.finish(record, op: op, files: files, outputs: outputs, errors: errors, notes: notes, started: started)
        }
    }

    nonisolated private static func reporter(_ record: JobRecord, slot: Int, of count: Int) -> (Double) -> Void {
        { value in Task { @MainActor in record.progress = value } }
    }

    private func finish(_ record: JobRecord, op: Operation, files: [URL], outputs: [URL], errors: [Error],
                        notes: [String], started: Date) {
        let cancelled = errors.contains { $0 is CancellationError } || record.task?.isCancelled == true
        record.outputs = outputs
        record.progress = 1
        record.finishedAt = Date()
        if cancelled {
            outputs.forEach { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
            record.state = .failed(tr("Cancelled"))
        } else if let first = errors.first, outputs.isEmpty, notes.isEmpty {
            record.state = .failed(message(for: first))
        } else {
            record.state = .done
            if !errors.isEmpty {
                record.note = trf("%d of %d didn't work: %@", errors.count, files.count, message(for: errors[0]))
            } else if let note = notes.first {
                record.note = notes.count > 1 ? notes.joined(separator: " · ") : note
            } else {
                record.note = outputs.count == 1 ? outputs[0].lastPathComponent : filesCount(outputs.count)
            }
            if Prefs.shared.revealWhenDone, !outputs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            }
        }
        if !cancelled {
            let entry = HistoryEntry(title: record.title, detail: record.detail, date: Date(),
                                     inputs: files.map(\.path), outputs: outputs.map(\.path),
                                     failed: record.state != .done)
            history.insert(entry, at: 0)
            if history.count > 60 { history.removeLast(history.count - 60) }
            saveHistory()
        }
        HUDController.shared.update()
        scheduleDismiss(record)
    }

    private func message(for error: Error) -> String {
        if let k = error as? KError { return k.errorDescription ?? "" }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteNoPermissionError {
            return tr("No permission to write in that folder.")
        }
        return ns.localizedDescription
    }

    // MARK: Messages without a job

    /// A one-line result in the HUD (path copied, nothing selected).
    func flash(_ text: String, failed: Bool = false, reveal: [URL] = []) {
        let record = JobRecord(title: text, detail: "", symbol: failed ? "exclamationmark.circle" : "checkmark", code: nil)
        record.progress = 1
        record.state = failed ? .failed(text) : .done
        record.outputs = reveal
        record.finishedAt = Date()
        records.append(record)
        HUDController.shared.update()
        scheduleDismiss(record, after: failed ? 4 : 2.2)
    }

    // MARK: Dismiss

    var hudHovered = false {
        didSet { if !hudHovered { records.filter { $0.state != .running }.forEach { scheduleDismiss($0, after: 1.5) } } }
    }

    private func scheduleDismiss(_ record: JobRecord, after delay: Double? = nil) {
        let wait = delay ?? (record.state == .done ? 3.5 : 6)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, !self.hudHovered, record.state != .running else { return }
            self.dismiss(record)
        }
    }

    func dismiss(_ record: JobRecord) {
        records.removeAll { $0.id == record.id }
        HUDController.shared.update()
    }

    // MARK: History

    func undo(_ entry: HistoryEntry) {
        guard let i = history.firstIndex(where: { $0.id == entry.id }) else { return }
        for url in entry.outputURLs where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        history[i].undone = true
        saveHistory()
        flash(tr("Moved the result to the Trash"))
    }

    func undoLast() {
        if let entry = history.first(where: \.canUndo) { undo(entry) }
    }

    func reveal(_ entry: HistoryEntry) {
        let existing = entry.outputURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            let inputs = entry.inputs.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            NSWorkspace.shared.activateFileViewerSelecting(inputs)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: historyURL, options: .atomic) }
    }
}

/// Per-file progress for a batch, averaged.
final class ProgressBox: @unchecked Sendable {
    private var values: [Double]
    private let lock = NSLock()
    init(count: Int) { values = Array(repeating: 0, count: count) }
    func set(_ i: Int, _ v: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        values[i] = v
        return values.reduce(0, +) / Double(values.count)
    }
}
