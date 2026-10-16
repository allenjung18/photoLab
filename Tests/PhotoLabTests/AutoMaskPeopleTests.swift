import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
@testable import PhotoLab

/// Select Person and Select Faces (AutoMasks.swift, `Library.selectAuto(.person,
/// for:)`, `Library.selectFaces(for:)`): `FaceMasks.radial` turns Vision's
/// bottom-left face box into a source-frame radial (centre flipped, radii over
/// the long side, roll's sign reversed); faces become radial masks in one undo
/// step; a person is one `.auto` mask as a subject is; real Vision on an image
/// with no people finds none (or skips where the host has no model).
@MainActor
final class AutoMaskPeopleTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-automaskpeople-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fakes

    /// A face Vision might report: `box` normalised, origin bottom-left.
    nonisolated private static func face(_ box: CGRect, roll: Double? = nil) -> VNFaceObservation {
        VNFaceObservation(requestRevision: VNDetectFaceRectanglesRequestRevision3, boundingBox: box,
                          roll: roll.map { NSNumber(value: $0) }, yaw: nil, pitch: nil)
    }

    /// Returns `person` and one face per box in `faceBoxes`.
    private struct FakeDetector: AutoMaskDetector {
        var person: MaskBitmap?
        var faceBoxes: [CGRect] = []
        func subject(in image: CGImage) async throws -> MaskBitmap? { nil }
        func person(in image: CGImage) async throws -> MaskBitmap? { person }
        func faces(in image: CGImage) async throws -> [VNFaceObservation] {
            faceBoxes.map { AutoMaskPeopleTests.face($0) }
        }
    }

    /// The left half white.
    private var leftHalf: MaskBitmap {
        var g = [UInt8](repeating: 0, count: 40 * 30)
        for y in 0..<30 { for x in 0..<20 { g[y * 40 + x] = 255 } }
        return MaskBitmap(gray: g, width: 40, height: 30)
    }

    private func writeFlat(_ name: String, width: Int = 12, height: Int = 8) {
        let url = folder.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// One flat photo open in the loupe, `detector` installed.
    private func open(_ detector: FakeDetector) throws -> (Library, Photo.ID) {
        writeFlat("p0.png")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let id = try XCTUnwrap(lib.photos.first?.id)
        lib.selection = id
        lib.loupe = true
        lib.autoMaskDetector = detector
        return (lib, id)
    }

    // MARK: FaceMasks.radial

    private func parts(_ shape: MaskShape) throws -> (MaskPoint, MaskRadii, Double, Double) {
        guard case .radial(let c, let r, let a, let f) = shape else {
            XCTFail("not a radial")
            throw XCTSkip("unreachable")
        }
        return (c, r, a, f)
    }

    func testAFaceBoxBecomesARadialInTheSourceFrameOnLandscapeAndPortrait() throws {
        // Vision's box: x 0.2...0.4, y 0.6...0.9 from the BOTTOM.
        let obs = Self.face(CGRect(x: 0.2, y: 0.6, width: 0.2, height: 0.3), roll: 0)
        let landscape = CGSize(width: 2000, height: 1000)
        let (c, r, a, f) = try parts(FaceMasks.radial(for: obs.boundingBox, roll: obs.roll?.doubleValue,
                                                      imageSize: landscape))
        XCTAssertEqual(c.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.25, accuracy: 1e-9, "centre flipped to the top-left origin")
        // Box 400 x 300 px over a 2000 px long side, half of each, times the margin.
        XCTAssertEqual(r.x, 0.2 * 2000 / 2000 / 2 * FaceMasks.margin, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0.3 * 1000 / 2000 / 2 * FaceMasks.margin, accuracy: 1e-9)
        XCTAssertEqual(a, 0, accuracy: 1e-12)
        XCTAssertEqual(f, 0.4)

        let portrait = CGSize(width: 1000, height: 2000)
        let (pc, pr, _, _) = try parts(FaceMasks.radial(for: obs.boundingBox, roll: nil, imageSize: portrait))
        XCTAssertEqual(pc.y, 0.25, accuracy: 1e-9)
        XCTAssertEqual(pr.x, 0.2 * 1000 / 2000 / 2 * FaceMasks.margin, accuracy: 1e-9)
        XCTAssertEqual(pr.y, 0.3 * 2000 / 2000 / 2 * FaceMasks.margin, accuracy: 1e-9)

        // A face box square in pixels is a circle (equal radii) on either aspect.
        for size in [landscape, portrait] {
            let side = 300.0
            let box = CGRect(x: 0.1, y: 0.1, width: side / size.width, height: side / size.height)
            let (_, rr, _, _) = try parts(FaceMasks.radial(for: box, roll: nil, imageSize: size))
            XCTAssertEqual(rr.x, rr.y, accuracy: 1e-9, "\(size)")
        }
    }

    func testRollTurnsTheOtherWayAndTheFaceIsInsideTheMask() throws {
        let obs = Self.face(CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.25), roll: 0.3)
        let size = CGSize(width: 1600, height: 1200)
        let shape = FaceMasks.radial(for: obs.boundingBox, roll: obs.roll?.doubleValue, imageSize: size)
        let (c, _, a, _) = try parts(shape)
        XCTAssertEqual(a, -17.19, accuracy: 0.005, "Vision's roll is counter-clockwise, a radial's angle clockwise")
        XCTAssertEqual(MaskMath.weight(of: shape, at: c, in: size), 1, "full effect at the face centre")
        // Top-left frame: the box spans x 0.4...0.6, y 0.45...0.7.
        XCTAssertEqual(c.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.575, accuracy: 1e-9)
        for p in [MaskPoint(x: 0.1, y: 0.575), MaskPoint(x: 0.9, y: 0.575),
                  MaskPoint(x: 0.5, y: 0.1), MaskPoint(x: 0.5, y: 0.95), MaskPoint(x: 0.05, y: 0.05)] {
            XCTAssertEqual(MaskMath.weight(of: shape, at: p, in: size), 0, "well outside the box: \(p)")
        }
    }

    // MARK: The flows

    func testThreeFacesAreThreeRadialMasksInOneUndoStepTheFirstSelected() async throws {
        let boxes = [CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.15),
                     CGRect(x: 0.45, y: 0.55, width: 0.1, height: 0.15),
                     CGRect(x: 0.75, y: 0.5, width: 0.12, height: 0.18)]
        let (lib, id) = try open(FakeDetector(faceBoxes: boxes))
        lib.addMask(.linear, for: id)
        let writes = lib.sidecarWrites
        let added = await lib.selectFaces(for: id)
        XCTAssertEqual(added.count, 3)
        let masks = lib.recipe(for: id).masks
        XCTAssertEqual(masks.count, 4)
        XCTAssertEqual(Array(masks.suffix(3).map(\.id)), added, "appended in face order")
        let size = CGSize(width: 12, height: 8)
        for (mask, box) in zip(masks.suffix(3), boxes) {
            XCTAssertEqual(mask.shape, FaceMasks.radial(for: box, roll: nil, imageSize: size))
        }
        XCTAssertEqual(lib.selectedMask, added.first)
        XCTAssertEqual(lib.sidecarWrites, writes + 1, "one sidecar write")
        XCTAssertNil(lib.autoMaskMessage)
        XCTAssertFalse(lib.autoMaskDetecting)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: id).masks.count, 1, "one undo step removes all three")
    }

    func testNoFacesSaysSoAndChangesNothing() async throws {
        let (lib, id) = try open(FakeDetector())
        let writes = lib.sidecarWrites
        let added = await lib.selectFaces(for: id)
        XCTAssertEqual(added, [])
        XCTAssertEqual(lib.autoMaskMessage, "No faces found")
        XCTAssertEqual(lib.recipe(for: id).masks, [])
        XCTAssertFalse(lib.canUndo)
        XCTAssertEqual(lib.sidecarWrites, writes)
    }

    func testAPersonIsOneSelectedAutoMaskAndNoneSaysSo() async throws {
        let (lib, id) = try open(FakeDetector(person: leftHalf))
        let writes = lib.sidecarWrites
        let found = await lib.selectAuto(.person, for: id)
        let maskID = try XCTUnwrap(found)
        let masks = lib.recipe(for: id).masks
        XCTAssertEqual(masks.map(\.id), [maskID])
        guard case .auto(let auto) = masks.first?.shape else { return XCTFail("not an automatic mask") }
        XCTAssertEqual(auto.kind, .person)
        XCTAssertEqual(auto.bitmap, leftHalf)
        XCTAssertEqual(MaskKind.names(of: masks)[maskID], "Person 1")
        XCTAssertEqual(lib.selectedMask, maskID)
        XCTAssertEqual(lib.sidecarWrites, writes + 1)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: id).masks, [], "one undo step")

        for result in [nil, MaskBitmap.blank] {
            lib.autoMaskDetector = FakeDetector(person: result)
            let before = lib.sidecarWrites
            let none = await lib.selectAuto(.person, for: id)
            XCTAssertNil(none)
            XCTAssertEqual(lib.autoMaskMessage, "No person found")
            XCTAssertEqual(lib.recipe(for: id).masks, [])
            XCTAssertEqual(lib.sidecarWrites, before)
        }
    }

    func testTheCommandsHaveNoKeyAndNeedTheLoupe() throws {
        let (lib, _) = try open(FakeDetector())
        let ctx = CommandContext(library: lib)
        for name in [AppCommand.Name.selectPerson, .selectFaces] {
            let command = AppCommand.command(name)
            XCTAssertNil(command.key, "no key")
            XCTAssertTrue(command.isEnabled(ctx))
            lib.loupe = false
            XCTAssertFalse(command.isEnabled(ctx), "loupe only")
            lib.loupe = true
        }
        XCTAssertEqual(AppCommand.command(.selectPerson).title, "Select Person")
        XCTAssertEqual(AppCommand.command(.selectFaces).title, "Select Faces")
    }

    // MARK: Real Vision

    func testVisionFindsNoPersonAndNoFacesInAFlatImage() async throws {
        writeFlat("flat.png", width: 640, height: 480)
        let url = folder.appendingPathComponent("flat.png")
        let image = try XCTUnwrap(ImageLoading.downsampledCGImage(url, maxPixelSize: VisionDetector.inputPixelSize))
        let detector = VisionDetector()
        do {
            let person = try await detector.person(in: image)
            XCTAssertNil(person, "no person in a flat grey image")
        } catch {
            throw XCTSkip("Vision person request failed on this host: \(error)")
        }
        do {
            let faces = try await detector.faces(in: image)
            XCTAssertEqual(faces.count, 0, "no faces in a flat grey image")
        } catch {
            throw XCTSkip("Vision face request failed on this host: \(error)")
        }
    }
}
