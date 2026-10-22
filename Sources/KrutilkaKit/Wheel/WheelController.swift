import AppKit
import SwiftUI

/// Borderless, non-activating, above everything. It can take keyboard focus for the
/// keyboard path without pulling the app forward.
final class WheelPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Receives the drag (and, on the keyboard path, the mouse and keys) for the whole panel.
final class WheelDropView: NSView {
    weak var controller: WheelController?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The SwiftUI view only draws; every event lands here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    private func local(_ sender: NSDraggingInfo) -> CGPoint { convert(sender.draggingLocation, from: nil) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.hover(nil) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let controller, controller.hover(local(sender)) else { return [] }
        let mask = sender.draggingSourceOperationMask
        return mask.contains(.copy) ? .copy : mask.contains(.generic) ? .generic : .every
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return controller?.drop(at: local(sender), urls: urls) ?? false
    }

    // MARK: Keyboard path

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard controller?.model.interactive == true else { return }
        controller?.hover(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard controller?.model.interactive == true else { return }
        controller?.click(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return }
        switch event.keyCode {
        case 53: controller.close()                                   // esc
        case 36, 76: controller.commitHovered()                       // return, enter
        case 48: controller.cycleKind(forward: !event.modifierFlags.contains(.shift)) // tab
        case 123, 126: controller.step(-1)                            // left, up
        case 124, 125: controller.step(1)                             // right, down
        default:
            if let c = event.charactersIgnoringModifiers, let n = Int(c), n >= 1 {
                controller.select(index: n - 1)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

@MainActor
final class WheelController: NSObject, NSWindowDelegate {
    static let shared = WheelController()

    let model = WheelModel()
    private let panel = WheelPanel()
    private let dropView = WheelDropView(frame: .zero)
    private var springTimer: Timer?
    private var springKind: WheelKind?
    private var closeWork: DispatchWorkItem?

    var isOpen: Bool { model.isOpen }
    var panelForSnapshot: NSPanel { panel }

    private override init() {
        super.init()
        dropView.controller = self
        let host = NSHostingView(rootView: WheelView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        dropView.addSubview(host)
        panel.contentView = dropView
        panel.delegate = self
    }

    /// Renders once off-screen at launch so the first real open has nothing left to compile.
    /// (Opening lag was the most specific complaint about the original.)
    func prewarm() {
        model.geometry = WheelGeometry(scale: Prefs.shared.wheelSize.scale)
        let size = model.geometry.size
        panel.setFrame(NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height), display: false)
        dropView.subviews.first?.frame = NSRect(origin: .zero, size: size)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if let sample = Bundle.main.executableURL {
            model.load(files: [sample], kind: .actions)
            model.isOpen = true
        }
        panel.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.model.isOpen = false
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
    }

    // MARK: Open / close

    /// Opens centred on `point` (screen coordinates), kept inside the visible screen.
    func open(kind: WheelKind, files: [URL], at point: NSPoint, interactive: Bool) {
        guard !files.isEmpty else { return }
        closeWork?.cancel()
        model.geometry = WheelGeometry(scale: Prefs.shared.wheelSize.scale)
        model.interactive = interactive
        model.load(files: files, kind: kind)

        let g = model.geometry
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        var frame = NSRect(x: point.x - g.center.x, y: point.y - (g.size.height - g.center.y),
                           width: g.size.width, height: g.size.height)
        if let visible = screen?.visibleFrame {
            // Keep the dial and chips on screen; the empty margin above the outer ring may go under the menu bar.
            let spareTop = g.ring1Outer - g.ring0Outer
            frame.origin.x = min(max(frame.minX, visible.minX - g.margin), visible.maxX - frame.width + g.margin)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height + g.margin + spareTop)
        }
        panel.setFrame(frame, display: false)
        dropView.subviews.first?.frame = NSRect(origin: .zero, size: g.size)
        panel.alphaValue = 1
        if interactive {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(dropView)
        } else {
            panel.orderFrontRegardless()
        }
        model.isOpen = true
    }

    func switchTo(_ kind: WheelKind) {
        guard model.isOpen, kind != model.kind else { return }
        model.show(kind)
    }

    func cycleKind(forward: Bool) {
        let all = WheelKind.allCases.filter { model.available.contains($0) }
        guard let i = all.firstIndex(of: model.kind), all.count > 1 else { return }
        switchTo(all[(i + (forward ? 1 : all.count - 1)) % all.count])
    }

    func close() {
        guard model.isOpen else { return }
        model.isOpen = false
        model.hit = .none
        cancelSpring()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// The button came up somewhere. If it was over the wheel, AppKit delivers the drop a moment
    /// after this; give it time, then close if nothing landed.
    func dragEnded() {
        guard model.isOpen, !model.interactive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.model.isOpen, !self.model.interactive else { return }
            self.close()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if model.interactive { close() }
    }

    // MARK: Pointer

    /// Returns whether the point is over a segment that can take the files.
    @discardableResult
    func hover(_ point: CGPoint?) -> Bool {
        guard let point else { model.setHit(.none); cancelSpring(); return false }
        let chips = WheelKind.allCases.map { model.chipFrames[$0] ?? .zero }
        let hit = model.geometry.hit(point, ring0: model.rings[0].count, ring1: model.rings[1].count, chips: chips)
        model.setHit(hit)
        if case let .chip(kind) = hit {
            springLoad(kind)
            return false
        }
        cancelSpring()
        return model.operation(at: hit)?.enabled == true
    }

    /// Hovering a chip during a drag switches to that wheel after a short pause, so the
    /// other wheels are reachable without knowing the keys.
    private func springLoad(_ kind: WheelKind) {
        guard kind != model.kind, model.available.contains(kind), springKind != kind else { return }
        cancelSpring()
        springKind = kind
        springTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.switchTo(kind)
                self?.springKind = nil
            }
        }
    }

    private func cancelSpring() {
        springTimer?.invalidate()
        springTimer = nil
        springKind = nil
    }

    func drop(at point: CGPoint, urls: [URL]) -> Bool {
        hover(point)
        DebugLog.write("drop at \(point) hit=\(model.hit) urls=\(urls.count)")
        guard let op = model.operation(at: model.hit), op.enabled else { close(); return false }
        let files = urls.isEmpty ? model.files : urls
        close()
        JobCenter.shared.start(op, files: files)
        return true
    }

    func click(at point: CGPoint) {
        let chips = WheelKind.allCases.map { model.chipFrames[$0] ?? .zero }
        let hit = model.geometry.hit(point, ring0: model.rings[0].count, ring1: model.rings[1].count, chips: chips)
        switch hit {
        case .chip(let kind): switchTo(kind)
        case .segment:
            model.setHit(hit)
            commitHovered()
        case .hub, .none: close()
        }
    }

    func commitHovered() {
        guard let op = model.operation(at: model.hit), op.enabled else { return }
        let files = model.files
        close()
        JobCenter.shared.start(op, files: files)
    }

    func step(_ delta: Int) {
        let flat = model.operations
        guard !flat.isEmpty else { return }
        var current = -1
        if case let .segment(ring, index) = model.hit { current = ring == 0 ? index : model.rings[0].count + index }
        let next = current < 0 ? (delta > 0 ? 0 : flat.count - 1) : (current + delta + flat.count) % flat.count
        select(index: next)
    }

    func select(index: Int) {
        let n0 = model.rings[0].count
        if index < n0 { model.setHit(.segment(ring: 0, index: index)) }
        else if index - n0 < model.rings[1].count { model.setHit(.segment(ring: 1, index: index - n0)) }
    }
}
