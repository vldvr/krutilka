import AppKit
import SwiftUI

/// The menu bar icon: click for recent results, drop files on it to open the wheel.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    static let shared = StatusItemController()

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var catcher: StatusCatcher?

    func install() {
        guard let button = item.button else { return }
        button.image = Glyphs.menuBar()
        button.setAccessibilityLabel("Krutilka")
        let catcher = StatusCatcher(frame: button.bounds)
        catcher.autoresizingMask = [.width, .height]
        catcher.owner = self
        button.addSubview(catcher)
        self.catcher = catcher

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuView(center: JobCenter.shared, close: { [weak self] in
            self?.popover.performClose(nil)
        }))
    }

    func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            button.highlight(true)
        }
    }

    func popoverDidClose(_ notification: Notification) { item.button?.highlight(false) }

    func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: tr("Choose Files…"), action: #selector(AppDelegate.chooseFiles), keyEquivalent: "")
        menu.addItem(withTitle: tr("How It Works"), action: #selector(AppDelegate.showOnboarding), keyEquivalent: "")
        menu.addItem(withTitle: tr("Settings…"), action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Quit Krutilka"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// Files dragged onto the icon: open the wheel just below it so the drag can carry on into it.
    func dragEntered(_ files: [URL]) {
        guard let button = item.button, let window = button.window else { return }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let g = WheelGeometry(scale: Prefs.shared.wheelSize.scale)
        let point = NSPoint(x: frame.midX, y: frame.minY - g.dialRadius - 8)
        WheelController.shared.open(kind: .convert, files: files, at: point, interactive: false)
    }
}

/// Sits on top of the status button: forwards clicks, accepts file drags.
final class StatusCatcher: NSView {
    weak var owner: StatusItemController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { owner?.toggle() }
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { owner?.showMenu() }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return [] }
        MainActor.assumeIsolated {
            if !WheelController.shared.isOpen { owner?.dragEntered(urls) }
        }
        return []
    }
}

/// Drawn marks, so nothing is borrowed: a knob with a pointer and tick marks.
enum Glyphs {
    static func menuBar() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 5.6, y: c.y - 5.6, width: 11.2, height: 11.2))
            ring.lineWidth = 1.6
            ring.stroke()
            let pointer = NSBezierPath()
            pointer.move(to: c)
            pointer.line(to: CGPoint(x: c.x + 3.4, y: c.y + 3.4))
            pointer.lineWidth = 1.8
            pointer.lineCapStyle = .round
            pointer.stroke()
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                let r0 = 7.4, r1 = 8.6
                let tick = NSBezierPath()
                tick.move(to: CGPoint(x: c.x + r0 * sin(a), y: c.y + r0 * cos(a)))
                tick.line(to: CGPoint(x: c.x + r1 * sin(a), y: c.y + r1 * cos(a)))
                tick.lineWidth = i == 1 ? 1.6 : 1
                tick.lineCapStyle = .round
                tick.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct MenuView: View {
    @ObservedObject var center: JobCenter
    @ObservedObject var prefs = Prefs.shared
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Krutilka").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { close(); AppDelegate.shared?.showSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help(Text("Settings"))
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            keys
                .padding(.horizontal, 16).padding(.bottom, 12)

            Divider().padding(.horizontal, 12)

            recent
                .padding(.vertical, 8)

            Divider().padding(.horizontal, 12)

            HStack(spacing: 14) {
                Button("Choose Files…") { close(); AppDelegate.shared?.chooseFiles() }
                if center.history.contains(where: \.canUndo) {
                    Button("Undo Last") { center.undoLast() }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .padding(.horizontal, 16).padding(.vertical, 11)
        }
        .frame(width: 320)
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drag a file, then tap:")
                .font(.system(size: 11.5))
                .foregroundStyle(Color(nsColor: Theme.textMuted))
            HStack(spacing: 6) {
                ForEach(WheelKind.allCases) { kind in
                    HStack(spacing: 4) {
                        Text(prefs.key(for: kind).glyphs).font(.system(size: 12, weight: .semibold))
                        Text(kind.title).font(.system(size: 11.5))
                    }
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
            if prefs.hotkeyEnabled {
                Text(trf("Or select files in Finder and press %@.", HotKey.Preset.named(prefs.hotkeyPreset).label))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.textMuted))
            }
        }
    }

    @ViewBuilder
    private var recent: some View {
        if center.history.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing converted yet").font(.system(size: 12, weight: .medium))
                Text("Results show up here, with a way to undo them.")
                    .font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.textMuted))
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        } else {
            VStack(spacing: 0) {
                ForEach(center.history.prefix(6)) { entry in
                    HistoryRow(entry: entry, center: center)
                }
            }
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    @ObservedObject var center: JobCenter
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.failed ? "exclamationmark.circle" : entry.undone ? "arrow.uturn.backward.circle" : "checkmark.circle")
                .foregroundStyle(entry.failed ? Color(nsColor: Theme.danger) : entry.undone ? Color(nsColor: Theme.textMuted) : Theme.mark)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .strikethrough(entry.undone)
                Text(entry.detail).font(.system(size: 10.5)).foregroundStyle(Color(nsColor: Theme.textMuted))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if hovering {
                if entry.canUndo {
                    Button { center.undo(entry) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless).help(Text("Undo: move the result to the Trash"))
                }
                Button { center.reveal(entry) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help(Text("Show in Finder"))
            } else {
                Text(entry.date, style: .relative)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Color(nsColor: Theme.textMuted))
                    .lineLimit(1)
                    .frame(maxWidth: 70, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.primary.opacity(hovering ? 0.05 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { center.reveal(entry) }
    }
}
