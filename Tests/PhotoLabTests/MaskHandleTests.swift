import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// The on-canvas mask handles (MaskOverlay.swift): what each handle's drag
/// does to the shape (`MaskHandles`), and that every drag through
/// `Library.dragMask` / `dragPlacement` is one undo step and one sidecar
/// write, measured from the drag's start, with a placement creating exactly
/// one mask.
@MainActor
final class MaskHandleTests: XCTestCase {
    private var folder: URL!
    private let wide = CGSize(width: 1200, height: 800)

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-maskhandles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func p(_ x: Double, _ y: Double) -> MaskPoint { MaskPoint(x: x, y: y) }

    private func assertEqual(_ a: MaskPoint, _ b: MaskPoint, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-9, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-9, message, file: file, line: line)
    }

    /// One flat photo open in the loupe.
    private func openOne() throws -> (Library, Photo.ID) {
        let url = folder.appendingPathComponent("a.png")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let id = try XCTUnwrap(lib.photos.first?.id)
        lib.selection = id
        lib.loupe = true
        return (lib, id)
    }

    // MARK: The arithmetic

    func testALinearCentreDragMovesBothPointsByTheSameSourceDelta() {
        let start = MaskShape.linear(start: p(0.3, 0.2), end: p(0.6, 0.5))
        let moved = MaskHandles.drag(.linearCenter, shape: start, from: p(0.45, 0.35), to: p(0.52, 0.31), size: wide)
        guard case .linear(let a, let b) = moved else { return XCTFail() }
        assertEqual(a, p(0.37, 0.16))
        assertEqual(b, p(0.67, 0.46))
    }

    func testALinearEndDragTurnsAndStretchesAboutTheCentre() {
        let start = MaskShape.linear(start: p(0.5, 0.2), end: p(0.5, 0.6))
        // The end handle dragged right: the centre (0.5, 0.4) stays, the
        // start mirrors the end through it.
        let moved = MaskHandles.drag(.linearEnd, shape: start, from: p(0.5, 0.6), to: p(0.7, 0.6), size: wide)
        guard case .linear(let a, let b) = moved else { return XCTFail() }
        assertEqual(b, p(0.7, 0.6))
        assertEqual(a, p(0.3, 0.2))
        assertEqual(MaskPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), p(0.5, 0.4), "the centre stays")
        // Dragged onto the centre it would vanish: it keeps the start.
        XCTAssertEqual(MaskHandles.drag(.linearStart, shape: start, from: p(0.5, 0.2), to: p(0.5, 0.4), size: wide), start)
    }

    func testARadialEdgeDragChangesOneRadiusOnly() {
        for angle in [0.0, 35] {
            let radii = MaskRadii(x: 0.2, y: 0.1)
            let start = MaskShape.radial(center: p(0.5, 0.5), radii: radii, angle: angle, feather: 0.4)
            let pos = MaskHandles.positions(of: start, size: wide)
            for edge in MaskHandle.RadialEdge.allCases {
                let h = pos[.radialEdge(edge)]!
                // Out along the screen diagonal: only this edge's axis counts.
                let moved = MaskHandles.drag(.radialEdge(edge), shape: start, from: h, to: p(h.x + 0.05, h.y + 0.04), size: wide)
                guard case .radial(let c, let r, let a, let f) = moved else { return XCTFail() }
                assertEqual(c, p(0.5, 0.5), "\(edge): the centre stays")
                XCTAssertEqual(a, angle); XCTAssertEqual(f, 0.4)
                if edge.isFirstAxis {
                    XCTAssertNotEqual(r.x, radii.x, accuracy: 1e-6, "\(edge) at \(angle): radii.x moves")
                    XCTAssertEqual(r.y, radii.y, "\(edge) at \(angle): radii.y stays")
                } else {
                    XCTAssertNotEqual(r.y, radii.y, accuracy: 1e-6, "\(edge) at \(angle): radii.y moves")
                    XCTAssertEqual(r.x, radii.x, "\(edge) at \(angle): radii.x stays")
                }
            }
        }
        // At angle 0 the right edge dragged 0.05 of the width right adds
        // 0.05 x 1200 / 1200 long-side units to radii.x.
        let start = MaskShape.radial(center: p(0.5, 0.5), radii: MaskRadii(x: 0.2, y: 0.1), angle: 0, feather: 0.4)
        let h = MaskHandles.positions(of: start, size: wide)[.radialEdge(.right)]!
        guard case .radial(_, let r, _, _) = MaskHandles.drag(.radialEdge(.right), shape: start, from: h,
                                                               to: p(h.x + 0.05, h.y), size: wide) else { return XCTFail() }
        XCTAssertEqual(r.x, 0.25, accuracy: 1e-9)
    }

    func testRadialRotateFeatherAndCentreHandles() {
        let start = MaskShape.radial(center: p(0.5, 0.5), radii: MaskRadii(x: 0.2, y: 0.1), angle: 0, feather: 0.4)
        let pos = MaskHandles.positions(of: start, size: wide)
        // The rotate knob is straight above the centre; dragged to straight
        // right of it, the ellipse turns 90 degrees clockwise.
        let knob = pos[.radialRotate]!
        let right = p(0.5 + (0.5 - knob.y) * wide.height / wide.width, 0.5)
        guard case .radial(_, _, let angle, _) = MaskHandles.drag(.radialRotate, shape: start, from: knob, to: right,
                                                                   size: wide) else { return XCTFail() }
        XCTAssertEqual(angle, 90, accuracy: 1e-9)
        // The feather handle dragged out to the edge: no feather.
        let f0 = pos[.radialFeather]!, edge = pos[.radialEdge(.right)]!
        guard case .radial(_, _, _, let feather) = MaskHandles.drag(.radialFeather, shape: start, from: f0, to: edge,
                                                                     size: wide) else { return XCTFail() }
        XCTAssertEqual(feather, 0, accuracy: 1e-9)
        // The centre pin moves the centre only.
        guard case .radial(let c, let r, _, _) = MaskHandles.drag(.radialCenter, shape: start, from: p(0.5, 0.5),
                                                                   to: p(0.6, 0.45), size: wide) else { return XCTFail() }
        assertEqual(c, p(0.6, 0.45))
        XCTAssertEqual(r, MaskRadii(x: 0.2, y: 0.1))
    }

    func testAPlacementIsStartToEndOrCentreToEdge() {
        XCTAssertEqual(MaskHandles.placed(.linear, from: p(0.2, 0.3), to: p(0.4, 0.7), size: wide),
                       .linear(start: p(0.2, 0.3), end: p(0.4, 0.7)))
        // 0.1 of the width right of the centre: a circle of radius 0.1 long-side units.
        guard case .radial(let c, let r, _, _) = MaskHandles.placed(.radial, from: p(0.5, 0.5), to: p(0.6, 0.5), size: wide)
        else { return XCTFail() }
        assertEqual(c, p(0.5, 0.5))
        XCTAssertEqual(r.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0.1, accuracy: 1e-9)
        XCTAssertNil(MaskHandles.placed(.brush, from: p(0, 0), to: p(1, 1), size: wide))
    }

    // MARK: Through the library

    func testADragIsOneUndoStepAndOneSidecarWriteMeasuredFromItsStart() throws {
        let (lib, photo) = try openOne()
        let mask = lib.addMask(.linear, for: photo)
        let before = lib.recipe(for: photo)
        let writes = lib.sidecarWrites
        let from = p(0.5, 0.2)
        // Many moves: each measured from the drag's start, not the last move.
        for step in 1...20 {
            lib.dragMask(.linearCenter, mask, from: from, to: p(0.5 + 0.01 * Double(step), 0.2), size: wide, for: photo)
        }
        XCTAssertEqual(lib.sidecarWrites, writes, "nothing written mid-drag")
        lib.endMaskDrag(photo)
        XCTAssertEqual(lib.sidecarWrites, writes + 1, "one sidecar write")
        guard case .linear(let a, let b) = lib.mask(mask, for: photo)?.shape else { return XCTFail() }
        assertEqual(a, p(0.7, 0), "moved by the last delta only (no drift)")
        assertEqual(b, p(0.7, 0.4))
        XCTAssertEqual(try SidecarStore(folder: folder).load(for: photo)?.masks.first?.shape, lib.mask(mask, for: photo)?.shape)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), before, "one undo step")
    }

    func testAPlacementDragCreatesExactlyOneMaskInOneStep() throws {
        let (lib, photo) = try openOne()
        let before = lib.recipe(for: photo)
        lib.maskPlacement = .radial
        let writes = lib.sidecarWrites
        for step in 1...10 {
            lib.dragPlacement(.radial, from: p(0.5, 0.5), to: p(0.5 + 0.01 * Double(step), 0.5), size: wide, for: photo)
        }
        XCTAssertEqual(lib.recipe(for: photo).masks.count, 1, "one mask however many moves")
        lib.endMaskDrag(photo)
        let masks = lib.recipe(for: photo).masks
        XCTAssertEqual(masks.count, 1)
        XCTAssertEqual(lib.selectedMask, masks.first?.id, "the new mask is selected")
        XCTAssertNil(lib.maskPlacement, "a placement disarms")
        XCTAssertEqual(lib.sidecarWrites, writes + 1, "one sidecar write")
        guard case .radial(_, let r, _, _) = masks[0].shape else { return XCTFail() }
        XCTAssertEqual(r.x, 0.1, accuracy: 1e-9)
        // Not armed: a placement call does nothing.
        lib.dragPlacement(.radial, from: p(0.2, 0.2), to: p(0.3, 0.3), size: wide, for: photo)
        lib.endMaskDrag(photo)
        XCTAssertEqual(lib.recipe(for: photo).masks.count, 1)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: photo), before, "one undo step takes the placement back")
    }

    func testArmingIsExclusiveWithTheOtherTools() throws {
        let (lib, _) = try openOne()
        for other: (Library) -> Void in [{ $0.cropMode = true }, { $0.compare = true },
                                         { $0.whiteBalancePicking = true }, { $0.maskBrushArmed = true },
                                         { $0.loupe = false }] {
            lib.loupe = true
            lib.cropMode = false; lib.compare = false; lib.whiteBalancePicking = false; lib.maskBrushArmed = false
            lib.maskPlacement = .linear
            other(lib)
            XCTAssertNil(lib.maskPlacement)
        }
        lib.loupe = true
        lib.cropMode = true
        lib.maskPlacement = .radial
        XCTAssertFalse(lib.cropMode, "arming leaves crop mode")
    }

    func testEscDeselectsTheMaskBeforeLeavingTheLoupe() throws {
        let (lib, photo) = try openOne()
        let ctx = CommandContext(library: lib)
        lib.addMask(.radial, for: photo)
        XCTAssertNotNil(lib.selectedMask)
        AppCommand.command(.back).perform(ctx)
        XCTAssertNil(lib.selectedMask, "Esc deselects (the handles go)")
        XCTAssertTrue(lib.loupe)
        AppCommand.command(.back).perform(ctx)
        XCTAssertFalse(lib.loupe, "then Esc leaves the loupe")
    }
}
