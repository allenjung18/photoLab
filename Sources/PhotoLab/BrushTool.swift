import SwiftUI
import AppKit

// MARK: - The brush's settings

/// The brush a new stroke is painted with: tool state like the crop's
/// aspect, never in a recipe and never remembered. A stroke keeps the values
/// it was painted with (`BrushStroke`), so changing them changes only the
/// strokes that follow. `size` is the stroke's radius, a fraction of the
/// source's long side (as `BrushStroke.radius`), so a brush covers the same
/// part of the photo at any zoom.
struct BrushSettings: Equatable {
    var size: Double = 0.05
    var feather: Double = 0.5
    var flow: Double = 1

    static let sizeRange: ClosedRange<Double> = 0.005...0.3
    static let featherRange: ClosedRange<Double> = 0...1
    static let flowRange: ClosedRange<Double> = 0.05...1
    /// What one [ or ] does to the size: a step of a quarter, so eight
    /// presses about double or halve it twice over, the same feel at any size.
    static let sizeStep = 1.25

    /// The size one ] (larger) or [ (smaller) from `size`, held in `sizeRange`.
    static func stepped(_ size: Double, larger: Bool) -> Double {
        let next = larger ? size * sizeStep : size / sizeStep
        return min(max(next, sizeRange.lowerBound), sizeRange.upperBound)
    }
}

// MARK: - Thinning: how many points a drag keeps

/// The rule that keeps a long drag a few hundred points: a pointer position
/// joins the stroke only once it is at least a quarter of the radius (the
/// raster's dab spacing, `BrushRaster.dabSpacing`) from the last point
/// kept, measured in units of the source's long side. Thinner than that
/// would add points the raster lays no new dab for.
enum BrushThinning {
    static func minimumGap(radius: Double) -> Double { BrushRaster.dabSpacing(radius: radius) }

    /// True when `next` is far enough from `last` (source fractions, over a
    /// source of `size`) to join a stroke of `radius`.
    static func keeps(_ next: MaskPoint, after last: MaskPoint, radius: Double, size: CGSize) -> Bool {
        let s = MaskHandles.scale(size)
        let d = hypot((next.x - last.x) * s.x, (next.y - last.y) * s.y)
        return d >= minimumGap(radius: radius)
    }
}

// MARK: - The library's painting

/// Painting goes through `Library.setRecipe` like every other mask edit: a
/// stroke opens one `beginEdit` on its first point and grows the selected
/// brush mask's last stroke in place on every later one (so the loupe
/// re-renders as it grows, latest-wins), and its mouse-up closes the edit:
/// ONE stroke is ONE undo step and ONE sidecar write.
extension Library {
    /// The brush mask a drag on the photo paints into: the selected mask,
    /// when it is a brush, the brush is armed and the loupe shows. Nil
    /// otherwise, and then a drag paints nothing.
    var paintingBrush: UUID? {
        guard loupe, maskBrushArmed, let photo = selection, let id = selectedMask,
              let mask = mask(id, for: photo), case .brush = mask.shape else { return nil }
        return id
    }

    /// A point of the stroke being painted: `start` is where the drag began,
    /// `point` where the pointer is now (both source fractions over a source
    /// of `size` pixels). The first call opens the edit and adds a new stroke
    /// at `start` with the brush's size, feather and flow (an erase stroke
    /// when `erase`, read once, at the stroke's start); every call then adds
    /// `point` if it is far enough from the last one kept (`BrushThinning`).
    /// Nothing happens with no brush to paint into (`paintingBrush`).
    func paintBrush(from start: MaskPoint, to point: MaskPoint, erase: Bool, size: CGSize, for id: Photo.ID) {
        if brushStrokeMask == nil {
            guard id == selection, let maskID = paintingBrush else { return }
            beginEdit(id)
            let stroke = BrushStroke(points: [start], radius: brush.size, feather: brush.feather,
                                     flow: brush.flow, erase: erase)
            updateMask(maskID, for: id) { mask in
                if case .brush(let strokes) = mask.shape { mask.shape = .brush(strokes + [stroke]) }
            }
            brushStrokeMask = maskID
        }
        guard let maskID = brushStrokeMask, let mask = mask(maskID, for: id),
              case .brush(var strokes) = mask.shape, var stroke = strokes.last,
              let last = stroke.points.last,
              BrushThinning.keeps(point, after: last, radius: stroke.radius, size: size) else { return }
        stroke.points.append(point)
        strokes[strokes.count - 1] = stroke
        updateMask(maskID, for: id) { $0.shape = .brush(strokes) }
    }

    /// The stroke's mouse-up: the edit closes, one undo step and one write.
    func endBrushStroke(_ id: Photo.ID) {
        guard brushStrokeMask != nil else { return }
        brushStrokeMask = nil
        endEdit(id)
    }

    /// [ and ]: the brush one step smaller or larger, within its range.
    func stepBrushSize(larger: Bool) {
        brush.size = BrushSettings.stepped(brush.size, larger: larger)
    }
}

// MARK: - The painting layer

/// While the brush is armed on a selected brush mask (`Library.paintingBrush`):
/// the photo takes the drag and paints, Option held at its start erases, and
/// a circle of the brush's size with an inner ring where the feather starts
/// follows the pointer over the photo. Points go to the library in the
/// SOURCE frame (`MaskMath.viewToSource`), so a stroke lands on the same
/// pixels under any rotate, crop or zoom.
struct BrushOverlay: View {
    let geometry: MaskMath.Geometry
    let viewport: MaskMath.Viewport
    /// The area the photo covers in view points.
    let bounds: CGRect
    let settings: BrushSettings
    let paint: (MaskPoint, MaskPoint, Bool) -> Void
    let end: () -> Void

    private static let space = "brushOverlay"
    @State private var pointer: CGPoint?
    /// Whether the drag in progress erases, read at its first point.
    @State private var erasing: Bool?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: bounds.width, height: bounds.height)
                .position(x: bounds.midX, y: bounds.midY)
                .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                    switch phase {
                    case .active(let p): pointer = p
                    case .ended: pointer = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                        .onChanged { g in
                            pointer = g.location
                            let erase = erasing ?? NSEvent.modifierFlags.contains(.option)
                            erasing = erase
                            guard let a = source(g.startLocation), let b = source(g.location) else { return }
                            paint(a, b, erase)
                        }
                        .onEnded { _ in
                            erasing = nil
                            end()
                        })
                .accessibilityLabel("Paint the brush mask: drag on the photo; hold Option to erase")
            if let pointer, bounds.contains(pointer) {
                cursor(at: pointer).allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
    }

    private func source(_ v: CGPoint) -> MaskPoint? { MaskMath.viewToSource(v, geometry, viewport) }

    /// The brush's radius in view points at `p`: the source distance mapped
    /// through the viewport (rotate keeps lengths, crop and zoom scale them).
    private func radius(at p: CGPoint) -> CGFloat {
        BrushOverlay.viewRadius(settings.size, at: p, geometry, viewport)
    }

    /// `size` (long-side fraction) as a radius in view points about view point `p`.
    static func viewRadius(_ size: Double, at p: CGPoint, _ g: MaskMath.Geometry, _ v: MaskMath.Viewport) -> CGFloat {
        guard let c = MaskMath.viewToSource(p, g, v) else { return 0 }
        let s = MaskHandles.scale(g.source)
        let edge = MaskMath.sourceToView(MaskPoint(x: c.x + size / s.x, y: c.y), g, v)
        let a = MaskMath.sourceToView(c, g, v)
        return hypot(edge.x - a.x, edge.y - a.y)
    }

    private func cursor(at p: CGPoint) -> some View {
        let r = radius(at: p)
        let inner = r * (1 - min(max(settings.feather, 0), 1))
        return ZStack {
            Circle().stroke(Color.white, lineWidth: 1).frame(width: 2 * r, height: 2 * r)
            if inner > 1, inner < r - 1 {
                Circle().stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 2 * inner, height: 2 * inner)
            }
        }
        .shadow(color: .black.opacity(0.7), radius: 1)
        .position(p)
    }
}

/// The selected brush's three rows in the Masks section: Size, Feather and
/// Flow of the strokes painted next (`Library.brush`); a double-click on a
/// name puts it back to its default.
struct BrushSettingsRows: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        VStack(alignment: .leading, spacing: 10) {
            row("Size", value: $library.brush.size, range: BrushSettings.sizeRange,
                reset: BrushSettings().size, format: { String(format: "%.1f%%", $0 * 100) },
                help: "The brush's radius, a share of the photo's long side ([ and ])")
            row("Feather", value: $library.brush.feather, range: BrushSettings.featherRange,
                reset: BrushSettings().feather, format: { String(format: "%.0f%%", $0 * 100) },
                help: "How much of the brush's edge is soft")
            row("Flow", value: $library.brush.flow, range: BrushSettings.flowRange,
                reset: BrushSettings().flow, format: { String(format: "%.0f%%", $0 * 100) },
                help: "How much one stroke lays down")
            Text(library.maskBrushArmed ? "Drag on the photo to paint; hold Option to erase."
                 : "Press K or the Brush button to paint into this mask.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, reset: Double,
                     format: @escaping (Double) -> String, help: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(name)
                    .onTapGesture(count: 2) { value.wrappedValue = reset }
                    .help("Double-click to reset")
                Spacer()
                Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: value, in: range).controlSize(.small)
                .help(help)
                .accessibilityLabel("Brush " + name.lowercased())
        }
    }
}
