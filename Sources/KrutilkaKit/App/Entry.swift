import AppKit

/// Process entry: the menu bar app, or one of the developer modes (`--op`, `--snap`).
public enum KrutilkaMain {
    @MainActor public static func run() {
        _ = NSApplication.shared
        if Snapshots.requested {
            Snapshots.run()
            NSApplication.shared.run()
        } else if SelfTest.requested {
            NSApplication.shared.setActivationPolicy(.prohibited)
            SelfTest.run()
            NSApplication.shared.run()
        } else {
            let delegate = AppDelegate()
            NSApplication.shared.delegate = delegate
            NSApplication.shared.run()
        }
    }
}
