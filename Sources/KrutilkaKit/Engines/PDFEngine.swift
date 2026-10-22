import AppKit
import CoreText
import PDFKit
import Vision

enum PDFEngine {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw KError.unreadable(url.lastPathComponent) }
        if doc.isLocked { throw KError.failed(tr("This PDF is password-protected.")) }
        return doc
    }

    // MARK: Images in

    /// One page per image. Big photos get an A4-sized page with full resolution kept;
    /// opaque images are embedded as JPEG so the PDF stays small.
    static func writeImagesPDF(_ images: [CGImage], to url: URL) throws {
        var box = CGRect.zero
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw KError.failed(tr("Couldn't create the PDF."))
        }
        for image in images {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let scale = min(1, 842 / max(w, h))
            var page = CGRect(x: 0, y: 0, width: (w * scale).rounded(), height: (h * scale).rounded())
            pdf.beginPage(mediaBox: &page)
            pdf.interpolationQuality = .high
            pdf.draw(embeddable(image), in: page)
            pdf.endPage()
        }
        pdf.closePDF()
    }

    private static func embeddable(_ image: CGImage) -> CGImage {
        guard !ImageEngine.hasAlpha(image),
              let data = ImageEngine.encode(image, uti: "public.jpeg", quality: 0.9),
              let provider = CGDataProvider(data: data as CFData),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return image }
        return jpeg
    }

    static func imagesToPDF(_ inputs: [URL], ctx: JobContext) async throws -> URL {
        let files = Naming.finderOrder(inputs)
        var images: [CGImage] = []
        for (i, url) in files.enumerated() {
            try Task.checkCancellation()
            images.append(try await ImageEngine.load(url, maxSide: 4000, ctx: ctx))
            ctx.progress(Double(i + 1) / Double(files.count + 1))
        }
        let out = ctx.destination(for: files[0], ext: "pdf", suffix: files.count > 1 ? trf("%d pages", files.count) : nil)
        try writeImagesPDF(images, to: out)
        return out
    }

    // MARK: Pages out

    static func render(_ page: PDFPage, dpi: Int) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let scale = CGFloat(dpi) / 72
        var size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        if rotated { size = NSSize(width: size.height, height: size.width) }
        // Keep giant pages (posters, maps) from exhausting memory.
        let maxSide: CGFloat = 12_000
        if max(size.width, size.height) > maxSide {
            let s = maxSide / max(size.width, size.height)
            size = NSSize(width: size.width * s, height: size.height * s)
        }
        let image = page.thumbnail(of: size, for: .mediaBox)
        var rect = NSRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func toImages(_ input: URL, as target: ImageTarget, ctx: JobContext) async throws -> [URL] {
        let doc = try open(input)
        let count = doc.pageCount
        guard count > 0 else { throw KError.nothingToDo(tr("This PDF has no pages.")) }
        let folder: URL? = count > 1 ? try ctx.folder(for: input, suffix: target.code) : nil
        var outputs: [URL] = []
        let base = input.deletingPathExtension().lastPathComponent
        for i in 0..<count {
            try Task.checkCancellation()
            guard let page = doc.page(at: i), let image = render(page, dpi: ctx.settings.pdfDPI) else { continue }
            let out: URL
            if let folder {
                let digits = String(count).count
                let number = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
                out = folder.appendingPathComponent("\(base) \(number)").appendingPathExtension(target.ext)
            } else {
                out = ctx.destination(for: input, ext: target.ext)
            }
            try await ImageEngine.write(image, as: target, to: out, quality: ctx.settings.imageQuality, ctx: ctx)
            outputs.append(out)
            ctx.progress(Double(i + 1) / Double(count))
        }
        return folder.map { [$0] } ?? outputs
    }

    // MARK: Text out

    /// The PDF's own text layer, or Live Text when the pages are scans.
    static func text(of input: URL, ctx: JobContext) throws -> String {
        let doc = try open(input)
        let own = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if own.count > 20 { return doc.string ?? own }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            if let page = doc.page(at: i), let image = render(page, dpi: 300) {
                pages.append(try ImageEngine.recognizeText(in: image))
            }
            ctx.progress(Double(i + 1) / Double(max(doc.pageCount, 1)))
        }
        return pages.joined(separator: "\n\n")
    }

    static func attributedText(of input: URL) throws -> NSAttributedString {
        let doc = try open(input)
        let result = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let text = page.attributedString else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(text)
        }
        return result
    }

    // MARK: Tools

    static func merge(_ inputs: [URL], ctx: JobContext) async throws -> URL {
        let files = Naming.finderOrder(inputs)
        let merged = PDFDocument()
        for (n, url) in files.enumerated() {
            try Task.checkCancellation()
            if FileKind.of(url) == .pdf {
                let doc = try open(url)
                for i in 0..<doc.pageCount {
                    if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
                }
            } else {
                let image = try await ImageEngine.load(url, maxSide: 4000, ctx: ctx)
                if let page = PDFPage(image: NSImage(cgImage: image, size: .zero)) { merged.insert(page, at: merged.pageCount) }
            }
            ctx.progress(Double(n + 1) / Double(files.count))
        }
        let out = ctx.destination(for: files[0], ext: "pdf", suffix: tr("merged"))
        guard merged.write(to: out) else { throw KError.failed(tr("Couldn't save the PDF.")) }
        return out
    }

    static func split(_ input: URL, ctx: JobContext) async throws -> URL {
        let doc = try open(input)
        guard doc.pageCount > 1 else { throw KError.nothingToDo(tr("This PDF has only one page.")) }
        let folder = try ctx.folder(for: input, suffix: tr("pages"))
        let base = input.deletingPathExtension().lastPathComponent
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            let single = PDFDocument()
            if let page = doc.page(at: i)?.copy() as? PDFPage { single.insert(page, at: 0) }
            single.write(to: folder.appendingPathComponent("\(base) \(i + 1).pdf"))
            ctx.progress(Double(i + 1) / Double(doc.pageCount))
        }
        return folder
    }

    static var canCompress: Bool {
        if #available(macOS 13.4, *) { return true }
        return false
    }

    static func compress(_ input: URL, ctx: JobContext) async throws -> URL {
        let doc = try open(input)
        let out = ctx.destination(for: input, ext: "pdf", suffix: tr("compressed"))
        var options: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.4, *) {
            options[.saveImagesAsJPEGOption] = true
            options[.optimizeImagesForScreenOption] = true
        }
        ctx.progress(0.3)
        guard doc.write(to: out, withOptions: options) else { throw KError.failed(tr("Couldn't save the PDF.")) }
        let before = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if after >= before {
            try? FileManager.default.removeItem(at: out)
            throw KError.nothingToDo(tr("This PDF is already as small as it gets."))
        }
        return out
    }

    static func stripMetadata(_ input: URL, ctx: JobContext) async throws -> URL {
        let doc = try open(input)
        doc.documentAttributes = [:]
        let out = ctx.destination(for: input, ext: "pdf", suffix: tr("no metadata"))
        guard doc.write(to: out) else { throw KError.failed(tr("Couldn't save the PDF.")) }
        return out
    }

    static func rotate(_ input: URL, ctx: JobContext) async throws -> URL {
        let doc = try open(input)
        for i in 0..<doc.pageCount { doc.page(at: i)?.rotation += 90 }
        let out = ctx.destination(for: input, ext: "pdf", suffix: tr("rotated"))
        guard doc.write(to: out) else { throw KError.failed(tr("Couldn't save the PDF.")) }
        return out
    }

    /// Scanned PDF -> same pages with an invisible text layer, so it can be searched and copied from.
    static func makeSearchable(_ input: URL, ctx: JobContext) async throws -> URL {
        let doc = try open(input)
        let out = ctx.destination(for: input, ext: "pdf", suffix: tr("searchable"))
        var box = CGRect.zero
        guard let consumer = CGDataConsumer(url: out as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw KError.failed(tr("Couldn't create the PDF."))
        }
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            var media = page.bounds(for: .mediaBox)
            if page.rotation % 180 != 0 { media = CGRect(x: 0, y: 0, width: media.height, height: media.width) }
            media.origin = .zero
            pdf.beginPage(mediaBox: &media)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
            page.draw(with: .mediaBox, to: pdf)
            NSGraphicsContext.restoreGraphicsState()
            if let image = render(page, dpi: 300) {
                drawInvisibleText(recognize(image), in: media, context: pdf)
            }
            pdf.endPage()
            ctx.progress(Double(i + 1) / Double(doc.pageCount))
        }
        pdf.closePDF()
        return out
    }

    private static func recognize(_ image: CGImage) -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
        try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        return request.results ?? []
    }

    private static func drawInvisibleText(_ lines: [VNRecognizedTextObservation], in page: CGRect, context c: CGContext) {
        c.saveGState()
        c.setTextDrawingMode(.invisible)
        for line in lines {
            guard let text = line.topCandidates(1).first?.string, !text.isEmpty else { continue }
            let box = VNImageRectForNormalizedRect(line.boundingBox, Int(page.width), Int(page.height))
            let font = CTFontCreateWithName("Helvetica" as CFString, max(box.height * 0.85, 1), nil)
            let attr = NSAttributedString(string: text, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attr)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard width > 0 else { continue }
            c.saveGState()
            c.translateBy(x: box.minX, y: box.minY + box.height * 0.15)
            c.scaleBy(x: box.width / CGFloat(width), y: 1)
            c.textPosition = .zero
            CTLineDraw(ctLine, c)
            c.restoreGState()
        }
        c.restoreGState()
    }
}
