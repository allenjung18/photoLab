import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Mask kinds, names and default placements

/// The three kinds of local adjustment, as the Masks section and the Photo
/// menu offer them. A linear or radial is placed by a drag on the photo
/// (`MaskHandles.placed`); `defaultShape` is what a click places (moved to
/// the click) and what `Library.addMask` adds: a linear from the top edge
/// to 40% down, a radial ellipse centred at a third of the frame, an empty
/// brush.
enum MaskKind: CaseIterable {
    case linear, radial, brush

    init(_ shape: MaskShape) {
        switch shape {
        case .linear: self = .linear
        case .radial: self = .radial
        case .brush: self = .brush
        }
    }

    var title: String {
        switch self {
        case .linear: "Linear"
        case .radial: "Radial"
        case .brush: "Brush"
        }
    }

    var systemImage: String {
        switch self {
        case .linear: "rectangle.tophalf.filled"
        case .radial: "circle.dashed"
        case .brush: "paintbrush.pointed"
        }
    }

    /// Where a new mask of this kind starts, in the source frame.
    var defaultShape: MaskShape {
        switch self {
        case .linear:
            return .linear(start: MaskPoint(x: 0.5, y: 0), end: MaskPoint(x: 0.5, y: 0.4))
        case .radial:
            return .radial(center: MaskPoint(x: 1.0 / 3, y: 1.0 / 3),
                           radii: MaskRadii(x: 0.2, y: 0.15), angle: 0, feather: 0.5)
        case .brush:
            return .brush([])
        }
    }

    /// Each mask's name in `masks`: its kind and its place among the masks of
    /// that kind, in list order ("Linear 1", "Radial 1", "Linear 2"). Derived,
    /// never stored, so a delete renumbers the rest.
    static func names(of masks: [LocalMask]) -> [UUID: String] {
        var counts: [MaskKind: Int] = [:]
        var out: [UUID: String] = [:]
        for mask in masks {
            let kind = MaskKind(mask.shape)
            counts[kind, default: 0] += 1
            out[mask.id] = "\(kind.title) \(counts[kind]!)"
        }
        return out
    }
}

// MARK: - The library's mask edits

/// Every mask edit goes through `Library.setRecipe` (the one writer), so an
/// add, a duplicate, a delete or a checkbox is one undo step and one sidecar
/// write, and a slider drag inside `beginEdit` / `endEdit` is one of each.
extension Library {
    /// The mask `maskID` of photo `id`, if its recipe holds it.
    func mask(_ maskID: UUID, for id: Photo.ID) -> LocalMask? {
        recipe(for: id).masks.first { $0.id == maskID }
    }

    /// Adds a mask of `kind` at its default placement to the end of the
    /// photo's list and selects it; a brush is armed for painting. Leaves
    /// crop mode and puts the eyedropper down. One undo step.
    @discardableResult
    func addMask(_ kind: MaskKind, for id: Photo.ID) -> UUID {
        endEdit(id)
        let mask = LocalMask(shape: kind.defaultShape)
        var r = recipe(for: id)
        r.masks.append(mask)
        setRecipe(r, for: id)
        cropMode = false
        whiteBalancePicking = false
        selectedMask = mask.id
        if kind == .brush { maskBrushArmed = true }
        return mask.id
    }

    /// Changes mask `maskID` of photo `id` through `setRecipe`; nothing when
    /// the photo has no such mask or the change changes nothing.
    func updateMask(_ maskID: UUID, for id: Photo.ID, _ change: (inout LocalMask) -> Void) {
        var r = recipe(for: id)
        guard let i = r.masks.firstIndex(where: { $0.id == maskID }) else { return }
        change(&r.masks[i])
        setRecipe(r, for: id)
    }

    /// A copy of mask `maskID` (a new id) right after it, selected. One undo
    /// step; nil when there is no such mask.
    @discardableResult
    func duplicateMask(_ maskID: UUID, for id: Photo.ID) -> UUID? {
        var r = recipe(for: id)
        guard let i = r.masks.firstIndex(where: { $0.id == maskID }) else { return nil }
        var copy = r.masks[i]
        copy.id = UUID()
        r.masks.insert(copy, at: i + 1)
        setRecipe(r, for: id)
        selectedMask = copy.id
        return copy.id
    }

    /// Removes mask `maskID`: one undo step (undo brings it back, unselected);
    /// the selection clears with it (`apply`).
    func deleteMask(_ maskID: UUID, for id: Photo.ID) {
        var r = recipe(for: id)
        guard r.masks.contains(where: { $0.id == maskID }) else { return }
        r.masks.removeAll { $0.id == maskID }
        setRecipe(r, for: id)
    }
}

/// One mask slider: its value and the edit it makes. A drag opens one edit
/// on mouse-down (`beginEdit`) and closes it on mouse-up (`endEdit`), so the
/// whole drag is ONE undo step and ONE sidecar write, as the global sliders'
/// `AdjustmentRow` is; the view and the tests go through this.
@MainActor
struct MaskSliderEdit {
    let library: Library
    let photo: Photo.ID
    let mask: UUID
    let kind: AdjustmentKind

    var value: Double { library.mask(mask, for: photo)?.value(of: kind) ?? kind.neutral }

    func set(_ value: Double) {
        library.updateMask(mask, for: photo) { $0.set(kind, to: value) }
    }

    func editingChanged(_ editing: Bool) {
        if editing { library.beginEdit(photo) } else { library.endEdit(photo) }
    }

    /// Back to neutral (a double-click on the name): one step.
    func reset() { set(kind.neutral) }
}

// MARK: - The overlay

/// Show Mask Overlay: the selected mask's weight, red at half strength,
/// over a finished 8-bit frame of the loupe. The mask is drawn and placed
/// exactly as the renderer places it (`MaskRender.placedImage`, through the
/// recipe's rotate and crop), over the same scaled source extent
/// `Renderer.render` used, so the tint lands on the pixels the mask's
/// adjustments change. Composed by `PreviewModel` beside the clipping
/// warning, after the render, so it never reaches compare's Before, a
/// thumbnail or an export (none of those go through `PreviewModel`'s
/// After frame).
enum MaskTint {
    static let color = CIColor(red: 1, green: 0, blue: 0)
    static let opacity: CGFloat = 0.5

    /// The chain's input extent for `source` at `maxPixelSize`: the rule
    /// `Renderer.render` scales by (never upscaled).
    static func sourceExtent(of source: CGRect, maxPixelSize: Int?) -> CGRect {
        guard let maxPixelSize else { return source }
        let longest = max(source.width, source.height)
        guard longest > CGFloat(maxPixelSize) else { return source }
        let s = CGFloat(maxPixelSize) / longest
        return source.applying(CGAffineTransform(scaleX: s, y: s))
    }

    /// `frame` (a render of `recipe` over a source of extent `sourceExtent`
    /// after scaling) with `mask` tinted over it. `window` is the 1:1
    /// render's region (top-left, in the frame's pixels) when `frame` is
    /// that window; nil for the whole frame. Inverted masks tint where they
    /// apply (1 - w). Synchronous; call off the main thread.
    static func compose(over frame: CGImage, mask: LocalMask, recipe: Recipe, sourceExtent: CGRect,
                        window: CGRect? = nil, renderer: Renderer = .shared) -> CGImage? {
        let geometry = Recipe(adjustments: MaskRender.geometryKinds.map { recipe[$0] })
        let frameRect = renderer.apply(geometry, to: CIImage(color: .black).cropped(to: sourceExtent)).extent.integral
        guard !frameRect.isEmpty else { return nil }
        var weight = MaskRender.placedImage(for: mask, recipe: recipe, sourceExtent: sourceExtent, renderer: renderer)
            ?? CIImage(color: .black).cropped(to: frameRect)
        if mask.inverted {
            let invert = CIFilter.colorInvert()
            invert.inputImage = weight
            weight = invert.outputImage ?? weight
        }
        // The CI rect the frame's pixels cover: the whole frame, or the
        // window (top-left) cut from it.
        let rect: CGRect
        if let window {
            rect = CGRect(x: frameRect.minX + window.minX, y: frameRect.maxY - window.maxY,
                          width: window.width, height: window.height)
        } else {
            rect = frameRect
        }
        let half = CIFilter.colorMatrix()
        half.inputImage = weight
        half.rVector = CIVector(x: opacity, y: 0, z: 0, w: 0)
        half.gVector = CIVector(x: 0, y: opacity, z: 0, w: 0)
        half.bVector = CIVector(x: 0, y: 0, z: opacity, w: 0)
        half.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        // Untagged in and out, like the clipping overlay: the tint is a
        // display aid, not a color to match.
        let source = CIImage(cgImage: frame, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        let blend = CIFilter.blendWithMask()
        blend.inputImage = CIImage(color: color).cropped(to: rect)
        blend.backgroundImage = source
        blend.maskImage = half.outputImage
        guard let out = blend.outputImage?.cropped(to: rect),
              let cg = renderer.context.createCGImage(out, from: rect, format: .RGBA8, colorSpace: nil) else { return nil }
        guard let space = frame.colorSpace, let tagged = cg.copy(colorSpace: space) else { return cg }
        return tagged
    }
}

// MARK: - The Masks section

/// The adjustments panel's Masks section (after the preset strip): New
/// Linear, New Radial and New Brush (the Photo menu's commands and keys),
/// the photo's masks by kind and order, and for the selected one
/// (`Library.selectedMask`) its switch, Invert, Duplicate, Delete and the
/// seven sliders of `LocalMask.kinds`. Show Overlay is View › Show Mask
/// Overlay (O).
struct MasksSection: View {
    @Environment(Library.self) private var library
    let photo: Photo
    @State private var expanded = true

    var body: some View {
        let masks = library.recipe(for: photo.id).masks
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                addRow
                if masks.isEmpty {
                    Text("No masks. Pick Linear or Radial, then drag on the photo to place one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    list(masks)
                    overlayToggle
                }
                if let id = library.selectedMask, let mask = masks.first(where: { $0.id == id }) {
                    Divider()
                    selected(mask)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
        } label: {
            HStack {
                Text("Masks").font(.callout.weight(.semibold))
                if !masks.isEmpty {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        .help("Has masks")
                }
            }
        }
    }

    private var context: CommandContext { CommandContext(library: library) }

    private func help(_ name: AppCommand.Name, _ text: String) -> String {
        let command = AppCommand.command(name)
        guard let key = command.key else { return text }
        let shift = command.modifiers.contains(.shift) ? "⇧" : ""
        return "\(text) (\(shift)\(AppCommand.label(for: key)))"
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            placementToggle(.linear, .newLinearMask, "A new linear gradient: drag on the photo from full effect to none")
            placementToggle(.radial, .newRadialMask, "A new radial gradient: drag on the photo from its centre to its edge")
            Toggle(isOn: Binding(get: { library.maskBrushArmed },
                                 set: { if $0 != library.maskBrushArmed { AppCommand.command(.brushMask).perform(context) } })) {
                Label("Brush", systemImage: MaskKind.brush.systemImage)
            }
            .toggleStyle(.button)
            .disabled(!AppCommand.command(.brushMask).isEnabled(context))
            .help(help(.brushMask, "A new brush mask, armed for painting"))
        }
        .controlSize(.small)
    }

    /// New Linear / New Radial: armed while the next drag on the photo will
    /// place one (`Library.maskPlacement`).
    private func placementToggle(_ kind: MaskKind, _ name: AppCommand.Name, _ text: String) -> some View {
        Toggle(isOn: Binding(get: { library.maskPlacement == kind },
                             set: { if $0 != (library.maskPlacement == kind) { AppCommand.command(name).perform(context) } })) {
            Label(kind.title, systemImage: kind.systemImage)
        }
        .toggleStyle(.button)
        .disabled(!AppCommand.command(name).isEnabled(context))
        .help(help(name, text))
    }

    private func list(_ masks: [LocalMask]) -> some View {
        let names = MaskKind.names(of: masks)
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(masks) { mask in
                let isSelected = library.selectedMask == mask.id
                Button {
                    library.selectedMask = isSelected ? nil : mask.id
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: MaskKind(mask.shape).systemImage)
                            .frame(width: 16)
                        Text(names[mask.id] ?? "")
                        if mask.inverted {
                            Text("inverted").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(mask.enabled ? HierarchicalShapeStyle.primary : .tertiary)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(isSelected ? "Click to deselect" : "Show this mask's sliders")
            }
        }
    }

    private var overlayToggle: some View {
        Toggle(isOn: Binding(get: { library.showMaskOverlay },
                             set: { if $0 != library.showMaskOverlay { AppCommand.command(.maskOverlay).perform(context) } })) {
            Text("Show Overlay").font(.callout)
        }
        .toggleStyle(.checkbox)
        .help(help(.maskOverlay, "Tint the selected mask red on the photo"))
    }

    @ViewBuilder
    private func selected(_ mask: LocalMask) -> some View {
        let id = photo.id
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { mask.enabled },
                                 set: { on in library.updateMask(mask.id, for: id) { $0.enabled = on } })) {
                Text(MaskKind.names(of: library.recipe(for: id).masks)[mask.id] ?? "Mask")
                    .font(.callout.weight(.medium))
            }
            .toggleStyle(.checkbox)
            .help("Apply this mask")
            Spacer(minLength: 4)
            Toggle("Invert", isOn: Binding(get: { mask.inverted },
                                           set: { on in library.updateMask(mask.id, for: id) { $0.inverted = on } }))
                .toggleStyle(.button)
                .help("Apply where the mask is not")
            Button {
                library.duplicateMask(mask.id, for: id)
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .help("Duplicate this mask")
            .accessibilityLabel("Duplicate mask")
            Button {
                library.deleteMask(mask.id, for: id)
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete this mask")
            .accessibilityLabel("Delete mask")
        }
        .controlSize(.small)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(LocalMask.kinds) { kind in
                MaskSliderRow(edit: MaskSliderEdit(library: library, photo: id, mask: mask.id, kind: kind))
            }
        }
        .disabled(!mask.enabled)
        .opacity(mask.enabled ? 1 : 0.6)
    }
}

/// One of a mask's seven sliders, laid out as the global `AdjustmentRow` is
/// (name, value, slider; a double-click on the name resets it).
private struct MaskSliderRow: View {
    let edit: MaskSliderEdit

    var body: some View {
        let kind = edit.kind
        VStack(spacing: 4) {
            HStack {
                Text(kind.label)
                    .onTapGesture(count: 2) { edit.reset() }
                    .help("Double-click to reset")
                Spacer()
                Text(kind.format(edit.value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: Binding(get: { edit.value }, set: { edit.set($0) }), in: kind.range,
                   onEditingChanged: edit.editingChanged)
                .controlSize(.small)
                .accessibilityLabel("Mask " + AccessibleName.adjustment(kind).lowercased())
        }
    }
}
