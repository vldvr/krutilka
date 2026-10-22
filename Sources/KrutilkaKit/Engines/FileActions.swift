import AppKit
import CryptoKit
import QuickLookUI

/// The actions wheel: things to do *with* files rather than to them. None of them change the files.
@MainActor
enum FileActions {
    static func airDrop(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            JobCenter.shared.flash(tr("AirDrop isn't available right now."), failed: true)
            return
        }
        service.perform(withItems: urls)
    }

    static func copyPaths(_ urls: [URL]) {
        let text = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        JobCenter.shared.flash(urls.count == 1 ? tr("Path copied") : trf("%d paths copied", urls.count))
    }

    static func copyToClipboard(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        JobCenter.shared.flash(trf("Copied %@. Paste with ⌘V.", filesCount(urls.count)))
    }

    static func openTerminal(_ urls: [URL]) {
        guard let first = urls.first else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
        let folder = isDir.boolValue ? first : first.deletingLastPathComponent()
        let id = Prefs.shared.terminalApp
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Lets the person pick a folder, then copies or moves the files there without overwriting.
    static func transfer(_ urls: [URL], move: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = move ? tr("Move Here") : tr("Copy Here")
        panel.message = move ? trf("Move %@ to…", filesCount(urls.count)) : trf("Copy %@ to…", filesCount(urls.count))
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var done: [URL] = []
        var failure: Error?
        for url in urls {
            let target = Naming.unique(folder.appendingPathComponent(url.lastPathComponent))
            do {
                if move { try FileManager.default.moveItem(at: url, to: target) }
                else { try FileManager.default.copyItem(at: url, to: target) }
                done.append(target)
            } catch { failure = error }
        }
        if let failure { JobCenter.shared.flash(failure.localizedDescription, failed: true) }
        if !done.isEmpty {
            JobCenter.shared.flash(move ? trf("Moved %@", filesCount(done.count)) : trf("Copied %@", filesCount(done.count)), reveal: done)
        }
    }

    static func quickLook(_ urls: [URL]) {
        QuickLooker.shared.show(urls)
    }
}

final class QuickLooker: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLooker()
    private var urls: [URL] = []

    @MainActor func show(_ urls: [URL]) {
        self.urls = urls
        NSApp.activate(ignoringOtherApps: true)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { urls[index] as NSURL }
}

enum Hashing {
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func run(_ inputs: [URL], ctx: JobContext) async throws -> [URL] {
        var lines: [String] = []
        var first = ""
        for (i, url) in inputs.enumerated() {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard !isDir.boolValue else { continue }
            let hash = try sha256(url)
            if first.isEmpty { first = hash }
            lines.append(inputs.count == 1 ? hash : "\(hash)  \(url.lastPathComponent)")
            ctx.progress(Double(i + 1) / Double(inputs.count))
        }
        guard !lines.isEmpty else { throw KError.nothingToDo(tr("Folders have no checksum.")) }
        Clipboard.copy(lines.joined(separator: "\n"))
        let short = "\(first.prefix(12))…\(first.suffix(6))"
        ctx.note = "SHA-256 \(short) \(tr("copied"))"
        return []
    }
}
