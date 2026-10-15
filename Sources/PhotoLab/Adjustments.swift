import Foundation

/// Every adjustment, listed in the order the chain applies them (geometry,
/// then exposure and white balance, tone, color, per-band HSL, detail,
/// effects). Values are user-facing units (EV for exposure, degrees for
/// rotate, percent of the frame for a crop edge, -100…100 or 0…100 for the
/// rest); `Renderer` maps them onto Core Image parameters.
///
/// Some kinds are applied together as one stage (`group`): the four crop
/// edges are one crop, highlights / shadows / whites / blacks and the five
/// curve points are one tone lookup, the 24 HSL sliders are one color cube.
enum AdjustmentKind: String, CaseIterable, Codable, Identifiable {
    // Geometry
    case rotate, cropLeft, cropTop, cropRight, cropBottom
    // Exposure and white balance
    case exposure, temperature, tint, contrast
    // Tone (one lookup)
    case highlights, shadows, whites, blacks
    case curveBlacks, curveShadows, curveMidtones, curveHighlights, curveWhites
    // Color
    case vibrance, saturation
    // Per-band HSL (one cube)
    case hueRed, hueOrange, hueYellow, hueGreen, hueAqua, hueBlue, huePurple, hueMagenta
    case satRed, satOrange, satYellow, satGreen, satAqua, satBlue, satPurple, satMagenta
    case lumRed, lumOrange, lumYellow, lumGreen, lumAqua, lumBlue, lumPurple, lumMagenta
    // Detail and effects
    case clarity, sharpening, grain, vignette

    var id: String { rawValue }

    /// Kinds the renderer applies as one stage.
    enum Group: Hashable { case crop, tone, hsl }

    var group: Group? {
        switch self {
        case .cropLeft, .cropTop, .cropRight, .cropBottom: return .crop
        case .highlights, .shadows, .whites, .blacks,
             .curveBlacks, .curveShadows, .curveMidtones, .curveHighlights, .curveWhites: return .tone
        case .hueRed, .hueOrange, .hueYellow, .hueGreen, .hueAqua, .hueBlue, .huePurple, .hueMagenta,
             .satRed, .satOrange, .satYellow, .satGreen, .satAqua, .satBlue, .satPurple, .satMagenta,
             .lumRed, .lumOrange, .lumYellow, .lumGreen, .lumAqua, .lumBlue, .lumPurple, .lumMagenta: return .hsl
        default: return nil
        }
    }

    // These run per kind on every render; keep them table lookups (a debug
    // build pays for string work in a hot loop).
    static func members(of group: Group) -> [AdjustmentKind] { membersByGroup[group] ?? [] }
    private static let membersByGroup: [Group: [AdjustmentKind]] =
        Dictionary(grouping: allCases.filter { $0.group != nil }, by: { $0.group! })

    var label: String {
        switch self {
        case .rotate: return "Rotate"
        case .cropLeft: return "Crop left"
        case .cropTop: return "Crop top"
        case .cropRight: return "Crop right"
        case .cropBottom: return "Crop bottom"
        case .exposure: return "Exposure"
        case .temperature: return "Temperature"
        case .tint: return "Tint"
        case .contrast: return "Contrast"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .whites: return "Whites"
        case .blacks: return "Blacks"
        case .curveBlacks: return "Blacks"
        case .curveShadows: return "Shadows"
        case .curveMidtones: return "Midtones"
        case .curveHighlights: return "Highlights"
        case .curveWhites: return "Whites"
        case .vibrance: return "Vibrance"
        case .saturation: return "Saturation"
        case .clarity: return "Clarity"
        case .sharpening: return "Sharpening"
        case .grain: return "Grain"
        case .vignette: return "Vignette"
        default:
            if let (_, band) = hsl { return band.label }
            return rawValue
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -5...5
        case .rotate: return -45...45
        case .cropLeft, .cropTop, .cropRight, .cropBottom: return 0...40
        case .sharpening, .grain: return 0...100
        default: return -100...100
        }
    }

    /// The value at which the adjustment does nothing.
    var neutral: Double { 0 }

    func format(_ value: Double) -> String {
        switch self {
        case .exposure: return String(format: "%+.2f", value)
        case .rotate: return String(format: "%+.1f°", value)
        case .cropLeft, .cropTop, .cropRight, .cropBottom: return String(format: "%.0f%%", value)
        case .sharpening, .grain: return String(format: "%.0f", value)
        default: return String(format: "%+.0f", value)
        }
    }

    // MARK: Panel layout

    enum Section: CaseIterable {
        case basic, color, curve, hsl, detail, effects, geometry

        var title: String {
            switch self {
            case .basic: return "Basic"
            case .color: return "Color"
            case .curve: return "Tone Curve"
            case .hsl: return "HSL"
            case .detail: return "Detail"
            case .effects: return "Effects"
            case .geometry: return "Crop & Rotate"
            }
        }

        var kinds: [AdjustmentKind] { AdjustmentKind.allCases.filter { $0.section == self } }
    }

    /// Rotate and the four crop edges: the kinds a preset never carries.
    static let geometryKinds: [AdjustmentKind] = allCases.filter { $0.section == .geometry }

    var section: Section {
        switch self {
        case .rotate, .cropLeft, .cropTop, .cropRight, .cropBottom: return .geometry
        case .exposure, .contrast, .highlights, .shadows, .whites, .blacks: return .basic
        case .temperature, .tint, .vibrance, .saturation: return .color
        case .curveBlacks, .curveShadows, .curveMidtones, .curveHighlights, .curveWhites: return .curve
        case .clarity, .sharpening, .grain: return .detail
        case .vignette: return .effects
        default: return .hsl
        }
    }

    // MARK: HSL

    enum HSLChannel: CaseIterable {
        case hue, saturation, luminance
        var title: String {
            switch self {
            case .hue: return "Hue"
            case .saturation: return "Saturation"
            case .luminance: return "Luminance"
            }
        }
        var prefix: String {
            switch self {
            case .hue: return "hue"
            case .saturation: return "sat"
            case .luminance: return "lum"
            }
        }
    }

    /// Lightroom's eight bands, with the hue each is centered on (degrees).
    enum HSLBand: Int, CaseIterable {
        case red, orange, yellow, green, aqua, blue, purple, magenta
        var label: String {
            switch self {
            case .red: return "Red"
            case .orange: return "Orange"
            case .yellow: return "Yellow"
            case .green: return "Green"
            case .aqua: return "Aqua"
            case .blue: return "Blue"
            case .purple: return "Purple"
            case .magenta: return "Magenta"
            }
        }
        var centerDegrees: Double {
            switch self {
            case .red: return 0
            case .orange: return 30
            case .yellow: return 60
            case .green: return 120
            case .aqua: return 180
            case .blue: return 240
            case .purple: return 280
            case .magenta: return 320
            }
        }
    }

    static func hsl(_ channel: HSLChannel, _ band: HSLBand) -> AdjustmentKind {
        AdjustmentKind(rawValue: channel.prefix + band.label)!
    }

    /// The channel and band of an HSL kind, nil for every other kind.
    var hsl: (HSLChannel, HSLBand)? { Self.hslByKind[self] }
    private static let hslByKind: [AdjustmentKind: (HSLChannel, HSLBand)] = {
        var map: [AdjustmentKind: (HSLChannel, HSLBand)] = [:]
        for channel in HSLChannel.allCases { for band in HSLBand.allCases { map[hsl(channel, band)] = (channel, band) } }
        return map
    }()

    /// The x position (0…1) of a tone-curve point, nil for every other kind.
    var curveX: Double? {
        switch self {
        case .curveBlacks: return 0
        case .curveShadows: return 0.25
        case .curveMidtones: return 0.5
        case .curveHighlights: return 0.75
        case .curveWhites: return 1
        default: return nil
        }
    }
}

/// One entry of a recipe: a kind, its value and whether it is applied.
struct Adjustment: Codable, Hashable, Identifiable {
    var kind: AdjustmentKind
    var value: Double
    var enabled: Bool = true

    var id: AdjustmentKind { kind }

    /// True when applying this entry would change nothing.
    var isNoop: Bool { !enabled || value == kind.neutral }
}

/// An ordered list of adjustments: the whole edit of one photo. Edits are
/// data (README, Design): toggles, presets and batch apply all mutate this,
/// and the sidecar persists it as JSON. A kind that is missing from the
/// list (an older sidecar) reads as neutral; the renderer applies kinds in
/// `AdjustmentKind.allCases` order whatever order the list has.
struct Recipe: Codable, Hashable {
    var adjustments: [Adjustment]

    /// Every kind at its neutral value, enabled.
    static let neutral = Recipe(
        adjustments: AdjustmentKind.allCases.map { Adjustment(kind: $0, value: $0.neutral) })

    /// Render identity: applying this recipe changes nothing. A disabled
    /// entry counts (it is not applied), so a recipe can be neutral and still
    /// carry values worth keeping; use `isDefault` for "is there an edit".
    var isNeutral: Bool { adjustments.allSatisfy(\.isNoop) }

    /// True when this is the default recipe: every kind at its neutral value
    /// and enabled. A disabled-only edit (a value kept but switched off) is
    /// NOT the default, so it stays in memory, keeps its sidecar and counts
    /// as edited; `isNeutral` is the render-side notion.
    var isDefault: Bool { normalized == .neutral }

    subscript(kind: AdjustmentKind) -> Adjustment {
        get {
            adjustments.first { $0.kind == kind } ?? Adjustment(kind: kind, value: kind.neutral)
        }
        set {
            if let i = adjustments.firstIndex(where: { $0.kind == kind }) {
                adjustments[i] = newValue
            } else {
                adjustments.append(newValue)
            }
        }
    }

    func value(of kind: AdjustmentKind) -> Double { self[kind].value }
    func isEnabled(_ kind: AdjustmentKind) -> Bool { self[kind].enabled }

    /// The applied value: neutral when disabled.
    func effective(_ kind: AdjustmentKind) -> Double {
        let a = self[kind]
        return a.isNoop ? kind.neutral : a.value
    }

    /// Every kind present once, in chain order: the canonical form, so two
    /// recipes that render the same compare equal whatever a sidecar listed.
    var normalized: Recipe {
        Recipe(adjustments: AdjustmentKind.allCases.map { self[$0] })
    }

    mutating func set(_ kind: AdjustmentKind, to value: Double) { self[kind].value = value }
    mutating func setEnabled(_ kind: AdjustmentKind, _ on: Bool) { self[kind].enabled = on }
    mutating func reset(_ kind: AdjustmentKind) { self[kind].value = kind.neutral }
    mutating func resetAll() { self = .neutral }
}
