import AppKit
import SwiftUI

/// One screen: the keys on the right, a real file to practise on at the left.
/// A tour of slides was the original's answer; a working sandbox teaches faster.
@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: OnboardingView(close: { [weak w] in
                Prefs.shared.onboardingDone = true
                w?.close()
            }))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum PracticeFile {
    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Krutilka/Practice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A picture drawn here, so the practice file is ours and always exists.
    static func make() -> URL {
        let url = folder.appendingPathComponent(tr("Practice picture")).appendingPathExtension("png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let size = 900
        guard let ctx = CGContext(data: nil, width: size, height: size * 2 / 3, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return url }
        let w = CGFloat(size), h = CGFloat(size * 2 / 3)
        let colors = [NSColor(hex: 0x0B7366).cgColor, NSColor(hex: 0x9AD9CC).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: h), options: [])
        }
        ctx.setFillColor(NSColor(white: 1, alpha: 0.92).cgColor)
        ctx.fillEllipse(in: CGRect(x: w / 2 - 150, y: h / 2 - 150, width: 300, height: 300))
        ctx.setStrokeColor(NSColor(hex: 0x0B7366).cgColor)
        ctx.setLineWidth(22)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: w / 2, y: h / 2))
        ctx.addLine(to: CGPoint(x: w / 2 + 80, y: h / 2 + 80))
        ctx.strokePath()
        if let image = ctx.makeImage(), let data = ImageEngine.encode(image, uti: "public.png", quality: nil) {
            try? data.write(to: url)
        }
        return url
    }
}

struct OnboardingView: View {
    var close: () -> Void
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var center = JobCenter.shared
    @State private var practice = PracticeFile.make()
    @State private var startCount = JobCenter.shared.history.count

    private var practised: Bool { center.history.count > startCount }

    var body: some View {
        HStack(spacing: 0) {
            sandbox
                .frame(width: 340)
                .frame(maxHeight: .infinity)
                .background(Color.primary.opacity(0.04))
            explanation
                .padding(.horizontal, 36)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(width: 760, height: 440)
    }

    private var sandbox: some View {
        VStack(spacing: 18) {
            Spacer()
            VStack(spacing: 8) {
                Image(nsImage: NSImage(contentsOf: practice) ?? NSWorkspace.shared.icon(forFile: practice.path))
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                Text(practice.lastPathComponent).font(.system(size: 11.5))
            }
            .onDrag { NSItemProvider(contentsOf: practice) ?? NSItemProvider() }
            .help(Text("Drag me"))

            VStack(spacing: 4) {
                if practised {
                    Label("That's it. Your file is next to the original.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.mark)
                        .font(.system(size: 12.5, weight: .medium))
                } else {
                    Text(trf("Drag this picture a little, then tap %@.", prefs.key(for: .convert).glyphs))
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Let go over PNG or any other format.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(nsColor: Theme.textMuted))
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            Spacer()
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Convert files mid-drag").font(.system(size: 24, weight: .bold))
                Text("Start dragging any file, tap a key, drop it on the wheel. The result appears next to the original.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: Theme.textMuted))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                keyRow(.convert, tr("Turn it into another format."))
                keyRow(.tools, tr("Compress, cut out, read text, merge."))
                keyRow(.actions, tr("AirDrop, shelf, copy the path, Terminal."))
            }
            VStack(alignment: .leading, spacing: 4) {
                if prefs.hotkeyEnabled {
                    Text(trf("Without the mouse: select files in Finder and press %@.", HotKey.Preset.named(prefs.hotkeyPreset).label))
                }
                Text("You can also drop files on the menu bar icon.")
            }
            .font(.system(size: 12))
            .foregroundStyle(Color(nsColor: Theme.textMuted))
            HStack {
                Spacer()
                Button(practised ? tr("Done") : tr("Skip")) { close() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
    }

    private func keyRow(_ kind: WheelKind, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(prefs.key(for: kind).glyphs)
                .font(.system(size: 15, weight: .semibold))
                .frame(minWidth: 36, minHeight: 30)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(Color(nsColor: Theme.textMuted))
            }
        }
    }
}
