import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's RegisterEventHotKey, which needs no permission.
final class HotKey {
    struct Preset: Identifiable, Equatable {
        let id: String
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String

        static let all: [Preset] = [
            Preset(id: "optCmdK", keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey | cmdKey), label: "⌥⌘K"),
            Preset(id: "ctrlOptK", keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥K"),
            Preset(id: "shiftCmdK", keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(shiftKey | cmdKey), label: "⇧⌘K"),
            Preset(id: "ctrlOptSpace", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey | cmdKey), label: "⌃⌥⌘Space"),
        ]

        static func named(_ id: String) -> Preset { all.first { $0.id == id } ?? all[0] }
    }

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(_ preset: Preset, handler: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B52544C), id: id) // 'KRTL'
        let status = RegisterEventHotKey(preset.keyCode, preset.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        Self.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Asks Finder for its selection over Apple Events. The first time, macOS asks the person
/// whether Krutilka may control Finder.
enum FinderSelection {
    static func current() -> [URL] {
        let source = """
        tell application "Finder"
            set out to {}
            repeat with i in (get selection)
                set end of out to POSIX path of (i as alias)
            end repeat
            return out
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { i in
            result.atIndex(i)?.stringValue.map { URL(fileURLWithPath: $0) }
        }
    }
}
