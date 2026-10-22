import AppKit
import SwiftUI

/// Renders the app's own surfaces to PNG for design review, no screen recording needed:
///   Krutilka --snap wheel out.png <convert|tools|actions> <hit index or -1> <glass|solid> <light|dark> files…
///   Krutilka --snap <menu|hud|settings|onboarding> out.png <light|dark>
enum Snapshots {
    static var requested: Bool { CommandLine.arguments.contains("--snap") }
    @MainActor private static var beforeExit: () -> Void = {}

    @MainActor static func run() {
        let args = Array(CommandLine.arguments.drop { $0 != "--snap" }.dropFirst())
        guard args.count >= 3 else { print("usage: see Snapshots.swift"); exit(64) }
        let what = args[0], out = URL(fileURLWithPath: args[1])
        NSApp.setActivationPolicy(.accessory)
        switch what {
        case "wheel":
            let kind = WheelKind(rawValue: args[2]) ?? .convert
            let hit = Int(args[3]) ?? -1
            // Show the requested style, then put the person's setting back before exiting.
            let previous = Prefs.shared.wheelStyle
            Prefs.shared.wheelStyle = WheelStyle(rawValue: args[4]) ?? .glass
            beforeExit = { Prefs.shared.wheelStyle = previous }
            NSApp.appearance = NSAppearance(named: args[5] == "dark" ? .darkAqua : .aqua)
            let files = args[6...].map { URL(fileURLWithPath: $0) }
            let wheel = WheelController.shared
            let screen = NSScreen.main!.visibleFrame
            wheel.open(kind: kind, files: files, at: NSPoint(x: screen.midX, y: screen.midY), interactive: false)
            if hit >= 0 { wheel.select(index: hit) }
            capture(after: 0.9, out: out) { wheel.panelForSnapshot.contentView }
        case "editor":
            NSApp.appearance = NSAppearance(named: args[2] == "dark" ? .darkAqua : .aqua)
            let url = URL(fileURLWithPath: args[3])
            Task { @MainActor in
                guard let image = try? await ImageEngine.load(url) else { exit(1) }
                let model = PhotoEditModel(url: url, image: image)
                let w = CGFloat(image.width), h = CGFloat(image.height)
                model.commitRect(CGRect(x: w * 0.02, y: h * 0.22, width: w * 0.62, height: h * 0.2))
                model.hideStyle = .black
                model.commitRect(CGRect(x: w * 0.55, y: h * 0.55, width: w * 0.3, height: h * 0.15))
                model.commitArrow(from: CGPoint(x: w * 0.45, y: h * 0.92), to: CGPoint(x: w * 0.53, y: h * 0.72))
                model.typingAt = CGPoint(x: w * 0.06, y: h * 0.78)
                model.commitNote("Скрыто")
                model.mode = .arrow
                let view = NSHostingView(rootView: PhotoEditorView(model: model) {})
                let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 820, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = view
                window.orderFrontRegardless()
                capture(after: 0.6, out: out) { view }
            }
        case "menu", "hud", "settings", "onboarding":
            NSApp.appearance = NSAppearance(named: args[2] == "dark" ? .darkAqua : .aqua)
            let view: NSView
            switch what {
            case "menu": view = NSHostingView(rootView: MenuView(center: JobCenter.shared, close: {}))
            case "settings": view = NSHostingView(rootView: SettingsView())
            case "onboarding": view = NSHostingView(rootView: OnboardingView(close: {}))
            default:
                let a = JobRecord(title: "HEIC → PNG", detail: "IMG_2041.HEIC", symbol: nil, code: "PNG")
                a.progress = 0.62
                let b = JobRecord(title: tr("Remove background"), detail: "portrait.jpg", symbol: "person.crop.rectangle", code: nil)
                b.state = .done; b.note = "portrait (no background).png"; b.outputs = [URL(fileURLWithPath: "/tmp/x")]
                let c = JobRecord(title: "DOCX → PDF", detail: "report.docx", symbol: nil, code: "PDF")
                c.state = .failed(tr("LibreOffice couldn't convert this file."))
                view = NSHostingView(rootView: VStack(spacing: 8) { HUDRow(record: a); HUDRow(record: b); HUDRow(record: c) }
                    .padding(14).frame(width: 330))
            }
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = view
            window.setContentSize(view.fittingSize)
            window.orderFrontRegardless()
            capture(after: 0.8, out: out) { view }
        default:
            exit(64)
        }
    }

    @MainActor private static func capture(after delay: Double, out: URL, _ view: @escaping () -> NSView?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let view = view() else { exit(1) }
            let size = view.bounds.size, scale: CGFloat = 2
            func bitmap() -> NSBitmapImageRep {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size
                return rep
            }
            let content = bitmap()
            view.cacheDisplay(in: view.bounds, to: content)
            // A quiet backdrop, so translucency and contrast can be judged.
            let canvas = bitmap()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            NSGradient(colors: dark ? [NSColor(hex: 0x1C2328), NSColor(hex: 0x26323A)] : [NSColor(hex: 0xEEF2F1), NSColor(hex: 0xDCE6E3)])!
                .draw(in: NSRect(origin: .zero, size: size), angle: -60)
            content.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            guard let png = canvas.representation(using: .png, properties: [:]) else { exit(1) }
            try? png.write(to: out)
            print("wrote \(out.path)")
            beforeExit()
            exit(0)
        }
    }
}
