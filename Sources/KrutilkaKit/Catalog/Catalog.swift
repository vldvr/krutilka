import AppKit

/// One segment on a wheel.
struct Operation: Identifiable {
    enum Batch {
        /// Run once per file (conversions).
        case each
        /// Run once with every file (merge, AirDrop, checksums).
        case all
        /// Not a job: happens right away on the main thread (copy path, open Terminal).
        case immediate
    }

    let id: String
    let wheel: WheelKind
    let title: String
    /// SF Symbol for tools and actions. Formats show their code instead.
    var symbol: String? = nil
    var hint: String = ""
    var batch: Batch = .each
    var enabled = true
    /// Shown in the hub when the segment is greyed out.
    var disabledReason: String? = nil
    var run: (JobContext) async throws -> [URL] = { _ in [] }
    var perform: @MainActor ([URL]) -> Void = { _ in }
}

/// Builds the segments for a set of files. Order is stable per file type, so a format always sits
/// in the same place on the dial and hands learn where it is.
enum Catalog {
    static func operations(for files: [URL], wheel: WheelKind) -> [Operation] {
        guard !files.isEmpty else { return [] }
        switch wheel {
        case .actions: return actions(files)
        case .convert, .tools:
            let kinds = files.map(FileKind.of).reduce(into: [FileKind]()) { if !$0.contains($1) { $0.append($1) } }
            var perKind: [FileKind: [Operation]] = [:]
            for kind in kinds {
                let sample = files.first { FileKind.of($0) == kind }!
                let sameKind = files.filter { FileKind.of($0) == kind }
                perKind[kind] = wheel == .convert ? conversions(kind, sample: sample) : tools(kind, files: sameKind)
            }
            var ops = mixed(perKind, order: kinds)
            if wheel == .convert {
                // Grey out a format only when every file already is that format.
                ops = ops.map { op in
                    var op = op
                    if files.allSatisfy({ isAlready($0, op.id) }) {
                        op.enabled = false
                        op.disabledReason = trf("Already %@", op.title)
                    }
                    return op
                }
            }
            return ops.filter { op in
                // Joining needs at least two files.
                if ["join", "pdfmerge"].contains(op.id) { return files.count >= 2 }
                return true
            }
        }
    }

    /// Segments for a selection of several file types: only those every type has, and each file is
    /// handled by its own type's implementation ("Compress" on a photo and a video does two different
    /// things). Whole-batch jobs survive only where one implementation takes every type.
    static func mixed(_ perKind: [FileKind: [Operation]], order: [FileKind]) -> [Operation] {
        guard let first = order.first, var base = perKind[first] else { return [] }
        if order.count == 1 { return base }
        let mixable: Set<String> = ["pdfmerge", "stats"]
        base = base.filter { op in order.allSatisfy { kind in perKind[kind]?.contains { $0.id == op.id } ?? false } }
        return base.compactMap { op in
            switch op.batch {
            case .each:
                var combined = op
                let byKind = perKind.mapValues { list in list.first { $0.id == op.id } }
                combined.run = { ctx in
                    guard let own = byKind[FileKind.of(ctx.input)] ?? nil else { return [] }
                    return try await own.run(ctx)
                }
                return combined
            case .all:
                return mixable.contains(op.id) ? op : nil
            case .immediate:
                return nil
            }
        }
    }

    static func isAlready(_ url: URL, _ id: String) -> Bool {
        let ext = url.pathExtension.lowercased()
        let normalized: String
        switch ext {
        case "jpg", "jpeg": normalized = "jpeg"
        case "tif", "tiff": normalized = "tiff"
        case "htm", "html": normalized = "html"
        case "heif", "heic": normalized = "heic"
        case "markdown", "md": normalized = "md"
        case "aif", "aiff": normalized = "aiff"
        default: normalized = ext
        }
        if id == "tgz" { return url.lastPathComponent.lowercased().hasSuffix(".tar.gz") || ext == "tgz" }
        return normalized == id
    }

    // MARK: Formats

    private static func code(_ id: String) -> Operation {
        Operation(id: id, wheel: .convert, title: id == "jpeg" ? "JPG" : id == "tgz" ? "TAR.GZ" : id.uppercased())
    }

    static func conversions(_ kind: FileKind, sample: URL) -> [Operation] {
        let tools = ExternalTools.shared
        var ops: [Operation] = []

        func add(_ id: String, hint: String = "", when available: Bool = true, _ run: @escaping (URL, JobContext) async throws -> [URL]) {
            guard available else { return }
            var op = code(id)
            op.hint = hint
            op.run = { ctx in
                // Files already in the target format are skipped, not re-encoded.
                if isAlready(ctx.input, id) { return [] }
                return try await run(ctx.input, ctx)
            }
            ops.append(op)
        }

        switch kind {
        case .image, .svg:
            let order: [ImageTarget] = kind == .svg ? [.png, .jpeg, .pdf, .webp, .heic, .tiff]
                : [.png, .jpeg, .heic, .webp, .avif, .pdf, .tiff, .gif, .bmp, .ico]
            for t in order {
                add(t.rawValue, hint: imageHint(t), when: t.isAvailable) { url, ctx in
                    [try await ImageEngine.convert(url, to: t, ctx: ctx)]
                }
            }
        case .pdf:
            add("png", hint: tr("Every page as a picture")) { url, ctx in try await PDFEngine.toImages(url, as: .png, ctx: ctx) }
            add("jpeg", hint: tr("Every page as a picture")) { url, ctx in try await PDFEngine.toImages(url, as: .jpeg, ctx: ctx) }
            for t in [DocTarget.docx, .txt, .md, .rtf, .html] {
                add(t.rawValue, hint: t == .txt ? tr("Scans are read with Live Text") : tr("Text and basic formatting")) { url, ctx in
                    let out = ctx.destination(for: url, ext: t.ext)
                    if t == .txt || t == .md {
                        try PDFEngine.text(of: url, ctx: ctx).write(to: out, atomically: true, encoding: .utf8)
                    } else {
                        try await DocumentEngine.write(try PDFEngine.attributedText(of: url), as: t, to: out, ctx: ctx)
                    }
                    return [out]
                }
            }
            add("epub", hint: tr("E-book"), when: tools.has(.pandoc)) { url, ctx in
                let md = try ctx.scratch().appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".md")
                try PDFEngine.text(of: url, ctx: ctx).write(to: md, atomically: true, encoding: .utf8)
                let out = ctx.destination(for: url, ext: "epub")
                try await Shell.run(try tools.require(.pandoc), [md.path, "-o", out.path, "--metadata", "title=\(url.deletingPathExtension().lastPathComponent)"])
                return [out]
            }
        case .document, .markdown:
            let order: [DocTarget] = kind == .markdown ? [.pdf, .docx, .html, .txt, .rtf, .odt, .epub]
                : [.pdf, .docx, .txt, .md, .rtf, .html, .odt, .epub, .doc]
            for t in order where DocumentEngine.canProduce(t, from: sample) {
                add(t.rawValue, hint: docHint(t)) { url, ctx in [try await DocumentEngine.convert(url, to: t, ctx: ctx)] }
            }
        case .slides:
            guard OfficeEngine.available else { break }
            add("pdf", hint: tr("One page per slide")) { url, ctx in [try await OfficeEngine.convertBeside(url, filter: "pdf", ext: "pdf", ctx: ctx)] }
            add("pptx", hint: "PowerPoint") { url, ctx in [try await OfficeEngine.convertBeside(url, filter: "pptx", ext: "pptx", ctx: ctx)] }
            for t in [ImageTarget.png, .jpeg] {
                add(t.rawValue, hint: tr("Every slide as a picture")) { url, ctx in
                    let pdf = try await OfficeEngine.convert(url, filter: "pdf", ext: "pdf", ctx: ctx)
                    let renamed = pdf.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")
                    if renamed != pdf { try? FileManager.default.moveItem(at: pdf, to: renamed) }
                    let images = try await PDFEngine.toImages(renamed, as: t, ctx: ctx.redirected(to: url))
                    return images
                }
            }
            add("odp", hint: "LibreOffice Impress") { url, ctx in [try await OfficeEngine.convertBeside(url, filter: "odp", ext: "odp", ctx: ctx)] }
        case .sheet, .table, .json:
            let order: [TableTarget]
            switch kind {
            case .json: order = [.csv, .xlsx, .tsv, .html]
            case .table: order = [.xlsx, .csv, .tsv, .json, .pdf, .ods, .html]
            default: order = [.csv, .xlsx, .pdf, .tsv, .json, .ods, .html]
            }
            guard TableEngine.canRead(sample) else { break }
            for t in order where !t.needsOffice || OfficeEngine.available {
                if t == .xlsx, kind == .sheet, !OfficeEngine.available { continue }
                add(t.rawValue, hint: tableHint(t)) { url, ctx in [try await TableEngine.convert(url, to: t, ctx: ctx)] }
            }
        case .audio:
            guard AudioEngine.canRead(sample) else { break }
            for t in AudioTarget.allCases where t.isAvailable {
                add(t.rawValue, hint: t.hint) { url, ctx in [try await AudioEngine.convert(url, to: t, ctx: ctx)] }
            }
        case .video:
            guard VideoEngine.canRead(sample) else { break }
            for t in VideoTarget.allCases where t.isAvailable {
                add(t.rawValue, hint: t.hint) { url, ctx in [try await VideoEngine.convert(url, to: t, ctx: ctx)] }
            }
        case .archive:
            var unpack = Operation(id: "unpack", wheel: .convert, title: tr("Unpack"), symbol: "shippingbox.and.arrow.backward",
                               hint: tr("Into a folder next to it"))
            unpack.run = { ctx in [try await ArchiveEngine.extract(ctx.input, ctx: ctx)] }
            ops.append(unpack)
            for t in [ArchiveTarget.zip, .tgz, .tar] {
                add(t == .tgz ? "tgz" : t.rawValue, hint: tr("Same files, other archive")) { url, ctx in
                    [try await ArchiveEngine.repack(url, as: t, ctx: ctx)]
                }
            }
        case .subtitle:
            for ext in ["srt", "vtt", "txt"] {
                add(ext, hint: ext == "txt" ? tr("Just the lines, no timing") : tr("Subtitles")) { url, ctx in
                    [try await SubtitleEngine.convert(url, to: ext, ctx: ctx)]
                }
            }
        case .folder:
            for t in [ArchiveTarget.zip, .tgz] {
                add(t == .tgz ? "tgz" : t.rawValue, hint: tr("Pack the folder")) { url, ctx in
                    [try await ArchiveEngine.pack([url], as: t, ctx: ctx)]
                }
            }
        case .other:
            break
        }
        return ops
    }

    private static func imageHint(_ t: ImageTarget) -> String {
        switch t {
        case .png: return tr("Lossless, keeps transparency")
        case .jpeg: return tr("Photos, opens everywhere")
        case .heic: return tr("Half the size of JPEG")
        case .webp: return tr("Small, for the web")
        case .avif: return tr("Smallest, modern browsers")
        case .pdf: return tr("One page per picture")
        case .tiff: return tr("For print and archives")
        case .gif: return tr("256 colours")
        case .bmp: return tr("Uncompressed bitmap")
        case .ico: return tr("Windows icon, 256 px")
        }
    }

    private static func docHint(_ t: DocTarget) -> String {
        switch t {
        case .pdf: return ExternalTools.shared.has(.soffice) ? tr("Exact layout via LibreOffice") : tr("A4 pages")
        case .docx: return "Microsoft Word"
        case .doc: return "Word 97–2004"
        case .txt: return tr("Plain text, UTF-8")
        case .md: return "Markdown"
        case .rtf: return tr("Rich text")
        case .html: return tr("Web page")
        case .odt: return "OpenDocument"
        case .epub: return tr("E-book")
        }
    }

    private static func tableHint(_ t: TableTarget) -> String {
        switch t {
        case .xlsx: return "Excel"
        case .csv: return tr("Comma-separated, UTF-8")
        case .tsv: return tr("Tab-separated")
        case .json: return tr("Records with the header as keys")
        case .pdf: return tr("Printable table")
        case .ods: return "OpenDocument"
        case .html: return tr("Web table")
        }
    }

    // MARK: Tools

    static func tools(_ kind: FileKind, files: [URL]) -> [Operation] {
        let s = Prefs.shared
        var ops: [Operation] = []
        func tool(_ id: String, _ title: String, _ symbol: String, hint: String, batch: Operation.Batch = .each,
                  _ run: @escaping (JobContext) async throws -> [URL]) {
            ops.append(Operation(id: id, wheel: .tools, title: title, symbol: symbol, hint: hint, batch: batch, run: run))
        }
        let compressHint = trf("Quality %d%%", Int(s.compressQuality * 100))
        let stripHint = tr("Removes location, camera and dates")

        switch kind {
        case .image:
            ops.append(Operation(id: "edit", wheel: .tools, title: tr("Edit"), symbol: "crop",
                                 hint: tr("Crop, pixelate or black out parts"), batch: .immediate, perform: { urls in PhotoEditorController.show(urls[0]) }))
            tool("compress", tr("Compress"), "arrow.down.right.and.arrow.up.left", hint: compressHint) { [try await ImageEngine.compress($0.input, ctx: $0)] }
            tool("fit", trf("Under %@", sizeLabel(s.targetSizeMB)), "gauge.with.dots.needle.33percent", hint: tr("Lowers quality, then size, until it fits")) {
                [try await ImageEngine.fitToSize($0.input, ctx: $0)]
            }
            tool("half", tr("Half size"), "arrow.down.left.and.arrow.up.right.square", hint: tr("Half the width and height")) { [try await ImageEngine.resizeHalf($0.input, ctx: $0)] }
            if #available(macOS 14.0, *) {
                tool("nobg", tr("Remove background"), "person.crop.rectangle", hint: tr("Cuts out the subject, saves PNG")) { [try await ImageEngine.removeBackground($0.input, ctx: $0)] }
            }
            tool("ocr", tr("Get text"), "text.viewfinder", hint: tr("Live Text to a file and the clipboard")) { [try await ImageEngine.ocr($0.input, ctx: $0)] }
            tool("strip", tr("No metadata"), "eye.slash", hint: stripHint) { [try await ImageEngine.stripMetadata($0.input, ctx: $0)] }
            tool("rotate", tr("Rotate"), "rotate.right", hint: tr("90° clockwise")) { [try await ImageEngine.rotate($0.input, ctx: $0)] }
            tool("pdfmerge", tr("One PDF"), "doc.on.doc", hint: tr("All pictures in name order"), batch: .all) {
                [try await PDFEngine.merge($0.inputs, ctx: $0)]
            }
            tool("qr", tr("Read QR"), "qrcode.viewfinder", hint: tr("Copies what the code says")) { try await ImageEngine.readQR($0.input, ctx: $0) }
            for recipe in s.recipes where recipe.enabled && recipe.kind == .image {
                tool("recipe.\(recipe.id)", recipe.name, "wand.and.stars", hint: recipe.summary) { [try await ImageEngine.applyRecipe(recipe, to: $0.input, ctx: $0)] }
            }
        case .pdf:
            if PDFEngine.canCompress {
                tool("compress", tr("Compress"), "arrow.down.right.and.arrow.up.left", hint: tr("Recompresses images inside")) { [try await PDFEngine.compress($0.input, ctx: $0)] }
            }
            tool("pdfmerge", tr("Merge"), "doc.on.doc", hint: tr("One PDF in name order"), batch: .all) { [try await PDFEngine.merge($0.inputs, ctx: $0)] }
            tool("split", tr("Split"), "rectangle.split.3x1", hint: tr("One file per page")) { [try await PDFEngine.split($0.input, ctx: $0)] }
            tool("searchable", tr("Searchable"), "doc.text.magnifyingglass", hint: tr("Adds a text layer to scans")) { [try await PDFEngine.makeSearchable($0.input, ctx: $0)] }
            tool("ocr", tr("Get text"), "text.viewfinder", hint: tr("Text to a file and the clipboard")) { ctx in
                let text = try PDFEngine.text(of: ctx.input, ctx: ctx)
                let out = ctx.destination(for: ctx.input, ext: "txt", suffix: tr("text"))
                try text.write(to: out, atomically: true, encoding: .utf8)
                Clipboard.copy(text)
                ctx.note = tr("Text copied")
                return [out]
            }
            tool("strip", tr("No metadata"), "eye.slash", hint: tr("Removes author, title and app")) { [try await PDFEngine.stripMetadata($0.input, ctx: $0)] }
            tool("rotate", tr("Rotate"), "rotate.right", hint: tr("Every page 90° clockwise")) { [try await PDFEngine.rotate($0.input, ctx: $0)] }
            tool("stats", tr("Count words"), "number", hint: tr("Words and characters"), batch: .all) { try await DocumentEngine.stats($0.inputs, ctx: $0) }
        case .document, .markdown:
            tool("stats", tr("Count words"), "number", hint: tr("Words and characters"), batch: .all) { try await DocumentEngine.stats($0.inputs, ctx: $0) }
            tool("join", tr("Join"), "doc.on.doc", hint: tr("One Word file in name order"), batch: .all) { [try await DocumentEngine.join($0.inputs, ctx: $0)] }
        case .audio:
            guard AudioEngine.canRead(files[0]) else { break }
            ops.append(Operation(id: "trim", wheel: .tools, title: tr("Trim"), symbol: "timeline.selection",
                                 hint: tr("Pick the part to keep"), batch: .immediate, perform: { urls in TrimController.show(urls[0]) }))
            ops.append(Operation(id: "cut", wheel: .tools, title: tr("Split"), symbol: "scissors",
                                 hint: tr("Into parts at the points you mark"), batch: .immediate, perform: { urls in SplitController.show(urls[0]) }))
            tool("compress", tr("Compress"), "arrow.down.right.and.arrow.up.left", hint: "96 kbps") { [try await AudioEngine.compress($0.input, ctx: $0)] }
            tool("normalize", tr("Normalize"), "waveform.path", hint: tr("Even loudness, −16 LUFS")) { [try await AudioEngine.normalize($0.input, ctx: $0)] }
            tool("mono", tr("Mono"), "speaker.wave.1", hint: tr("Both channels into one")) { [try await AudioEngine.mono($0.input, ctx: $0)] }
            if ExternalTools.shared.has(.ffmpeg) {
                tool("strip", tr("No metadata"), "eye.slash", hint: tr("Removes tags and cover art")) { [try await AudioEngine.stripMetadata($0.input, ctx: $0)] }
            }
            tool("join", tr("Join"), "link", hint: tr("One track in name order"), batch: .all) { [try await AudioEngine.join($0.inputs, ctx: $0)] }
        case .video:
            guard VideoEngine.canRead(files[0]) else { break }
            let videoHint: String = {
                switch s.videoQuality {
                case .p720: return "720p, MP4"
                case .p1080: return "1080p, MP4"
                case .original: return tr("Same size, HEVC")
                }
            }()
            ops.append(Operation(id: "trim", wheel: .tools, title: tr("Trim"), symbol: "timeline.selection",
                                 hint: tr("Pick the part to keep, no re-encoding"), batch: .immediate, perform: { urls in TrimController.show(urls[0]) }))
            ops.append(Operation(id: "cut", wheel: .tools, title: tr("Split"), symbol: "scissors",
                                 hint: tr("Into parts at the points you mark"), batch: .immediate, perform: { urls in SplitController.show(urls[0]) }))
            tool("compress", tr("Compress"), "arrow.down.right.and.arrow.up.left", hint: videoHint) { [try await VideoEngine.compress($0.input, ctx: $0)] }
            tool("mute", tr("No sound"), "speaker.slash", hint: tr("Removes the audio track")) { [try await VideoEngine.mute($0.input, ctx: $0)] }
            tool("snapshot", tr("Frame"), "camera.viewfinder", hint: tr("The middle frame as JPEG")) { [try await VideoEngine.snapshot($0.input, ctx: $0)] }
            tool("speed", "2×", "hare", hint: tr("Twice as fast, same pitch")) { [try await VideoEngine.speedUp($0.input, ctx: $0)] }
            tool("rotate", tr("Rotate"), "rotate.right", hint: tr("90° clockwise, no re-encoding")) { [try await VideoEngine.rotate($0.input, ctx: $0)] }
            tool("strip", tr("No metadata"), "eye.slash", hint: tr("Removes location and device")) { [try await VideoEngine.stripMetadata($0.input, ctx: $0)] }
            tool("join", tr("Join"), "film.stack", hint: tr("One video in name order"), batch: .all) { [try await VideoEngine.join($0.inputs, ctx: $0)] }
            for recipe in s.recipes where recipe.enabled && recipe.kind == .video {
                tool("recipe.\(recipe.id)", recipe.name, "wand.and.stars", hint: recipe.summary) { [try await VideoEngine.applyRecipe(recipe, to: $0.input, ctx: $0)] }
            }
        default:
            break
        }
        return ops
    }

    static func sizeLabel(_ mb: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(mb * 1_000_000), countStyle: .file)
    }

    // MARK: Actions

    static func actions(_ files: [URL]) -> [Operation] {
        func now(_ id: String, _ title: String, _ symbol: String, hint: String, _ perform: @escaping @MainActor ([URL]) -> Void) -> Operation {
            Operation(id: id, wheel: .actions, title: title, symbol: symbol, hint: hint, batch: .immediate, perform: perform)
        }
        let terminalName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Prefs.shared.terminalApp)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "Terminal"
        return [
            now("airdrop", "AirDrop", "airplayaudio", hint: tr("Send to a nearby device")) { urls in FileActions.airDrop(urls) },
            now("shelf", tr("Shelf"), "tray.and.arrow.down", hint: tr("Keep it floating, drag out later")) { urls in ShelfController.shared.add(urls) },
            now("copyto", tr("Copy to…"), "doc.on.doc", hint: tr("Pick a folder")) { urls in FileActions.transfer(urls, move: false) },
            now("moveto", tr("Move to…"), "folder", hint: tr("Pick a folder")) { urls in FileActions.transfer(urls, move: true) },
            now("path", tr("Copy path"), "link", hint: tr("Full path to the clipboard")) { urls in FileActions.copyPaths(urls) },
            now("terminal", tr("Terminal"), "terminal", hint: trf("Open %@ in this folder", terminalName)) { urls in FileActions.openTerminal(urls) },
            Operation(id: "zip", wheel: .actions, title: "ZIP", symbol: "archivebox", hint: tr("Pack into an archive"), batch: .all) { ctx in
                [try await ArchiveEngine.pack(ctx.inputs, as: .zip, ctx: ctx)]
            },
            Operation(id: "sha", wheel: .actions, title: "SHA-256", symbol: "number.square", hint: tr("Checksum to the clipboard"), batch: .all) { ctx in
                try await Hashing.run(ctx.inputs, ctx: ctx)
            },
            now("quicklook", tr("Quick Look"), "eye", hint: tr("Preview without opening")) { urls in FileActions.quickLook(urls) },
            now("clipboard", tr("Copy file"), "doc.on.clipboard", hint: tr("Paste it anywhere with ⌘V")) { urls in FileActions.copyToClipboard(urls) },
        ]
    }
}
