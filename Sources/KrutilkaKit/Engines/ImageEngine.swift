import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

enum ImageTarget: String, CaseIterable {
    case png, jpeg, heic, webp, avif, pdf, tiff, gif, bmp, ico

    var ext: String { self == .jpeg ? "jpg" : rawValue }
    var code: String { self == .jpeg ? "JPG" : rawValue.uppercased() }

    var uti: String? {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .tiff: return "public.tiff"
        case .gif: return "com.compuserve.gif"
        case .bmp: return "com.microsoft.bmp"
        case .ico: return "com.microsoft.ico"
        case .webp, .pdf: return nil
        }
    }

    var isLossy: Bool { [.jpeg, .heic, .webp, .avif].contains(self) }

    /// The target an existing file already is, so the wheel can grey that segment out.
    static func of(_ url: URL) -> ImageTarget? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        default: return ImageTarget(rawValue: url.pathExtension.lowercased())
        }
    }

    /// Whether this Mac can write the format, natively or through an installed tool.
    var isAvailable: Bool {
        switch self {
        case .webp:
            let t = ExternalTools.shared
            return t.has(.cwebp) || t.has(.magick) || t.has(.ffmpeg)
        case .pdf: return true
        default:
            guard let uti else { return false }
            return ImageEngine.writableTypes.contains(uti) || (self == .avif && ExternalTools.shared.has(.magick))
        }
    }
}

enum ImageEngine {
    static let writableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    // MARK: Reading

    /// Decodes a file into a CGImage with EXIF orientation applied, optionally scaled so the longest
    /// side is at most `maxSide`. SVG and other formats ImageIO cannot read go through NSImage or magick.
    static func load(_ url: URL, maxSide: Int? = nil, ctx: JobContext? = nil) async throws -> CGImage {
        if FileKind.of(url) == .svg { return try await rasterizeSVG(url, ctx: ctx) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw KError.unreadable(url.lastPathComponent)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(w, h, 1)
        let limit = min(maxSide ?? longest, longest)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw KError.unreadable(url.lastPathComponent)
        }
        return image
    }

    private static func rasterizeSVG(_ url: URL, ctx: JobContext?) async throws -> CGImage {
        if let image = NSImage(contentsOf: url), image.size.width > 0 {
            // Vector art gets a longest side of 2048 px (never smaller than drawn), whatever the screen.
            let longest = max(image.size.width, image.size.height)
            let scale = max(1, 2048 / longest)
            let w = Int((image.size.width * scale).rounded()), h = Int((image.size.height * scale).rounded())
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = NSSize(width: w, height: h)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
                if let cg = rep.cgImage { return cg }
            }
        }
        // ImageMagick only if macOS can't read it; Homebrew's build may need a delegate the policy forbids.
        if ExternalTools.shared.has(.magick), let ctx {
            let out = try ctx.scratch().appendingPathComponent("svg.png")
            try await Magick.run(["-background", "none", "-density", "300", Magick.input(url, as: "svg"), out.path])
            return try await load(out)
        }
        throw KError.unreadable(url.lastPathComponent)
    }

    static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let o = props[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Metadata to carry into a converted file: everything except orientation (already applied
    /// to the pixels) and the stale pixel dimensions.
    static func carriedProperties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyPNGDictionary, kCGImagePropertyGIFDictionary] {
            props.removeValue(forKey: key)
        }
        return props
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    // MARK: Writing

    static func encode(_ image: CGImage, uti: String, quality: Double?, properties: [CFString: Any] = [:]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, uti as CFString, 1, nil) else { return nil }
        var p = properties
        if let quality { p[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, p as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Writes `image` as `target`. WebP and (on older systems) AVIF go through an installed tool.
    static func write(_ image: CGImage, as target: ImageTarget, to out: URL, quality: Double,
                      properties: [CFString: Any] = [:], ctx: JobContext) async throws {
        switch target {
        case .pdf:
            try PDFEngine.writeImagesPDF([image], to: out)
        case .webp:
            try await writeWebP(image, to: out, quality: quality, ctx: ctx)
        default:
            var img = image
            if target == .ico { img = scaled(image, maxSide: 256) }
            if target == .jpeg || target == .bmp, hasAlpha(img) { img = flattened(img) }
            guard let uti = target.uti else { throw KError.failed(tr("This format can't be written.")) }
            if writableTypes.contains(uti), let data = encode(img, uti: uti, quality: target.isLossy ? quality : nil, properties: properties) {
                try data.write(to: out)
            } else if ExternalTools.shared.has(.magick) {
                let png = try ctx.scratch().appendingPathComponent(UUID().uuidString + ".png")
                try encode(img, uti: "public.png", quality: nil)?.write(to: png)
                try await Magick.run([Magick.input(png, as: "png"), "-quality", "\(Int(quality * 100))", out.path])
            } else {
                throw KError.failed(trf("This Mac can't save %@.", target.code))
            }
        }
    }

    private static func writeWebP(_ image: CGImage, to out: URL, quality: Double, ctx: JobContext) async throws {
        let png = try ctx.scratch().appendingPathComponent(UUID().uuidString + ".png")
        guard let data = encode(image, uti: "public.png", quality: nil) else { throw KError.failed(tr("Couldn't prepare the image.")) }
        try data.write(to: png)
        let q = "\(Int((quality * 100).rounded()))"
        let tools = ExternalTools.shared
        if let cwebp = tools.url(.cwebp) {
            try await Shell.run(cwebp, ["-quiet", "-q", q, "-metadata", "icc", png.path, "-o", out.path])
        } else if tools.has(.magick) {
            try await Magick.run([Magick.input(png, as: "png"), "-quality", q, out.path])
        } else if let ffmpeg = tools.url(.ffmpeg) {
            try await Shell.run(ffmpeg, ["-y", "-loglevel", "error", "-i", png.path, "-c:v", "libwebp", "-quality", q, out.path])
        } else {
            throw KError.needsTool("cwebp")
        }
    }

    static func scaled(_ image: CGImage, maxSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let s = CGFloat(maxSide) / CGFloat(longest)
        let w = max(1, Int(CGFloat(image.width) * s)), h = max(1, Int(CGFloat(image.height) * s))
        return draw(width: w, height: h, alpha: hasAlpha(image)) { c in
            c.interpolationQuality = .high
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        } ?? image
    }

    static func flattened(_ image: CGImage) -> CGImage {
        draw(width: image.width, height: image.height, alpha: false) { c in
            c.setFillColor(CGColor(gray: 1, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        } ?? image
    }

    static func rotatedClockwise(_ image: CGImage) -> CGImage {
        let w = image.height, h = image.width
        return draw(width: w, height: h, alpha: hasAlpha(image)) { c in
            c.translateBy(x: 0, y: CGFloat(h))
            c.rotate(by: -.pi / 2)
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        } ?? image
    }

    private static func draw(width: Int, height: Int, alpha: Bool, _ body: (CGContext) -> Void) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: info) else { return nil }
        body(c)
        return c.makeImage()
    }

    // MARK: Operations

    /// Converts one image file. `maxSide`, `quality` and `strip` let recipes reuse this.
    static func convert(_ input: URL, to target: ImageTarget, ctx: JobContext, maxSide: Int? = nil,
                        quality: Double? = nil, strip: Bool = false, suffix: String? = nil) async throws -> URL {
        let out = ctx.destination(for: input, ext: target.ext, suffix: suffix)
        do {
            if target == .webp, maxSide == nil, isAnimatedGIF(input), let gif2webp = ExternalTools.shared.url(.gif2webp) {
                try await Shell.run(gif2webp, ["-quiet", "-q", "\(Int((quality ?? ctx.settings.imageQuality) * 100))", input.path, "-o", out.path])
                return out
            }
            let image = try await load(input, maxSide: maxSide, ctx: ctx)
            ctx.progress(0.5)
            let props = strip ? [:] : carriedProperties(input)
            try await write(image, as: target, to: out, quality: quality ?? ctx.settings.imageQuality, properties: props, ctx: ctx)
            return out
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    static func isAnimatedGIF(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "gif",
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// The format to re-save in when a tool keeps the format (compress, rotate, resize).
    static func sameFormat(_ input: URL) -> ImageTarget {
        if let t = ImageTarget.of(input), t != .pdf, t.isAvailable { return t }
        return .png
    }

    static func compress(_ input: URL, ctx: JobContext) async throws -> URL {
        let image = try await load(input, ctx: ctx)
        var target = sameFormat(input)
        if [.png, .tiff, .bmp].contains(target) && !hasAlpha(image) { target = .jpeg }
        let suffix = tr("compressed")
        if target == .png, ExternalTools.shared.has(.magick) {
            let out = ctx.destination(for: input, ext: "png", suffix: suffix)
            try await Magick.run([Magick.input(input, as: "png"), "-strip", "-colors", "256", "-define", "png:compression-level=9", out.path])
            return out
        }
        let out = ctx.destination(for: input, ext: target.ext, suffix: suffix)
        try await write(image, as: target, to: out, quality: ctx.settings.compressQuality, properties: carriedProperties(input), ctx: ctx)
        return out
    }

    /// Smallest change that gets the file under the size limit: lower quality first, then fewer pixels.
    static func fitToSize(_ input: URL, ctx: JobContext) async throws -> URL {
        let limit = Int(ctx.settings.targetSizeMB * 1_000_000)
        var image = try await load(input, ctx: ctx)
        let useHEIC = ImageTarget.of(input) == .heic && writableTypes.contains("public.heic")
        let uti = useHEIC ? "public.heic" : "public.jpeg"
        if hasAlpha(image) && !useHEIC { image = flattened(image) }
        let props = carriedProperties(input)
        var best: Data?
        for round in 0..<8 {
            try Task.checkCancellation()
            var lo = 0.3, hi = 0.95
            var found: Data?
            for _ in 0..<7 {
                let q = (lo + hi) / 2
                guard let data = encode(image, uti: uti, quality: q, properties: props) else { break }
                if data.count <= limit { found = data; lo = q } else { hi = q }
            }
            ctx.progress(Double(round + 1) / 8)
            if let found { best = found; break }
            image = scaled(image, maxSide: Int(Double(max(image.width, image.height)) * 0.8))
        }
        guard let data = best else { throw KError.failed(tr("Couldn't get the image that small.")) }
        let out = ctx.destination(for: input, ext: useHEIC ? "heic" : "jpg",
                                  suffix: trf("under %@", ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)))
        try data.write(to: out)
        return out
    }

    static func resizeHalf(_ input: URL, ctx: JobContext) async throws -> URL {
        let size = pixelSize(input) ?? CGSize(width: 2000, height: 2000)
        let side = max(1, Int(max(size.width, size.height) / 2))
        return try await convert(input, to: sameFormat(input), ctx: ctx, maxSide: side, suffix: tr("half size"))
    }

    static func rotate(_ input: URL, ctx: JobContext) async throws -> URL {
        let image = rotatedClockwise(try await load(input, ctx: ctx))
        let target = sameFormat(input)
        let out = ctx.destination(for: input, ext: target.ext, suffix: tr("rotated"))
        try await write(image, as: target, to: out, quality: max(ctx.settings.imageQuality, 0.92),
                        properties: carriedProperties(input), ctx: ctx)
        return out
    }

    /// Removes EXIF, GPS, XMP and IPTC. JPEG, PNG and TIFF are rewritten without re-encoding pixels.
    static func stripMetadata(_ input: URL, ctx: JobContext) async throws -> URL {
        let target = sameFormat(input)
        let out = ctx.destination(for: input, ext: target.ext, suffix: tr("no metadata"))
        if let source = CGImageSourceCreateWithURL(input as CFURL, nil),
           let type = CGImageSourceGetType(source),
           ImageTarget.of(input) == target,
           let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            let meta = CGImageMetadataCreateMutable()
            if orientation != 1 {
                CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary,
                                                             kCGImagePropertyTIFFOrientation, orientation as CFNumber)
            }
            let options: [CFString: Any] = [
                kCGImageDestinationMetadata: meta,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageMetadataShouldExcludeXMP: true,
            ]
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) { return out }
            try? FileManager.default.removeItem(at: out)
        }
        let image = try await load(input, ctx: ctx)
        try await write(image, as: target, to: out, quality: 0.95, properties: [:], ctx: ctx)
        return out
    }

    @available(macOS 14.0, *)
    static func removeBackground(_ input: URL, ctx: JobContext) async throws -> URL {
        let image = try await load(input, maxSide: 4096, ctx: ctx)
        ctx.progress(0.2)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw KError.nothingToDo(tr("No subject found in this picture."))
        }
        ctx.progress(0.7)
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { throw KError.failed(tr("Couldn't cut out the subject.")) }
        let out = ctx.destination(for: input, ext: "png", suffix: tr("no background"))
        guard let data = encode(cg, uti: "public.png", quality: nil) else { throw KError.failed(tr("Couldn't save PNG.")) }
        try data.write(to: out)
        return out
    }

    /// Live Text on a picture. Writes a .txt next to it and copies the text.
    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        request.recognitionLanguages = ["ru-RU", "en-US", "uk-UA", "de-DE", "fr-FR"].filter { supported.contains($0) }
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let lines = (request.results ?? []).sorted {
            let a = $0.boundingBox, b = $1.boundingBox
            if abs(a.midY - b.midY) > min(a.height, b.height) / 2 { return a.midY > b.midY }
            return a.minX < b.minX
        }
        return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func ocr(_ input: URL, ctx: JobContext) async throws -> URL {
        let text = try recognizeText(in: try await load(input, maxSide: 4096, ctx: ctx))
        guard !text.isEmpty else { throw KError.nothingToDo(tr("No text found.")) }
        let out = ctx.destination(for: input, ext: "txt", suffix: tr("text"))
        try text.write(to: out, atomically: true, encoding: .utf8)
        Clipboard.copy(text)
        ctx.note = tr("Text copied")
        return out
    }

    static func readQR(_ input: URL, ctx: JobContext) async throws -> [URL] {
        let image = try await load(input, maxSide: 3000, ctx: ctx)
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
        guard !payloads.isEmpty else { throw KError.nothingToDo(tr("No QR code or barcode found.")) }
        let text = payloads.joined(separator: "\n")
        Clipboard.copy(text)
        ctx.note = trf("Copied: %@", text.count > 80 ? String(text.prefix(80)) + "…" : text)
        return []
    }

    static func applyRecipe(_ recipe: Recipe, to input: URL, ctx: JobContext) async throws -> URL {
        let target = ImageTarget(rawValue: recipe.format).flatMap { $0.isAvailable ? $0 : nil } ?? .jpeg
        return try await convert(input, to: target, ctx: ctx, maxSide: recipe.maxSide > 0 ? recipe.maxSide : nil,
                                 quality: recipe.quality, strip: recipe.stripMetadata, suffix: recipe.name)
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
