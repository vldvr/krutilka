import AppKit

/// Notices file drags in any app and modifier taps during them, without Accessibility permission:
/// global *mouse* monitors are allowed, and the modifier state, the button state and the drag
/// pasteboard can be read by anyone.
@MainActor
final class DragWatcher {
    var onWheel: ((WheelKind, [URL]) -> Void)?
    var onDragEnded: (() -> Void)?
    /// Set while our own windows start a drag (the shelf), so we don't react to ourselves.
    var paused = false

    private var monitors: [Any] = []
    private var timer: Timer?
    private var baseline = 0
    private var files: [URL]?
    private var lastFlags: NSEvent.ModifierFlags = []
    private var openedThisDrag = false

    func start() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Our own panels (shelf, onboarding) are local, so watch those too.
        let localDown = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseDown() }
            return event
        }
        // Catches modifier taps shorter than one poll. Delivered when macOS allows it; polling covers the rest.
        let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(KeyCombo(event.modifierFlags).flags) }
        }
        let localFlags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(KeyCombo(event.modifierFlags).flags) }
            return event
        }
        monitors = [down, dragged, localDown, flags, localFlags].compactMap { $0 }
        DebugLog.write("watcher started, flags monitor: \(flags != nil)")
    }

    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        DebugLog.write("flagsChanged \(flags.rawValue) files=\(files?.count ?? -1)")
        guard timer != nil else { return }
        if files == nil { tick() }
        guard let urls = files, !urls.isEmpty, !flags.subtracting(lastFlags).isEmpty,
              let kind = Prefs.shared.wheel(for: flags) else { lastFlags = flags; return }
        lastFlags = flags
        openedThisDrag = true
        onWheel?(kind, urls)
    }

    private func mouseDown() {
        baseline = NSPasteboard(name: .drag).changeCount
        DebugLog.write("mouseDown baseline=\(baseline)")
        files = nil
        openedThisDrag = false
        lastFlags = KeyCombo(NSEvent.modifierFlags).flags
        timer?.invalidate()
        // 60 Hz only while the button is held; nothing runs between drags.
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 == 1 else { finish(); return }
        guard !paused else { return }
        let pb = NSPasteboard(name: .drag)
        if files == nil, pb.changeCount != baseline {
            let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            files = urls
            DebugLog.write("drag detected, \(urls.count) files, flags=\(lastFlags.rawValue)")
            // Holding the convert key while starting the drag also counts.
            if !urls.isEmpty, Prefs.shared.openOnShiftHeld, let kind = Prefs.shared.wheel(for: lastFlags), kind == .convert {
                openedThisDrag = true
                onWheel?(kind, urls)
            }
        }
        let flags = KeyCombo(NSEvent.modifierFlags).flags
        defer { lastFlags = flags }
        guard flags != lastFlags, let urls = files, !urls.isEmpty else { return }
        // A newly pressed combination opens (or switches) its wheel. Releasing keys does nothing:
        // the wheel stays until the drop, so a tap is enough.
        guard !flags.subtracting(lastFlags).isEmpty, let kind = Prefs.shared.wheel(for: flags) else { return }
        openedThisDrag = true
        DebugLog.write("open wheel \(kind.rawValue) (poll)")
        onWheel?(kind, urls)
    }

    private func finish() {
        DebugLog.write("mouse up, files=\(files?.count ?? -1) opened=\(openedThisDrag)")
        timer?.invalidate()
        timer = nil
        if files != nil || openedThisDrag { onDragEnded?() }
        files = nil
        openedThisDrag = false
    }
}
