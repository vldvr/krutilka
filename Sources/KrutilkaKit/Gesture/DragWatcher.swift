import AppKit

/// A recognized key press can arrive before the drag pasteboard supplies the files.
struct DragModifiers {
    private var lastFlags: NSEvent.ModifierFlags
    private var pendingWheel: WheelKind?

    init(initialFlags: NSEvent.ModifierFlags, heldWheel: WheelKind? = nil) {
        lastFlags = initialFlags
        pendingWheel = heldWheel
    }

    mutating func observe(_ flags: NSEvent.ModifierFlags, wheelFor: (NSEvent.ModifierFlags) -> WheelKind?) {
        defer { lastFlags = flags }
        if !flags.subtracting(lastFlags).isEmpty, let wheel = wheelFor(flags) {
            pendingWheel = wheel
        }
    }

    mutating func takeWheel() -> WheelKind? {
        defer { pendingWheel = nil }
        return pendingWheel
    }
}

/// Notices file drags and modifier taps without Accessibility permission. When global
/// modifier events are unavailable, the timer samples the current modifier state.
@MainActor
final class DragWatcher {
    var onWheel: ((WheelKind, [URL]) -> Void)?
    var onDragEnded: (() -> Void)?

    private var monitors: [Any] = []
    private var timer: Timer?
    private let pasteboard = NSPasteboard(name: .drag)
    // Sample between drags. A delayed mouse-down callback can already see the new file URLs.
    private var idleChangeCount = 0
    private var files: [URL]?
    private var modifiers: DragModifiers?

    func start() {
        idleChangeCount = pasteboard.changeCount
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mouse = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseEvent(event) }
        }
        let localMouse = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseEvent(event) }
            return event
        }
        let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.update(flags: event.modifierFlags) }
        }
        let localFlags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.update(flags: event.modifierFlags) }
            return event
        }
        monitors = [mouse, localMouse, flags, localFlags].compactMap { $0 }
        DebugLog.write("watcher started, mouse monitor: \(mouse != nil), flags monitor: \(flags != nil)")
    }

    private func mouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if modifiers != nil { finish() }
            let flags = KeyCombo(event.modifierFlags).flags
            let prefs = Prefs.shared
            let heldWheel: WheelKind? = prefs.openOnShiftHeld && prefs.wheel(for: flags) == .convert ? .convert : nil
            begin(DragModifiers(initialFlags: flags, heldWheel: heldWheel))
        case .leftMouseDragged:
            guard NSEvent.pressedMouseButtons & 1 == 1 else { return }
            if modifiers == nil {
                // A native drag may already own the pasteboard when we first see it.
                begin(DragModifiers(initialFlags: []))
            }
            update(flags: NSEvent.modifierFlags)
        case .leftMouseUp:
            finish()
        default:
            break
        }
    }

    private func begin(_ modifiers: DragModifiers) {
        self.modifiers = modifiers
        DebugLog.write("watching mouse press, pasteboard baseline=\(idleChangeCount)")
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(flags: NSEvent.modifierFlags) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func update(flags: NSEvent.ModifierFlags) {
        guard modifiers != nil else { return }
        guard NSEvent.pressedMouseButtons & 1 == 1 else { finish(); return }
        modifiers?.observe(KeyCombo(flags).flags, wheelFor: Prefs.shared.wheel(for:))

        if files == nil, pasteboard.changeCount != idleChangeCount {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            // The source can clear the pasteboard before it publishes its URLs.
            if !urls.isEmpty {
                files = urls
                DebugLog.write("drag detected, \(urls.count) files")
            }
        }
        guard let files, let kind = modifiers?.takeWheel() else { return }
        DebugLog.write("open wheel \(kind.rawValue)")
        onWheel?(kind, files)
    }

    private func finish() {
        idleChangeCount = pasteboard.changeCount
        timer?.invalidate()
        timer = nil
        modifiers = nil
        let hadFiles = files != nil
        files = nil
        if hadFiles { onDragEnded?() }
    }
}
