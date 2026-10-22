import AppKit
import Combine

/// The three wheels. Each one opens on its own modifier key during a drag.
enum WheelKind: String, CaseIterable, Codable, Identifiable {
    case convert, tools, actions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: return tr("Formats")
        case .tools: return tr("Tools")
        case .actions: return tr("Actions")
        }
    }
}

enum OutputPlace: String, CaseIterable, Identifiable {
    case besideOriginal, folder
    var id: String { rawValue }
}

enum WheelStyle: String, CaseIterable, Identifiable {
    case glass, solid
    var id: String { rawValue }
}

enum WheelSize: String, CaseIterable, Identifiable {
    case compact, regular, large
    var id: String { rawValue }
    var scale: CGFloat {
        switch self {
        case .compact: return 0.86
        case .regular: return 1
        case .large: return 1.16
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case patina, system
    var id: String { rawValue }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case p720, p1080, original
    var id: String { rawValue }
}

/// Modifier keys we let people bind. Stored as the raw value of `NSEvent.ModifierFlags`.
struct KeyCombo: Equatable {
    static let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    var flags: NSEvent.ModifierFlags

    init(_ flags: NSEvent.ModifierFlags) { self.flags = flags.intersection(KeyCombo.relevant) }
    init(raw: UInt) { self.init(NSEvent.ModifierFlags(rawValue: raw)) }
    var raw: UInt { flags.rawValue }

    var glyphs: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    static let choices: [KeyCombo] = [
        KeyCombo(.shift), KeyCombo(.option), KeyCombo(.control), KeyCombo(.command),
        KeyCombo([.shift, .option]), KeyCombo([.shift, .control]), KeyCombo([.control, .option]),
    ]
}

/// User settings, persisted in UserDefaults. One shared instance, observed by SwiftUI.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var convertKey: UInt { didSet { d.set(convertKey, forKey: "convertKey") } }
    @Published var toolsKey: UInt { didSet { d.set(toolsKey, forKey: "toolsKey") } }
    @Published var actionsKey: UInt { didSet { d.set(actionsKey, forKey: "actionsKey") } }
    @Published var openOnShiftHeld: Bool { didSet { d.set(openOnShiftHeld, forKey: "openOnShiftHeld") } }

    @Published var outputPlace: OutputPlace { didSet { d.set(outputPlace.rawValue, forKey: "outputPlace") } }
    @Published var outputFolder: String { didSet { d.set(outputFolder, forKey: "outputFolder") } }
    @Published var revealWhenDone: Bool { didSet { d.set(revealWhenDone, forKey: "revealWhenDone") } }
    @Published var trashOriginals: Bool { didSet { d.set(trashOriginals, forKey: "trashOriginals") } }

    @Published var imageQuality: Double { didSet { d.set(imageQuality, forKey: "imageQuality") } }
    @Published var compressQuality: Double { didSet { d.set(compressQuality, forKey: "compressQuality") } }
    @Published var targetSizeMB: Double { didSet { d.set(targetSizeMB, forKey: "targetSizeMB") } }
    @Published var pdfDPI: Int { didSet { d.set(pdfDPI, forKey: "pdfDPI") } }
    @Published var videoQuality: VideoQuality { didSet { d.set(videoQuality.rawValue, forKey: "videoQuality") } }
    @Published var audioBitrate: Int { didSet { d.set(audioBitrate, forKey: "audioBitrate") } }

    @Published var wheelStyle: WheelStyle { didSet { d.set(wheelStyle.rawValue, forKey: "wheelStyle") } }
    @Published var wheelSize: WheelSize { didSet { d.set(wheelSize.rawValue, forKey: "wheelSize") } }
    @Published var accent: AccentChoice { didSet { d.set(accent.rawValue, forKey: "accent") } }
    @Published var showHints: Bool { didSet { d.set(showHints, forKey: "showHints") } }

    @Published var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    @Published var hotkeyPreset: String { didSet { d.set(hotkeyPreset, forKey: "hotkeyPreset") } }
    @Published var terminalApp: String { didSet { d.set(terminalApp, forKey: "terminalApp") } }
    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    @Published var recipes: [Recipe] { didSet { saveRecipes() } }

    private init() {
        d.register(defaults: [
            "convertKey": NSEvent.ModifierFlags.shift.rawValue,
            "toolsKey": NSEvent.ModifierFlags.option.rawValue,
            "actionsKey": NSEvent.ModifierFlags.control.rawValue,
            "openOnShiftHeld": true,
            "outputPlace": OutputPlace.besideOriginal.rawValue,
            "outputFolder": FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory(),
            "revealWhenDone": true,
            "trashOriginals": false,
            "imageQuality": 0.88,
            "compressQuality": 0.72,
            "targetSizeMB": 1.0,
            "pdfDPI": 200,
            "videoQuality": VideoQuality.p1080.rawValue,
            "audioBitrate": 192,
            "wheelStyle": WheelStyle.glass.rawValue,
            "wheelSize": WheelSize.regular.rawValue,
            "accent": AccentChoice.patina.rawValue,
            "showHints": true,
            "hotkeyEnabled": true,
            "hotkeyPreset": "optCmdK",
            "terminalApp": "com.apple.Terminal",
            "onboardingDone": false,
        ])
        convertKey = UInt(d.integer(forKey: "convertKey"))
        toolsKey = UInt(d.integer(forKey: "toolsKey"))
        actionsKey = UInt(d.integer(forKey: "actionsKey"))
        openOnShiftHeld = d.bool(forKey: "openOnShiftHeld")
        outputPlace = OutputPlace(rawValue: d.string(forKey: "outputPlace") ?? "") ?? .besideOriginal
        outputFolder = d.string(forKey: "outputFolder") ?? NSHomeDirectory()
        revealWhenDone = d.bool(forKey: "revealWhenDone")
        trashOriginals = d.bool(forKey: "trashOriginals")
        imageQuality = d.double(forKey: "imageQuality")
        compressQuality = d.double(forKey: "compressQuality")
        targetSizeMB = d.double(forKey: "targetSizeMB")
        pdfDPI = d.integer(forKey: "pdfDPI")
        videoQuality = VideoQuality(rawValue: d.string(forKey: "videoQuality") ?? "") ?? .p1080
        audioBitrate = d.integer(forKey: "audioBitrate")
        wheelStyle = WheelStyle(rawValue: d.string(forKey: "wheelStyle") ?? "") ?? .glass
        wheelSize = WheelSize(rawValue: d.string(forKey: "wheelSize") ?? "") ?? .regular
        accent = AccentChoice(rawValue: d.string(forKey: "accent") ?? "") ?? .patina
        showHints = d.bool(forKey: "showHints")
        hotkeyEnabled = d.bool(forKey: "hotkeyEnabled")
        hotkeyPreset = d.string(forKey: "hotkeyPreset") ?? "optCmdK"
        terminalApp = d.string(forKey: "terminalApp") ?? "com.apple.Terminal"
        onboardingDone = d.bool(forKey: "onboardingDone")
        if let data = d.data(forKey: "recipes"), let list = try? JSONDecoder().decode([Recipe].self, from: data) {
            recipes = list
        } else {
            recipes = Recipe.defaults
        }
    }

    private func saveRecipes() {
        if let data = try? JSONEncoder().encode(recipes) { d.set(data, forKey: "recipes") }
    }

    func key(for kind: WheelKind) -> KeyCombo {
        switch kind {
        case .convert: return KeyCombo(raw: convertKey)
        case .tools: return KeyCombo(raw: toolsKey)
        case .actions: return KeyCombo(raw: actionsKey)
        }
    }

    func setKey(_ combo: KeyCombo, for kind: WheelKind) {
        switch kind {
        case .convert: convertKey = combo.raw
        case .tools: toolsKey = combo.raw
        case .actions: actionsKey = combo.raw
        }
    }

    /// Which wheel a set of held modifiers asks for. Exact match, so ⇧⌥ never opens the ⇧ wheel.
    func wheel(for flags: NSEvent.ModifierFlags) -> WheelKind? {
        let combo = KeyCombo(flags)
        guard !combo.flags.isEmpty else { return nil }
        return WheelKind.allCases.first { key(for: $0) == combo }
    }
}
