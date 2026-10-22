import AppKit
import SwiftUI

/// Progress capsules stacked under the menu bar, near the app's icon.
@MainActor
final class HUDController {
    static let shared = HUDController()

    private let panel: NSPanel
    private let width: CGFloat = 330
    private let rowHeight: CGFloat = 58
    private let spacing: CGFloat = 8

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: HUDView(center: JobCenter.shared))
        panel.contentView = host
    }

    func update() {
        let count = min(JobCenter.shared.records.count, 4)
        guard count > 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                if JobCenter.shared.records.isEmpty { self?.panel.orderOut(nil) }
            }
            return
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let height = CGFloat(count) * rowHeight + CGFloat(count - 1) * spacing + 24
        let frame = NSRect(x: visible.maxX - width - 10, y: visible.maxY - height - 4, width: width, height: height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }
}

struct HUDView: View {
    @ObservedObject var center: JobCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.records.suffix(4)) { record in
                HUDRow(record: record)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85), value: center.records.map(\.id))
        .onHover { center.hudHovered = $0 }
    }
}

struct HUDRow: View {
    @ObservedObject var record: JobRecord
    @ObservedObject var prefs = Prefs.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovering = false

    private var failed: Bool { if case .failed = record.state { return true } else { return false } }
    private var solid: Bool { prefs.wheelStyle == .solid || reduceTransparency }

    var body: some View {
        HStack(spacing: 11) {
            ProgressDial(progress: record.progress, state: record.state, symbol: record.symbol, code: record.code)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(failed ? Color(nsColor: Theme.danger) : Color(nsColor: Theme.textMuted))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(DialSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), solid: solid))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if !record.outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(record.outputs) }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        switch record.state {
        case .running: return record.detail.isEmpty ? tr("Working…") : record.detail
        case .done: return record.note ?? record.detail
        case .failed(let why): return why == record.title ? "" : why
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if record.state == .running {
            Button { record.cancel() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
            }
            .buttonStyle(.plain)
            .help(Text("Cancel"))
        } else if !record.outputs.isEmpty {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: Theme.textMuted))
                .opacity(hovering ? 1 : 0.6)
                .help(Text("Show in Finder"))
        }
    }
}

/// The dial again, as a progress ring: the same object at a smaller scale.
struct ProgressDial: View {
    var progress: Double
    var state: JobRecord.State
    var symbol: String?
    var code: String?

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 3)
            Circle()
                .trim(from: 0, to: state == .running ? max(0.03, progress) : 1)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: progress)
            center
        }
    }

    private var ringColor: Color {
        if case .failed = state { return Color(nsColor: Theme.danger) }
        return Theme.mark
    }

    @ViewBuilder
    private var center: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.mark)
        case .failed:
            Image(systemName: "exclamationmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Color(nsColor: Theme.danger))
        case .running:
            if let code {
                Text(code).font(.dialCode(7.5, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal, 4)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            }
        }
    }
}
