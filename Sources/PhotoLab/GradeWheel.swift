import SwiftUI

/// The arithmetic of a color-grading wheel (`GradeWheel`), pure: a point in
/// the wheel's square to a range's hue and saturation, and back.
///
/// The wheel fills a `side`-point square (origin top left, y down, as SwiftUI
/// lays it out). Hue is the angle COUNTER-CLOCKWISE from 3 o'clock: red at
/// 0°, 90° at 12 o'clock, green at 120°, blue at 240°, the convention
/// `ColorCubes.tintDirection(hue:)` renders, so the colour under the puck is
/// the colour the grade gives. Saturation is the distance from the centre as
/// a percent of the radius, clamped at the rim: a point outside the wheel is
/// saturation 100 at its angle.
enum GradeWheelMath {
    /// One range's hue (0…360) and saturation (0…100), the values of
    /// `AdjustmentKind.grade(.hue, range)` and `.grade(.saturation, range)`.
    struct Puck: Equatable {
        var hue: Double
        var saturation: Double
    }

    /// The hue and saturation at `point` in a wheel `side` points across. At
    /// the centre the hue is undefined and `hueAtCentre` is returned with
    /// saturation 0, so dragging through the middle does not snap the hue.
    static func puck(at point: CGPoint, side: Double, hueAtCentre: Double = 0) -> Puck {
        let radius = side / 2
        guard radius > 0 else { return Puck(hue: hueAtCentre, saturation: 0) }
        let dx = (Double(point.x) - radius) / radius
        let dy = (radius - Double(point.y)) / radius
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 1e-9 else { return Puck(hue: hueAtCentre, saturation: 0) }
        var hue = atan2(dy, dx) * 180 / .pi
        if hue < 0 { hue += 360 }
        return Puck(hue: hue, saturation: min(distance, 1) * 100)
    }

    /// Where the puck for `puck` sits in a wheel `side` points across; the
    /// inverse of `puck(at:side:)` inside the rim.
    static func point(for puck: Puck, side: Double) -> CGPoint {
        let radius = side / 2
        let s = min(max(puck.saturation, 0), 100) / 100
        let a = puck.hue * .pi / 180
        return CGPoint(x: radius + cos(a) * s * radius, y: radius - sin(a) * s * radius)
    }

    /// The range's puck as the recipe holds it.
    static func puck(of range: AdjustmentKind.GradeRange, in recipe: Recipe) -> Puck {
        Puck(hue: recipe.value(of: .grade(.hue, range)),
             saturation: recipe.value(of: .grade(.saturation, range)))
    }

    /// `recipe` with the range's hue and saturation set to `puck`; every
    /// other kind (the range's luminance, balance) is left alone.
    static func setting(_ puck: Puck, for range: AdjustmentKind.GradeRange, in recipe: Recipe) -> Recipe {
        var r = recipe
        r.set(.grade(.hue, range), to: puck.hue)
        r.set(.grade(.saturation, range), to: puck.saturation)
        return r
    }

    /// `recipe` with the range's hue and saturation back at neutral (the
    /// wheel's double-click); its luminance and balance are left alone.
    static func resetting(_ range: AdjustmentKind.GradeRange, in recipe: Recipe) -> Recipe {
        var r = recipe
        r.reset(.grade(.hue, range))
        r.reset(.grade(.saturation, range))
        return r
    }
}

/// One puck drag on a wheel, through the one recipe path: the first move
/// calls `Library.beginEdit`, every move sets the range's hue and saturation
/// through `Library.setRecipe` (the loupe follows live), and `end` calls
/// `Library.endEdit`, so the whole drag is ONE undo step and ONE sidecar
/// write, at mouse-up.
@MainActor
struct GradeWheelDrag {
    let range: AdjustmentKind.GradeRange
    private(set) var isOpen = false

    init(range: AdjustmentKind.GradeRange) { self.range = range }

    mutating func move(to point: CGPoint, side: Double, photo: Photo.ID, library: Library) {
        if !isOpen {
            library.beginEdit(photo)
            isOpen = true
        }
        let recipe = library.recipe(for: photo)
        let current = GradeWheelMath.puck(of: range, in: recipe)
        let puck = GradeWheelMath.puck(at: point, side: side, hueAtCentre: current.hue)
        library.setRecipe(GradeWheelMath.setting(puck, for: range, in: recipe), for: photo)
    }

    mutating func end(photo: Photo.ID, library: Library) {
        guard isOpen else { return }
        isOpen = false
        library.endEdit(photo)
    }

    /// The double-click: the range's hue and saturation to neutral, one
    /// `setRecipe` (one undo step; none when they already are).
    static func reset(_ range: AdjustmentKind.GradeRange, photo: Photo.ID, library: Library) {
        library.setRecipe(GradeWheelMath.resetting(range, in: library.recipe(for: photo)), for: photo)
    }
}

/// A color-grading wheel for one range: a hue disc, white at the centre and
/// full colour at the rim, with a puck at the range's hue (angle) and
/// saturation (radius). Drag the puck (or anywhere on the disc) to set both;
/// double-click to reset them.
struct GradeWheel: View {
    @Environment(Library.self) private var library
    let range: AdjustmentKind.GradeRange
    let photo: Photo.ID
    @State private var drag: GradeWheelDrag

    init(range: AdjustmentKind.GradeRange, photo: Photo.ID) {
        self.range = range
        self.photo = photo
        _drag = State(initialValue: GradeWheelDrag(range: range))
    }

    /// Hue stops for an `AngularGradient`, which runs CLOCKWISE on screen
    /// from 3 o'clock: listed from 360° down to 0° so the disc's hue runs
    /// counter-clockwise, as `GradeWheelMath` reads it.
    private static let hueStops: [Color] = stride(from: 360.0, through: 0, by: -30).map {
        Color(hue: $0.truncatingRemainder(dividingBy: 360) / 360, saturation: 1, brightness: 1)
    }

    var body: some View {
        let recipe = library.recipe(for: photo)
        let puck = GradeWheelMath.puck(of: range, in: recipe)
        let enabled = recipe.isEnabled(.grade(.hue, range)) && recipe.isEnabled(.grade(.saturation, range))
        VStack(spacing: 4) {
            GeometryReader { geo in
                let side = Double(min(geo.size.width, geo.size.height))
                let at = GradeWheelMath.point(for: puck, side: side)
                ZStack(alignment: .topLeading) {
                    Circle()
                        .fill(AngularGradient(colors: Self.hueStops, center: .center))
                        .overlay(Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)],
                                                              center: .center, startRadius: 0, endRadius: side / 2)))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                        .frame(width: side, height: side)
                    Circle()
                        .fill(puck.saturation > 0
                              ? Color(hue: puck.hue / 360, saturation: puck.saturation / 100, brightness: 1)
                              : Color.white)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.7), lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                        .offset(x: at.x - 5, y: at.y - 5)
                }
                .frame(width: side, height: side)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        drag.move(to: value.location, side: side, photo: photo, library: library)
                    }
                    .onEnded { _ in drag.end(photo: photo, library: library) })
                .onTapGesture(count: 2) { GradeWheelDrag.reset(range, photo: photo, library: library) }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(range.wheelTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(enabled ? 1 : 0.6)
        .disabled(!enabled)
        .help("Drag to set the \(range.label.lowercased()) hue and saturation; double-click to reset")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(range.wheelTitle) color wheel")
        .accessibilityValue(String(format: "hue %.0f degrees, saturation %.0f", puck.hue, puck.saturation))
        .onDisappear { drag.end(photo: photo, library: library) }
    }
}

extension AdjustmentKind.GradeRange {
    /// The wheel's caption: Shadows, Midtones, Highlights.
    var wheelTitle: String { label + "s" }
}
