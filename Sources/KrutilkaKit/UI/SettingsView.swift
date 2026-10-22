import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = tr("Krutilka Settings")
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }
            WheelPane().tabItem { Label("Wheel", systemImage: "dial.medium") }
            QualityPane().tabItem { Label("Quality", systemImage: "slider.horizontal.3") }
            RecipesPane().tabItem { Label("Recipes", systemImage: "wand.and.stars") }
            EnginesPane().tabItem { Label("Engines", systemImage: "shippingbox") }
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: General

struct GeneralPane: View {
    @ObservedObject var prefs = Prefs.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var terminals: [(id: String, name: String)] {
        ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
         "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty"].compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return (id, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
    }

    var body: some View {
        Form {
            Section("Results") {
                Picker("Save results", selection: $prefs.outputPlace) {
                    Text("Next to the original").tag(OutputPlace.besideOriginal)
                    Text("In a folder").tag(OutputPlace.folder)
                }
                if prefs.outputPlace == .folder {
                    HStack {
                        Text(prefs.outputFolder).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(Color(nsColor: Theme.textMuted))
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Show the result in Finder", isOn: $prefs.revealWhenDone)
                Toggle("Move originals to the Trash after converting", isOn: $prefs.trashOriginals)
                if prefs.trashOriginals {
                    Text("Only after a conversion succeeds. Tools and actions never touch the original.")
                        .font(.caption).foregroundStyle(Color(nsColor: Theme.textMuted))
                }
            }
            Section("Keyboard") {
                Toggle("Shortcut for files selected in Finder", isOn: $prefs.hotkeyEnabled)
                if prefs.hotkeyEnabled {
                    Picker("Shortcut", selection: $prefs.hotkeyPreset) {
                        ForEach(HotKey.Preset.all) { Text($0.label).tag($0.id) }
                    }
                    Text("Arrows pick a segment, Return applies it, Tab switches the wheel, Esc closes.")
                        .font(.caption).foregroundStyle(Color(nsColor: Theme.textMuted))
                }
            }
            Section("System") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { setLogin($0) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(Color(nsColor: Theme.danger))
                }
                Picker("Terminal for the actions wheel", selection: $prefs.terminalApp) {
                    ForEach(terminals, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Link("github.com/vldvr/krutilka", destination: URL(string: "https://github.com/vldvr/krutilka")!)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { prefs.outputFolder = url.path }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: Wheel

struct WheelPane: View {
    @ObservedObject var prefs = Prefs.shared

    private var duplicate: Bool {
        Set(WheelKind.allCases.map { prefs.key(for: $0).raw }).count < WheelKind.allCases.count
    }

    var body: some View {
        Form {
            Section {
                ForEach(WheelKind.allCases) { kind in
                    Picker(kind.title, selection: Binding(get: { prefs.key(for: kind).raw },
                                                          set: { prefs.setKey(KeyCombo(raw: $0), for: kind) })) {
                        ForEach(KeyCombo.choices, id: \.raw) { Text($0.glyphs).tag($0.raw) }
                    }
                }
                if duplicate {
                    Text("Two wheels share a key. Each wheel needs its own.")
                        .font(.caption).foregroundStyle(Color(nsColor: Theme.danger))
                }
                Toggle("Open the formats wheel when the drag starts with its key held", isOn: $prefs.openOnShiftHeld)
            } header: {
                Text("Keys")
            } footer: {
                Text("Tap the key while dragging. The wheel stays open until you drop, so there's no need to hold it.")
                    .font(.caption).foregroundStyle(Color(nsColor: Theme.textMuted))
            }
            Section("Look") {
                Picker("Style", selection: $prefs.wheelStyle) {
                    Text("Glass").tag(WheelStyle.glass)
                    Text("Solid").tag(WheelStyle.solid)
                }
                .pickerStyle(.segmented)
                Picker("Size", selection: $prefs.wheelSize) {
                    Text("Compact").tag(WheelSize.compact)
                    Text("Regular").tag(WheelSize.regular)
                    Text("Large").tag(WheelSize.large)
                }
                .pickerStyle(.segmented)
                Picker("Accent", selection: $prefs.accent) {
                    Text("Patina").tag(AccentChoice.patina)
                    Text("System accent").tag(AccentChoice.system)
                }
                .pickerStyle(.segmented)
                Toggle("Explain the highlighted option in the centre", isOn: $prefs.showHints)
            }
            Section {
                Button("Try the wheel") { AppDelegate.shared?.showOnboarding() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Quality

struct QualityPane: View {
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        Form {
            Section("Pictures") {
                LabeledContent("Converting") {
                    HStack {
                        Slider(value: $prefs.imageQuality, in: 0.5...1, step: 0.01)
                        Text("\(Int(prefs.imageQuality * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("Compressing") {
                    HStack {
                        Slider(value: $prefs.compressQuality, in: 0.3...0.95, step: 0.01)
                        Text("\(Int(prefs.compressQuality * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Picker("Size limit for “Under…”", selection: $prefs.targetSizeMB) {
                    ForEach([0.2, 0.5, 1.0, 2.0, 5.0, 10.0], id: \.self) { Text(Catalog.sizeLabel($0)).tag($0) }
                }
            }
            Section("PDF") {
                Picker("Page pictures", selection: $prefs.pdfDPI) {
                    Text("150 dpi").tag(150)
                    Text("200 dpi").tag(200)
                    Text("300 dpi").tag(300)
                }
            }
            Section("Video and sound") {
                Picker("Compressing video", selection: $prefs.videoQuality) {
                    Text("720p").tag(VideoQuality.p720)
                    Text("1080p").tag(VideoQuality.p1080)
                    Text("Same size, HEVC").tag(VideoQuality.original)
                }
                Picker("Audio bitrate", selection: $prefs.audioBitrate) {
                    ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Recipes

struct RecipesPane: View {
    @ObservedObject var prefs = Prefs.shared
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recipes appear on the tools wheel. One drop applies the whole set.")
                .font(.system(size: 12)).foregroundStyle(Color(nsColor: Theme.textMuted))
                .padding(.horizontal, 20).padding(.top, 16)
            HStack(alignment: .top, spacing: 0) {
                List(selection: $selection) {
                    ForEach(prefs.recipes) { recipe in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recipe.name).font(.system(size: 12.5, weight: .medium))
                            Text(recipe.summary).font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.textMuted))
                        }
                        .opacity(recipe.enabled ? 1 : 0.45)
                        .tag(recipe.id)
                    }
                }
                .frame(width: 210)
                Divider()
                if let index = prefs.recipes.firstIndex(where: { $0.id == selection }) {
                    RecipeEditor(recipe: $prefs.recipes[index])
                } else {
                    Text("Pick a recipe to edit it")
                        .foregroundStyle(Color(nsColor: Theme.textMuted))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            HStack {
                Button { add() } label: { Label("New Recipe", systemImage: "plus") }
                Button { remove() } label: { Label("Delete", systemImage: "minus") }
                    .disabled(selection == nil)
                Spacer()
                Button("Restore Defaults") { prefs.recipes = Recipe.defaults; selection = nil }
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
    }

    private func add() {
        let recipe = Recipe(name: tr("New recipe"), kind: .image, format: "jpeg", maxSide: 2048, quality: 0.8, stripMetadata: true)
        prefs.recipes.append(recipe)
        selection = recipe.id
    }

    private func remove() {
        prefs.recipes.removeAll { $0.id == selection }
        selection = nil
    }
}

struct RecipeEditor: View {
    @Binding var recipe: Recipe

    var body: some View {
        Form {
            TextField("Name", text: $recipe.name)
            Picker("For", selection: $recipe.kind) {
                Text("Pictures").tag(Recipe.Kind.image)
                Text("Video").tag(Recipe.Kind.video)
            }
            .onChange(of: recipe.kind) { kind in recipe.format = kind == .image ? "jpeg" : "mp4" }
            if recipe.kind == .image {
                Picker("Format", selection: $recipe.format) {
                    ForEach(["jpeg", "png", "heic", "webp", "avif"], id: \.self) { f in
                        Text(f == "jpeg" ? "JPG" : f.uppercased()).tag(f)
                    }
                }
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: $recipe.quality, in: 0.3...1, step: 0.01)
                        Text("\(Int(recipe.quality * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                }
            }
            Picker("Longest side", selection: $recipe.maxSide) {
                Text("Keep").tag(0)
                ForEach([640, 1080, 1280, 1600, 1920, 2048, 2560, 3840], id: \.self) { Text("\($0) px").tag($0) }
            }
            Toggle("Remove metadata", isOn: $recipe.stripMetadata)
            Toggle("Show on the wheel", isOn: $recipe.enabled)
        }
        .formStyle(.grouped)
    }
}

// MARK: Engines

struct EnginesPane: View {
    @State private var refreshed = 0

    var body: some View {
        Form {
            Section {
                LabeledContent("Built in") {
                    Text("Images, PDF, Word, RTF, HTML, AAC, FLAC, Opus, MP4, MOV, ZIP, Live Text")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(Color(nsColor: Theme.textMuted))
                }
            } footer: {
                Text("Everything runs on this Mac. Files are never uploaded.")
                    .font(.caption).foregroundStyle(Color(nsColor: Theme.textMuted))
            }
            Section("Optional helpers") {
                ForEach(ExternalTools.Tool.allCases) { tool in
                    let url = ExternalTools.shared.url(tool)
                    HStack(alignment: .top) {
                        Image(systemName: url == nil ? "circle.dashed" : "checkmark.circle.fill")
                            .foregroundStyle(url == nil ? Color(nsColor: Theme.textMuted) : Theme.mark)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.rawValue).font(.system(size: 12.5, weight: .semibold))
                            Text(tool.purpose).font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.textMuted))
                        }
                        Spacer()
                        if url == nil {
                            Button("Copy Install Command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("brew install \(tool.brewFormula)", forType: .string)
                            }
                            .controlSize(.small)
                        } else {
                            Text(url!.deletingLastPathComponent().path)
                                .font(.system(size: 10.5)).foregroundStyle(Color(nsColor: Theme.textMuted))
                        }
                    }
                }
                .id(refreshed)
                Button("Check Again") { ExternalTools.shared.refresh(); refreshed += 1 }
            }
        }
        .formStyle(.grouped)
    }
}
