import AppKit
import CoreImage
import SwiftUI

/// Crop, hide, point at and label parts of a picture: what people do to a screenshot before sending it.
@MainActor
final class PhotoEditorController: NSObject, NSWindowDelegate {
    private static var open: [PhotoEditorController] = []
    private let window: NSWindow

    static func show(_ url: URL) {
        Task { @MainActor in
            do {
                let image = try await ImageEngine.load(url)
                let controller = PhotoEditorController(url: url, image: image)
                open.append(controller)
                NSApp.activate(ignoringOtherApps: true)
                controller.window.makeKeyAndOrderFront(nil)
            } catch {
                JobCenter.shared.flash((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, failed: true)
            }
        }
    }

    private init(url: URL, image: CGImage) {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1400, height: 900)
        let fit = min(screen.width * 0.7 / CGFloat(image.width), (screen.height * 0.75 - 70) / CGFloat(image.height), 1)
        let size = NSSize(width: max(640, CGFloat(image.width) * fit + 40), height: max(400, CGFloat(image.height) * fit + 110))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = trf("Edit %@", url.lastPathComponent)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 620, height: 380)
        let model = PhotoEditModel(url: url, image: image)
        window.contentViewController = NSHostingController(rootView: PhotoEditorView(model: model) { [weak self] in
            self?.window.close()
        })
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        PhotoEditorController.open.removeAll { $0 === self }
    }
}

@MainActor
final class PhotoEditModel: ObservableObject {
    enum Mode: String, CaseIterable { case hide, crop, arrow, text }
    enum HideStyle: String, CaseIterable { case pixelate, black }

    enum Ink: String, CaseIterable {
        case red, patina, black, white
        var nsColor: NSColor {
            switch self {
            case .red: return NSColor(hex: 0xE5372B)
            case .patina: return NSColor(hex: 0x0B7366)
            case .black: return NSColor(hex: 0x111111)
            case .white: return .white
            }
        }
        var title: String {
            switch self {
            case .red: return tr("Red")
            case .patina: return tr("Patina")
            case .black: return tr("Black ink")
            case .white: return tr("White")
            }
        }
        /// The outline that keeps a mark readable on any background.
        var halo: NSColor { self == .white ? NSColor(white: 0, alpha: 0.85) : NSColor(white: 1, alpha: 0.9) }
    }

    enum Aspect: String, CaseIterable {
        case free, square, fourThree, sixteenNine
        var ratio: CGFloat? {
            switch self {
            case .free: return nil
            case .square: return 1
            case .fourThree: return 4.0 / 3.0
            case .sixteenNine: return 16.0 / 9.0
            }
        }
        var label: String {
            switch self {
            case .free: return tr("Free")
            case .square: return "1:1"
            case .fourThree: return "4:3"
            case .sixteenNine: return "16:9"
            }
        }
    }

    struct Patch: Identifiable { let id = UUID(); var rect: CGRect; var style: HideStyle }
    struct Arrow: Identifiable { let id = UUID(); var from: CGPoint; var to: CGPoint; var ink: Ink }
    struct Note: Identifiable { let id = UUID(); var at: CGPoint; var text: String; var ink: Ink }

    let url: URL
    let image: CGImage
    let pixelated: CGImage?
    @Published var mode: Mode = .hide
    @Published var hideStyle: HideStyle = .pixelate
    @Published var aspect: Aspect = .free
    @Published var ink: Ink = .red
    /// All geometry is in image pixels with the origin at the top left.
    @Published var crop: CGRect?
    @Published var patches: [Patch] = []
    @Published var arrows: [Arrow] = []
    @Published var notes: [Note] = []
    @Published var draftRect: CGRect?
    @Published var draftArrow: (CGPoint, CGPoint)?
    @Published var typingAt: CGPoint?
    private var order: [UUID] = []

    var size: CGSize { CGSize(width: image.width, height: image.height) }
    var hasEdits: Bool { crop != nil || !order.isEmpty }
    var longest: CGFloat { max(size.width, size.height) }
    var lineWidth: CGFloat { max(3, longest / 220) }
    var fontSize: CGFloat { max(14, longest / 30) }

    init(url: URL, image: CGImage) {
        self.url = url
        self.image = image
        // Blocks about 1/45 of the longest side: unreadable text, still clearly "something was here".
        let ci = CIImage(cgImage: image)
        let filter = CIFilter(name: "CIPixellate")!
        filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(8, Double(max(image.width, image.height)) / 45), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        pixelated = filter.outputImage.flatMap { CIContext().createCGImage($0, from: ci.extent) }
    }

    func commitRect(_ rect: CGRect) {
        let r = rect.standardized.intersection(CGRect(origin: .zero, size: size))
        guard r.width >= 4, r.height >= 4 else { return }
        if mode == .crop {
            crop = r
        } else {
            let patch = Patch(rect: r, style: hideStyle)
            patches.append(patch)
            order.append(patch.id)
        }
    }

    func commitArrow(from: CGPoint, to: CGPoint) {
        guard hypot(to.x - from.x, to.y - from.y) > lineWidth * 3 else { return }
        let arrow = Arrow(from: from, to: to, ink: ink)
        arrows.append(arrow)
        order.append(arrow.id)
    }

    func commitNote(_ text: String) {
        defer { typingAt = nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = typingAt, !trimmed.isEmpty else { return }
        let note = Note(at: at, text: trimmed, ink: ink)
        notes.append(note)
        order.append(note.id)
    }

    func undo() {
        if mode == .crop, crop != nil { crop = nil; return }
        guard let last = order.popLast() else { crop = nil; return }
        patches.removeAll { $0.id == last }
        arrows.removeAll { $0.id == last }
        notes.removeAll { $0.id == last }
    }

    // MARK: Shapes shared by the preview and the saved file

    /// A filled arrow: round-capped shaft and a solid head, in image coordinates.
    static func arrowPath(from a: CGPoint, to b: CGPoint, width w: CGFloat) -> CGPath {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length
        let headLength = min(w * 4.4, length * 0.6), headWidth = w * 3.6
        let base = CGPoint(x: b.x - ux * headLength, y: b.y - uy * headLength)
        let shaft = CGMutablePath()
        shaft.move(to: a)
        shaft.addLine(to: CGPoint(x: base.x + ux * w, y: base.y + uy * w))
        let path = CGMutablePath()
        path.addPath(shaft.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 4))
        path.move(to: b)
        path.addLine(to: CGPoint(x: base.x - uy * headWidth / 2, y: base.y + ux * headWidth / 2))
        path.addLine(to: CGPoint(x: base.x + uy * headWidth / 2, y: base.y - ux * headWidth / 2))
        path.closeSubpath()
        return path
    }

    func noteAttributes(_ ink: Ink, scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize * scale, weight: .bold),
         .foregroundColor: ink.nsColor,
         .strokeColor: ink.halo,
         .strokeWidth: -4]
    }

    // MARK: Saving

    /// Draws everything, applies the crop, saves "name (edited).ext". Hidden areas also drop
    /// the location and camera data, since hiding is about privacy.
    func save() throws -> URL {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw KError.failed(tr("Couldn't prepare the image."))
        }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(image, in: full)
        for patch in patches {
            let r = CGRect(x: patch.rect.minX, y: CGFloat(h) - patch.rect.maxY, width: patch.rect.width, height: patch.rect.height)
            if patch.style == .pixelate, let pixelated {
                ctx.saveGState()
                ctx.clip(to: r)
                ctx.draw(pixelated, in: full)
                ctx.restoreGState()
            } else {
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(r)
            }
        }

        // Marks are drawn top-left-origin, like everything the editor stores.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        for arrow in arrows {
            let path = Self.arrowPath(from: arrow.from, to: arrow.to, width: lineWidth)
            ctx.addPath(path)
            ctx.setStrokeColor(arrow.ink.halo.cgColor)
            ctx.setLineWidth(lineWidth * 0.5)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.addPath(path)
            ctx.setFillColor(arrow.ink.nsColor.cgColor)
            ctx.fillPath()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for note in notes {
            NSAttributedString(string: note.text, attributes: noteAttributes(note.ink)).draw(at: note.at)
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        guard var result = ctx.makeImage() else { throw KError.failed(tr("Couldn't prepare the image.")) }
        if let crop, let cropped = result.cropping(to: crop.integral) { result = cropped }

        var target = ImageTarget.of(url) ?? .png
        if !target.isAvailable || target == .pdf || target == .webp || target == .gif { target = .png }
        if target == .jpeg || target == .bmp, ImageEngine.hasAlpha(result) { result = ImageEngine.flattened(result) }
        let props = patches.isEmpty ? ImageEngine.carriedProperties(url) : [:]
        let base = url.deletingPathExtension().lastPathComponent + " (\(tr("edited")))"
        let out = Naming.unique(url.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension(target.ext))
        guard let uti = target.uti,
              let data = ImageEngine.encode(result, uti: uti, quality: target.isLossy ? 0.92 : nil, properties: props) else {
            throw KError.failed(tr("Couldn't save the picture."))
        }
        try data.write(to: out)
        return out
    }
}

struct PhotoEditorView: View {
    @ObservedObject var model: PhotoEditModel
    var close: () -> Void
    @State private var typed = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            GeometryReader { proxy in
                let fit = fitted(in: proxy.size)
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .underPageBackgroundColor)
                    Image(decorative: model.image, scale: 1)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .offset(x: fit.minX, y: fit.minY)
                    patches(fit)
                    marks(fit)
                    cropOverlay(fit)
                    drafts(fit)
                    if let at = model.typingAt {
                        textEntry(at, fit)
                    }
                }
                .contentShape(Rectangle())
                .gesture(canvasGesture(fit))
            }
            Divider()
            footer
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    // MARK: Bars

    private var toolbar: some View {
        HStack(spacing: 14) {
            Picker("", selection: $model.mode) {
                Text("Hide").tag(PhotoEditModel.Mode.hide)
                Text("Crop").tag(PhotoEditModel.Mode.crop)
                Text("Arrow").tag(PhotoEditModel.Mode.arrow)
                Text("Text").tag(PhotoEditModel.Mode.text)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 290)
            switch model.mode {
            case .hide:
                Picker("", selection: $model.hideStyle) {
                    Text("Pixelate").tag(PhotoEditModel.HideStyle.pixelate)
                    Text("Black").tag(PhotoEditModel.HideStyle.black)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
            case .crop:
                Picker("", selection: $model.aspect) {
                    ForEach(PhotoEditModel.Aspect.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
            case .arrow, .text:
                inkPicker
            }
            Spacer()
            Text(LocalizedStringKey(hint))
                .font(.system(size: 11.5))
                .foregroundStyle(Color(nsColor: Theme.textMuted))
                .lineLimit(1)
        }
    }

    private var hint: String {
        switch model.mode {
        case .hide: return "Drag over what to hide"
        case .crop: return "Drag to frame the part to keep"
        case .arrow: return "Drag from the tail to the tip"
        case .text: return "Click where the text goes"
        }
    }

    private var inkPicker: some View {
        HStack(spacing: 8) {
            ForEach(PhotoEditModel.Ink.allCases, id: \.self) { ink in
                Button { model.ink = ink } label: {
                    Circle()
                        .fill(Color(nsColor: ink.nsColor))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color(nsColor: Theme.edge), lineWidth: 0.75))
                        .padding(3)
                        .overlay(Circle().stroke(Theme.mark, lineWidth: model.ink == ink ? 2 : 0))
                }
                .buttonStyle(.plain)
                .help(Text(ink.title))
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.hasEdits)
            Spacer()
            Button("Cancel", role: .cancel) { close() }
                .keyboardShortcut(.cancelAction)
            Button("Save Copy") {
                do {
                    let out = try model.save()
                    JobCenter.shared.flash(out.lastPathComponent, reveal: [out])
                    if Prefs.shared.revealWhenDone { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                    close()
                } catch {
                    JobCenter.shared.flash((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, failed: true)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.hasEdits || model.typingAt != nil)
        }
    }

    // MARK: Canvas input

    private func canvasGesture(_ fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let a = toImage(value.startLocation, fit), b = toImage(value.location, fit)
                switch model.mode {
                case .hide, .crop: model.draftRect = constrained(from: a, to: b)
                case .arrow: model.draftArrow = (a, b)
                case .text: break
                }
            }
            .onEnded { value in
                let a = toImage(value.startLocation, fit), b = toImage(value.location, fit)
                switch model.mode {
                case .hide, .crop:
                    if let draft = model.draftRect { model.commitRect(draft) }
                case .arrow:
                    model.commitArrow(from: a, to: b)
                case .text:
                    if model.typingAt != nil { model.commitNote(typed) }
                    typed = ""
                    model.typingAt = a
                    typing = true
                }
                model.draftRect = nil
                model.draftArrow = nil
            }
    }

    private func textEntry(_ at: CGPoint, _ fit: CGRect) -> some View {
        let s = fit.width / model.size.width
        let p = CGPoint(x: fit.minX + at.x * s, y: fit.minY + at.y * s)
        return TextField("", text: $typed)
            .textFieldStyle(.plain)
            .font(.system(size: max(12, model.fontSize * s), weight: .bold))
            .foregroundStyle(Color(nsColor: model.ink.nsColor))
            .focused($typing)
            .onSubmit { model.commitNote(typed); typed = "" }
            .onExitCommand { model.typingAt = nil; typed = "" }
            .frame(width: max(160, fit.maxX - p.x - 8), alignment: .leading)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 4).stroke(Theme.mark, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .offset(x: p.x - 3, y: p.y)
    }

    // MARK: Overlays

    private func patches(_ fit: CGRect) -> some View {
        ForEach(model.patches) { patch in
            let r = toView(patch.rect, fit)
            Group {
                if patch.style == .pixelate, let pixelated = model.pixelated {
                    Image(decorative: pixelated, scale: 1)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .offset(x: fit.minX - r.minX, y: fit.minY - r.minY)
                        .frame(width: r.width, height: r.height, alignment: .topLeading)
                        .clipped()
                } else {
                    Rectangle().fill(Color.black)
                }
            }
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
        }
    }

    private func marks(_ fit: CGRect) -> some View {
        let s = fit.width / model.size.width
        let toViewSpace = CGAffineTransform(translationX: fit.minX, y: fit.minY).scaledBy(x: s, y: s)
        return ZStack(alignment: .topLeading) {
            ForEach(model.arrows) { arrow in
                let path = Path(PhotoEditModel.arrowPath(from: arrow.from, to: arrow.to, width: model.lineWidth)).applying(toViewSpace)
                path.fill(Color(nsColor: arrow.ink.nsColor))
                    .overlay(path.stroke(Color(nsColor: arrow.ink.halo), lineWidth: max(0.75, model.lineWidth * s * 0.5)))
            }
            ForEach(model.notes) { note in
                Text(note.text)
                    .font(.system(size: model.fontSize * s, weight: .bold))
                    .foregroundStyle(Color(nsColor: note.ink.nsColor))
                    .shadow(color: Color(nsColor: note.ink.halo), radius: 0.8)
                    .shadow(color: Color(nsColor: note.ink.halo), radius: 0.8)
                    .fixedSize()
                    .offset(x: fit.minX + note.at.x * s, y: fit.minY + note.at.y * s)
            }
        }
    }

    @ViewBuilder
    private func drafts(_ fit: CGRect) -> some View {
        if let draft = model.draftRect {
            let r = toView(draft, fit)
            Rectangle()
                .stroke(Theme.mark, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
        }
        if let (a, b) = model.draftArrow {
            let s = fit.width / model.size.width
            Path(PhotoEditModel.arrowPath(from: a, to: b, width: model.lineWidth))
                .applying(CGAffineTransform(translationX: fit.minX, y: fit.minY).scaledBy(x: s, y: s))
                .fill(Color(nsColor: model.ink.nsColor).opacity(0.7))
        }
    }

    @ViewBuilder
    private func cropOverlay(_ fit: CGRect) -> some View {
        if let crop = model.crop {
            let r = toView(crop, fit)
            Path { p in
                p.addRect(fit)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
        }
    }

    // MARK: Geometry

    private func fitted(in container: CGSize) -> CGRect {
        let pad: CGFloat = 16
        let avail = CGSize(width: max(container.width - pad * 2, 10), height: max(container.height - pad * 2, 10))
        let s = min(avail.width / model.size.width, avail.height / model.size.height)
        let w = model.size.width * s, h = model.size.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    private func toImage(_ p: CGPoint, _ fit: CGRect) -> CGPoint {
        let x = (p.x - fit.minX) / fit.width * model.size.width
        let y = (p.y - fit.minY) / fit.height * model.size.height
        return CGPoint(x: min(max(x, 0), model.size.width), y: min(max(y, 0), model.size.height))
    }

    private func toView(_ r: CGRect, _ fit: CGRect) -> CGRect {
        let sx = fit.width / model.size.width, sy = fit.height / model.size.height
        return CGRect(x: fit.minX + r.minX * sx, y: fit.minY + r.minY * sy, width: r.width * sx, height: r.height * sy)
    }

    /// A rectangle from two corners, held to the chosen aspect ratio while cropping.
    private func constrained(from a: CGPoint, to b: CGPoint) -> CGRect {
        var w = b.x - a.x, h = b.y - a.y
        if model.mode == .crop, let ratio = model.aspect.ratio {
            if abs(w) / ratio > abs(h) { h = (h < 0 ? -1 : 1) * abs(w) / ratio } else { w = (w < 0 ? -1 : 1) * abs(h) * ratio }
        }
        return CGRect(x: a.x, y: a.y, width: w, height: h).standardized
    }
}
