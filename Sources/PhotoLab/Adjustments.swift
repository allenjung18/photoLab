import Foundation

/// The six chunk-2 adjustments, in the order the chain applies them.
/// Values are user-facing units (EV for exposure, -100…100 for the rest);
/// `Renderer` maps them onto Core Image parameters.
enum AdjustmentKind: String, CaseIterable, Codable, Identifiable {
    case exposure, contrast, temperature, tint, vibrance, saturation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .exposure: return "Exposure"
        case .contrast: return "Contrast"
        case .temperature: return "Temperature"
        case .tint: return "Tint"
        case .vibrance: return "Vibrance"
        case .saturation: return "Saturation"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -5...5
        default: return -100...100
        }
    }

    /// The value at which the adjustment does nothing.
    var neutral: Double { 0 }

    func format(_ value: Double) -> String {
        switch self {
        case .exposure: return String(format: "%+.2f", value)
        default: return String(format: "%+.0f", value)
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
/// and chunk 3 persists it as the sidecar JSON.
struct Recipe: Codable, Hashable {
    var adjustments: [Adjustment]

    /// Every kind at its neutral value, enabled.
    static let neutral = Recipe(
        adjustments: AdjustmentKind.allCases.map { Adjustment(kind: $0, value: $0.neutral) })

    var isNeutral: Bool { adjustments.allSatisfy(\.isNoop) }

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

    mutating func set(_ kind: AdjustmentKind, to value: Double) { self[kind].value = value }
    mutating func setEnabled(_ kind: AdjustmentKind, _ on: Bool) { self[kind].enabled = on }
    mutating func reset(_ kind: AdjustmentKind) { self[kind].value = kind.neutral }
    mutating func resetAll() { self = .neutral }
}
