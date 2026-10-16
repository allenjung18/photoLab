import SwiftUI

// MARK: - Handles: what a drag on the photo does to a mask

/// One on-canvas handle of a linear or radial mask, or a placement drag of
/// a new one. Positions and drags are in the SOURCE frame (`MaskPoint`):
/// the view maps the pointer there first (`MaskMath.viewToSource`), so a
/// handle means the same thing under any rotate, crop or zoom.
enum MaskHandle: Hashable {
    /// A linear mask's start line (full effect), centre pin and end line
    /// (no effect). The pin moves the gradient; an end handle turns it and
    /// sets the fade's length, about the pin, the other end mirroring it.
    case linearStart, linearCenter, linearEnd
    /// A radial mask's centre pin, one of its four edge handles (each sets
    /// one radius), its rotate handle (above the top edge) and its feather
    /// handle (on the inner ellipse, along the first axis).
    case radialCenter, radialEdge(RadialEdge), radialRotate, radialFeather

    /// The radial edges in the ellipse's own axes: `right` / `left` lie on
    /// its first axis (radii.x), `bottom` / `top` on its second (radii.y);
    /// an unturned ellipse's right is the screen's right.
    enum RadialEdge: CaseIterable, Hashable {
        case right, bottom, left, top

        var isFirstAxis: Bool { self == .right || self == .left }
    }

    var label: String {
        switch self {
        case .linearStart: "gradient start"
        case .linearCenter: "gradient centre"
        case .linearEnd: "gradient end"
        case .radialCenter: "radial centre"
        case .radialEdge(let e):
            switch e {
            case .right: "radial right edge"
            case .bottom: "radial bottom edge"
            case .left: "radial left edge"
            case .top: "radial top edge"
            }
        case .radialRotate: "radial rotation"
        case .radialFeather: "radial feather"
        }
    }
}

/// The handles' arithmetic, kept out of the view so it can be tested. Every
/// distance is in units of the source's long side (as `MaskMath.weight`
/// measures them), so a turn is a turn on screen and equal radii stay a
/// circle on any aspect ratio; points go in and come out as source
/// fractions. A drag is measured from where it started: the shape at the
/// drag's start, the pointer's start and where it is now, so a drag that
/// runs past a bound and comes back picks up where the pointer is.
enum MaskHandles {
    /// The least a radius may be: a radial shrunk to nothing would vanish
    /// with its handles.
    static let minRadius = 0.005
    /// How far above the top edge the rotate handle sits.
    static let rotateOffset = 0.06

    /// The source's long-side scale per axis: a fraction times this is long-side units.
    static func scale(_ size: CGSize) -> (x: Double, y: Double) {
        let long = max(Double(size.width), Double(size.height))
        guard long > 0 else { return (1, 1) }
        return (Double(size.width) / long, Double(size.height) / long)
    }

    private static func long(_ p: MaskPoint, _ s: (x: Double, y: Double)) -> (x: Double, y: Double) {
        (p.x * s.x, p.y * s.y)
    }

    private static func point(_ x: Double, _ y: Double, _ s: (x: Double, y: Double)) -> MaskPoint {
        MaskPoint(x: x / s.x, y: y / s.y)
    }

    /// The ellipse's two axes on screen (y down) for a clockwise `angle`.
    private static func axes(_ angle: Double) -> (u: (x: Double, y: Double), v: (x: Double, y: Double)) {
        let a = angle * .pi / 180
        return ((cos(a), sin(a)), (-sin(a), cos(a)))
    }

    /// Where each handle of `shape` sits, in the source frame; empty for a brush.
    static func positions(of shape: MaskShape, size: CGSize) -> [MaskHandle: MaskPoint] {
        let s = scale(size)
        switch shape {
        case .linear(let start, let end):
            return [.linearStart: start, .linearEnd: end,
                    .linearCenter: MaskPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)]
        case .radial(let center, let radii, let angle, let feather):
            let c = long(center, s), (u, v) = axes(angle)
            func at(_ a: Double, _ b: Double) -> MaskPoint {
                point(c.x + u.x * a + v.x * b, c.y + u.y * a + v.y * b, s)
            }
            let f = min(max(feather, 0), 1)
            return [.radialCenter: center,
                    .radialEdge(.right): at(radii.x, 0), .radialEdge(.left): at(-radii.x, 0),
                    .radialEdge(.bottom): at(0, radii.y), .radialEdge(.top): at(0, -radii.y),
                    .radialRotate: at(0, -(radii.y + rotateOffset)),
                    .radialFeather: at(radii.x * (1 - f), 0)]
        case .brush:
            return [:]
        }
    }

    /// `handle` dragged from `from` to `to` (source points) on a mask whose
    /// shape was `start` when the drag began, over a source of `size`. A
    /// handle that does not belong to the shape changes nothing.
    static func drag(_ handle: MaskHandle, shape start: MaskShape, from: MaskPoint, to: MaskPoint,
                     size: CGSize) -> MaskShape {
        let s = scale(size)
        let a = long(from, s), b = long(to, s)
        let dx = b.x - a.x, dy = b.y - a.y
        func moved(_ p: MaskPoint) -> MaskPoint {
            let l = long(p, s)
            return point(l.x + dx, l.y + dy, s)
        }
        switch (handle, start) {
        case (.linearCenter, .linear(let p0, let p1)):
            return .linear(start: moved(p0), end: moved(p1))
        case (.linearStart, .linear(let p0, let p1)), (.linearEnd, .linear(let p0, let p1)):
            // The dragged end follows the pointer; the other mirrors it
            // through the centre, which stays where it was.
            let l0 = long(p0, s), l1 = long(p1, s)
            let c = ((l0.x + l1.x) / 2, (l0.y + l1.y) / 2)
            let own = handle == .linearStart ? l0 : l1
            let e = (own.x + dx, own.y + dy)
            guard hypot(e.0 - c.0, e.1 - c.1) > 1e-6 else { return start }
            let other = point(2 * c.0 - e.0, 2 * c.1 - e.1, s), mine = point(e.0, e.1, s)
            return handle == .linearStart ? .linear(start: mine, end: other) : .linear(start: other, end: mine)
        case (.radialCenter, .radial(let center, let radii, let angle, let feather)):
            return .radial(center: moved(center), radii: radii, angle: angle, feather: feather)
        case (.radialEdge(let edge), .radial(let center, var radii, let angle, let feather)):
            let c = long(center, s), (u, v) = axes(angle)
            guard let h = positions(of: start, size: size)[handle] else { return start }
            let p = long(h, s), px = p.x + dx - c.x, py = p.y + dy - c.y
            if edge.isFirstAxis {
                radii.x = max(abs(px * u.x + py * u.y), minRadius)
            } else {
                radii.y = max(abs(px * v.x + py * v.y), minRadius)
            }
            return .radial(center: center, radii: radii, angle: angle, feather: feather)
        case (.radialRotate, .radial(let center, let radii, let angle, let feather)):
            let c = long(center, s)
            guard let h = positions(of: start, size: size)[handle] else { return start }
            let p = long(h, s)
            let before = atan2(p.y - c.y, p.x - c.x), after = atan2(p.y + dy - c.y, p.x + dx - c.x)
            return .radial(center: center, radii: radii, angle: normalized(angle + (after - before) * 180 / .pi),
                           feather: feather)
        case (.radialFeather, .radial(let center, let radii, let angle, _)):
            let c = long(center, s), (u, _) = axes(angle)
            guard let h = positions(of: start, size: size)[handle] else { return start }
            let p = long(h, s), px = p.x + dx - c.x, py = p.y + dy - c.y
            let along = px * u.x + py * u.y
            return .radial(center: center, radii: radii, angle: angle,
                           feather: min(max(1 - along / radii.x, 0), 1))
        default:
            return start
        }
    }

    /// An angle folded to -180...180.
    static func normalized(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }

    /// A new mask's shape from a placement drag: a linear from where the
    /// drag started (full effect) to where it is; a radial circle centred
    /// where it started, out to where it is. Nil for a brush.
    static func placed(_ kind: MaskKind, from: MaskPoint, to: MaskPoint, size: CGSize) -> MaskShape? {
        switch kind {
        case .linear:
            return .linear(start: from, end: to)
        case .radial:
            let s = scale(size), a = long(from, s), b = long(to, s)
            let r = max(hypot(b.x - a.x, b.y - a.y), minRadius)
            guard case .radial(_, _, let angle, let feather) = kind.defaultShape else { return nil }
            return .radial(center: from, radii: MaskRadii(x: r, y: r), angle: angle, feather: feather)
        case .brush:
            return nil
        }
    }

    /// A new mask's shape from a click (no drag): the kind's default shape
    /// (`MaskKind.defaultShape`) moved so its centre is where it was clicked.
    static func placed(_ kind: MaskKind, at point: MaskPoint) -> MaskShape? {
        switch kind.defaultShape {
        case .linear(let a, let b):
            let hx = (b.x - a.x) / 2, hy = (b.y - a.y) / 2
            return .linear(start: MaskPoint(x: point.x - hx, y: point.y - hy),
                           end: MaskPoint(x: point.x + hx, y: point.y + hy))
        case .radial(_, let radii, let angle, let feather):
            return .radial(center: point, radii: radii, angle: angle, feather: feather)
        case .brush:
            return nil
        }
    }
}

// MARK: - The overlay

/// The selected linear or radial mask's handles over the loupe photo, at fit
/// or in the 1:1 window (`MaskMath.Viewport`), on the `CropOverlay` pattern:
/// lines and an ellipse drawn in view points through
/// `MaskMath.sourceToView`, handles that take a drag in the overlay's own
/// coordinate space, measured from the drag's start. A linear shows its
/// start line (solid), centre line (dashed) and end line (solid) across the
/// photo, a centre pin and two end handles; a radial its ellipse, its inner
/// (feather) ellipse dashed, four edge handles, a centre pin, a rotate
/// handle and a feather handle. With New Linear or New Radial armed
/// (`Library.maskPlacement`) the whole photo takes the drag instead and it
/// places a new mask; a click places the kind's default shape there.
/// `drag` gets the handle and the pointer's start and current point in the
/// SOURCE frame; `end` the mouse-up.
struct MaskOverlay: View {
    /// The mask shown, nil while only placing.
    let shape: MaskShape?
    let geometry: MaskMath.Geometry
    let viewport: MaskMath.Viewport
    /// The area the photo covers in view points: lines are clipped to it.
    let bounds: CGRect
    let placing: MaskKind?
    let drag: (MaskHandle, MaskPoint, MaskPoint) -> Void
    let place: (MaskKind, MaskPoint, MaskPoint) -> Void
    let click: (MaskKind, MaskPoint) -> Void
    let end: () -> Void

    private static let space = "maskOverlay"
    private static let hitSize: CGFloat = 22
    /// How far an infinite gradient line is drawn each way, in long-side units.
    private static let lineReach = 3.0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let shape {
                drawing(shape)
                    .clipShape(Rectangle().path(in: bounds))
                    .allowsHitTesting(false)
                if placing == nil { handles(shape) }
            }
            if let placing { placementLayer(placing) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
    }

    private func view(_ p: MaskPoint) -> CGPoint { MaskMath.sourceToView(p, geometry, viewport) }
    private func source(_ v: CGPoint) -> MaskPoint? { MaskMath.viewToSource(v, geometry, viewport) }

    /// Lines, ellipses: the shape as it sits on the photo.
    @ViewBuilder private func drawing(_ shape: MaskShape) -> some View {
        let s = MaskHandles.scale(geometry.source)
        switch shape {
        case .linear(let start, let end):
            let mid = MaskPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            // The perpendicular to start -> end, in long-side units.
            let dx = (end.x - start.x) * s.x, dy = (end.y - start.y) * s.y
            let len = max(hypot(dx, dy), 1e-9)
            let px = -dy / len * Self.lineReach / s.x, py = dx / len * Self.lineReach / s.y
            let across = { (p: MaskPoint) -> (CGPoint, CGPoint) in
                (view(MaskPoint(x: p.x - px, y: p.y - py)), view(MaskPoint(x: p.x + px, y: p.y + py)))
            }
            ZStack {
                ForEach(Array([start, end].enumerated()), id: \.offset) { _, p in
                    let (a, b) = across(p)
                    linePath(a, b).stroke(Color.white, lineWidth: 1)
                }
                let (a, b) = across(mid)
                linePath(a, b).stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .shadow(color: .black.opacity(0.6), radius: 1)
        case .radial(let center, let radii, let angle, let feather):
            let f = min(max(feather, 0), 1)
            ZStack {
                ellipsePath(center, radii, angle, factor: 1).stroke(Color.white, lineWidth: 1)
                if f > 0, f < 1 {
                    ellipsePath(center, radii, angle, factor: 1 - f)
                        .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                if let top = MaskHandles.positions(of: shape, size: geometry.source)[.radialEdge(.top)],
                   let knob = MaskHandles.positions(of: shape, size: geometry.source)[.radialRotate] {
                    linePath(view(top), view(knob)).stroke(Color.white.opacity(0.8), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(0.6), radius: 1)
        case .brush:
            EmptyView()
        }
    }

    private func linePath(_ a: CGPoint, _ b: CGPoint) -> Path {
        Path { p in
            p.move(to: a)
            p.addLine(to: b)
        }
    }

    /// The ellipse (radii scaled by `factor`) through the view mapping, as a
    /// polygon: under a rotate an ellipse in the source stays an ellipse,
    /// and 96 sides draw it smoothly at any size the loupe shows.
    private func ellipsePath(_ center: MaskPoint, _ radii: MaskRadii, _ angle: Double, factor: Double) -> Path {
        let s = MaskHandles.scale(geometry.source)
        let a = angle * .pi / 180
        let c = (x: center.x * s.x, y: center.y * s.y)
        return Path { p in
            for i in 0...96 {
                let t = Double(i) / 96 * 2 * .pi
                let u = radii.x * factor * cos(t), v = radii.y * factor * sin(t)
                let x = c.x + u * cos(a) - v * sin(a), y = c.y + u * sin(a) + v * cos(a)
                let pt = view(MaskPoint(x: x / s.x, y: y / s.y))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        }
    }

    /// The handles of `shape`, each taking its own drag.
    @ViewBuilder private func handles(_ shape: MaskShape) -> some View {
        let positions = MaskHandles.positions(of: shape, size: geometry.source)
        ForEach(Self.order.filter { positions[$0] != nil }, id: \.self) { handle in
            handleMark(handle)
                .frame(width: Self.hitSize, height: Self.hitSize)
                .contentShape(Rectangle())
                .position(view(positions[handle]!))
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                        .onChanged { g in
                            guard let a = source(g.startLocation), let b = source(g.location) else { return }
                            drag(handle, a, b)
                        }
                        .onEnded { _ in end() })
                .accessibilityLabel("Mask \(handle.label)")
        }
    }

    /// Drawing order, last on top: the centre pin over everything, so a
    /// tiny mask can still be moved.
    private static let order: [MaskHandle] =
        [.linearStart, .linearEnd, .radialFeather, .radialRotate]
        + MaskHandle.RadialEdge.allCases.map { .radialEdge($0) }
        + [.linearCenter, .radialCenter]

    private func handleMark(_ handle: MaskHandle) -> some View {
        Group {
            switch handle {
            case .linearCenter, .radialCenter:
                Circle().fill(Color.accentColor).overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .frame(width: 11, height: 11)
            case .radialRotate:
                Circle().stroke(Color.white, lineWidth: 1.5).frame(width: 9, height: 9)
            case .radialFeather:
                Rectangle().fill(Color.white).frame(width: 7, height: 7).rotationEffect(.degrees(45))
            default:
                Rectangle().fill(Color.white).frame(width: 8, height: 8)
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 1)
    }

    /// New Linear / New Radial armed: the photo takes the drag (start to
    /// end; centre to edge) or a click, and a hint says what to do.
    @ViewBuilder private func placementLayer(_ kind: MaskKind) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: bounds.width, height: bounds.height)
            .position(x: bounds.midX, y: bounds.midY)
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                    .onChanged { g in
                        guard let a = source(g.startLocation), let b = source(g.location) else { return }
                        place(kind, a, b)
                    }
                    .onEnded { _ in end() })
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named(Self.space))
                    .onEnded { g in if let p = source(g.location) { click(kind, p) } })
            .accessibilityLabel(kind == .linear ? "Place a linear gradient: drag from full effect to none"
                                : "Place a radial gradient: drag from its centre to its edge")
        Text(kind == .linear ? "Drag from where the effect is full to where it ends; Esc to cancel"
             : "Drag from the centre out to the edge; Esc to cancel")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
            .position(x: bounds.midX, y: bounds.minY + 20)
            .allowsHitTesting(false)
    }
}
