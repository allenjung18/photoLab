import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Match Look (`Library.matchLook`, `MatchLookModel`): a reference photo's
/// look brought to the batch targets as one undo step, the reference only
/// read. Every file is synthetic in a temp folder.
@MainActor
final class MatchLookTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var reference: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-matchlook-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reference = root.appendingPathComponent("reference.png")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A continuous field (hue across, brightness down, saturation rising),
    /// 512 px, flipped vertically when `flipped` so two photos differ.
    private func field(flipped: Bool = false) -> CGImage {
        let w = 512, h = 512
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let hue = Double(x) / Double(w) * 6
                let sat = 0.05 + 0.55 * Double(x) / Double(w - 1)
                let yy = flipped ? h - 1 - y : y
                let v = 0.06 + 0.9 * Double(yy) / Double(h - 1)
                let c = v * sat, m = v - c
                let k = c * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
                let (r, g, b): (Double, Double, Double)
                switch Int(hue) {
                case 0: (r, g, b) = (c, k, 0)
                case 1: (r, g, b) = (k, c, 0)
                case 2: (r, g, b) = (0, c, k)
                case 3: (r, g, b) = (0, k, c)
                case 4: (r, g, b) = (k, 0, c)
                default: (r, g, b) = (c, 0, k)
                }
                let i = (y * w + x) * 4
                px[i] = UInt8(((r + m) * 255).rounded()); px[i + 1] = UInt8(((g + m) * 255).rounded())
                px[i + 2] = UInt8(((b + m) * 255).rounded()); px[i + 3] = 255
            }
        }
        return ctx.makeImage()!
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// The field rendered through a warm look, saved as the reference.
    private func makeWarmReference() throws {
        var warm = Recipe.neutral
        warm.set(.temperature, to: 40)
        let frame = try XCTUnwrap(Renderer.shared.render(CIImage(cgImage: field()), recipe: warm, maxPixelSize: 512))
        try write(frame.image, to: reference)
    }

    private func makeLibrary() throws -> (Library, [Photo.ID]) {
        try write(field(), to: folder.appendingPathComponent("a.png"))
        try write(field(flipped: true), to: folder.appendingPathComponent("b.png"))
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.selectAll()
        let ids = lib.batchTargets
        XCTAssertEqual(ids.count, 2)
        return (lib, ids)
    }

    func testTwoPhotosMatchedToAWarmReferenceMoveTemperatureUpInOneUndoStep() async throws {
        try makeWarmReference()
        let (lib, ids) = try makeLibrary()
        let outcome = try await lib.matchLook(reference: reference, to: ids)
        XCTAssertEqual(outcome.changed, 2)
        for id in ids {
            XCTAssertGreaterThan(lib.recipe(for: id).value(of: .temperature), 0, "temperature moved up on \(id)")
        }
        let row = try XCTUnwrap(outcome.moved.first { $0.kind == .temperature })
        XCTAssertEqual(row.photos, 2)
        XCTAssertGreaterThan(row.value, 0)
        // One Undo takes both back.
        lib.undo()
        for id in ids { XCTAssertFalse(lib.isEdited(id), "one Undo restores \(id)") }
        lib.redo()
        for id in ids { XCTAssertGreaterThan(lib.recipe(for: id).value(of: .temperature), 0) }
        XCTAssertFalse(lib.autoToning)
    }

    func testTheSidecarsHoldOrdinarySliderValues() async throws {
        try makeWarmReference()
        let (lib, ids) = try makeLibrary()
        _ = try await lib.matchLook(reference: reference, to: ids)
        let store = SidecarStore(folder: folder)
        for id in ids {
            let stored = try XCTUnwrap(store.load(for: id))
            XCTAssertEqual(stored.normalized, lib.recipe(for: id).normalized)
            for kind in LookMatch.kinds {
                let v = stored.value(of: kind)
                XCTAssertTrue(kind.range.contains(v), "\(kind) \(v) inside its slider range")
            }
            XCTAssertGreaterThan(stored.value(of: .temperature), 0)
        }
    }

    func testAnUnreadableReferenceChangesNothing() async throws {
        try "not an image".write(to: reference, atomically: true, encoding: .utf8)
        let (lib, ids) = try makeLibrary()
        do {
            _ = try await lib.matchLook(reference: reference, to: ids)
            XCTFail("an unreadable reference throws")
        } catch let error as MatchLookError {
            XCTAssertEqual(error, .unreadable("reference.png"))
        }
        for id in ids { XCTAssertFalse(lib.isEdited(id)) }
        XCTAssertFalse(lib.autoToning)
        // The model says so and holds no reference.
        let model = MatchLookModel(library: lib, targets: ids)
        model.setReference(reference)
        XCTAssertNil(model.reference)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.canMatch)
        let missing = root.appendingPathComponent("gone.png")
        do { _ = try await lib.matchLook(reference: missing, to: ids); XCTFail("missing file throws") } catch {}
        for id in ids { XCTAssertFalse(lib.isEdited(id)) }
    }

    func testTheReferenceFileIsOnlyRead() async throws {
        try makeWarmReference()
        let (lib, ids) = try makeLibrary()
        let before = try Data(contentsOf: reference)
        let attrs = try FileManager.default.attributesOfItem(atPath: reference.path)
        let listing = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        _ = try await lib.matchLook(reference: reference, to: ids)
        XCTAssertEqual(try Data(contentsOf: reference), before)
        let after = try FileManager.default.attributesOfItem(atPath: reference.path)
        XCTAssertEqual(after[.modificationDate] as? Date, attrs[.modificationDate] as? Date)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), listing,
                       "nothing written beside the reference")
        XCTAssertEqual(lib.photos.count, 2, "the reference was not imported")
    }

    func testTheModelRunsTheMatchAndListsTheSlidersMoved() async throws {
        try makeWarmReference()
        let (lib, ids) = try makeLibrary()
        XCTAssertTrue(lib.requestMatchLook(for: ids, reference: reference))
        let model = try XCTUnwrap(lib.matchLookRequest)
        XCTAssertNotNil(model.thumbnail)
        XCTAssertTrue(model.canMatch)
        XCTAssertFalse(lib.requestMatchLook(for: ids), "one sheet at a time")
        await model.match()
        XCTAssertNil(model.error)
        let outcome = try XCTUnwrap(model.outcome)
        XCTAssertEqual(outcome.changed, 2)
        XCTAssertTrue(outcome.moved.contains { $0.kind == .temperature })
        model.close()
        XCTAssertNil(lib.matchLookRequest)
    }
}
