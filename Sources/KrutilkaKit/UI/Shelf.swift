import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A floating tray that holds files so they can be dragged out later, from any Space.
@MainActor
final class ShelfController: ObservableObject {
    static let shared = ShelfController()

    @Published var files: [URL] = []
    private var panel: NSPanel?

    func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) { files.append(url) }
        show()
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        if files.isEmpty { close() }
    }

    func close() {
        panel?.orderOut(nil)
        files = []
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 236, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: ShelfView(shelf: self))
            if let screen = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: screen.maxX - 236 - 16, y: screen.midY - 150))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }
}

struct ShelfView: View {
    @ObservedObject var shelf: ShelfController
    @ObservedObject var prefs = Prefs.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Shelf").font(.system(size: 12, weight: .semibold))
                Text(filesCount(shelf.files.count)).font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.textMuted))
                Spacer()
                Button { shelf.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(Text("Empty the shelf"))
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(shelf.files, id: \.self) { url in
                        ShelfItem(url: url) { shelf.remove(url) }
                    }
                }
                .padding(.horizontal, 8)
            }

            Text("Drag a file out to drop it anywhere")
                .font(.system(size: 10.5))
                .foregroundStyle(Color(nsColor: Theme.textMuted))
                .padding(.vertical, 8)
        }
        .background(DialSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous),
                                solid: prefs.wheelStyle == .solid || reduceTransparency))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.mark, lineWidth: targeted ? 2 : 0))
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { shelf.add([url]) } }
                }
            }
            return true
        }
    }
}

struct ShelfItem: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 28, height: 28)
            Text(url.lastPathComponent)
                .font(.system(size: 11.5))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(Color(nsColor: Theme.textMuted))
                }
                .buttonStyle(.plain)
                .help(Text("Remove from the shelf"))
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}
