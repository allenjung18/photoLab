import Foundation

/// What reading one Lightroom `.xmp` preset gave: a recipe and an account of
/// every setting in the file that changes a photo (D-471 (a), direct sliders
/// with the tone curves approximated). Nothing that changes a photo is
/// dropped silently: each such setting is in exactly one of `mapped`,
/// `approximated` or `unsupported`; `clamped` names the mapped or
/// approximated settings whose value fell outside the slider's range.
struct XMPImport: Equatable {
    /// One setting carried straight onto a slider: the file's key (as
    /// `XMPPreset.mapping` names it), the kind it set and the value it set
    /// it to (after the table's scale and any clamp).
    struct Mapped: Equatable {
        var setting: String
        var kind: AdjustmentKind
        var value: Double
    }

    /// A setting with no PhotoLab equivalent: the file's key and a plain
    /// label for the import sheet ("Dehaze", "Masks").
    struct Unsupported: Equatable {
        var setting: String
        var label: String
    }

    /// `crs:PresetName`, else the `crs:Name` alt text, else the file's stem.
    var name: String
    /// Every mapped and approximated value on top of `Recipe.neutral`; no
    /// geometry, no lens kinds and no masks, ever.
    var recipe: Recipe
    /// Non-neutral direct settings, in `XMPPreset.mapping` order.
    var mapped: [Mapped]
    /// Tone-curve settings approximated onto the five curve points.
    var approximated: [String]
    /// Non-neutral settings outside the table: those `XMPPreset.unsupportedRules`
    /// names, in its order, then any other key, sorted, by `XMPPreset.plainLabel`.
    var unsupported: [Unsupported]
    /// Settings whose value was clamped into the kind's range.
    var clamped: [String]
}

enum XMPImportError: Error, Equatable, LocalizedError {
    /// The data is not well-formed XML.
    case notXML
    /// Well-formed, but no Camera Raw (`crs:`) setting at the top level.
    case noCameraRawSettings

    var errorDescription: String? {
        switch self {
        case .notXML: return "The file is not an XMP preset (it is not XML)."
        case .noCameraRawSettings: return "The file holds no Lightroom develop settings."
        }
    }
}

/// Reads a Lightroom Classic / Camera Raw `.xmp` preset (or sidecar) into an
/// `XMPImport`. Pure: it reads the bytes it is given and never writes the
/// file. Both forms Adobe writes are read, `crs:Exposure2012="+0.50"` as an
/// attribute of an `rdf:Description` and `<crs:Exposure2012>+0.50</...>` as
/// an element; a `crs:` element's own nested `crs:` keys (a mask's
/// correction, a Look's parameters) are never read as global settings.
enum XMPPreset {
    static let namespace = "http://ns.adobe.com/camera-raw-settings/1.0/"

    /// The direct mapping, D-471 (a): the file's key -> the kind it sets and
    /// the factor its value is multiplied by. When two keys set one kind and
    /// both are present, the earlier row wins (Color Grading before the old
    /// Split Toning, which Lightroom 10+ writes beside it as a mirror).
    static let mapping: [(setting: String, kind: AdjustmentKind, scale: Double)] = [
        // Basic tone, process 2012 (EV, then -100...100)
        ("Exposure2012", .exposure, 1),
        ("Contrast2012", .contrast, 1),
        ("Highlights2012", .highlights, 1),
        ("Shadows2012", .shadows, 1),
        ("Whites2012", .whites, 1),
        ("Blacks2012", .blacks, 1),
        // Relative white balance (a preset's; + is warmer / more magenta, as here)
        ("IncrementalTemperature", .temperature, 1),
        ("IncrementalTint", .tint, 1),
        // Presence
        ("Vibrance", .vibrance, 1),
        ("Saturation", .saturation, 1),
        ("Clarity2012", .clarity, 1),
        // Detail and effects: Lightroom's Sharpening amount runs 0...150
        ("Sharpness", .sharpening, 100.0 / 150),
        ("GrainAmount", .grain, 1),
        // Noise reduction; Lightroom's colour NR default of 25 maps to 0
        // (`apply`), so a preset carrying the default changes nothing.
        ("LuminanceSmoothing", .luminanceNoise, 1),
        ("ColorNoiseReduction", .colorNoise, 1),
        ("PostCropVignetteAmount", .vignette, 1),
        // HSL, eight bands each
        ("HueAdjustmentRed", .hueRed, 1),
        ("HueAdjustmentOrange", .hueOrange, 1),
        ("HueAdjustmentYellow", .hueYellow, 1),
        ("HueAdjustmentGreen", .hueGreen, 1),
        ("HueAdjustmentAqua", .hueAqua, 1),
        ("HueAdjustmentBlue", .hueBlue, 1),
        ("HueAdjustmentPurple", .huePurple, 1),
        ("HueAdjustmentMagenta", .hueMagenta, 1),
        ("SaturationAdjustmentRed", .satRed, 1),
        ("SaturationAdjustmentOrange", .satOrange, 1),
        ("SaturationAdjustmentYellow", .satYellow, 1),
        ("SaturationAdjustmentGreen", .satGreen, 1),
        ("SaturationAdjustmentAqua", .satAqua, 1),
        ("SaturationAdjustmentBlue", .satBlue, 1),
        ("SaturationAdjustmentPurple", .satPurple, 1),
        ("SaturationAdjustmentMagenta", .satMagenta, 1),
        ("LuminanceAdjustmentRed", .lumRed, 1),
        ("LuminanceAdjustmentOrange", .lumOrange, 1),
        ("LuminanceAdjustmentYellow", .lumYellow, 1),
        ("LuminanceAdjustmentGreen", .lumGreen, 1),
        ("LuminanceAdjustmentAqua", .lumAqua, 1),
        ("LuminanceAdjustmentBlue", .lumBlue, 1),
        ("LuminanceAdjustmentPurple", .lumPurple, 1),
        ("LuminanceAdjustmentMagenta", .lumMagenta, 1),
        // Color Grading (hue 0...359, sat 0...100, lum and balance -100...100)
        ("ColorGradeShadowHue", .gradeShadowHue, 1),
        ("ColorGradeShadowSat", .gradeShadowSat, 1),
        ("ColorGradeShadowLum", .gradeShadowLum, 1),
        ("ColorGradeMidtoneHue", .gradeMidtoneHue, 1),
        ("ColorGradeMidtoneSat", .gradeMidtoneSat, 1),
        ("ColorGradeMidtoneLum", .gradeMidtoneLum, 1),
        ("ColorGradeHighlightHue", .gradeHighlightHue, 1),
        ("ColorGradeHighlightSat", .gradeHighlightSat, 1),
        ("ColorGradeHighlightLum", .gradeHighlightLum, 1),
        ("ColorGradeBalance", .gradeBalance, 1),
        // Split Toning (pre-2020): shadow and highlight only
        ("SplitToningShadowHue", .gradeShadowHue, 1),
        ("SplitToningShadowSaturation", .gradeShadowSat, 1),
        ("SplitToningHighlightHue", .gradeHighlightHue, 1),
        ("SplitToningHighlightSaturation", .gradeHighlightSat, 1),
        ("SplitToningBalance", .gradeBalance, 1),
    ]

    /// The point curve (`ToneCurvePV2012`, "x, y" pairs on 0...255) and the
    /// parametric curve's four regions: approximated onto the five curve
    /// points (`approximateCurve`).
    static let pointCurveKey = "ToneCurvePV2012"
    static let parametricKeys = ["ParametricShadows", "ParametricDarks", "ParametricLights", "ParametricHighlights"]

    /// The y lift (0...1 scale) a parametric region at +100 gives the curve
    /// points either side of it. An approximation (the sheet says so).
    static let parametricLift = 0.1

    /// One raw setting as the file holds it.
    enum Raw: Equatable, Sendable {
        /// An attribute's or a simple element's text.
        case text(String)
        /// An element holding an `rdf:Seq` / `rdf:Bag` / `rdf:Alt`: its items' text.
        case list([String])
        /// An element holding a nested structure (a Look): the nested
        /// `crs:Name`, if any.
        case structure(name: String?)

        var number: Double? {
            guard case .text(let s) = self else { return nil }
            return Double(s.trimmingCharacters(in: .whitespaces))
        }
        var isTrue: Bool {
            guard case .text(let s) = self else { return false }
            return s.trimmingCharacters(in: .whitespaces).lowercased() == "true"
        }
        var text: String? {
            guard case .text(let s) = self else { return nil }
            return s.trimmingCharacters(in: .whitespaces)
        }
    }

    /// A family of settings PhotoLab has no slider for. `isActive` says
    /// whether this setting, in this file, changes a photo; neutral ones are
    /// not listed.
    struct UnsupportedRule: Sendable {
        var settings: [String]
        var label: String
        var isActive: @Sendable (_ value: Raw, _ all: [String: Raw]) -> Bool
    }

    /// Profile and Look names that are Lightroom's own default rendering:
    /// asking for one is not a look PhotoLab lacks.
    static let defaultProfiles: Set<String> = ["", "Adobe Standard", "Adobe Color", "Adobe Default", "Embedded"]

    private static let nonZero: @Sendable (Raw, [String: Raw]) -> Bool = { v, _ in (v.number ?? 0) != 0 }
    private static let isTrue: @Sendable (Raw, [String: Raw]) -> Bool = { v, _ in v.isTrue }
    private static let hasItems: @Sendable (Raw, [String: Raw]) -> Bool = { v, _ in
        switch v {
        case .list(let items): return !items.isEmpty
        case .structure: return true
        case .text(let s): return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static let unsupportedRules: [UnsupportedRule] = [
        UnsupportedRule(settings: ["CameraProfile"], label: "Profile") { v, _ in
            !defaultProfiles.contains(v.text ?? "")
        },
        UnsupportedRule(settings: ["Look"], label: "Look") { v, _ in
            if case .structure(let name) = v { return !defaultProfiles.contains(name ?? "") }
            return hasItems(v, [:])
        },
        UnsupportedRule(settings: ["Dehaze"], label: "Dehaze", isActive: nonZero),
        UnsupportedRule(settings: ["Texture"], label: "Texture", isActive: nonZero),
        UnsupportedRule(settings: ["RedHue", "RedSaturation", "GreenHue", "GreenSaturation",
                                   "BlueHue", "BlueSaturation", "ShadowTint"],
                        label: "Calibration", isActive: nonZero),
        UnsupportedRule(settings: ["WhiteBalance"], label: "White balance (Kelvin)") { v, _ in
            !["", "as shot"].contains((v.text ?? "").lowercased())
        },
        // Absolute Kelvin / tint: a photo's own white balance. A sidecar
        // written "As Shot" carries them too and is not listed; with no
        // WhiteBalance key, a Temperature or Tint is a set balance.
        UnsupportedRule(settings: ["Temperature", "Tint"], label: "White balance (Kelvin)") { _, all in
            all["WhiteBalance"]?.text?.lowercased() != "as shot"
        },
        // Process 2010 basic tone (pre-2012 presets), at its own defaults.
        UnsupportedRule(settings: ["Exposure", "HighlightRecovery", "FillLight", "Clarity"],
                        label: "Process 2010 tone", isActive: nonZero),
        UnsupportedRule(settings: ["Brightness"], label: "Process 2010 tone") { v, _ in (v.number ?? 50) != 50 },
        UnsupportedRule(settings: ["Contrast"], label: "Process 2010 tone") { v, _ in (v.number ?? 25) != 25 },
        UnsupportedRule(settings: ["Shadows"], label: "Process 2010 tone") { v, _ in (v.number ?? 5) != 5 },
        UnsupportedRule(settings: ["ToneCurve"], label: "Process 2010 tone curve") { v, _ in !isIdentityCurve(v) },
        UnsupportedRule(settings: ["ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue"],
                        label: "Per-channel tone curve") { v, _ in !isIdentityCurve(v) },
        UnsupportedRule(settings: ["ColorGradeGlobalSat", "ColorGradeGlobalLum"],
                        label: "Color grading global wheel", isActive: nonZero),
        UnsupportedRule(settings: ["ColorGradeBlending"], label: "Color grading blending") { v, _ in
            (v.number ?? 50) != 50
        },
        UnsupportedRule(settings: ["ConvertToGrayscale"], label: "Black & white", isActive: isTrue),
        UnsupportedRule(settings: ["LensProfileEnable", "AutoLateralCA", "LensManualDistortionAmount",
                                   "VignetteAmount", "DefringePurpleAmount", "DefringeGreenAmount"],
                        label: "Lens corrections", isActive: nonZero),
        UnsupportedRule(settings: ["PerspectiveVertical", "PerspectiveHorizontal", "PerspectiveRotate",
                                   "PerspectiveAspect", "PerspectiveUpright", "PerspectiveX", "PerspectiveY"],
                        label: "Transform", isActive: nonZero),
        UnsupportedRule(settings: ["PerspectiveScale"], label: "Transform") { v, _ in (v.number ?? 100) != 100 },
        UnsupportedRule(settings: ["HasCrop"], label: "Crop", isActive: isTrue),
        UnsupportedRule(settings: ["CropAngle", "CropTop", "CropLeft"], label: "Crop", isActive: nonZero),
        UnsupportedRule(settings: ["CropBottom", "CropRight"], label: "Crop") { v, _ in (v.number ?? 1) != 1 },
        UnsupportedRule(settings: ["MaskGroupBasedCorrections"], label: "Masks", isActive: hasItems),
        UnsupportedRule(settings: ["PaintBasedCorrections"], label: "Brush corrections", isActive: hasItems),
        UnsupportedRule(settings: ["GradientBasedCorrections"], label: "Linear gradients", isActive: hasItems),
        UnsupportedRule(settings: ["CircularGradientBasedCorrections"], label: "Radial gradients", isActive: hasItems),
        UnsupportedRule(settings: ["RetouchAreas"], label: "Spot removal", isActive: hasItems),
    ]

    // MARK: Parse

    /// Reads `data` (an `.xmp` file's bytes; `fileName` gives the fallback
    /// name). Throws `XMPImportError.notXML` on malformed XML and
    /// `.noCameraRawSettings` when no top-level `crs:` setting is present.
    static func parse(_ data: Data, fileName: String) throws -> XMPImport {
        let settings = try settings(in: data)
        guard !settings.isEmpty else { throw XMPImportError.noCameraRawSettings }
        return interpret(settings, fileName: fileName)
    }

    /// Every top-level `crs:` setting of `data`, by key (no prefix).
    static func settings(in data: Data) throws -> [String: Raw] {
        let reader = SettingsReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.delegate = reader
        guard parser.parse(), reader.sawElement else { throw XMPImportError.notXML }
        return reader.settings
    }

    static func interpret(_ settings: [String: Raw], fileName: String) -> XMPImport {
        var recipe = Recipe.neutral
        var mapped: [XMPImport.Mapped] = []
        var clamped: [String] = []
        var setKinds: Set<AdjustmentKind> = []

        for row in mapping {
            guard let raw = settings[row.setting], var number = raw.number,
                  !setKinds.contains(row.kind) else { continue }
            if row.setting == "ColorNoiseReduction", number == Self.secondaryDefaults["ColorNoiseReduction"] { number = 0 }
            setKinds.insert(row.kind)
            let scaled = number * row.scale
            let value = clamp(scaled, row.kind)
            if abs(value - scaled) > 1e-9 { clamped.append(row.setting) }
            recipe.set(row.kind, to: value)
            if value != row.kind.neutral {
                mapped.append(.init(setting: row.setting, kind: row.kind, value: value))
            }
        }

        // Tone curves, approximated.
        var approximated: [String] = []
        let pointCurve = settings[pointCurveKey].flatMap(curvePoints)
        if let points = pointCurve, !isIdentity(points) { approximated.append(pointCurveKey) }
        let parametric = parametricKeys.map { settings[$0]?.number ?? 0 }
        for (key, value) in zip(parametricKeys, parametric) where value != 0 { approximated.append(key) }
        if !approximated.isEmpty {
            let offsets = approximateCurve(points: pointCurve, parametric: parametric)
            let kinds: [AdjustmentKind] = [.curveBlacks, .curveShadows, .curveMidtones, .curveHighlights, .curveWhites]
            var curveClamped = false
            for (kind, offset) in zip(kinds, offsets) {
                // A point's value is its y offset in quarters (ColorCubes.curvePoints: ±100 is ±¼).
                let scaled = offset * 400
                let value = clamp(scaled, kind)
                if abs(value - scaled) > 1e-9 { curveClamped = true }
                recipe.set(kind, to: value)
            }
            if curveClamped { clamped.append(contentsOf: approximated) }
        }

        var unsupported: [XMPImport.Unsupported] = []
        for rule in unsupportedRules {
            for key in rule.settings {
                if let raw = settings[key], rule.isActive(raw, settings) {
                    unsupported.append(.init(setting: key, label: rule.label))
                }
            }
        }

        // Every other key: a number away from its default, a curve that is
        // not the identity, a non-empty structure. Nothing that may change a
        // photo goes unlisted; metadata and enum text are not settings.
        let known = Set(mapping.map(\.setting) + [pointCurveKey] + parametricKeys
                        + unsupportedRules.flatMap(\.settings) + metadataKeys)
        for key in settings.keys.sorted() where !known.contains(key) {
            let raw = settings[key]!
            let active: Bool
            switch raw {
            case .text: active = raw.number.map { $0 != (secondaryDefaults[key] ?? 0) } ?? false
            case .list: active = curvePoints(raw).map { !isIdentity($0) } ?? hasItems(raw, settings)
            case .structure: active = true
            }
            if active { unsupported.append(.init(setting: key, label: plainLabel(key))) }
        }

        return XMPImport(name: presetName(settings, fileName: fileName), recipe: recipe,
                         mapped: mapped, approximated: approximated,
                         unsupported: unsupported, clamped: clamped)
    }

    /// Keys that describe the file, never a photo: not listed.
    static let metadataKeys: [String] = [
        "Version", "ProcessVersion", "CompatibleVersion", "HasSettings", "AlreadyApplied", "PresetType",
        "UUID", "Name", "PresetName", "ShortName", "SortName", "Group", "Description", "Cluster",
        "Copyright", "ContactInfo", "SupportsAmount", "SupportsAmount2", "SupportsColor",
        "SupportsMonochrome", "SupportsHighDynamicRange", "SupportsNormalDynamicRange",
        "SupportsSceneReferred", "SupportsOutputReferred", "CameraModelRestriction",
        "RequiresRGBTables", "CameraProfileDigest", "ToneCurveName", "ToneCurveName2010",
        "ToneCurveName2012", "RawFileName", "ParametricShadowSplit", "ParametricMidtoneSplit",
        "ParametricHighlightSplit",
    ]

    /// The neutral value of the secondary settings (a slider's radius,
    /// detail, feather...) whose default is not 0: at it, a key is not listed.
    static let secondaryDefaults: [String: Double] = [
        "GrainSize": 25, "GrainFrequency": 50,
        "PostCropVignetteMidpoint": 50, "PostCropVignetteFeather": 50, "PostCropVignetteStyle": 1,
        "SharpenRadius": 1, "SharpenDetail": 25,
        "ColorNoiseReduction": 25, "ColorNoiseReductionDetail": 50, "ColorNoiseReductionSmoothness": 50,
        "LuminanceNoiseReductionDetail": 50, "VignetteMidpoint": 50,
        "LensProfileDistortionScale": 100,
        "LensProfileChromaticAberrationScale": 100, "LensProfileVignettingScale": 100,
        "DefringePurpleHueLo": 30, "DefringePurpleHueHi": 70,
        "DefringeGreenHueLo": 40, "DefringeGreenHueHi": 60,
    ]

    /// "GrainSize" -> "Grain size": a key as words, for the sheet.
    static func plainLabel(_ key: String) -> String {
        var out = ""
        for (i, c) in key.enumerated() {
            if i > 0, c.isUppercase, let prev = out.last, !prev.isUppercase, prev != " " {
                out.append(" ")
                out.append(Character(c.lowercased()))
            } else {
                out.append(c)
            }
        }
        return out
    }

    private static func clamp(_ value: Double, _ kind: AdjustmentKind) -> Double {
        min(kind.range.upperBound, max(kind.range.lowerBound, value))
    }

    static func presetName(_ settings: [String: Raw], fileName: String) -> String {
        for key in ["PresetName", "Name"] {
            switch settings[key] {
            case .text(let s)? where !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            case .list(let items)?:
                if let first = items.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    return first.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            default: break
            }
        }
        return ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: Curves

    /// A point curve's points on 0...1, sorted by x; nil when it is not a
    /// list of "x, y" pairs.
    static func curvePoints(_ raw: Raw) -> [(Double, Double)]? {
        guard case .list(let items) = raw else { return nil }
        var points: [(Double, Double)] = []
        for item in items {
            let parts = item.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, let x = parts[0], let y = parts[1] else { return nil }
            points.append((x / 255, y / 255))
        }
        return points.isEmpty ? nil : points.sorted { $0.0 < $1.0 }
    }

    static func isIdentity(_ points: [(Double, Double)]) -> Bool {
        points.allSatisfy { abs($0.0 - $0.1) < 1e-6 }
    }

    static func isIdentityCurve(_ raw: Raw) -> Bool {
        guard let points = curvePoints(raw) else { return true }
        return isIdentity(points)
    }

    /// The point curve read linearly at x = 0, ¼, ½, ¾, 1, as y − x.
    static func pointCurveOffsets(_ points: [(Double, Double)]) -> [Double] {
        [0.0, 0.25, 0.5, 0.75, 1.0].map { x in
            guard let first = points.first, let last = points.last else { return 0 }
            if x <= first.0 { return first.1 - x }
            if x >= last.0 { return last.1 - x }
            let i = points.lastIndex { $0.0 <= x }!
            let a = points[i], b = points[min(i + 1, points.count - 1)]
            let t = b.0 > a.0 ? (x - a.0) / (b.0 - a.0) : 0
            return a.1 + (b.1 - a.1) * t - x
        }
    }

    /// The five y offsets (0...1 scale) of the point curve plus the
    /// parametric one. Lightroom's regions (shadows, darks, lights,
    /// highlights, at the default splits ¼ ½ ¾) each lift the inner points
    /// either side of them by half `parametricLift` per +100; the end points
    /// stay where the point curve put them.
    static func approximateCurve(points: [(Double, Double)]?, parametric: [Double]) -> [Double] {
        var offsets = points.map(pointCurveOffsets) ?? [0, 0, 0, 0, 0]
        let p = parametric.map { $0 / 100 * parametricLift }
        guard p.count == 4 else { return offsets }
        offsets[1] += (p[0] + p[1]) / 2
        offsets[2] += (p[1] + p[2]) / 2
        offsets[3] += (p[2] + p[3]) / 2
        return offsets
    }
}

/// The `XMLParser` delegate behind `XMPPreset.settings(in:)`: collects the
/// `crs:` attributes of any `rdf:Description` that is not inside a `crs:`
/// element, and every `crs:` element at that level as text, a list (an
/// `rdf:Seq` / `Bag` / `Alt` child: one entry per `rdf:li`, its text) or a
/// nested structure (anything else, with the first nested `crs:Name`).
/// Nothing inside a top-level `crs:` element is read as a setting of its
/// own. Prefixes are resolved through the document's own declarations, so a
/// file binding the namespace to another prefix reads too.
private final class SettingsReader: NSObject, XMLParserDelegate {
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

    var settings: [String: XMPPreset.Raw] = [:]
    var sawElement = false

    private var prefixes: [String: [String]] = [:]
    private var depth = 0

    /// The open top-level crs element and what it has collected so far.
    private struct Open {
        var key: String
        var depth: Int
        var text = ""
        var sawList = false
        var items: [String] = []
        var itemText: String?
        var nested = false
        var name: String?
        var nameText: String?
        var nameDepth: Int?
    }
    private var open: Open?

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixes[prefix, default: []].append(namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        _ = prefixes[prefix]?.popLast()
    }

    private func crsKey(ofAttribute qName: String) -> String? {
        let parts = qName.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, prefixes[parts[0]]?.last == XMPPreset.namespace else { return nil }
        return parts[1]
    }

    private static func isList(_ name: String, _ ns: String?) -> Bool {
        ns == rdf && (name == "Seq" || name == "Bag" || name == "Alt")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        sawElement = true
        depth += 1
        guard var o = open else {
            if namespaceURI == XMPPreset.namespace {
                open = Open(key: elementName, depth: depth)
            } else if namespaceURI == Self.rdf && elementName == "Description" {
                for (name, value) in attributeDict {
                    if let key = crsKey(ofAttribute: name) { settings[key] = .text(value) }
                }
            }
            return
        }
        if depth == o.depth + 1 && Self.isList(elementName, namespaceURI) {
            o.sawList = true
        } else if o.sawList && depth == o.depth + 2 && namespaceURI == Self.rdf && elementName == "li" {
            o.itemText = ""
        } else if !o.sawList {
            o.nested = true
        }
        if o.name == nil {
            for (name, value) in attributeDict where crsKey(ofAttribute: name) == "Name" { o.name = value }
            if o.name == nil && o.nameDepth == nil && namespaceURI == XMPPreset.namespace && elementName == "Name" {
                o.nameDepth = depth
                o.nameText = ""
            }
        }
        open = o
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard var o = open else { return }
        if o.itemText != nil { o.itemText! += string }
        if o.nameDepth != nil { o.nameText! += string }
        if depth == o.depth { o.text += string }
        open = o
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        defer { depth -= 1 }
        guard var o = open else { return }
        if depth == o.depth {
            if o.sawList {
                settings[o.key] = .list(o.items)
            } else if o.nested {
                settings[o.key] = .structure(name: o.name)
            } else {
                settings[o.key] = .text(o.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            open = nil
            return
        }
        if depth == o.depth + 2, o.sawList, namespaceURI == Self.rdf, elementName == "li", let item = o.itemText {
            o.items.append(item.trimmingCharacters(in: .whitespacesAndNewlines))
            o.itemText = nil
        }
        if depth == o.nameDepth {
            let t = (o.nameText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { o.name = t }
            o.nameDepth = nil
            o.nameText = nil
        }
        open = o
    }
}
