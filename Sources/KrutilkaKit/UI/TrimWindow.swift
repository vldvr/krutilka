import AppKit
import AVKit
import SwiftUI

/// QuickTime-style trimming through AVKit's own trim bar, then a lossless cut.
@MainActor
final class TrimController: NSObject, NSWindowDelegate {
    private static var open: [TrimController] = []

    private let url: URL
    private let window: NSWindow
    private let playerView = AVPlayerView()
    private var observation: NSKeyValueObservation?

    static func show(_ url: URL) {
        let controller = TrimController(url: url)
        open.append(controller)
        controller.start()
    }

    private init(url: URL) {
        self.url = url
        let isAudio = FileKind.of(url) == .audio
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: isAudio ? 150 : 460),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = trf("Trim %@", url.lastPathComponent)
        window.isReleasedWhenClosed = false
        window.delegate = self
        playerView.controlsStyle = .inline
        playerView.player = AVPlayer(url: url)
        window.contentView = playerView
        window.center()
    }

    private func start() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        observation = playerView.player?.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async { self?.beginTrimming() }
        }
    }

    private func beginTrimming() {
        observation = nil
        guard playerView.canBeginTrimming else {
            JobCenter.shared.flash(tr("This file can't be trimmed."), failed: true)
            window.close()
            return
        }
        playerView.beginTrimming { [weak self] result in
            // AVKit calls back on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                if result == .okButton, let item = self.playerView.player?.currentItem {
                    let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
                    let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
                    self.export(CMTimeRange(start: start, end: end))
                }
                self.window.close()
            }
        }
    }

    private func export(_ range: CMTimeRange) {
        let source = url
        var op = Operation(id: "trim", wheel: .tools, title: tr("Trim"), symbol: "timeline.selection",
                           hint: "", batch: .each)
        op.run = { ctx in [try await Trimmer.cut(source, range: range, ctx: ctx)] }
        JobCenter.shared.start(op, files: [source])
    }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        TrimController.open.removeAll { $0 === self }
    }
}

/// Mark points while it plays, then cut into parts, losslessly.
@MainActor
final class SplitController: NSObject, NSWindowDelegate {
    private static var open: [SplitController] = []
    private let window: NSWindow
    private let model: SplitModel

    static func show(_ url: URL) {
        let controller = SplitController(url: url)
        open.append(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.window.makeKeyAndOrderFront(nil)
    }

    private init(url: URL) {
        model = SplitModel(url: url)
        let isAudio = FileKind.of(url) == .audio
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: isAudio ? 190 : 500),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = trf("Split %@", url.lastPathComponent)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SplitView(model: model) { [weak self] in self?.window.close() })
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        model.player.pause()
        model.stopObserving()
        SplitController.open.removeAll { $0 === self }
    }
}

@MainActor
final class SplitModel: ObservableObject {
    let url: URL
    let player: AVPlayer
    @Published var now: Double = 0
    @Published var duration: Double = 0
    @Published var cuts: [Double] = []
    private var observer: Any?

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = time.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
    }

    func stopObserving() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    var canMark: Bool { now > 0.2 && (duration == 0 || now < duration - 0.2) && !cuts.contains { abs($0 - now) < 0.2 } }

    func mark() {
        guard canMark else { return }
        cuts.append(now)
        cuts.sort()
    }

    /// Parts between the marks, start to end.
    var ranges: [CMTimeRange] {
        let points = [0] + cuts + [duration]
        return zip(points, points.dropFirst()).map { a, b in
            CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600), end: CMTime(seconds: b, preferredTimescale: 600))
        }
    }

    func split() {
        let source = url
        let parts = ranges
        var op = Operation(id: "cut", wheel: .tools, title: tr("Split"), symbol: "scissors", hint: "", batch: .each)
        op.run = { ctx in
            var outputs: [URL] = []
            for (i, range) in parts.enumerated() {
                try Task.checkCancellation()
                outputs.append(try await Trimmer.cut(source, range: range, ctx: ctx, suffix: trf("part %d", i + 1)))
                ctx.progress(Double(i + 1) / Double(parts.count))
            }
            return outputs
        }
        JobCenter.shared.start(op, files: [source])
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds * 10)
        let m = total / 600, s = (total / 10) % 60, t = total % 10
        return String(format: "%d:%02d.%d", m, s, t)
    }
}

struct SplitView: View {
    @ObservedObject var model: SplitModel
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PlayerSurface(player: model.player)
            Divider()
            HStack(spacing: 10) {
                Button { model.mark() } label: {
                    Label(trf("Cut at %@", SplitModel.clock(model.now)), systemImage: "scissors")
                        .monospacedDigit()
                }
                .keyboardShortcut("k", modifiers: [])
                .disabled(!model.canMark)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.cuts, id: \.self) { cut in
                            HStack(spacing: 4) {
                                Text(SplitModel.clock(cut)).monospacedDigit()
                                Button { model.cuts.removeAll { $0 == cut } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                    .buttonStyle(.plain)
                                    .help(Text("Remove the mark"))
                            }
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Capsule().fill(Theme.accent.opacity(0.14)))
                        }
                    }
                }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(model.cuts.isEmpty ? tr("Split") : trf("Split into %d parts", model.cuts.count + 1)) {
                    model.split()
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.cuts.isEmpty)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

enum Trimmer {
    /// Cuts without re-encoding: ffmpeg stream copy keeps any format; AVFoundation passthrough otherwise.
    static func cut(_ input: URL, range: CMTimeRange, ctx: JobContext, suffix: String = tr("trimmed")) async throws -> URL {
        let ext = input.pathExtension.lowercased()
        let isAudio = FileKind.of(input) == .audio
        if let ffmpeg = ExternalTools.shared.url(.ffmpeg), isAudio || !Media.isNative(input) {
            let out = ctx.destination(for: input, ext: ext, suffix: suffix)
            try await Shell.run(ffmpeg, ["-y", "-hide_banner", "-loglevel", "error",
                                         "-ss", String(format: "%.3f", range.start.seconds), ] + (try await FFmpeg.input(input)) + [
                                         "-t", String(format: "%.3f", range.duration.seconds),
                                         "-map", "0", "-c", "copy", out.path])
            return out
        }
        let asset = AVURLAsset(url: input)
        let type: AVFileType = isAudio ? .m4a : (ext == "mov" ? .mov : .mp4)
        let out = ctx.destination(for: input, ext: isAudio ? "m4a" : (ext == "mov" ? "mov" : "mp4"), suffix: suffix)
        try await Media.export(asset, preset: isAudio ? AVAssetExportPresetAppleM4A : AVAssetExportPresetPassthrough,
                               type: type, to: out, ctx: ctx, timeRange: range)
        return out
    }
}
