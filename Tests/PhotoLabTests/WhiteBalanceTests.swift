import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// The white-balance eyedropper (`WhiteBalance`, `Library.pickWhiteBalance`,
/// `ZoomMath.point(forClick:)`): a grey patch given a cast by known slider
/// values solves back to grey, a neutral one to zero, clipped and dark
/// patches are refused and change nothing, a pick is one undo step that
/// takes both sliders back, and a click at fit and at 1:1 sample the same
/// pixel.
@MainActor
final class WhiteBalanceTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-wb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: The solve

    /// Grey patches warmed, cooled and tinted both ways by known slider
    /// values: the solved pair renders each back to grey (channel spread
    /// under 0.01 in sRGB; the cast itself is several times that).
    func testACastGreyPatchSolvesBackToGrey() throws {
        let casts: [(t: Double, i: Double)] = [(40, -25), (-60, 30), (25, 45), (-35, -40), (50, 0), (0, -70)]
        for grey in [0.5, 0.3, 0.75] {
            for cast in casts {
                let patch = WhiteBalance.rendered(SIMD3(repeating: grey), temperature: cast.t, tint: cast.i)
                XCTAssertGreaterThan(WhiteBalance.spread(patch), 0.03, "the cast shows (\(cast), grey \(grey))")
                guard case let .balanced(t, i) = WhiteBalance.neutralising(patch) else {
                    return XCTFail("refused \(patch)")
                }
                XCTAssertTrue(AdjustmentKind.temperature.range.contains(t))
                XCTAssertTrue(AdjustmentKind.tint.range.contains(i))
                let back = WhiteBalance.rendered(patch, temperature: t, tint: i)
                XCTAssertLessThan(WhiteBalance.spread(back), 0.01,
                                  "cast \(cast) on grey \(grey): solved \(t), \(i) renders \(back)")
            }
        }
    }

    /// A cast beyond the sliders' reach (temperature +80 needs a cooling
    /// past -100: the slider maps to kelvin, which is not symmetric) is
    /// clamped to the range and reduced, not refused.
    func testACastBeyondTheRangeIsClampedAndReduced() throws {
        let patch = WhiteBalance.rendered(SIMD3(repeating: 0.5), temperature: 80, tint: 0)
        guard case let .balanced(t, i) = WhiteBalance.neutralising(patch) else { return XCTFail("refused") }
        XCTAssertEqual(t, AdjustmentKind.temperature.range.lowerBound, "clamped at the slider's end")
        XCTAssertTrue(AdjustmentKind.tint.range.contains(i))
        let back = WhiteBalance.rendered(patch, temperature: t, tint: i)
        XCTAssertLessThan(WhiteBalance.spread(back), WhiteBalance.spread(patch) * 0.6, "the cast is reduced")
    }

    /// The sign of the answer: a warmed patch is cooled, a magenta one
    /// greened (temperature and tint each move against the cast).
    func testTheSolveMovesAgainstTheCast() throws {
        let warm = WhiteBalance.rendered(SIMD3(repeating: 0.5), temperature: 40, tint: 0)
        guard case let .balanced(t, _) = WhiteBalance.neutralising(warm) else { return XCTFail() }
        XCTAssertLessThan(t, -10, "a warm patch takes a cooler temperature")
        let magenta = WhiteBalance.rendered(SIMD3(repeating: 0.5), temperature: 0, tint: 40)
        guard case let .balanced(_, i) = WhiteBalance.neutralising(magenta) else { return XCTFail() }
        XCTAssertLessThan(i, -10, "a magenta patch takes a greener tint")
    }

    func testANeutralPatchSolvesToZero() throws {
        for grey in [0.2, 0.5, 0.9] {
            guard case let .balanced(t, i) = WhiteBalance.neutralising(SIMD3(repeating: grey)) else {
                return XCTFail("grey \(grey) refused")
            }
            XCTAssertEqual(t, 0, accuracy: 1, "grey \(grey)")
            XCTAssertEqual(i, 0, accuracy: 1, "grey \(grey)")
        }
    }

    func testClippedAndDarkPatchesAreRefused() {
        XCTAssertEqual(WhiteBalance.neutralising(SIMD3(0.98, 0.6, 0.5)), .clipped, "a channel at 0.98")
        XCTAssertEqual(WhiteBalance.neutralising(SIMD3(0.5, 0.6, 1.0)), .clipped)
        XCTAssertEqual(WhiteBalance.neutralising(SIMD3(0.01, 0.01, 0.01)), .tooDark, "near black")
        XCTAssertEqual(WhiteBalance.neutralising(SIMD3(0.3, 0.019, 0.3)), .tooDark, "a channel below 0.02")
        if case .balanced = WhiteBalance.neutralising(SIMD3(0.97, 0.9, 0.85)) {} else { XCTFail("just under") }
        if case .balanced = WhiteBalance.neutralising(SIMD3(0.02, 0.03, 0.04)) {} else { XCTFail("just over") }
        XCTAssertNotNil(WhiteBalance.Solve.clipped.refusal)
        XCTAssertNotNil(WhiteBalance.Solve.tooDark.refusal)
    }

    /// The solve is meant to run on every click: under 50 ms (the best of
    /// three, scaled under load like the frame-budget gates).
    func testTheSolveIsUnder50ms() throws {
        let patch = WhiteBalance.rendered(SIMD3(repeating: 0.45), temperature: -30, tint: 20)
        _ = WhiteBalance.neutralising(patch)  // warm the context
        var best = Double.infinity
        for _ in 0..<3 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = WhiteBalance.neutralising(patch)
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        }
        try assertFrameBudget(best, bound: 50, load: loadAverage(), "WhiteBalance.neutralising")
    }

    /// The sampled frame is the white-balance stage's input: every kind from
    /// temperature on at neutral, geometry and exposure kept.
    func testTheBaseKeepsWhatComesBeforeTheWhiteBalanceStage() {
        var r = Recipe.neutral
        r.set(.rotate, to: 3)
        r.set(.cropLeft, to: 10)
        r.set(.exposure, to: 0.5)
        r.set(.temperature, to: 30)
        r.set(.tint, to: -20)
        r.set(.contrast, to: 40)
        r.set(.hsl(.hue, .blue), to: 15)
        r.set(.vignette, to: -50)
        r.masks = [LocalMask(shape: .radial(center: MaskPoint(x: 0.5, y: 0.5), radii: MaskRadii(x: 0.2, y: 0.2),
                                            angle: 0, feather: 0.5),
                             adjustments: [Adjustment(kind: .temperature, value: 40)])]
        let base = WhiteBalance.base(r)
        XCTAssertTrue(base.masks.isEmpty, "local adjustments render after the white-balance stage")
        XCTAssertEqual(base.value(of: .rotate), 3)
        XCTAssertEqual(base.value(of: .cropLeft), 10)
        XCTAssertEqual(base.value(of: .exposure), 0.5)
        let from = AdjustmentKind.allCases.firstIndex(of: .temperature)!
        for kind in AdjustmentKind.allCases[from...] {
            XCTAssertTrue(base[kind].isNoop, "\(kind) at neutral")
        }
    }

    // MARK: Fit and 1:1

    /// One pixel of a 6000×4000 rendered frame, clicked in the 1:1 window
    /// and at the matching spot of the fit frame: both clicks map to the
    /// same point, so the 5×5 patch cut from the 3200 px master is the same.
    func testFitAndOneToOneHitTheSameSourcePixel() throws {
        let full = CGSize(width: 6000, height: 4000)
        let fit = CGSize(width: 1500, height: 1000)
        let master = CGSize(width: 3200, height: 2133)
        let pane = CGSize(width: 900, height: 620), scale: CGFloat = 2
        let window = ZoomMath.window(pane: pane, displayScale: scale)
        for (centre, target) in [(CGPoint(x: 0.7, y: 0.3), CGPoint(x: 4321, y: 1234)),
                                 (CGPoint(x: 0.98, y: 0.02), CGPoint(x: 5990, y: 7)),
                                 (CGPoint(x: 0.5, y: 0.5), CGPoint(x: 3000, y: 2000))] {
            let region = Renderer.Region(center: centre, size: window).rect(in: full)
            XCTAssertTrue(region.contains(target), "\(target) is in the window")
            let click = CGPoint(x: (target.x - region.minX + 0.5) / scale, y: (target.y - region.minY + 0.5) / scale)
            let atActual = try XCTUnwrap(ZoomMath.point(forClick: click, region: region, frame: full,
                                                        pane: pane, displayScale: scale))
            XCTAssertEqual(atActual.x, (target.x + 0.5) / full.width, accuracy: 1e-9)
            XCTAssertEqual(atActual.y, (target.y + 0.5) / full.height, accuracy: 1e-9)

            let r = ZoomMath.fitRect(frame: fit, pane: pane)
            let fitClick = CGPoint(x: r.minX + atActual.x * r.width, y: r.minY + atActual.y * r.height)
            let atFit = try XCTUnwrap(ZoomMath.center(forClick: fitClick, frame: fit, pane: pane))
            let patch = CGSize(width: WhiteBalance.patchSize, height: WhiteBalance.patchSize)
            XCTAssertEqual(Renderer.Region(center: atFit, size: patch).rect(in: master),
                           Renderer.Region(center: atActual, size: patch).rect(in: master),
                           "same 5×5 patch of the master from \(target)")
        }
        // A window smaller than the pane is centred: a click beside it is off the photo.
        let small = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertNil(ZoomMath.point(forClick: CGPoint(x: 10, y: 10), region: small,
                                    frame: CGSize(width: 400, height: 300), pane: pane, displayScale: scale))
        XCTAssertNotNil(ZoomMath.point(forClick: CGPoint(x: 450, y: 310), region: small,
                                       frame: CGSize(width: 400, height: 300), pane: pane, displayScale: scale))
    }

    // MARK: Through the library

    /// A photo filled with one sRGB colour.
    private func makePhoto(_ name: String, _ rgb: SIMD3<Double>) throws {
        let url = folder.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: space, components: [rgb.x, rgb.y, rgb.z, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// A pick on a photo with a cast sets temperature and tint so the photo
    /// renders grey, through `setRecipe`: one undo step (both sliders back
    /// together), the sidecar written once, the tool disarmed. The sliders'
    /// values before the pick do not enter the sample.
    func testAPickIsOneUndoStepThatRestoresBothSliders() async throws {
        let cast = WhiteBalance.rendered(SIMD3(repeating: 0.5), temperature: 45, tint: -30)
        try makePhoto("cast.png", cast)
        let store = SidecarStore(folder: folder)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let photo = try XCTUnwrap(lib.photos.first).id
        lib.selection = photo
        lib.loupe = true
        var before = Recipe.neutral
        before.set(.temperature, to: 12)
        before.set(.tint, to: 7)
        before.setEnabled(.tint, false)
        lib.setRecipe(before, for: photo)

        lib.cropMode = true
        lib.whiteBalancePicking = true
        XCTAssertFalse(lib.cropMode, "arming leaves crop mode")
        let solve = await lib.pickWhiteBalance(at: CGPoint(x: 0.5, y: 0.5), for: photo)
        guard case let .balanced(t, i) = try XCTUnwrap(solve) else { return XCTFail("refused") }
        XCTAssertFalse(lib.whiteBalancePicking, "a balanced pick disarms")
        XCTAssertNil(lib.whiteBalanceNote)
        let after = lib.recipe(for: photo)
        XCTAssertEqual(after.value(of: .temperature), t)
        XCTAssertEqual(after.value(of: .tint), i)
        XCTAssertTrue(after.isEnabled(.tint), "the pick switches tint on")
        XCTAssertEqual(try store.load(for: photo), after, "written at once")

        let master = try XCTUnwrap(Renderer.previewMaster(folder.appendingPathComponent("cast.png"), maxPixelSize: 3200))
        let shown = try XCTUnwrap(WhiteBalance.patch(of: master, recipe: after, at: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertLessThan(WhiteBalance.spread(shown), 0.015, "the photo renders grey: \(shown)")

        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), before, "one undo takes both sliders back")
        XCTAssertEqual(try store.load(for: photo), before)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), .neutral, "and the step before it is the setup's")
        lib.redo()
        lib.redo()
        XCTAssertEqual(lib.recipe(for: photo), after)
    }

    /// A clipped or near-black patch is refused: no recipe change, no undo
    /// step, no sidecar, a status line, and the tool stays armed.
    func testARefusedPickChangesNothing() async throws {
        try makePhoto("white.png", SIMD3(1, 1, 0.99))
        try makePhoto("black.png", SIMD3(0.005, 0.005, 0.005))
        let store = SidecarStore(folder: folder)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.loupe = true
        for (name, expected) in [("black.png", WhiteBalance.Solve.tooDark), ("white.png", .clipped)] {
            let photo = try XCTUnwrap(lib.photos.first { $0.fileURL?.lastPathComponent == name }).id
            lib.selection = photo
            lib.whiteBalancePicking = true
            let solve = await lib.pickWhiteBalance(at: CGPoint(x: 0.5, y: 0.5), for: photo)
            XCTAssertEqual(solve, expected, "\(photo)")
            XCTAssertEqual(lib.recipe(for: photo), .neutral)
            XCTAssertFalse(lib.isEdited(photo))
            XCTAssertFalse(lib.canUndo, "no undo step")
            XCTAssertNil(try store.load(for: photo), "no sidecar")
            XCTAssertEqual(lib.whiteBalanceNote, expected.refusal)
            XCTAssertTrue(lib.whiteBalancePicking, "still armed for another click")
        }
        lib.whiteBalancePicking = false
        lib.whiteBalancePicking = true
        XCTAssertNil(lib.whiteBalanceNote, "arming again clears the note")
    }
}
