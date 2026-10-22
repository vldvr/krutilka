import Foundation

enum TableTarget: String, CaseIterable {
    case xlsx, csv, tsv, json, ods, pdf, html

    var ext: String { rawValue }
    var code: String { rawValue.uppercased() }
    var needsOffice: Bool { self == .ods || self == .pdf }
}

/// CSV, TSV, JSON and XLSX natively (a small OOXML reader and writer); ODS, XLS, Numbers and PDF via LibreOffice.
enum TableEngine {
    static func canRead(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["csv", "tsv", "json", "xlsx"].contains(ext) || OfficeEngine.available
    }

    static func convert(_ input: URL, to target: TableTarget, ctx: JobContext) async throws -> URL {
        let ext = input.pathExtension.lowercased()
        if target.needsOffice || (target == .xlsx && !["csv", "tsv", "json"].contains(ext)) {
            var source = input
            if ext == "json" || ext == "tsv" {
                // LibreOffice reads CSV reliably; hand it one.
                source = try ctx.scratch().appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".csv")
                try csvString(try await rows(of: input, ctx: ctx), separator: ",").write(to: source, atomically: true, encoding: .utf8)
            }
            let produced = try await OfficeEngine.convert(source, filter: target.rawValue, ext: target.ext, ctx: ctx)
            let out = ctx.destination(for: input, ext: target.ext)
            try FileManager.default.moveItem(at: produced, to: out)
            return out
        }
        let table = try await rows(of: input, ctx: ctx)
        ctx.progress(0.5)
        let out = ctx.destination(for: input, ext: target.ext)
        switch target {
        case .csv: try csvString(table, separator: ",").write(to: out, atomically: true, encoding: .utf8)
        case .tsv: try csvString(table, separator: "\t").write(to: out, atomically: true, encoding: .utf8)
        case .json: try jsonData(table).write(to: out)
        case .html: try htmlString(table, title: input.deletingPathExtension().lastPathComponent).write(to: out, atomically: true, encoding: .utf8)
        case .xlsx: try await XLSX.write(table, to: out, ctx: ctx)
        case .ods, .pdf: break
        }
        return out
    }

    // MARK: Reading

    static func rows(of url: URL, ctx: JobContext) async throws -> [[String]] {
        switch url.pathExtension.lowercased() {
        case "csv":
            let text = try readText(url)
            return parseDelimited(text, separator: guessSeparator(text))
        case "tsv":
            return parseDelimited(try readText(url), separator: "\t")
        case "json":
            return try rowsFromJSON(Data(contentsOf: url))
        case "xlsx":
            return try await XLSX.read(url)
        default:
            let csv = try await OfficeEngine.convert(url, filter: OfficeEngine.csvFilter, ext: "csv", ctx: ctx)
            return parseDelimited(try readText(csv), separator: ",")
        }
    }

    private static func readText(_ url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return try String(contentsOf: url, encoding: .windowsCP1251)
    }

    /// Excel in Russian and German locales writes `;`. Pick whichever appears more on the first line.
    static func guessSeparator(_ text: String) -> Character {
        let first = text.prefix { $0 != "\n" }
        let counts: [(Character, Int)] = [",", ";", "\t"].map { c in (c, first.filter { $0 == c }.count) }
        return counts.max { $0.1 < $1.1 }.map { $0.1 > 0 ? $0.0 : "," } ?? ","
    }

    static func parseDelimited(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        if text.hasPrefix("\u{FEFF}"), var first = rows.first, !first.isEmpty {
            first[0] = String(first[0].dropFirst()); rows[0] = first
        }
        return rows
    }

    private static func rowsFromJSON(_ data: Data) throws -> [[String]] {
        let object = try JSONSerialization.jsonObject(with: data)
        let items: [Any]
        if let array = object as? [Any] { items = array }
        else if let dict = object as? [String: Any] { items = [dict] }
        else { throw KError.failed(tr("This JSON isn't a list of records.")) }
        var keys: [String] = []
        for case let dict as [String: Any] in items {
            for key in dict.keys.sorted() where !keys.contains(key) { keys.append(key) }
        }
        if keys.isEmpty { return items.map { [stringify($0)] } }
        var rows = [keys]
        for item in items {
            let dict = item as? [String: Any] ?? [:]
            rows.append(keys.map { dict[$0].map(stringify) ?? "" })
        }
        return rows
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case is NSNull: return ""
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
            return "\(value)"
        }
    }

    // MARK: Writing

    static func csvString(_ rows: [[String]], separator: Character) -> String {
        rows.map { row in
            row.map { field in
                if field.contains(separator) || field.contains("\"") || field.contains("\n") {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }.joined(separator: String(separator))
        }.joined(separator: "\n") + "\n"
    }

    private static let numberPattern = try! NSRegularExpression(pattern: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?$")

    static func isNumber(_ s: String) -> Bool {
        numberPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func jsonData(_ rows: [[String]]) throws -> Data {
        guard let header = rows.first else { return Data("[]".utf8) }
        let records: [[String: Any]] = rows.dropFirst().map { row in
            var dict: [String: Any] = [:]
            for (i, key) in header.enumerated() {
                let value = i < row.count ? row[i] : ""
                dict[key.isEmpty ? "column\(i + 1)" : key] = isNumber(value) ? (Double(value).map { $0 == $0.rounded() && !value.contains(".") ? Int($0) as Any : $0 as Any } ?? value) : value
            }
            return dict
        }
        return try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func htmlString(_ rows: [[String]], title: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var html = "<!doctype html>\n<meta charset=\"utf-8\">\n<title>\(esc(title))</title>\n"
        html += "<style>body{font:14px -apple-system,system-ui,sans-serif;margin:24px}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 8px;text-align:left}th{background:#f2f4f3}</style>\n<table>\n"
        for (i, row) in rows.enumerated() {
            let tag = i == 0 ? "th" : "td"
            html += "<tr>" + row.map { "<\(tag)>\(esc($0))</\(tag)>" }.joined() + "</tr>\n"
        }
        return html + "</table>\n"
    }
}

/// The smallest valid .xlsx: one sheet, inline strings, numbers as numbers.
enum XLSX {
    static func write(_ rows: [[String]], to out: URL, ctx: JobContext) async throws {
        let root = try ctx.scratch().appendingPathComponent("xlsx-" + UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        for dir in ["_rels", "xl/_rels", "xl/worksheets", "docProps"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        func put(_ path: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try put("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
        """)
        try put("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
        try put("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """)
        try put("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """)
        try put("xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font></fonts><fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="2"><xf/><xf fontId="1" applyFont="1"/></cellXfs></styleSheet>
        """)
        var sheet = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><sheetData>"
        for (r, row) in rows.enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = column(c) + String(r + 1)
                let style = r == 0 ? " s=\"1\"" : ""
                if r > 0, TableEngine.isNumber(value) {
                    sheet += "<c r=\"\(ref)\"\(style)><v>\(value)</v></c>"
                } else {
                    sheet += "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(escape(value))</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"
        try put("xl/worksheets/sheet1.xml", sheet)
        try await Shell.run(URL(fileURLWithPath: "/usr/bin/zip"), ["-q", "-X", "-r", "-nw", out.path, "[Content_Types].xml", "_rels", "xl"], cwd: root)
    }

    static func read(_ url: URL) async throws -> [[String]] {
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        let shared = (try? await Shell.run(unzip, ["-p", url.path, "xl/sharedStrings.xml"])) ?? ""
        let sheet = try await Shell.run(unzip, ["-p", url.path, "xl/worksheets/sheet1.xml"])
        let strings = SharedStringsParser.parse(Data(shared.utf8))
        return SheetParser.parse(Data(sheet.utf8), strings: strings)
    }

    static func column(_ index: Int) -> String {
        var n = index + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    static func columnIndex(_ ref: String) -> Int {
        var n = 0
        for ch in ref.unicodeScalars where ch.value >= 65 && ch.value <= 90 { n = n * 26 + Int(ch.value - 64) }
        return max(0, n - 1)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var items: [String] = []
    private var current = ""
    private var inText = false

    static func parse(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        let p = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "si" { current = "" }
        if name == "t" { inText = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inText = false }
        if name == "si" { items.append(current) }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    var rows: [[String]] = []
    let strings: [String]
    private var row: [Int: String] = [:]
    private var cellRef = "", cellType = "", value = ""
    private var capture = false

    init(strings: [String]) { self.strings = strings }

    static func parse(_ data: Data, strings: [String]) -> [[String]] {
        let p = SheetParser(strings: strings)
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.rows
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "row":
            row = [:]
            if let r = attributes["r"], let n = Int(r) { while rows.count < n - 1 { rows.append([]) } }
        case "c": cellRef = attributes["r"] ?? ""; cellType = attributes["t"] ?? "n"; value = ""
        case "v", "t": capture = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if capture { value += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t": capture = false
        case "c":
            var text = value
            if cellType == "s", let i = Int(value), i < strings.count { text = strings[i] }
            if cellType == "b" { text = value == "1" ? "TRUE" : "FALSE" }
            row[XLSX.columnIndex(cellRef)] = text
        case "row":
            let width = (row.keys.max() ?? -1) + 1
            rows.append((0..<width).map { row[$0] ?? "" })
        default: break
        }
    }
}
