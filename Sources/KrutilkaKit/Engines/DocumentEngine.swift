import AppKit
import CoreText

enum DocTarget: String, CaseIterable {
    case pdf, docx, txt, md, rtf, html, odt, epub, doc

    var ext: String { rawValue }
    var code: String { rawValue.uppercased() }

    static func of(_ url: URL) -> DocTarget? {
        switch url.pathExtension.lowercased() {
        case "htm": return .html
        case "markdown": return .md
        case "text": return .txt
        default: return DocTarget(rawValue: url.pathExtension.lowercased())
        }
    }
}

/// Text documents. Native NSAttributedString covers Word, RTF, ODT, HTML and plain text;
/// pandoc adds EPUB and proper Markdown; LibreOffice gives a faithful Word to PDF and opens Pages.
enum DocumentEngine {
    static let pandocInputs: Set<String> = ["md", "markdown", "docx", "odt", "html", "htm", "epub", "rtf", "txt"]

    static func canProduce(_ target: DocTarget, from input: URL) -> Bool {
        let ext = input.pathExtension.lowercased()
        let tools = ExternalTools.shared
        if ext == "pages" { return tools.has(.soffice) && [.pdf, .docx, .txt, .rtf, .odt, .html, .doc].contains(target) }
        if ext == "epub" { return tools.has(.pandoc) && target != .epub }
        if target == .epub { return tools.has(.pandoc) && pandocInputs.contains(ext) }
        return true
    }

    static func convert(_ input: URL, to target: DocTarget, ctx: JobContext) async throws -> URL {
        let ext = input.pathExtension.lowercased()
        let tools = ExternalTools.shared

        // LibreOffice keeps layout, images and tables when making a PDF or opening Pages.
        if tools.has(.soffice), ext == "pages" || (target == .pdf && ["docx", "doc", "odt", "rtf"].contains(ext)) {
            let filter = target == .txt ? "txt:Text (encoded):UTF8" : target.rawValue
            return try await OfficeEngine.convertBeside(input, filter: filter, ext: target.ext, ctx: ctx)
        }

        // Markdown to PDF: pandoc lays it out as Word, LibreOffice prints it. Proper headings, lists, tables.
        if target == .pdf, ["md", "markdown"].contains(ext), let pandoc = tools.url(.pandoc), tools.has(.soffice) {
            let docx = try ctx.scratch().appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".docx")
            try await Shell.run(pandoc, [input.path, "-f", "gfm", "-o", docx.path], cwd: input.deletingLastPathComponent())
            let produced = try await OfficeEngine.convert(docx, filter: "pdf", ext: "pdf", ctx: ctx)
            let out = ctx.destination(for: input, ext: "pdf")
            try FileManager.default.moveItem(at: produced, to: out)
            return out
        }

        // pandoc is the better path whenever Markdown or EPUB is on either side.
        if let pandoc = tools.url(.pandoc), target != .pdf, target != .doc,
           pandocInputs.contains(ext), [ext, target.rawValue].contains(where: { ["md", "markdown", "epub"].contains($0) }) {
            let out = ctx.destination(for: input, ext: target.ext)
            var args = [input.path, "-o", out.path, "--standalone"]
            if ext == "md" || ext == "markdown" { args += ["-f", "gfm"] }
            if target == .md { args += ["-t", "gfm"] }
            if target == .txt { args += ["-t", "plain"] }
            try await Shell.run(pandoc, args, cwd: input.deletingLastPathComponent())
            return out
        }

        let text = try await read(input, ctx: ctx)
        ctx.progress(0.5)
        let out = ctx.destination(for: input, ext: target.ext)
        do {
            try await write(text, as: target, to: out, ctx: ctx)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    // MARK: Reading

    static func read(_ url: URL, ctx: JobContext) async throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown":
            let source = try String(contentsOf: url, encoding: .utf8)
            return Markdown.attributed(from: source)
        case "pdf":
            return try PDFEngine.attributedText(of: url)
        case "pages":
            let docx = try await OfficeEngine.convert(url, filter: "docx", ext: "docx", ctx: ctx)
            return try await read(docx, ctx: ctx)
        case "epub":
            let pandoc = try ExternalTools.shared.require(.pandoc)
            let html = try ctx.scratch().appendingPathComponent("book.html")
            try await Shell.run(pandoc, [url.path, "-o", html.path, "--standalone"])
            return try await read(html, ctx: ctx)
        default:
            let type: NSAttributedString.DocumentType
            switch ext {
            case "docx": type = .officeOpenXML
            case "doc": type = .docFormat
            case "odt": type = .openDocument
            case "rtf": type = .rtf
            case "rtfd": type = .rtfd
            case "html", "htm": type = .html
            case "webarchive": type = .webArchive
            default: type = .plain
            }
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
            if type == .plain || type == .html { options[.characterEncoding] = String.Encoding.utf8.rawValue }
            // HTML and web archives are parsed with WebKit, which wants the main thread.
            if type == .html || type == .webArchive {
                let readOptions = Unchecked(value: options)
                return try await MainActor.run {
                    Unchecked(value: try NSAttributedString(url: url, options: readOptions.value, documentAttributes: nil))
                }.value
            }
            do {
                return try NSAttributedString(url: url, options: options, documentAttributes: nil)
            } catch where type == .plain {
                let text = try String(contentsOf: url, encoding: .windowsCP1251)
                return NSAttributedString(string: text)
            }
        }
    }

    // MARK: Writing

    static func write(_ text: NSAttributedString, as target: DocTarget, to out: URL, ctx: JobContext) async throws {
        let range = NSRange(location: 0, length: text.length)
        switch target {
        case .txt:
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        case .md:
            try Markdown.markdown(from: text).write(to: out, atomically: true, encoding: .utf8)
        case .pdf:
            try renderPDF(text, to: out)
        case .epub:
            let pandoc = try ExternalTools.shared.require(.pandoc)
            let html = try ctx.scratch().appendingPathComponent("doc.html")
            try await write(text, as: .html, to: html, ctx: ctx)
            try await Shell.run(pandoc, [html.path, "-o", out.path, "--standalone"])
        default:
            let type: NSAttributedString.DocumentType
            switch target {
            case .docx: type = .officeOpenXML
            case .doc: type = .docFormat
            case .odt: type = .openDocument
            case .rtf: type = .rtf
            default: type = .html
            }
            let text = portableFonts(text)
            var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if type == .html {
                attrs[.characterEncoding] = String.Encoding.utf8.rawValue
                attrs[.excludedElements] = ["XML", "DOCTYPE"]
            }
            let data = try text.data(from: range, documentAttributes: attrs)
            try data.write(to: out)
        }
    }

    /// System UI fonts have private names (".SFNS…") that Word and LibreOffice don't know.
    /// Swap them for real families with the same weight and slant.
    static func portableFonts(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.enumerateAttribute(.font, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let font = value as? NSFont, font.fontName.hasPrefix(".") else { return }
            let traits = font.fontDescriptor.symbolicTraits
            let family = traits.contains(.monoSpace) ? "Menlo" : "Helvetica Neue"
            var replacement = NSFont(name: family, size: font.pointSize) ?? NSFont.userFont(ofSize: font.pointSize)!
            let wanted = traits.intersection([.bold, .italic])
            if !wanted.isEmpty {
                let d = replacement.fontDescriptor.withSymbolicTraits(wanted)
                replacement = NSFont(descriptor: d, size: font.pointSize) ?? replacement
            }
            out.addAttribute(.font, value: replacement, range: range)
        }
        return out
    }

    /// Paginates onto A4 with CoreText. Text without a font gets the system font at 12 pt.
    static func renderPDF(_ text: NSAttributedString, to out: URL) throws {
        let styled = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: styled.length)
        styled.enumerateAttribute(.font, in: full) { value, range, _ in
            if value == nil { styled.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range) }
        }
        styled.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if value == nil { styled.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let frameRect = page.insetBy(dx: 64, dy: 64)
        guard let consumer = CGDataConsumer(url: out as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: &page, nil) else {
            throw KError.failed(tr("Couldn't create the PDF."))
        }
        let setter = CTFramesetterCreateWithAttributedString(styled)
        var start = 0
        repeat {
            pdf.beginPage(mediaBox: &page)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, pdf)
            let visible = CTFrameGetVisibleStringRange(frame)
            pdf.endPage()
            if visible.length == 0 { break }
            start += visible.length
        } while start < styled.length
        pdf.closePDF()
    }

    /// Words and characters, copied for pasting into a form.
    static func stats(_ inputs: [URL], ctx: JobContext) async throws -> [URL] {
        var words = 0, chars = 0
        for url in inputs {
            let text = FileKind.of(url) == .pdf ? try PDFEngine.text(of: url, ctx: ctx) : try await read(url, ctx: ctx).string
            chars += text.count
            words += text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        }
        let summary = trf("%d words, %d characters", words, chars)
        Clipboard.copy("\(words)")
        ctx.note = summary
        return []
    }

    static func join(_ inputs: [URL], ctx: JobContext) async throws -> URL {
        let files = Naming.finderOrder(inputs)
        let merged = NSMutableAttributedString()
        for (i, url) in files.enumerated() {
            if merged.length > 0 { merged.append(NSAttributedString(string: "\n\n")) }
            merged.append(try await read(url, ctx: ctx))
            ctx.progress(Double(i + 1) / Double(files.count + 1))
        }
        let out = ctx.destination(for: files[0], ext: "docx", suffix: tr("merged"))
        try await write(merged, as: .docx, to: out, ctx: ctx)
        return out
    }
}

/// Minimal Markdown <-> attributed text for when pandoc isn't installed.
enum Markdown {
    static func attributed(from source: String) -> NSAttributedString {
        let body = NSFont(name: "Helvetica Neue", size: 12) ?? NSFont.systemFont(ofSize: 12)
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return NSAttributedString(string: source, attributes: [.font: body])
        }
        let out = NSMutableAttributedString()
        var lastBlock: Int?
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var font = body
            var color = NSColor.black
            var prefix = ""
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 8
            style.lineHeightMultiple = 1.15
            if let intent = run.presentationIntent {
                let block = intent.components.first?.identity ?? 0
                if let last = lastBlock, last != block { out.append(NSAttributedString(string: "\n")) }
                let starting = lastBlock != block
                lastBlock = block
                var depth = 0
                for component in intent.components {
                    switch component.kind {
                    case .header(let level):
                        let size: CGFloat = [22, 17, 14, 13, 12, 12][min(level, 6) - 1]
                        font = NSFont(name: "Helvetica Neue Bold", size: size) ?? NSFont.boldSystemFont(ofSize: size)
                        style.paragraphSpacingBefore = level == 1 ? 6 : 10
                        style.paragraphSpacing = 6
                    case .codeBlock:
                        font = NSFont(name: "Menlo", size: 10.5) ?? NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
                        style.headIndent = 14; style.firstLineHeadIndent = 14
                        color = NSColor(white: 0.25, alpha: 1)
                    case .blockQuote:
                        style.headIndent = 18; style.firstLineHeadIndent = 18
                        color = NSColor(white: 0.38, alpha: 1)
                    case .listItem(let ordinal):
                        depth += 1
                        style.paragraphSpacing = 3
                        if starting {
                            let ordered = intent.components.contains { if case .orderedList = $0.kind { return true } else { return false } }
                            prefix = ordered ? "\(ordinal).\t" : "•\t"
                        }
                    default: break
                    }
                }
                if depth > 0 {
                    let indent = CGFloat(depth) * 18
                    style.headIndent = indent
                    style.firstLineHeadIndent = indent - 14
                    style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                }
            }
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) { font = NSFont(name: "Menlo", size: font.pointSize - 1) ?? font }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if inline.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: prefix + text, attributes: attrs))
        }
        return out
    }

    static func markdown(from text: NSAttributedString) -> String {
        let baseSize: CGFloat = {
            var sizes: [CGFloat: Int] = [:]
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { v, r, _ in
                if let f = v as? NSFont { sizes[f.pointSize, default: 0] += r.length }
            }
            return sizes.max { $0.value < $1.value }?.key ?? 12
        }()
        var lines: [String] = []
        let ns = text.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0 else { lines.append(""); return }
            var line = ""
            var headerLevel = 0
            text.enumerateAttributes(in: range) { attrs, r, _ in
                var piece = ns.substring(with: r)
                let font = attrs[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                if let f = font, r.location == range.location {
                    let ratio = f.pointSize / baseSize
                    headerLevel = ratio >= 1.6 ? 1 : ratio >= 1.3 ? 2 : ratio >= 1.12 && traits.contains(.bold) ? 3 : 0
                }
                if headerLevel == 0, !piece.trimmingCharacters(in: .whitespaces).isEmpty {
                    if traits.contains(.bold) && traits.contains(.italic) { piece = "***\(piece)***" }
                    else if traits.contains(.bold) { piece = "**\(piece)**" }
                    else if traits.contains(.italic) { piece = "*\(piece)*" }
                }
                if let link = attrs[.link] { piece = "[\(piece)](\(link))" }
                line += piece
            }
            if headerLevel > 0 { line = String(repeating: "#", count: headerLevel) + " " + line }
            else if line.hasPrefix("• ") || line.hasPrefix("◦ ") || line.hasPrefix("•\t") { line = "- " + line.dropFirst(2) }
            lines.append(line)
        }
        return lines.joined(separator: "\n\n").replacingOccurrences(of: "\n\n\n\n", with: "\n\n") + "\n"
    }
}
