@preconcurrency import AVFoundation
import ImageIO

enum VideoTarget: String, CaseIterable {
    case mp4, mov, gif, hevc, webm, mkv, m4a, mp3, avi, wav

    var ext: String { self == .hevc ? "mp4" : rawValue }
    var code: String { rawValue.uppercased() }
    var isAudio: Bool { [.m4a, .mp3, .wav].contains(self) }

    var hint: String {
        switch self {
        case .mp4: return tr("H.264, plays everywhere")
        case .mov: return tr("QuickTime")
        case .gif: return tr("Silent loop, 12 fps")
        case .hevc: return tr("Half the size, same look")
        case .webm: return tr("VP9 for the web")
        case .mkv: return tr("Same streams, new container")
        case .m4a, .mp3, .wav: return tr("Only the sound")
        case .avi: return tr("For old players")
        }
    }

    var isAvailable: Bool {
        switch self {
        case .webm, .mkv, .avi: return ExternalTools.shared.has(.ffmpeg)
        case .mp3: return AudioTarget.mp3.isAvailable
        default: return true
        }
    }

    static func of(_ url: URL) -> VideoTarget? { VideoTarget(rawValue: url.pathExtension.lowercased()) }
}

enum Media {
    static let nativeVideo: Set<String> = ["mp4", "mov", "m4v", "3gp", "mts", "m2ts", "ts", "mpg", "mpeg"]

    static func isNative(_ url: URL) -> Bool { nativeVideo.contains(url.pathExtension.lowercased()) }

    static func duration(_ url: URL) async -> Double? {
        if let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite, seconds > 0 {
            return seconds
        }
        guard let ffprobe = ExternalTools.shared.url(.ffprobe),
              let out = try? await Shell.run(ffprobe, ["-v", "error"] + FFmpeg.safeInput + ["-show_entries", "format=duration", "-of", "csv=p=0", url.path])
        else { return nil }
        return Double(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func videoCodec(_ url: URL) async -> String? {
        guard let ffprobe = ExternalTools.shared.url(.ffprobe),
              let out = try? await Shell.run(ffprobe, ["-v", "error"] + FFmpeg.safeInput + ["-select_streams", "v:0", "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path])
        else { return nil }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// AVAssetExportSession with progress and cancellation.
    static func export(_ asset: AVAsset, preset: String, type: AVFileType, to out: URL, ctx: JobContext,
                       videoComposition: AVVideoComposition? = nil, forSharing: Bool = false,
                       timeRange: CMTimeRange? = nil) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw KError.failed(tr("This video can't be exported that way."))
        }
        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        session.audioTimePitchAlgorithm = .spectral
        if let videoComposition { session.videoComposition = videoComposition }
        if forSharing { session.metadataItemFilter = AVMetadataItemFilter.forSharing() }
        if let timeRange { session.timeRange = timeRange }

        let shared = Unchecked(value: session)
        let poll = Task {
            while !Task.isCancelled {
                ctx.progress(Double(shared.value.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poll.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                shared.value.exportAsynchronously {
                    let session = shared.value
                    switch session.status {
                    case .completed: cont.resume()
                    case .cancelled: cont.resume(throwing: CancellationError())
                    default: cont.resume(throwing: session.error ?? KError.failed(tr("Export failed.")))
                    }
                }
            }
        } onCancel: {
            shared.value.cancelExport()
        }
    }
}

enum VideoEngine {
    static func canRead(_ url: URL) -> Bool { Media.isNative(url) || ExternalTools.shared.has(.ffmpeg) }

    static func convert(_ input: URL, to target: VideoTarget, ctx: JobContext) async throws -> URL {
        if target.isAudio {
            let audio: AudioTarget = target == .mp3 ? .mp3 : target == .wav ? .wav : .m4a
            if Media.isNative(input), audio != .mp3 || !ExternalTools.shared.has(.ffmpeg) {
                let out = ctx.destination(for: input, ext: audio.ext)
                if audio == .m4a {
                    try await Media.export(AVURLAsset(url: input), preset: AVAssetExportPresetAppleM4A, type: .m4a, to: out, ctx: ctx)
                } else {
                    let m4a = try ctx.scratch().appendingPathComponent(UUID().uuidString + ".m4a")
                    try await Media.export(AVURLAsset(url: input), preset: AVAssetExportPresetAppleM4A, type: .m4a, to: m4a, ctx: ctx)
                    try await AudioEngine.transcode(m4a, to: out, target: audio, ctx: ctx)
                }
                return out
            }
            return try await AudioEngine.convert(input, to: audio, ctx: ctx)
        }

        let out = ctx.destination(for: input, ext: target.ext, suffix: target == .hevc ? "HEVC" : nil)
        do {
            switch target {
            case .gif: try await makeGIF(input, to: out, ctx: ctx)
            case .webm, .mkv, .avi: try await ffmpegConvert(input, to: out, target: target, ctx: ctx)
            default:
                if Media.isNative(input) {
                    try await nativeConvert(input, to: out, target: target, ctx: ctx)
                } else {
                    try await ffmpegConvert(input, to: out, target: target, ctx: ctx)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    private static func nativeConvert(_ input: URL, to out: URL, target: VideoTarget, ctx: JobContext) async throws {
        let asset = AVURLAsset(url: input)
        let type: AVFileType = target == .mov ? .mov : .mp4
        if target == .hevc {
            try await Media.export(asset, preset: AVAssetExportPresetHEVCHighestQuality, type: type, to: out, ctx: ctx)
            return
        }
        // A container change is lossless and instant when the streams fit the new container.
        do {
            try await Media.export(asset, preset: AVAssetExportPresetPassthrough, type: type, to: out, ctx: ctx)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: out)
            try await Media.export(asset, preset: AVAssetExportPresetHighestQuality, type: type, to: out, ctx: ctx)
        }
    }

    private static func ffmpegConvert(_ input: URL, to out: URL, target: VideoTarget, ctx: JobContext) async throws {
        let ffmpeg = try ExternalTools.shared.require(.ffmpeg)
        let duration = await Media.duration(input)
        var args = ["-y", "-hide_banner", "-loglevel", "error", ] + (try await FFmpeg.input(input))
        switch target {
        case .webm:
            args += ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k"]
        case .mkv:
            args += ["-map", "0", "-c", "copy"]
        case .avi:
            args += ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-b:a", "192k"]
        case .hevc:
            args += ["-c:v", "hevc_videotoolbox", "-q:v", "55", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        default:
            let codec = await Media.videoCodec(input)
            if codec == "h264" || codec == "hevc" {
                args += ["-map", "0:v:0", "-map", "0:a?", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k"]
                if codec == "hevc" { args += ["-tag:v", "hvc1"] }
            } else {
                args += ["-c:v", "libx264", "-crf", "20", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
            }
            if target != .mov { args += ["-movflags", "+faststart"] }
        }
        do {
            try await FFmpeg.run(ffmpeg, args + [out.path], duration: duration, ctx: ctx)
        } catch let error as KError where target == .mkv {
            // Some streams can't be copied into Matroska as-is; re-encode them.
            _ = error
            try await FFmpeg.run(ffmpeg, ["-y", "-hide_banner", "-loglevel", "error", ] + (try await FFmpeg.input(input)) + [
                                          "-c:v", "libx264", "-crf", "20", "-preset", "veryfast", "-c:a", "aac", out.path],
                                 duration: duration, ctx: ctx)
        }
    }

    /// A good-looking GIF: ffmpeg's two-pass palette, or frame grabs through ImageIO.
    private static func makeGIF(_ input: URL, to out: URL, ctx: JobContext) async throws {
        if let ffmpeg = ExternalTools.shared.url(.ffmpeg) {
            let filter = "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4"
            try await FFmpeg.run(ffmpeg, ["-y", "-hide_banner", "-loglevel", "error", ] + (try await FFmpeg.input(input)) + [ "-t", "60",
                                          "-vf", filter, "-loop", "0", out.path],
                                 duration: min(await Media.duration(input) ?? 60, 60), ctx: ctx)
            return
        }
        let asset = AVURLAsset(url: input)
        let duration = min(try await asset.load(.duration).seconds, 60)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 24)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 24)
        let fps = 10.0
        let count = max(1, Int(duration * fps))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "com.compuserve.gif" as CFString, count, nil) else {
            throw KError.failed(tr("Couldn't create the GIF."))
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let frame = try? generator.copyCGImage(at: time, actualTime: nil) {
                CGImageDestinationAddImage(dest, frame, frameProps)
            }
            ctx.progress(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else { throw KError.failed(tr("Couldn't create the GIF.")) }
    }

    // MARK: Tools

    static func compress(_ input: URL, ctx: JobContext, maxSide: Int? = nil, suffix: String? = nil) async throws -> URL {
        let out = ctx.destination(for: input, ext: "mp4", suffix: suffix ?? tr("compressed"))
        let preset: String
        switch maxSide ?? (ctx.settings.videoQuality == .p720 ? 1280 : ctx.settings.videoQuality == .p1080 ? 1920 : 0) {
        case 1...1280: preset = AVAssetExportPreset1280x720
        case 1281...1920: preset = AVAssetExportPreset1920x1080
        default: preset = AVAssetExportPresetHEVCHighestQuality
        }
        var source = input
        if !Media.isNative(input) {
            source = try ctx.scratch().appendingPathComponent(UUID().uuidString + ".mp4")
            try await ffmpegConvert(input, to: source, target: .mp4, ctx: ctx)
        }
        try await Media.export(AVURLAsset(url: source), preset: preset, type: .mp4, to: out, ctx: ctx, forSharing: true)
        return out
    }

    static func applyRecipe(_ recipe: Recipe, to input: URL, ctx: JobContext) async throws -> URL {
        try await compress(input, ctx: ctx, maxSide: recipe.maxSide > 0 ? recipe.maxSide : 99_999, suffix: recipe.name)
    }

    static func mute(_ input: URL, ctx: JobContext) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        for source in try await asset.loadTracks(withMediaType: .video) {
            let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try track?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
            track?.preferredTransform = try await source.load(.preferredTransform)
        }
        let type: AVFileType = input.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let out = ctx.destination(for: input, ext: type == .mov ? "mov" : "mp4", suffix: tr("no sound"))
        try await Media.export(composition, preset: AVAssetExportPresetPassthrough, type: type, to: out, ctx: ctx)
        return out
    }

    static func snapshot(_ input: URL, ctx: JobContext) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTimeMultiplyByFloat64(duration, multiplier: 0.5)
        let frame = try generator.copyCGImage(at: time, actualTime: nil)
        let out = ctx.destination(for: input, ext: "jpg", suffix: tr("frame"))
        guard let data = ImageEngine.encode(frame, uti: "public.jpeg", quality: 0.92) else { throw KError.failed(tr("Couldn't grab a frame.")) }
        try data.write(to: out)
        return out
    }

    static func speedUp(_ input: URL, ctx: JobContext) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        for type in [AVMediaType.video, .audio] {
            for source in try await asset.loadTracks(withMediaType: type) {
                let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
                try track?.insertTimeRange(range, of: source, at: .zero)
                if type == .video { track?.preferredTransform = try await source.load(.preferredTransform) }
            }
        }
        composition.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 0.5))
        let out = ctx.destination(for: input, ext: "mp4", suffix: "2×")
        try await Media.export(composition, preset: AVAssetExportPresetHighestQuality, type: .mp4, to: out, ctx: ctx)
        return out
    }

    /// Rotation is stored as the track transform, so this is lossless and takes a second.
    static func rotate(_ input: URL, ctx: JobContext) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        for type in [AVMediaType.video, .audio] {
            for source in try await asset.loadTracks(withMediaType: type) {
                let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
                try track?.insertTimeRange(range, of: source, at: .zero)
                if type == .video {
                    let size = try await source.load(.naturalSize)
                    let current = try await source.load(.preferredTransform)
                    let shown = CGRect(origin: .zero, size: size).applying(current)
                    let turn = CGAffineTransform(translationX: abs(shown.height), y: 0).rotated(by: .pi / 2)
                    track?.preferredTransform = current.concatenating(turn)
                }
            }
        }
        let type: AVFileType = input.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let out = ctx.destination(for: input, ext: type == .mov ? "mov" : "mp4", suffix: tr("rotated"))
        try await Media.export(composition, preset: AVAssetExportPresetPassthrough, type: type, to: out, ctx: ctx)
        return out
    }

    static func stripMetadata(_ input: URL, ctx: JobContext) async throws -> URL {
        let type: AVFileType = input.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let out = ctx.destination(for: input, ext: type == .mov ? "mov" : "mp4", suffix: tr("no metadata"))
        if let ffmpeg = ExternalTools.shared.url(.ffmpeg) {
            try await Shell.run(ffmpeg, ["-y", "-hide_banner", "-loglevel", "error", ] + (try await FFmpeg.input(input)) + [ "-map", "0",
                                         "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy", out.path])
        } else {
            try await Media.export(AVURLAsset(url: input), preset: AVAssetExportPresetPassthrough, type: type, to: out, ctx: ctx, forSharing: true)
        }
        return out
    }

    /// Clips one after another. Different sizes and orientations are fitted into the first clip's frame.
    static func join(_ inputs: [URL], ctx: JobContext) async throws -> URL {
        let files = Naming.finderOrder(inputs)
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw KError.failed(tr("Couldn't join the clips.")) }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var renderSize = CGSize.zero
        var cursor = CMTime.zero
        for url in files {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { continue }
            try videoTrack.insertTimeRange(range, of: source, at: cursor)
            if let sound = try await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(range, of: sound, at: cursor)
            }
            let natural = try await source.load(.naturalSize)
            let transform = try await source.load(.preferredTransform)
            let shown = CGRect(origin: .zero, size: natural).applying(transform)
            let size = CGSize(width: abs(shown.width), height: abs(shown.height))
            if renderSize == .zero { renderSize = size }
            let scale = min(renderSize.width / size.width, renderSize.height / size.height)
            let fit = transform
                .concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (renderSize.width - size.width * scale) / 2,
                                                 y: (renderSize.height - size.height * scale) / 2))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(fit, at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: duration)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = cursor + duration
        }
        let video = AVMutableVideoComposition()
        video.instructions = instructions
        video.renderSize = CGSize(width: renderSize.width.rounded(), height: renderSize.height.rounded())
        video.frameDuration = CMTime(value: 1, timescale: 30)
        let out = ctx.destination(for: files[0], ext: "mp4", suffix: tr("joined"))
        try await Media.export(composition, preset: AVAssetExportPresetHighestQuality, type: .mp4, to: out, ctx: ctx, videoComposition: video)
        return out
    }
}
