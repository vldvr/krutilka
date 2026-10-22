import AppKit
import SwiftUI

/// An annular sector with rounded corners. Angles: clockwise from 12 o'clock.
/// The path is inset by `corner`; drawing it filled *and* stroked with a round join at
/// `2 * corner` gives the full-size shape with soft corners.
struct SectorShape: Shape {
    var center: CGPoint
    var inner: CGFloat
    var outer: CGFloat
    var mid: Double
    var span: Double
    var gap: CGFloat
    var corner: CGFloat

    func path(in rect: CGRect) -> Path {
        let ri = inner + corner, ro = outer - corner
        guard ro > ri else { return Path() }
        // A single option would be a closed ring; leave a hairline opening at the bottom instead.
        let half = min(span, 2 * .pi - 0.02) / 2
        let ai = min(Double((gap / 2 + corner) / ri), half * 0.9)
        let ao = min(Double((gap / 2 + corner) / ro), half * 0.9)
        func pt(_ a: Double, _ r: CGFloat) -> CGPoint {
            CGPoint(x: center.x + r * CGFloat(sin(a)), y: center.y - r * CGFloat(cos(a)))
        }
        let steps = max(6, Int(span * 18))
        var p = Path()
        let o0 = mid - half + ao, o1 = mid + half - ao
        p.move(to: pt(o0, ro))
        for s in 1...steps { p.addLine(to: pt(o0 + (o1 - o0) * Double(s) / Double(steps), ro)) }
        let i0 = mid + half - ai, i1 = mid - half + ai
        for s in 0...steps { p.addLine(to: pt(i0 + (i1 - i0) * Double(s) / Double(steps), ri)) }
        p.closeSubpath()
        return p
    }
}

/// Glass on macOS 26 and later, a behind-window blur before that, a solid fill when the person
/// asked for it or turned on Reduce Transparency.
struct DialSurface<S: Shape>: View {
    var shape: S
    var solid: Bool
    var tint: Color? = nil

    var body: some View {
        if solid {
            shape.fill(Color(nsColor: Theme.ring))
                .overlay(shape.stroke(Color(nsColor: Theme.edge).opacity(0.55), lineWidth: 0.75))
        } else {
            glass
        }
    }

    // The glass API exists only in the macOS 26 SDK (Swift 6.2 toolchains); older toolchains
    // still build, with the blur for everyone.
    @ViewBuilder
    private var glass: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            blur
        }
        #else
        blur
        #endif
    }

    private var blur: some View {
        VisualEffect(material: .hudWindow).clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.75))
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    @ObservedObject var prefs = Prefs.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var g: WheelGeometry { model.geometry }
    private var solid: Bool { prefs.wheelStyle == .solid || reduceTransparency }
    private var openSpring: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.78) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            dial
                .scaleEffect(model.isOpen || reduceMotion ? 1 : 0.82, anchor: UnitPoint(x: g.center.x / g.size.width, y: g.center.y / g.size.height))
                .opacity(model.isOpen ? 1 : 0)
            chips
                .offset(y: model.isOpen || reduceMotion ? 0 : -8)
                .opacity(model.isOpen ? 1 : 0)
        }
        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        .coordinateSpace(name: "wheel")
        .animation(openSpring, value: model.isOpen)
    }

    // MARK: Dial

    private var dial: some View {
        ZStack(alignment: .topLeading) {
            // Ring 0 background, one piece so the glass reads as a single object.
            // With nothing to offer, only the hub shows, so an empty ring doesn't pretend to have options.
            let backdrop = model.operations.isEmpty ? g.hubRadius + 6 * g.scale : g.ring0Outer + 4
            DialSurface(shape: Circle().path(in: CGRect(x: g.center.x - backdrop, y: g.center.y - backdrop,
                                                         width: backdrop * 2, height: backdrop * 2)),
                        solid: solid)
                .shadow(color: .black.opacity(solid ? 0.16 : 0.1), radius: 22, y: 10)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8), value: model.operations.isEmpty)

            ForEach(Array(model.rings[1].enumerated()), id: \.element.id) { i, _ in
                DialSurface(shape: sector(ring: 1, index: i, expandBy: g.corner), solid: solid)
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            }

            ForEach(0..<2, id: \.self) { ring in
                ForEach(Array(model.rings[ring].enumerated()), id: \.element.id) { i, op in
                    segment(op, ring: ring, index: i)
                }
            }

            hub
            needle
        }
        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.kind)
    }

    private func sector(ring: Int, index: Int, expandBy extra: CGFloat = 0) -> some Shape {
        let count = model.rings[ring].count
        let mid = g.angles(ring: ring, count: count)[index]
        return SectorShape(center: g.center,
                           inner: (ring == 0 ? g.ring0Inner : g.ring1Inner) - extra,
                           outer: (ring == 0 ? g.ring0Outer : g.ring1Outer) + extra,
                           mid: mid, span: g.span(ring: ring, count: count), gap: g.gap, corner: g.corner)
    }

    private func isHovered(_ ring: Int, _ index: Int) -> Bool {
        model.hit == .segment(ring: ring, index: index)
    }

    @ViewBuilder
    private func segment(_ op: Operation, ring: Int, index: Int) -> some View {
        let hovered = isHovered(ring, index)
        let count = model.rings[ring].count
        let mid = g.angles(ring: ring, count: count)[index]
        let shape = sector(ring: ring, index: index)
        let active = hovered && op.enabled
        let pop: CGFloat = hovered && !reduceMotion ? 3 * g.scale : 0
        ZStack(alignment: .topLeading) {
            // Fill and the round-join stroke overlap; drawing them opaque and fading the group
            // keeps a translucent segment one even tone.
            ZStack {
                shape.fill(active ? Theme.accent : Color.primary)
                shape.stroke(active ? Theme.accent : Color.primary, style: StrokeStyle(lineWidth: g.corner * 2, lineJoin: .round))
            }
            .compositingGroup()
            .opacity(active ? 1 : (solid ? 0.04 : 0.07))
            label(op, ring: ring, mid: mid, count: count, hovered: hovered)
        }
        .offset(x: pop * CGFloat(sin(mid)), y: -pop * CGFloat(cos(mid)))
        .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.8), value: hovered)
        .accessibilityElement()
        .accessibilityLabel(op.title)
        .accessibilityHint(op.hint)
    }

    @ViewBuilder
    private func label(_ op: Operation, ring: Int, mid: Double, count: Int, hovered: Bool) -> some View {
        let radius = ring == 0 ? (g.ring0Inner + g.ring0Outer) / 2 + 2 * g.scale : (g.ring1Inner + g.ring1Outer) / 2
        let p = g.point(angle: mid, radius: radius)
        let chord = 2 * radius * CGFloat(sin(min(g.span(ring: ring, count: count), .pi) / 2)) - 14 * g.scale
        let width = max(44 * g.scale, min(chord, 86 * g.scale))
        let color: Color = hovered && op.enabled ? .white : Color(nsColor: Theme.text)
        let small = ring == 1
        Group {
            if let symbol = op.symbol {
                VStack(spacing: 3 * g.scale) {
                    Image(systemName: symbol)
                        .font(.system(size: (small ? 12 : 15) * g.scale, weight: .medium))
                        .frame(height: (small ? 13 : 17) * g.scale)
                    if !small || count <= 4 {
                        Text(op.title)
                            .font(.system(size: (small ? 8.5 : 9.5) * g.scale, weight: .medium))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                }
            } else {
                Text(op.title)
                    .font(.dialCode((small ? 11 : 14) * g.scale))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
        }
        .foregroundStyle(color)
        .opacity(op.enabled ? 1 : 0.32)
        .frame(width: width)
        .position(p)
    }

    // MARK: Needle

    private var hoveredRing: Int? {
        if case let .segment(ring, _) = model.hit { return ring }
        return nil
    }

    /// The hub is the knob; its pointer turns to whatever is highlighted.
    private var needle: some View {
        let r = g.hubRadius - 9 * g.scale
        return Capsule()
            .fill(Theme.mark)
            .frame(width: 3.5 * g.scale, height: 10 * g.scale)
            .position(x: g.center.x, y: g.center.y - r)
            .rotationEffect(.radians(model.needleAngle), anchor: UnitPoint(x: g.center.x / g.size.width, y: g.center.y / g.size.height))
            .opacity(hoveredRing == nil ? 0 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.7), value: model.needleAngle)
            .animation(.easeOut(duration: 0.12), value: hoveredRing)
    }

    // MARK: Hub

    private var hub: some View {
        let d = g.hubRadius * 2
        return ZStack {
            Circle().fill(Color(nsColor: Theme.hub).opacity(solid ? 1 : 0.55))
                .overlay(Circle().stroke(Color(nsColor: Theme.edge).opacity(solid ? 0.5 : 0.25), lineWidth: 0.75))
            hubContent
                .frame(width: d - 26 * g.scale, height: d - 24 * g.scale)
        }
        .frame(width: d, height: d)
        .position(g.center)
    }

    @ViewBuilder
    private var hubContent: some View {
        if model.operations.isEmpty {
            VStack(spacing: 2 * g.scale) {
                Image(systemName: "circle.slash").font(.system(size: 15 * g.scale)).foregroundStyle(Color(nsColor: Theme.textMuted))
                Text(LocalizedStringKey(model.kind == .tools ? "No tools for this file" : "Nothing to convert to"))
                    .font(.system(size: 9 * g.scale, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.text))
                    .multilineTextAlignment(.center)
            }
        } else if let op = model.operation(at: model.hit) {
            VStack(spacing: 2 * g.scale) {
                if let symbol = op.symbol {
                    Image(systemName: symbol).font(.system(size: 17 * g.scale, weight: .medium)).foregroundStyle(Theme.mark)
                    Text(op.title).font(.system(size: 11 * g.scale, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                } else {
                    Text(op.title).font(.dialCode(17 * g.scale, weight: .bold)).foregroundStyle(Theme.mark)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(fromTo(op)).font(.system(size: 9.5 * g.scale, weight: .medium))
                        .foregroundStyle(Color(nsColor: Theme.textMuted)).lineLimit(1).minimumScaleFactor(0.7)
                }
                if prefs.showHints || !op.enabled {
                    Text(op.enabled ? op.hint : (op.disabledReason ?? ""))
                        .font(.system(size: 8.5 * g.scale))
                        .foregroundStyle(Color(nsColor: Theme.textMuted))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }
            .foregroundStyle(Color(nsColor: Theme.text))
        } else {
            VStack(spacing: 3 * g.scale) {
                ZStack(alignment: .bottomTrailing) {
                    if let thumb = model.thumbnail {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 44 * g.scale, height: 44 * g.scale)
                            .clipShape(RoundedRectangle(cornerRadius: 7 * g.scale, style: .continuous))
                    }
                    if model.files.count > 1 {
                        Text("\(model.files.count)")
                            .font(.system(size: 9 * g.scale, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5 * g.scale).padding(.vertical, 1.5 * g.scale)
                            .background(Capsule().fill(Theme.accent))
                            .offset(x: 6 * g.scale, y: 4 * g.scale)
                    }
                }
                Text(subjectCode)
                    .font(.dialCode(9 * g.scale, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Theme.textMuted))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    private var subjectCode: String {
        let codes = Set(model.files.map { FileKind.code(of: $0) }.filter { !$0.isEmpty })
        if codes.count == 1, let c = codes.first { return c }
        if model.files.count == 1 { return tr("Folder") }
        return filesCount(model.files.count)
    }

    private func fromTo(_ op: Operation) -> String {
        "\(subjectCode) → \(op.title)"
    }

    // MARK: Chips

    private var chips: some View {
        HStack(spacing: 6 * g.scale) {
            ForEach(WheelKind.allCases) { kind in
                chip(kind)
            }
        }
        .frame(width: g.size.width, height: g.chipsHeight)
        .position(x: g.size.width / 2, y: g.chipsRect.midY)
    }

    private func chip(_ kind: WheelKind) -> some View {
        let active = model.kind == kind
        let hovered = model.hit == .chip(kind)
        let enabled = model.available.contains(kind)
        return HStack(spacing: 4 * g.scale) {
            Text(prefs.key(for: kind).glyphs).font(.system(size: 11 * g.scale, weight: .semibold))
            Text(kind.title).font(.system(size: 11 * g.scale, weight: .medium))
        }
        .foregroundStyle(active ? Color.white : Color(nsColor: Theme.text))
        .padding(.horizontal, 10 * g.scale)
        .frame(height: 26 * g.scale)
        .background {
            if active {
                Capsule().fill(Theme.accent)
            } else {
                DialSurface(shape: Capsule(), solid: solid)
                    .overlay(Capsule().stroke(Theme.mark.opacity(hovered ? 0.9 : 0), lineWidth: 1.5))
            }
        }
        .opacity(enabled || active ? 1 : 0.4)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { model.chipFrames[kind] = proxy.frame(in: .named("wheel")) }
                .onChange(of: proxy.frame(in: .named("wheel"))) { model.chipFrames[kind] = $0 }
        })
    }
}
