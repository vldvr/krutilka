import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    private let watcher = DragWatcher()
    private var hotKey: HotKey?
    private var bag: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        StatusItemController.shared.install()

        watcher.onWheel = { kind, files in
            let wheel = WheelController.shared
            if wheel.isOpen && !wheel.model.interactive {
                wheel.switchTo(kind)
            } else {
                wheel.open(kind: kind, files: files, at: NSEvent.mouseLocation, interactive: false)
            }
        }
        watcher.onDragEnded = { WheelController.shared.dragEnded() }
        watcher.start()
        WheelController.shared.prewarm()

        let prefs = Prefs.shared
        Publishers.CombineLatest(prefs.$hotkeyEnabled, prefs.$hotkeyPreset)
            .sink { [weak self] enabled, preset in self?.registerHotKey(enabled: enabled, preset: preset) }
            .store(in: &bag)

        if !prefs.onboardingDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showOnboarding() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func registerHotKey(enabled: Bool, preset: String) {
        hotKey = nil
        guard enabled else { return }
        hotKey = HotKey(HotKey.Preset.named(preset)) { [weak self] in self?.openForFinderSelection() }
    }

    /// The keyboard path: whatever is selected in Finder, wheel at the pointer.
    func openForFinderSelection() {
        let files = FinderSelection.current()
        guard !files.isEmpty else {
            JobCenter.shared.flash(tr("Select files in Finder first."), failed: true)
            return
        }
        WheelController.shared.open(kind: .convert, files: files, at: NSEvent.mouseLocation, interactive: true)
    }

    @objc func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = tr("Open Wheel")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        WheelController.shared.open(kind: .convert, files: panel.urls, at: NSPoint(x: screen.midX, y: screen.midY), interactive: true)
    }

    @objc func showSettings() { SettingsWindowController.shared.show() }
    @objc func showOnboarding() { OnboardingWindowController.shared.show() }
}
