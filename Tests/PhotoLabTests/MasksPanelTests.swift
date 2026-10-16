import XCTest
import SwiftUI
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// The Masks section's model (MasksPanel.swift, `Library.selectedMask`):
/// each add, duplicate, delete and switch is one undo step and one sidecar
/// write and an add selects the new mask; a mask slider drag through
/// `MaskSliderEdit` is one step and one write; the selection clears when
/// undo takes its mask away and on a photo change; the keys M, Shift-M, K
/// and O come from the command table; the overlay (`MaskTint`) is off by
/// default, tints only the After frame where the mask applies, and never
/// reaches an export.
@MainActor
final class MasksPanelTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-maskspanel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    /// A flat mid-grey PNG.
    @discardableResult
    private func makePhoto(_ name: String, width: Int = 12, height: Int = 8, level: CGFloat = 0.5) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// Two photos open, the first in the loupe.
    private func openTwo() throws -> (Library, CommandContext, [Photo.ID]) {
        try makePhoto("a.png")
        try makePhoto("b.png")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let ids = lib.photos.map(\.id)
        XCTAssertEqual(ids.count, 2)
        lib.selection = ids[0]
        lib.loupe = true
        return (lib, CommandContext(library: lib), ids)
    }

    private func run(_ name: AppCommand.Name, _ ctx: CommandContext, file: StaticString = #filePath, line: UInt = #line) {
        let command = AppCommand.command(name)
        XCTAssertTrue(command.isEnabled(ctx), "\(name) disabled", file: file, line: line)
        command.perform(ctx)
    }

    /// The pixel at (x, y), top-left origin, drawn into sRGB RGBA8.
    private func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = y * ctx.bytesPerRow + x * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    /// How red a pixel is over its green: the tint's signature on grey.
    private func redness(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
        let p = rgb(image, x, y)
        return p.r - p.g
    }

    // MARK: Adds, duplicate, delete

    func testEachAddIsOneUndoStepAndOneSidecarWriteAndSelectsTheNewMask() throws {
        let (lib, _, ids) = try openTwo()
        let photo = ids[0]
        let store = SidecarStore(folder: folder)
        var counts: [Int] = []
        for kind in MaskKind.allCases {
            let writes = lib.sidecarWrites
            let before = lib.recipe(for: photo)
            let id = lib.addMask(kind, for: photo)
            XCTAssertEqual(lib.sidecarWrites, writes + 1, "\(kind): one sidecar write")
            XCTAssertEqual(lib.selectedMask, id, "\(kind): the new mask is selected")
            XCTAssertEqual(lib.maskBrushArmed, kind == .brush, "only a brush is armed")
            let mask = try XCTUnwrap(lib.mask(id, for: photo))
            XCTAssertEqual(mask.shape, kind.defaultShape)
            XCTAssertEqual(lib.recipe(for: photo).masks.last?.id, id, "added at the end")
            XCTAssertEqual(try store.load(for: photo), lib.recipe(for: photo), "\(kind): written at once")
            lib.undo()
            XCTAssertEqual(lib.recipe(for: photo), before, "\(kind): the add is one undo step")
            lib.redo()
            counts.append(lib.recipe(for: photo).masks.count)
        }
        XCTAssertEqual(counts, [1, 2, 3])
        // The defaults: a linear from the top edge to 40% down, a radial
        // centred at a third of the frame, an empty brush.
        XCTAssertEqual(MaskKind.linear.defaultShape, .linear(start: MaskPoint(x: 0.5, y: 0), end: MaskPoint(x: 0.5, y: 0.4)))
        guard case .radial(let c, _, _, _) = MaskKind.radial.defaultShape else { return XCTFail("radial") }
        XCTAssertEqual(c, MaskPoint(x: 1.0 / 3, y: 1.0 / 3))
        XCTAssertEqual(MaskKind.brush.defaultShape, .brush([]))

        // Names by kind and order.
        lib.addMask(.linear, for: photo)
        let masks = lib.recipe(for: photo).masks
        let names = MaskKind.names(of: masks)
        XCTAssertEqual(masks.map { names[$0.id]! }, ["Linear 1", "Radial 1", "Brush 1", "Linear 2"])
        // The new masks render as nothing until a slider moves.
        XCTAssertTrue(lib.recipe(for: photo).isNeutral)
    }

    func testDuplicateAndTheSwitchesAreOneStepEach() throws {
        let (lib, _, ids) = try openTwo()
        let photo = ids[0]
        let a = lib.addMask(.radial, for: photo)
        lib.addMask(.linear, for: photo)
        lib.updateMask(a, for: photo) { $0.set(.exposure, to: 0.7) }

        var writes = lib.sidecarWrites
        let copy = try XCTUnwrap(lib.duplicateMask(a, for: photo))
        XCTAssertEqual(lib.sidecarWrites, writes + 1)
        XCTAssertEqual(lib.selectedMask, copy, "the copy is selected")
        let masks = lib.recipe(for: photo).masks
        XCTAssertEqual(masks.map(\.id).firstIndex(of: copy), 1, "right after its original")
        XCTAssertEqual(masks[1].shape, masks[0].shape)
        XCTAssertEqual(masks[1].value(of: .exposure), 0.7)
        XCTAssertNotEqual(copy, a)
        lib.undo()
        XCTAssertNil(lib.mask(copy, for: photo))
        XCTAssertNil(lib.selectedMask, "undo took the copy away, and its selection")

        for change in [{ (m: inout LocalMask) in m.enabled = false }, { (m: inout LocalMask) in m.inverted = true }] {
            writes = lib.sidecarWrites
            let before = lib.recipe(for: photo)
            lib.updateMask(a, for: photo, change)
            XCTAssertEqual(lib.sidecarWrites, writes + 1)
            lib.undo()
            XCTAssertEqual(lib.recipe(for: photo), before, "one step")
            lib.redo()
        }
        XCTAssertEqual(lib.mask(a, for: photo)?.enabled, false)
        XCTAssertEqual(lib.mask(a, for: photo)?.inverted, true)
    }

    func testDeleteIsOneStepAndUndoBringsTheMaskBack() throws {
        let (lib, _, ids) = try openTwo()
        let photo = ids[0]
        let keep = lib.addMask(.linear, for: photo)
        let gone = lib.addMask(.radial, for: photo)
        lib.updateMask(gone, for: photo) { $0.set(.contrast, to: 20) }
        let before = lib.recipe(for: photo)
        XCTAssertEqual(lib.selectedMask, gone)

        let writes = lib.sidecarWrites
        lib.deleteMask(gone, for: photo)
        XCTAssertEqual(lib.sidecarWrites, writes + 1, "one sidecar write")
        XCTAssertNil(lib.mask(gone, for: photo))
        XCTAssertNotNil(lib.mask(keep, for: photo))
        XCTAssertNil(lib.selectedMask, "the deleted mask is no longer selected")
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), before, "undo brings it back, sliders and place")
        // Deleting what is not there changes nothing.
        lib.deleteMask(UUID(), for: photo)
        XCTAssertEqual(lib.recipe(for: photo), before)
    }

    // MARK: Slider drags

    /// The mask sliders' binding (`MaskSliderEdit`, what `MaskSliderRow`
    /// drives): mouse-down, many values, mouse-up is ONE undo step and ONE
    /// sidecar write, with nothing written mid-drag.
    func testAMaskSliderDragIsOneUndoStepAndOneWrite() throws {
        let (lib, _, ids) = try openTwo()
        let photo = ids[0]
        let mask = lib.addMask(.linear, for: photo)
        let before = lib.recipe(for: photo)
        let writes = lib.sidecarWrites
        let edit = MaskSliderEdit(library: lib, photo: photo, mask: mask, kind: .exposure)
        XCTAssertEqual(edit.value, 0)
        edit.editingChanged(true)
        for v in stride(from: 0.1, through: 1.5, by: 0.1) { edit.set(v) }
        XCTAssertEqual(lib.sidecarWrites, writes, "nothing written mid-drag")
        edit.editingChanged(false)
        XCTAssertEqual(edit.value, 1.5, accuracy: 1e-9)
        XCTAssertEqual(lib.sidecarWrites, writes + 1, "one write at mouse-up")
        XCTAssertEqual(try SidecarStore(folder: folder).load(for: photo), lib.recipe(for: photo))
        XCTAssertEqual(lib.recipe(for: photo).value(of: .exposure), 0, "the global slider did not move")
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), before, "the whole drag is one undo step")

        // Every one of the seven kinds writes into the mask only.
        for kind in LocalMask.kinds {
            let e = MaskSliderEdit(library: lib, photo: photo, mask: mask, kind: kind)
            e.set(kind.range.upperBound / 2)
            XCTAssertEqual(lib.mask(mask, for: photo)?.value(of: kind), kind.range.upperBound / 2, "\(kind)")
            e.reset()
            XCTAssertEqual(e.value, kind.neutral)
        }
    }

    // MARK: The selected mask

    func testSelectedMaskClearsWhenUndoRemovesItAndOnAPhotoChange() throws {
        let (lib, ctx, ids) = try openTwo()
        let photo = ids[0]
        let mask = lib.addMask(.radial, for: photo)
        XCTAssertEqual(lib.selectedMask, mask)
        lib.undo()
        XCTAssertNil(lib.selectedMask, "undo removed it")
        lib.redo()
        XCTAssertNil(lib.selectedMask, "redo brings the mask back unselected")
        lib.selectedMask = mask
        run(.next, ctx)
        XCTAssertNil(lib.selectedMask, "a photo change clears it")
        run(.previous, ctx)
        XCTAssertNil(lib.selectedMask)

        // A reset takes every mask away, and the selection with it.
        lib.selectedMask = mask
        lib.resetRecipe(for: photo)
        XCTAssertNil(lib.selectedMask)

        // Tool state, never in a recipe.
        lib.undo()
        lib.selectedMask = mask
        XCTAssertEqual(try SidecarStore(folder: folder).load(for: photo)?.masks.map(\.id), [mask])
        XCTAssertNil(lib.recipe(for: ids[1]).masks.first)
    }

    // MARK: Commands

    func testMShiftMAndKAddMasksInTheLoupeAndKTogglesTheBrush() throws {
        let linear = AppCommand.command(.newLinearMask), radial = AppCommand.command(.newRadialMask)
        let brush = AppCommand.command(.brushMask), overlay = AppCommand.command(.maskOverlay)
        XCTAssertEqual(linear.key, "m"); XCTAssertEqual(linear.modifiers, [])
        XCTAssertEqual(radial.key, "m"); XCTAssertEqual(radial.modifiers, .shift)
        XCTAssertEqual(brush.key, "k"); XCTAssertEqual(brush.modifiers, [])
        XCTAssertEqual(overlay.key, "o"); XCTAssertEqual(overlay.modifiers, [])
        for c in [linear, radial, brush, overlay] {
            XCTAssertTrue(c.isBareKey, "\(c.name) types a character: a hidden shortcut, off while typing")
        }
        XCTAssertEqual([linear, radial, brush].map(\.placement), [.photo, .photo, .photo])
        XCTAssertEqual(overlay.placement, .view)

        let (lib, ctx, ids) = try openTwo()
        XCTAssertEqual(linear.menuTitle(ctx), "New Linear Gradient (M)")
        XCTAssertEqual(radial.menuTitle(ctx), "New Radial Gradient (⇧M)")
        XCTAssertEqual(brush.menuTitle(ctx), "Brush (K)")
        XCTAssertEqual(overlay.menuTitle(ctx), "Show Mask Overlay (O)")

        lib.loupe = false
        XCTAssertFalse(linear.isEnabled(ctx), "the grid adds no mask")
        XCTAssertFalse(brush.isEnabled(ctx))
        lib.loupe = true
        lib.textEntryActive = true
        for c in [linear, radial, brush, overlay] { XCTAssertFalse(c.isEnabled(ctx), "\(c.name) off while typing") }
        lib.textEntryActive = false

        // M and Shift-M arm placement (the drag on the photo is
        // MaskHandleTests'); a click with one armed places its default shape.
        lib.cropMode = true
        run(.newLinearMask, ctx)
        XCTAssertFalse(lib.cropMode, "arming a new mask leaves crop mode")
        XCTAssertEqual(lib.maskPlacement, .linear)
        XCTAssertEqual(linear.isOn?(ctx), true)
        XCTAssertTrue(lib.recipe(for: ids[0]).masks.isEmpty, "arming adds nothing")
        run(.newLinearMask, ctx)
        XCTAssertNil(lib.maskPlacement, "M again disarms")
        run(.newLinearMask, ctx)
        lib.placeMask(.linear, at: MaskPoint(x: 0.5, y: 0.2), for: ids[0])
        XCTAssertNil(lib.maskPlacement, "a placement disarms")
        run(.newRadialMask, ctx)
        XCTAssertEqual(radial.isOn?(ctx), true)
        run(.back, ctx)
        XCTAssertNil(lib.maskPlacement, "Esc disarms placement")
        XCTAssertTrue(lib.loupe)
        run(.newRadialMask, ctx)
        lib.placeMask(.radial, at: MaskPoint(x: 1.0 / 3, y: 1.0 / 3), for: ids[0])
        let masks = lib.recipe(for: ids[0]).masks
        XCTAssertEqual(masks.first?.shape, MaskKind.linear.defaultShape, "a click places the default, centred there")
        XCTAssertEqual(masks.map { MaskKind($0.shape) }, [.linear, .radial])
        XCTAssertEqual(lib.selectedMask, masks[1].id)

        run(.brushMask, ctx)
        XCTAssertTrue(lib.maskBrushArmed)
        XCTAssertEqual(brush.isOn?(ctx), true)
        let brushID = try XCTUnwrap(lib.selectedMask)
        XCTAssertEqual(lib.mask(brushID, for: ids[0])?.shape, .brush([]))
        run(.brushMask, ctx)
        XCTAssertFalse(lib.maskBrushArmed, "K again puts the brush down")
        XCTAssertEqual(lib.recipe(for: ids[0]).masks.count, 3, "and adds nothing")

        // Esc puts the brush down before it leaves the loupe; crop mode,
        // compare, the eyedropper and another mask disarm it.
        run(.brushMask, ctx)
        run(.back, ctx)
        XCTAssertFalse(lib.maskBrushArmed)
        XCTAssertTrue(lib.loupe)
        for disarm: (Library) -> Void in [{ $0.cropMode = true }, { $0.compare = true },
                                          { $0.whiteBalancePicking = true }, { $0.selectedMask = masks[0].id }] {
            lib.cropMode = false; lib.compare = false; lib.whiteBalancePicking = false
            run(.brushMask, ctx)
            XCTAssertTrue(lib.maskBrushArmed)
            disarm(lib)
            XCTAssertFalse(lib.maskBrushArmed)
        }
        lib.compare = false
        run(.brushMask, ctx)
        lib.whiteBalancePicking = true
        XCTAssertFalse(lib.maskBrushArmed)
        run(.brushMask, ctx)
        XCTAssertFalse(lib.whiteBalancePicking, "arming puts the eyedropper down")
        run(.grid, ctx)
        XCTAssertFalse(lib.maskBrushArmed, "leaving the loupe disarms it")

        // O toggles the overlay, off by default.
        let fresh = Library(rememberFolder: false)
        XCTAssertFalse(fresh.showMaskOverlay, "off by default")
        run(.maskOverlay, ctx)
        XCTAssertTrue(lib.showMaskOverlay)
        XCTAssertEqual(overlay.isOn?(ctx), true)
        run(.maskOverlay, ctx)
        XCTAssertFalse(lib.showMaskOverlay)
    }

    // MARK: History label

    func testAMaskStepIsLabelledMask() {
        var a = Recipe.neutral
        var b = a
        b.masks.append(LocalMask(shape: MaskKind.linear.defaultShape))
        XCTAssertEqual(HistoryLabel.describe(from: a, to: b, batch: nil), "Mask")
        a = b
        b.masks[0].set(.exposure, to: 1)
        XCTAssertEqual(HistoryLabel.describe(from: a, to: b, batch: nil), "Mask")
        b.set(.exposure, to: 0.5)
        XCTAssertEqual(HistoryLabel.describe(from: a, to: b, batch: nil), "Exposure, Mask")
    }

    // MARK: The overlay

    /// The tint over a render: red at half strength where the mask's weight
    /// is 1 (the linear's top edge), nothing where it is 0 (below 40%);
    /// inverted, the other way round.
    func testTheTintIsHalfRedWhereTheMaskApplies() throws {
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        var recipe = Recipe.neutral
        var mask = LocalMask(shape: MaskKind.linear.defaultShape)
        recipe.masks = [mask]
        let frame = try XCTUnwrap(Renderer.shared.render(source, recipe: recipe)).image
        let extent = MaskTint.sourceExtent(of: source.extent, maxPixelSize: nil)
        let tinted = try XCTUnwrap(MaskTint.compose(over: frame, mask: mask, recipe: recipe, sourceExtent: extent))
        XCTAssertEqual(tinted.width, frame.width)
        XCTAssertEqual(tinted.height, frame.height)
        XCTAssertGreaterThan(redness(tinted, 150, 0), 100, "half red over grey at the top edge")
        XCTAssertLessThanOrEqual(abs(redness(tinted, 150, 150)), 1, "untouched below 40%")
        XCTAssertEqual(maxDiff(frame, try XCTUnwrap(Renderer.shared.render(source, recipe: .neutral)).image), 0,
                       "the frame itself carries no tint")

        mask.inverted = true
        let inverted = try XCTUnwrap(MaskTint.compose(over: frame, mask: mask, recipe: recipe, sourceExtent: extent))
        XCTAssertLessThanOrEqual(abs(redness(inverted, 150, 0)), 1)
        XCTAssertGreaterThan(redness(inverted, 150, 150), 100)
    }

    /// Under a rotate and a crop, the tint's centre is the centre of what
    /// the mask's exposure brightens (each the weighted centroid of its
    /// change): the tint is placed as the render places the mask.
    func testTheTintLandsWhereTheMasksAdjustmentLands() throws {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let source = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: rect)
        var mask = LocalMask(shape: .radial(center: MaskPoint(x: 0.75, y: 0.35), radii: MaskRadii(x: 0.05, y: 0.05),
                                            angle: 0, feather: 1))
        var recipe = Recipe.neutral
        recipe.set(.rotate, to: 7.5)
        recipe.set(.cropLeft, to: 20)
        recipe.masks = [mask]
        let maxPixel = 300
        let plain = try XCTUnwrap(Renderer.shared.render(source, recipe: recipe, maxPixelSize: maxPixel)).image
        let extent = MaskTint.sourceExtent(of: rect, maxPixelSize: maxPixel)
        XCTAssertEqual(extent.width, 300)
        let tinted = try XCTUnwrap(MaskTint.compose(over: plain, mask: mask, recipe: recipe, sourceExtent: extent))
        mask.set(.exposure, to: 0.5)
        recipe.masks = [mask]
        let bright = try XCTUnwrap(Renderer.shared.render(source, recipe: recipe, maxPixelSize: maxPixel)).image
        XCTAssertEqual(bright.width, tinted.width)

        let w = tinted.width
        func centroid(_ score: (Int) -> Int) -> (x: Double, y: Double, mass: Double) {
            var sx = 0.0, sy = 0.0, m = 0.0
            for y in 0..<tinted.height {
                for x in 0..<w {
                    let s = Double(max(score((y * w + x) * 4), 0))
                    sx += s * Double(x); sy += s * Double(y); m += s
                }
            }
            return (sx / max(m, 1), sy / max(m, 1), m)
        }
        let p = pixels(plain), b = pixels(bright), t = pixels(tinted)
        let effect = centroid { i in b[i + 1] - p[i + 1] }
        let tint = centroid { i in t[i] - t[i + 1] }
        XCTAssertGreaterThan(effect.mass, 1000, "the mask brightened something")
        XCTAssertGreaterThan(tint.mass, 1000, "and tinted something")
        XCTAssertEqual(effect.x, tint.x, accuracy: 1, "x: effect \(effect) tint \(tint)")
        XCTAssertEqual(effect.y, tint.y, accuracy: 1, "y: effect \(effect) tint \(tint)")
        // Not the trivial answer: the mask sits off the frame's centre.
        XCTAssertGreaterThan(abs(tint.x - Double(w) / 2), 20)
        XCTAssertGreaterThan(abs(tint.y - Double(tinted.height) / 2), 20)
    }

    private func pixels(_ image: CGImage) -> [Int] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height * 4)).map { Int(data[$0]) }
    }

    /// The loupe's model: with a mask overlaid, the After frame is tinted and
    /// compare's Before is exactly the neutral render; overlay off, the After
    /// frame is the plain render again.
    func testThePreviewTintsOnlyTheAfterFrame() async throws {
        let url = try makePhoto("p.png", width: 320, height: 240)
        var recipe = Recipe.neutral
        let mask = LocalMask(shape: MaskKind.linear.defaultShape)
        recipe.masks = [mask]
        let preview = PreviewModel()
        preview.load(url)
        preview.setCompare(true)
        preview.request(url: url, recipe: recipe, maxPixelSize: 160)
        preview.setMaskOverlay(mask.id)
        await preview.awaitLoad()
        let deadline = Date().addingTimeInterval(10)
        while (preview.beforeImage == nil || preview.image.map { redness($0, 80, 0) < 50 } ?? true) && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let after = try XCTUnwrap(preview.image)
        let before = try XCTUnwrap(preview.beforeImage)
        XCTAssertGreaterThan(redness(after, 80, 0), 50, "the After frame is tinted at the top")
        XCTAssertLessThanOrEqual(abs(redness(after, 80, 110)), 1, "and not below the gradient")
        XCTAssertLessThanOrEqual(abs(redness(before, 80, 0)), 1, "Before never carries the tint")

        preview.setMaskOverlay(nil)
        let off = Date().addingTimeInterval(10)
        while (preview.image.map { redness($0, 80, 0) > 1 } ?? true) && Date() < off {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertLessThanOrEqual(abs(redness(try XCTUnwrap(preview.image), 80, 0)), 1, "off: the plain frame")
    }

    /// The overlay is display only: with O on and a mask selected, the
    /// export items carry the photo's recipe and the written file has no
    /// red, while the same render tinted by `MaskTint` does.
    func testTheOverlayNeverReachesAnExport() async throws {
        let (lib, ctx, ids) = try openTwo()
        XCTAssertFalse(lib.showMaskOverlay, "off by default")
        let photo = ids[0]
        let mask = lib.addMask(.linear, for: photo)
        run(.maskOverlay, ctx)
        XCTAssertTrue(lib.showMaskOverlay)
        XCTAssertEqual(lib.selectedMask, mask)

        let items = try await lib.exportItems(for: [photo])
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.recipe, lib.recipe(for: photo))
        let out = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var options = ExportOptions()
        options.format = .tiff
        guard case .written(let file) = try Exporter.export(item.source, recipe: item.recipe, into: out, options: options) else {
            return XCTFail("not written")
        }
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        for y in 0..<exported.height {
            XCTAssertLessThanOrEqual(abs(redness(exported, exported.width / 2, y)), 1, "row \(y) has no tint")
        }
        let master = try XCTUnwrap(Renderer.previewMaster(item.source, maxPixelSize: 64))
        let frame = try XCTUnwrap(Renderer.shared.render(master, recipe: item.recipe)).image
        let tinted = try XCTUnwrap(MaskTint.compose(over: frame, mask: try XCTUnwrap(lib.mask(mask, for: photo)),
                                                    recipe: item.recipe, sourceExtent: master.extent))
        XCTAssertGreaterThan(redness(tinted, frame.width / 2, 0), 50, "the same frame tinted is red")
    }
}
