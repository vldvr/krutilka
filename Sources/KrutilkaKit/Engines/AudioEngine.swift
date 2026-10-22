@preconcurrency import AVFoundation
import AudioToolbox

enum AudioTarget: String, CaseIterable {
    case mp3, m4a, wav, flac, opus, ogg, aiff, alac, caf

    var ext: String {
        switch self {
        case .alac: return "m4a"
        default: return rawValue
        }
    }
    var code: String { rawValue.uppercased() }

    /// What the format is good for, shown in the hub while hovering.
    var hint: String {
        switch self {
        case .mp3: return tr("Plays everywhere")
        case .m4a: return tr("AAC, small and good")
        case .wav, .aiff: return tr("Uncompressed")
        case .flac, .alac: return tr("Lossless")
        case .opus: return tr("Best quality per megabyte")
        case .ogg: return tr("Vorbis")
        case .caf: return tr("Core Audio")
        }
    }

    var isAvailable: Bool {
        let tools = ExternalTools.shared
        switch self {
        case .mp3: return tools.has(.ffmpeg) || tools.has(.lame)
        // Core Audio encodes Opus but can only put it in CAF, not Ogg.
        case .ogg, .opus: return tools.has(.ffmpeg)
        default: return true
        }
    }

    static func of(_ url: URL) -> AudioTarget? {
        switch url.pathExtension.lowercased() {
        case "aif", "aifc": return .aiff
        case "oga": return .ogg
        default: return AudioTarget(rawValue: url.pathExtension.lowercased())
        }
    }
}

enum AudioEngine {
    /// Formats Core Audio decodes on its own. Everything else is decoded by ffmpeg.
    static let nativeInputs: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "aifc", "flac", "caf", "aac", "m4b", "amr", "opus"]

    static func canRead(_ url: URL) -> Bool {
        nativeInputs.contains(url.pathExtension.lowercased()) || ExternalTools.shared.has(.ffmpeg)
    }

    static func convert(_ input: URL, to target: AudioTarget, ctx: JobContext, suffix: String? = nil) async throws -> URL {
        let out = ctx.destination(for: input, ext: target.ext, suffix: suffix)
        do {
            try await transcode(input, to: out, target: target, ctx: ctx)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    static func transcode(_ input: URL, to out: URL, target: AudioTarget, ctx: JobContext,
                          channels: Int? = nil, bitrate: Int? = nil) async throws {
        let kbps = bitrate ?? ctx.settings.audioBitrate
        let ext = input.pathExtension.lowercased()
        let tools = ExternalTools.shared

        if let ffmpeg = tools.url(.ffmpeg), [.mp3, .ogg, .opus].contains(target) || !nativeInputs.contains(ext) {
            var args = ["-y", "-hide_banner", "-loglevel", "error", "-i", input.path, "-vn", "-map_metadata", "0"]
            if let channels { args += ["-ac", "\(channels)"] }
            switch target {
            case .mp3: args += ["-c:a", "libmp3lame", "-b:a", "\(kbps)k", "-id3v2_version", "3"]
            case .ogg: args += ["-c:a", "libvorbis", "-q:a", "6"]
            case .opus: args += ["-c:a", "libopus", "-b:a", "\(min(kbps, 160))k"]
            case .m4a: args += ["-c:a", "aac", "-b:a", "\(kbps)k"]
            case .alac: args += ["-c:a", "alac"]
            case .flac: args += ["-c:a", "flac"]
            case .wav: args += ["-c:a", "pcm_s16le"]
            case .aiff: args += ["-c:a", "pcm_s16be"]
            case .caf: args += ["-c:a", "pcm_s16le", "-f", "caf"]
            }
            try await FFmpeg.run(ffmpeg, args + [out.path], duration: Media.duration(input), ctx: ctx)
            return
        }

        if target == .mp3, let lame = tools.url(.lame) {
            let wav = try ctx.scratch().appendingPathComponent(UUID().uuidString + ".wav")
            try await nativeTranscode(input, to: wav, target: .wav, kbps: kbps, channels: channels, ctx: ctx)
            try await Shell.run(lame, ["--silent", "-b", "\(kbps)", wav.path, out.path])
            return
        }
        try await nativeTranscode(input, to: out, target: target, kbps: kbps, channels: channels, ctx: ctx)
    }

    /// Decode with AVAudioFile, encode with ExtAudioFile. Handles AAC, ALAC, FLAC, Opus (in Ogg),
    /// WAV, AIFF and CAF without any helper installed.
    static func nativeTranscode(_ input: URL, to out: URL, target: AudioTarget, kbps: Int, channels: Int?, ctx: JobContext) async throws {
        let source = try AVAudioFile(forReading: input)
        let inFormat = source.processingFormat
        let channelCount = AVAudioChannelCount(channels ?? Int(min(inFormat.channelCount, 2)))
        var sampleRate = inFormat.sampleRate
        if target == .opus { sampleRate = 48_000 }

        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channelCount, interleaved: false)
        else { throw KError.failed(tr("Unsupported audio layout.")) }

        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channelCount]
        var fileType: AudioFileTypeID
        switch target {
        case .m4a:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = kbps * 1000
            fileType = kAudioFileM4AType
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 16
            fileType = kAudioFileM4AType
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = 16
            fileType = kAudioFileFLACType
        case .opus:
            settings[AVFormatIDKey] = kAudioFormatOpus
            settings[AVEncoderBitRateKey] = min(kbps, 160) * 1000
            fileType = 0x4F676766 // 'Oggf'
        case .wav:
            settings.merge(pcmSettings(bigEndian: false)) { $1 }
            fileType = kAudioFileWAVEType
        case .aiff:
            settings.merge(pcmSettings(bigEndian: true)) { $1 }
            fileType = kAudioFileAIFFType
        case .caf:
            settings.merge(pcmSettings(bigEndian: false)) { $1 }
            fileType = kAudioFileCAFType
        case .mp3, .ogg:
            throw KError.needsTool("ffmpeg")
        }

        guard let outFormat = AVAudioFormat(settings: settings) else { throw KError.failed(tr("Unsupported audio settings.")) }
        var asbd = outFormat.streamDescription.pointee
        var fileRef: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(out as CFURL, fileType, &asbd, nil, AudioFileFlags.eraseFile.rawValue, &fileRef)
        guard status == noErr, let file = fileRef else { throw KError.failed(trf("Couldn't create %@ (%d).", target.code, Int(status))) }
        defer { ExtAudioFileDispose(file) }

        var client = pcm.streamDescription.pointee
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else { throw KError.failed(trf("Couldn't set up the %@ encoder (%d).", target.code, Int(status))) }
        if target == .m4a || target == .opus {
            setBitrate(file, bps: (target == .opus ? min(kbps, 160) : kbps) * 1000)
        }

        guard let converter = AVAudioConverter(from: inFormat, to: pcm) else { throw KError.failed(tr("Unsupported audio layout.")) }
        let total = max(Double(source.length), 1)
        let chunk: AVAudioFrameCount = 32_768
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else { return }
        let ratio = sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(chunk) * ratio) + 1024

        var finished = false
        while !finished {
            try Task.checkCancellation()
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: outCapacity) else { break }
            var convError: NSError?
            let result = converter.convert(to: outBuffer, error: &convError) { _, inputStatus in
                do {
                    try source.read(into: readBuffer, frameCount: chunk)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if readBuffer.frameLength == 0 { inputStatus.pointee = .endOfStream; return nil }
                inputStatus.pointee = .haveData
                return readBuffer
            }
            if let convError { throw convError }
            if outBuffer.frameLength > 0 {
                status = ExtAudioFileWrite(file, outBuffer.frameLength, outBuffer.audioBufferList)
                guard status == noErr else { throw KError.failed(trf("Writing %@ failed (%d).", target.code, Int(status))) }
            }
            if result == .endOfStream || result == .error { finished = true }
            ctx.progress(Double(source.framePosition) / total)
        }
    }

    private static func pcmSettings(bigEndian: Bool) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
         AVLinearPCMIsBigEndianKey: bigEndian, AVLinearPCMIsNonInterleaved: false]
    }

    private static func setBitrate(_ file: ExtAudioFileRef, bps: Int) {
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr, let converter else { return }
        var rate = UInt32(bps)
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
        // Tell ExtAudioFile the converter changed (a NULL config means "reread it").
        var config: Unmanaged<CFArray>? = nil
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<Unmanaged<CFArray>?>.size), &config)
    }

    // MARK: Tools

    /// Same container when possible, so an MP3 stays an MP3.
    private static func keepFormat(_ input: URL) -> AudioTarget {
        if let t = AudioTarget.of(input), t.isAvailable, t != .alac { return t }
        return .m4a
    }

    static func compress(_ input: URL, ctx: JobContext) async throws -> URL {
        let target: AudioTarget = AudioTarget.of(input) == .mp3 && AudioTarget.mp3.isAvailable ? .mp3 : .m4a
        let out = ctx.destination(for: input, ext: target.ext, suffix: tr("compressed"))
        try await transcode(input, to: out, target: target, ctx: ctx, bitrate: 96)
        return out
    }

    static func mono(_ input: URL, ctx: JobContext) async throws -> URL {
        let target = keepFormat(input)
        let out = ctx.destination(for: input, ext: target.ext, suffix: tr("mono"))
        try await transcode(input, to: out, target: target, ctx: ctx, channels: 1)
        return out
    }

    /// EBU R128 loudness with ffmpeg; a plain peak normalise otherwise.
    static func normalize(_ input: URL, ctx: JobContext) async throws -> URL {
        let target = keepFormat(input)
        let out = ctx.destination(for: input, ext: target.ext, suffix: tr("normalized"))
        if let ffmpeg = ExternalTools.shared.url(.ffmpeg) {
            var args = ["-y", "-hide_banner", "-loglevel", "error", "-i", input.path, "-vn", "-af", "loudnorm=I=-16:TP=-1.5:LRA=11"]
            switch target {
            case .mp3: args += ["-c:a", "libmp3lame", "-b:a", "\(ctx.settings.audioBitrate)k"]
            case .m4a: args += ["-c:a", "aac", "-b:a", "\(ctx.settings.audioBitrate)k"]
            case .flac: args += ["-c:a", "flac"]
            case .opus: args += ["-c:a", "libopus"]
            case .ogg: args += ["-c:a", "libvorbis", "-q:a", "6"]
            default: args += ["-ar", "48000"]
            }
            try await FFmpeg.run(ffmpeg, args + [out.path], duration: Media.duration(input), ctx: ctx)
            return out
        }
        let file = try AVAudioFile(forReading: input)
        var peak: Float = 0
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return out }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            for ch in 0..<Int(buffer.format.channelCount) {
                if let data = buffer.floatChannelData?[ch] {
                    for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
                }
            }
        }
        guard peak > 0 else { throw KError.nothingToDo(tr("The track is silent.")) }
        let gain = 0.891 / peak // -1 dBFS
        let wav = try ctx.scratch().appendingPathComponent(UUID().uuidString + ".caf")
        let source = try AVAudioFile(forReading: input)
        let dest = try AVAudioFile(forWriting: wav, settings: source.processingFormat.settings)
        guard let buf = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: chunk) else { return out }
        while source.framePosition < source.length {
            try source.read(into: buf, frameCount: chunk)
            for ch in 0..<Int(buf.format.channelCount) {
                if let data = buf.floatChannelData?[ch] {
                    for i in 0..<Int(buf.frameLength) { data[i] *= gain }
                }
            }
            try dest.write(from: buf)
        }
        try await nativeTranscode(wav, to: out, target: target == .mp3 || target == .ogg ? .m4a : target,
                                  kbps: ctx.settings.audioBitrate, channels: nil, ctx: ctx)
        return out
    }

    static func stripMetadata(_ input: URL, ctx: JobContext) async throws -> URL {
        let ffmpeg = try ExternalTools.shared.require(.ffmpeg)
        let out = ctx.destination(for: input, ext: input.pathExtension, suffix: tr("no metadata"))
        try await Shell.run(ffmpeg, ["-y", "-hide_banner", "-loglevel", "error", "-i", input.path,
                                     "-map", "0:a", "-map_metadata", "-1", "-c", "copy", out.path])
        return out
    }

    static func join(_ inputs: [URL], ctx: JobContext) async throws -> URL {
        let files = Naming.finderOrder(inputs)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw KError.failed(tr("Couldn't join the tracks."))
        }
        var cursor = CMTime.zero
        for url in files {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = cursor + duration
        }
        let out = ctx.destination(for: files[0], ext: "m4a", suffix: tr("joined"))
        try await Media.export(composition, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: out, ctx: ctx)
        return out
    }
}

/// ffmpeg with progress parsed from `-progress pipe:1`.
enum FFmpeg {
    static func run(_ ffmpeg: URL, _ args: [String], duration: Double?, ctx: JobContext) async throws {
        var full = args
        if let output = full.popLast() {
            full += ["-progress", "pipe:1", "-nostats", output]
        }
        try await Shell.run(ffmpeg, full) { line in
            guard let duration, duration > 0, line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") else { return }
            if let us = Double(line.split(separator: "=").last ?? "") {
                ctx.progress(us / 1_000_000 / duration)
            }
        }
    }
}
