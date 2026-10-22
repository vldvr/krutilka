// Checks for the parts of Krutilka that don't need a screen. Runs without Xcode:
//   swift run krutilka-checks
// Exits non-zero if anything fails.

import AppKit
import AVFoundation
import ImageIO
import PDFKit
@testable import KrutilkaKit

var passed = 0
var failed: [String] = []

func check(_ condition: @autoclosure () throws -> Bool, _ name: String, line: Int = #line) {
    do {
        if try condition() { passed += 1 } else { failed.append("\(name) (line \(line))") }
    } catch {
        failed.append("\(name) (line \(line)): \(error)")
    }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("krutilka-checks-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

func file(_ name: String, _ text: String = "x") -> URL {
    let url = root.appendingPathComponent(name)
    try? text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

func settings() -> JobSettings {
    JobSettings(imageQuality: 0.88, compressQuality: 0.7, targetSizeMB: 0.05, pdfDPI: 72, videoQuality: .p720,
                audioBitrate: 128, outputPlace: .besideOriginal, outputFolder: root)
}

func context(_ inputs: [URL]) -> JobContext { JobContext(inputs: inputs, settings: settings()) { _ in } }

/// A JPEG with EXIF orientation 6 (stored landscape, shown portrait) and a GPS position.
func photo(_ name: String, width: Int = 80, height: Int = 40) -> URL {
    let url = root.appendingPathComponent(name)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for x in 0..<width { ctx.setFillColor(CGColor(srgbRed: CGFloat(x) / CGFloat(width), green: 0.4, blue: 0.6, alpha: 1)); ctx.fill(CGRect(x: x, y: 0, width: 1, height: height)) }
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    let props: [CFString: Any] = [kCGImagePropertyOrientation: 6,
                                  kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 55.75, kCGImagePropertyGPSLatitudeRef: "N"]]
    CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    return url
}

func pixelSize(_ url: URL) -> CGSize? { ImageEngine.pixelSize(url) }

func hasGPS(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
    return props[kCGImagePropertyGPSDictionary] != nil
}

// MARK: File kinds

check(FileKind.of(URL(fileURLWithPath: "/x/a.HEIC")) == .image, "HEIC is an image")
check(FileKind.of(URL(fileURLWithPath: "/x/a.md")) == .markdown, "md is markdown")
check(FileKind.of(URL(fileURLWithPath: "/x/a.tar.gz")) == .archive, "tar.gz is an archive")
check(FileKind.of(URL(fileURLWithPath: "/x/a.srt")) == .subtitle, "srt is subtitles")
check(FileKind.of(URL(fileURLWithPath: "/x/a.mkv")) == .video, "mkv is video")
check(FileKind.of(root) == .folder, "a directory is a folder")
check(FileKind.code(of: URL(fileURLWithPath: "/x/a.jpeg")) == "JPG", "jpeg shows as JPG")

// MARK: Naming

let taken = file("report.pdf")
check(Naming.unique(taken).lastPathComponent == "report 2.pdf", "second copy gets 2")
_ = file("report 2.pdf")
check(Naming.unique(taken).lastPathComponent == "report 3.pdf", "third copy gets 3")
let tarball = file("photos.tar.gz")
check(Naming.unique(tarball).lastPathComponent == "photos 2.tar.gz", "number goes before .tar.gz")
check(Naming.finderOrder([file("scan 10.png"), file("scan 2.png")]).map(\.lastPathComponent) == ["scan 2.png", "scan 10.png"],
      "name order is Finder order")
let ctx0 = context([taken])
check(ctx0.destination(for: taken, ext: "png", suffix: "page").lastPathComponent == "report (page).png", "suffix in brackets")

// MARK: Tables

let csv = "Имя;Город;Сумма\r\nАня;\"Москва; центр\";007\r\nБорис;Казань;3.5\r\n"
check(TableEngine.guessSeparator(csv) == ";", "semicolon CSV detected")
let rows = TableEngine.parseDelimited(csv, separator: ";")
check(rows.count == 3 && rows[1] == ["Аня", "Москва; центр", "007"], "quoted field with separator")
check(TableEngine.parseDelimited("\u{FEFF}a,b\n1,2\n", separator: ",")[0][0] == "a", "BOM stripped")
check(TableEngine.parseDelimited("a,\"he said \"\"hi\"\"\"\n", separator: ",")[0][1] == "he said \"hi\"", "escaped quotes")
check(!TableEngine.isNumber("007") && TableEngine.isNumber("3.5") && TableEngine.isNumber("-12"), "number detection keeps leading zeros")
check(TableEngine.csvString([["a,b", "c"]], separator: ",") == "\"a,b\",c\n", "CSV quoting on write")

let xlsx = root.appendingPathComponent("table.xlsx")
try await XLSX.write(rows, to: xlsx, ctx: context([xlsx]))
let back = try await XLSX.read(xlsx)
check(back == rows, "XLSX round trip keeps text, numbers and Cyrillic")
check(XLSX.column(0) == "A" && XLSX.column(25) == "Z" && XLSX.column(26) == "AA" && XLSX.columnIndex("AB12") == 27, "column letters")

let json = file("people.json", #"[{"name":"Аня","age":30},{"name":"Борис","city":"СПб"}]"#)
let jsonRows = try await TableEngine.rows(of: json, ctx: context([json]))
check(jsonRows.first == ["age", "name", "city"] && jsonRows.count == 3, "JSON records become a table")

// MARK: Subtitles

let srt = "1\n00:00:01,000 --> 00:00:02,500\nПривет\n\n2\n00:00:03,000 --> 00:00:04,000\nДве\nстроки\n"
let cues = SubtitleEngine.parse(srt)
check(cues.count == 2 && cues[1].text == "Две\nстроки", "SRT parsed")
let srtFile = file("film.srt", srt)
let vtt = try await SubtitleEngine.convert(srtFile, to: "vtt", ctx: context([srtFile]))
let vttText = try String(contentsOf: vtt, encoding: .utf8)
check(vttText.hasPrefix("WEBVTT") && vttText.contains("00:00:01.000 --> 00:00:02.500"), "SRT to VTT")
let srtAgain = try await SubtitleEngine.convert(vtt, to: "srt", ctx: context([vtt]))
check(SubtitleEngine.parse(try String(contentsOf: srtAgain, encoding: .utf8)).map(\.text) == cues.map(\.text), "VTT back to SRT")

// MARK: Images

let jpg = photo("photo.jpg")
let png = try await ImageEngine.convert(jpg, to: .png, ctx: context([jpg]))
check(pixelSize(png) == CGSize(width: 40, height: 80), "EXIF rotation baked into pixels")
let clean = try await ImageEngine.stripMetadata(jpg, ctx: context([jpg]))
check(hasGPS(jpg) && !hasGPS(clean), "metadata strip removes GPS")
check(pixelSize(clean) == pixelSize(jpg), "metadata strip keeps the picture as it was")
let rotated = try await ImageEngine.rotate(jpg, ctx: context([jpg]))
check(pixelSize(rotated) == CGSize(width: 80, height: 40), "rotate turns the shown picture")
let half = try await ImageEngine.resizeHalf(jpg, ctx: context([jpg]))
check(pixelSize(half) == CGSize(width: 20, height: 40), "half size")
if ImageTarget.heic.isAvailable {
    let heic = try await ImageEngine.convert(jpg, to: .heic, ctx: context([jpg]))
    check(FileKind.of(heic) == .image && pixelSize(heic) != nil, "HEIC written")
}

// MARK: PDF

let pdf = try await PDFEngine.imagesToPDF([jpg, png], ctx: context([jpg, png]))
check(PDFDocument(url: pdf)?.pageCount == 2, "pictures to one PDF")
let pages = try await PDFEngine.split(pdf, ctx: context([pdf]))
check((try? fm.contentsOfDirectory(atPath: pages.path).count) == 2, "split makes one file per page")
let merged = try await PDFEngine.merge([pdf, jpg], ctx: context([pdf, jpg]))
check(PDFDocument(url: merged)?.pageCount == 3, "merge takes PDFs and pictures")
let pagePictures = try await PDFEngine.toImages(pdf, as: .png, ctx: context([pdf]))
check(pagePictures.count == 1 && FileKind.of(pagePictures[0]) == .folder, "multi-page PDF to pictures goes into a folder")

// MARK: Documents

let md = file("notes.md", "# Заголовок\n\nТекст с **жирным**.\n\n- пункт\n")
let rich = Markdown.attributed(from: try String(contentsOf: md, encoding: .utf8))
var sawBold = false
rich.enumerateAttribute(.font, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
    if let f = value as? NSFont, f.fontDescriptor.symbolicTraits.contains(.bold) { sawBold = true }
}
check(rich.string.contains("Заголовок") && sawBold, "Markdown rendered with headings and bold")
check(Markdown.markdown(from: rich).hasPrefix("# Заголовок"), "Markdown written back with a heading")
let html = try await DocumentEngine.read(file("page.html", "<meta charset=utf-8><p>Привет</p>"), ctx: context([md]))
check(html.string.contains("Привет"), "HTML read on the main thread")
let portable = DocumentEngine.portableFonts(NSAttributedString(string: "x", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
check((portable.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName.hasPrefix(".") == false, "system fonts replaced for Word")

// MARK: Archives

let folder = root.appendingPathComponent("pack", isDirectory: true)
try fm.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
try "a".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
try "b".write(to: folder.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
let zip = try await ArchiveEngine.pack([folder], as: .zip, ctx: context([folder]))
let listing = try await Shell.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-l", zip.path])
check(listing.contains("pack/sub/b.txt") && !listing.contains("__MACOSX"), "ZIP keeps folders, no __MACOSX")
try fm.removeItem(at: folder)
let unpacked = try await ArchiveEngine.extract(zip, ctx: context([zip]))
check(unpacked.lastPathComponent == "pack" && fm.fileExists(atPath: unpacked.appendingPathComponent("sub/b.txt").path),
      "single top folder lifted out on unpack")
let tgz = try await ArchiveEngine.repack(zip, as: .tgz, ctx: context([zip]))
check(tgz.lastPathComponent == "pack.tar.gz", "ZIP to TAR.GZ")
check(ArchiveEngine.baseName(URL(fileURLWithPath: "/x/a.b.tar.gz")) == "a.b", "archive base name")

// MARK: Audio

let wav = root.appendingPathComponent("tone.wav")
do {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    let out = try AVAudioFile(forWriting: wav, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
    buffer.frameLength = 44_100
    for ch in 0..<2 { for i in 0..<44_100 { buffer.floatChannelData![ch][i] = sin(Float(i) * 0.06) * 0.4 } }
    try out.write(from: buffer)
}
for target in [AudioTarget.m4a, .flac, .aiff, .alac] {
    let out = root.appendingPathComponent("tone-\(target.rawValue).\(target.ext)")
    try await AudioEngine.nativeTranscode(wav, to: out, target: target, kbps: 128, channels: nil, ctx: context([wav]))
    let seconds = try await AVURLAsset(url: out).load(.duration).seconds
    check(abs(seconds - 1) < 0.1, "native audio to \(target.code)")
}
let mono = root.appendingPathComponent("tone-mono.caf")
try await AudioEngine.nativeTranscode(wav, to: mono, target: .caf, kbps: 128, channels: 1, ctx: context([wav]))
check(try AVAudioFile(forReading: mono).processingFormat.channelCount == 1, "mono downmix")

// MARK: Catalog

let jpgConvert = Catalog.operations(for: [jpg], wheel: .convert)
check(jpgConvert.first?.id == "png", "PNG is the first image format")
check(jpgConvert.first { $0.id == "jpeg" }?.enabled == false, "own format greyed out")
check(Set(Catalog.operations(for: [jpg, md], wheel: .tools).map(\.id)).isEmpty, "picture + text share no tools")
let videoURL = URL(fileURLWithPath: "/x/clip.mov")
let mixedTools = Catalog.operations(for: [jpg, videoURL], wheel: .tools).map(\.id)
check(mixedTools == ["compress", "strip", "rotate"], "picture + video share compress, strip, rotate")
check(Catalog.operations(for: [zip], wheel: .convert).first?.id == "unpack", "archives start with unpack")
check(Catalog.operations(for: [root], wheel: .convert).map(\.id) == ["zip", "tgz"], "folders pack")
check(Catalog.operations(for: [jpg], wheel: .actions).count == 10, "every file gets the actions")
check(!Catalog.operations(for: [jpg], wheel: .tools).contains { $0.id == "pdfmerge" }, "merge needs two files")

// MARK: Wheel geometry

let g = WheelGeometry(scale: 1)
check(g.hit(g.center, ring0: 8, ring1: 0, chips: []) == .hub, "centre is the hub")
check(g.hit(g.point(angle: 0, radius: 95), ring0: 8, ring1: 0, chips: []) == .segment(ring: 0, index: 0), "12 o'clock is the first segment")
check(g.hit(g.point(angle: .pi / 2, radius: 95), ring0: 8, ring1: 0, chips: []) == .segment(ring: 0, index: 2), "3 o'clock is the third of eight")
check(g.hit(g.point(angle: -0.1, radius: 95), ring0: 8, ring1: 0, chips: []) == .segment(ring: 0, index: 0), "just left of 12 still the first")
check(g.hit(g.point(angle: -Double.pi / 8, radius: 163), ring0: 8, ring1: 2, chips: []) == .segment(ring: 1, index: 0), "outer ring left of 12")
check(g.hit(g.point(angle: .pi, radius: 163), ring0: 8, ring1: 2, chips: []) == .none, "outer ring has nothing at 6 o'clock")
check(g.hit(CGPoint(x: 5, y: 5), ring0: 8, ring1: 0, chips: [CGRect(x: 0, y: 0, width: 10, height: 10)]) == .chip(.convert), "chips are hit first")
check(g.size.height < g.size.width + g.chipsHeight, "panel is no taller than it needs")


// MARK: Settings

let prefs = Prefs.shared
check(prefs.wheel(for: .shift) == .convert && prefs.wheel(for: .option) == .tools && prefs.wheel(for: .control) == .actions,
      "default keys: ⇧ formats, ⌥ tools, ⌃ actions")
check(prefs.wheel(for: [.shift, .command]) == nil, "a wheel opens only on its exact keys")
check(KeyCombo([.control, .option, .shift, .command]).glyphs == "⌃⌥⇧⌘", "key glyphs in Apple order")
check(Recipe.defaults.count == 3 && Recipe.defaults[0].summary.hasPrefix("WEBP"), "default recipes")

// MARK: Checksums

let abc = file("abc.txt", "abc")
check(try Hashing.sha256(abc) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of abc")

// MARK: Files from strangers

check(ArchiveEngine.safeName("--checkpoint=1") == "./--checkpoint=1", "tar sees file names, not options")
let hostile = root.appendingPathComponent("hostile", isDirectory: true)
try fm.createDirectory(at: hostile, withIntermediateDirectories: true)
for name in ["--checkpoint=1", "--checkpoint-action=exec=touch PWNED", "ok.txt"] {
    fm.createFile(atPath: hostile.appendingPathComponent(name).path, contents: Data())
}
let hostileZip = try await ArchiveEngine.pack([hostile], as: .zip, ctx: context([hostile]))
let hostileTar = try await ArchiveEngine.repack(hostileZip, as: .tgz, ctx: context([hostileZip]))
let hostileList = try await Shell.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tzf", hostileTar.path])
check(hostileList.contains("--checkpoint-action") && !fm.fileExists(atPath: fm.currentDirectoryPath + "/PWNED"),
      "option-like names in an archive stay names")

if let pandoc = ExternalTools.shared.url(.pandoc) {
    let outside = file("outside.md", "# x\n\n![a](/etc/hosts)\n")
    let upward = file("upward.md", "![a](../secret.png)")
    let entity = file("entity.md", "![a](&#47;etc/hosts)")
    let cover = file("cover.md", "---\ncover-image: /etc/hosts\n---\n\ntext\n")
    let raw = file("raw.md", "text <img src=\"/etc/hosts\"> more")
    let remote = file("remote.html", "<p>plain page</p>")
    let metaImage = file("meta.md", "---\ntitle: \"![x](/etc/hosts)\"\n---\n\ntext\n")
    let unusualMeta = file("unusual.md", "---\nheader-includes: x\n---\n\ntext\n")
    let inside = file("inside.md", "![a](pics/a.png)\n\n[site](https://example.com)")
    var sandboxed = true
    for doc in [outside, upward, entity, cover, raw, remote, metaImage, unusualMeta] {
        let format = doc.pathExtension == "md" ? "gfm" : nil
        if !(await Pandoc.needsSandbox(doc, pandoc: pandoc, format: format)) { sandboxed = false; print("  not sandboxed: \(doc.lastPathComponent)") }
    }
    check(sandboxed, "pandoc sandboxed for outside paths, entities, covers, raw HTML, metadata, any HTML input")
    let plainMeta = file("plain.md", "---\ntitle: Notes\ntags: [a, b]\n---\n\n![a](pics/a.png)\n")
    let plainFree = await Pandoc.needsSandbox(plainMeta, pandoc: pandoc, format: "gfm")
    check(!plainFree, "titles and tags don't force the sandbox")
    let free = await Pandoc.needsSandbox(inside, pandoc: pandoc, format: "gfm")
    check(!free, "pandoc free when images stay in the folder")
}
let container = await Pandoc.needsSandbox(root.appendingPathComponent("book.docx"), pandoc: URL(fileURLWithPath: "/usr/bin/false"), format: nil)
check(container, "pandoc always sandboxed for containers")

let cleaned = HTMLSanitizer.neutralize(#"<p>Hello <b>there</b></p><img/src="file:///etc/hosts"><IMG SRC=x><link rel=stylesheet href="http://x/s.css"><p style="background:u&#114;l(http://x/b.png)">t</p><svg><image href="/etc/hosts"/></svg><script>alert(1)</script><table><tr><td colspan="2">c</td></tr></table><a href="https://example.com">l</a>"#)
check(!cleaned.lowercased().contains("src") && !cleaned.contains("<link") && !cleaned.contains("style") && !cleaned.contains("<script")
      && !cleaned.contains("/etc/hosts") && !cleaned.contains("<svg"), "HTML import has nothing left to load")
check(cleaned.contains("Hello") && cleaned.contains("<b>there</b>") && cleaned.contains("colspan=\"2\"") && cleaned.contains("href=\"https://example.com\""),
      "HTML import keeps text, emphasis, tables and links")
let rootCleaned = HTMLSanitizer.neutralize(#"<html background="file:///etc/hosts" style="background:url(x)"><body><a href="file:///etc/hosts">f</a><a href="javascript:alert(1)">j</a></body></html>"#)
check(!rootCleaned.contains("background") && !rootCleaned.contains("file:") && !rootCleaned.contains("javascript:"),
      "root element and unsafe link schemes cleaned too")

let playlist = file("movie.mp4", "#EXTM3U\n#EXTINF:1,\n/etc/hosts\n")
var refused = false
do { try FFmpeg.refusePlaylist(playlist) } catch { refused = true }
check(refused, "a playlist posing as a video gets a clear refusal")
let ffmpegInput = try await FFmpeg.input(jpg)
check(ffmpegInput.starts(with: ["-protocol_whitelist", "file", "-format_whitelist"]) && !FFmpeg.demuxers.contains("concat")
      && !FFmpeg.demuxers.contains("hls"), "ffmpeg reads local files in ordinary containers only")
if let ffmpeg = ExternalTools.shared.url(.ffmpeg) {
    let concat = file("joined.mp4", "ffconcat version 1.0\nfile /etc/hosts\n")
    var blocked = false
    do { try await Shell.run(ffmpeg, ["-v", "error"] + FFmpeg.safeInput + ["-i", concat.path, "-f", "null", "-"]) } catch { blocked = true }
    check(blocked, "ffmpeg itself rejects a concat list even without the quick look")
}

// MARK: Report

print("\(passed) passed, \(failed.count) failed")
for name in failed { print("  FAIL \(name)") }
exit(failed.isEmpty ? 0 : 1)
