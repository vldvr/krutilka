import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Where a point on the wheel lands.
enum WheelHit: Equatable {
    case none
    case hub
    case segment(ring: Int, index: Int)
    case chip(WheelKind)
}

/// Geometry of the dial, in points, origin at the dial centre, y pointing down,
/// angles measured clockwise from 12 o'clock.
struct WheelGeometry {
    var scale: CGFloat

    var hubRadius: CGFloat { 50 * scale }
    var ring0Inner: CGFloat { 57 * scale }
    var ring0Outer: CGFloat { 134 * scale }
    var ring1Inner: CGFloat { 140 * scale }
    var ring1Outer: CGFloat { 186 * scale }
    var gap: CGFloat { 3 * scale }
    var corner: CGFloat { 9 * scale }
    var margin: CGFloat { 22 * scale }
    var chipsHeight: CGFloat { 34 * scale }
    var chipsSpacing: CGFloat { 16 * scale }

    /// The panel always has room for the outer ring, so switching wheels never moves it.
    /// The outer ring only grows upward (at most five segments around 12 o'clock), so the
    /// wheel chips sit right under the inner ring.
    var dialRadius: CGFloat { ring1Outer }
    var size: CGSize {
        CGSize(width: (dialRadius + margin) * 2, height: center.y + ring0Outer + chipsSpacing + chipsHeight + margin / 2)
    }
    var center: CGPoint { CGPoint(x: dialRadius + margin, y: dialRadius + margin) }
    var chipsRect: CGRect {
        CGRect(x: 0, y: center.y + ring0Outer + chipsSpacing, width: (dialRadius + margin) * 2, height: chipsHeight)
    }

    /// Ring 0 is divided evenly; ring 1 uses 45° steps grouped around 12 o'clock.
    static let outerStep = Double.pi / 4

    func angles(ring: Int, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        if ring == 0 {
            let step = 2 * Double.pi / Double(count)
            return (0..<count).map { Double($0) * step }
        }
        let first = -Double(count - 1) / 2 * Self.outerStep
        return (0..<count).map { first + Double($0) * Self.outerStep }
    }

    func span(ring: Int, count: Int) -> Double {
        ring == 0 ? 2 * Double.pi / Double(max(count, 1)) : Self.outerStep
    }

    func point(angle: Double, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
    }

    func hit(_ p: CGPoint, ring0: Int, ring1: Int, chips: [CGRect]) -> WheelHit {
        if let i = chips.firstIndex(where: { $0.contains(p) }) { return .chip(WheelKind.allCases[i]) }
        let dx = Double(p.x - center.x), dy = Double(p.y - center.y)
        let r = CGFloat((dx * dx + dy * dy).squareRoot())
        if r <= ring0Inner - gap { return .hub }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        if r <= ring0Outer + gap / 2, ring0 > 0 {
            let step = 2 * Double.pi / Double(ring0)
            return .segment(ring: 0, index: Int((angle / step).rounded()) % ring0)
        }
        if r <= ring1Outer + gap * 3, ring1 > 0 {
            var a = angle
            if a > .pi { a -= 2 * .pi }
            let first = -Double(ring1 - 1) / 2 * Self.outerStep
            let i = Int(((a - first) / Self.outerStep).rounded())
            if (0..<ring1).contains(i) { return .segment(ring: 1, index: i) }
        }
        return .none
    }
}

/// State of the wheel panel, observed by `WheelView`.
@MainActor
final class WheelModel: ObservableObject {
    @Published var kind: WheelKind = .convert
    @Published var files: [URL] = []
    @Published var rings: [[Operation]] = [[], []]
    @Published var hit: WheelHit = .none
    @Published var isOpen = false
    @Published var interactive = false
    @Published var thumbnail: NSImage?
    @Published var available: Set<WheelKind> = []
    /// Needle angle, kept continuous (no jump from 359° to 1°) so the spring takes the short way.
    @Published var needleAngle: Double = 0
    @Published var geometry = WheelGeometry(scale: 1)

    /// Chip rectangles in panel coordinates, reported by the view for hit-testing.
    var chipFrames: [WheelKind: CGRect] = [:]

    private var byKind: [WheelKind: [Operation]] = [:]

    var operations: [Operation] { rings[0] + rings[1] }

    func load(files: [URL], kind: WheelKind) {
        self.files = files
        byKind = [:]
        for k in WheelKind.allCases { byKind[k] = Catalog.operations(for: files, wheel: k) }
        available = Set(WheelKind.allCases.filter { !(byKind[$0] ?? []).isEmpty })
        show(kind)
        thumbnail = NSWorkspace.shared.icon(forFile: files[0].path)
        loadThumbnail(files[0])
    }

    func show(_ kind: WheelKind) {
        self.kind = kind
        let ops = byKind[kind] ?? []
        if ops.count <= 9 {
            rings = [ops, []]
        } else {
            rings = [Array(ops.prefix(8)), Array(ops.dropFirst(8).prefix(5))]
        }
        hit = .none
    }

    func operation(at hit: WheelHit) -> Operation? {
        guard case let .segment(ring, index) = hit, ring < rings.count, index < rings[ring].count else { return nil }
        return rings[ring][index]
    }

    func setHit(_ new: WheelHit) {
        guard new != hit else { return }
        hit = new
        if case let .segment(ring, index) = new {
            let target = geometry.angles(ring: ring, count: rings[ring].count)[index]
            var delta = (target - needleAngle).truncatingRemainder(dividingBy: 2 * .pi)
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            needleAngle += delta
        }
    }

    private func loadThumbnail(_ url: URL) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async {
                guard self?.files.first == url else { return }
                self?.thumbnail = image
            }
        }
    }
}
