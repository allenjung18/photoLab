import XCTest
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Select Subject (AutoMasks.swift, `Library.selectAuto`): a detection
/// becomes one selected `.auto` mask in one undo step; nothing found says so
/// and changes nothing; a photo switched mid-run gets nothing; the command is
/// off while one runs. `MaskBitmap(pixelBuffer:)` keeps row 0 at the top for
/// both buffer formats, and the real Vision detector, where the host has its
/// model, finds a drawn figure where it is displayed, EXIF orientation included.
@MainActor
final class AutoMaskDetectTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-automaskdetect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fakes

    /// Opens when told: a detection held mid-run.
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    /// Returns `result` for any image, after `gate` opens when there is one.
    private struct FakeDetector: AutoMaskDetector {
        let result: MaskBitmap?
        var gate: Gate?
        func subject(in image: CGImage) async throws -> MaskBitmap? {
            if let gate { await gate.wait() }
            return result
        }
    }

    /// The top half white.
    private var topHalf: MaskBitmap {
        var g = [UInt8](repeating: 0, count: 64 * 48)
        for i in 0..<(64 * 24) { g[i] = 255 }
        return MaskBitmap(gray: g, width: 64, height: 48)
    }

    private func writeFlat(_ name: String) {
        let url = folder.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// `count` flat photos open, the first in the loupe, `detector` installed.
    private func open(_ count: Int, _ detector: FakeDetector) throws -> (Library, [Photo.ID]) {
        for i in 0..<count { writeFlat("p\(i).png") }
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let ids = lib.photos.map(\.id)
        XCTAssertEqual(ids.count, count)
        lib.selection = try XCTUnwrap(ids.first)
        lib.loupe = true
        lib.autoMaskDetector = detector
        return (lib, ids)
    }

    // MARK: The flow

    func testASubjectFoundIsOneSelectedAutoMaskAtTheEndAndOneUndoStep() async throws {
        let (lib, ids) = try open(1, FakeDetector(result: topHalf))
        let id = ids[0]
        lib.addMask(.radial, for: id)
        let writes = lib.sidecarWrites
        let added = await lib.selectAuto(.subject, for: id)
        let maskID = try XCTUnwrap(added)
        let masks = lib.recipe(for: id).masks
        XCTAssertEqual(masks.count, 2)
        XCTAssertEqual(masks.last?.id, maskID, "added at the end")
        guard case .auto(let auto) = masks.last?.shape else { return XCTFail("not an automatic mask") }
        XCTAssertEqual(auto.kind, .subject)
        XCTAssertEqual(auto.bitmap, topHalf)
        XCTAssertEqual(auto.strokes, [])
        XCTAssertEqual(lib.selectedMask, maskID)
        XCTAssertFalse(lib.maskBrushArmed, "a detection is not armed for painting")
        XCTAssertEqual(lib.sidecarWrites, writes + 1, "one sidecar write")
        XCTAssertNil(lib.autoMaskMessage)
        XCTAssertFalse(lib.autoMaskDetecting)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: id).masks.count, 1, "one undo step removes it")
        XCTAssertNil(lib.selectedMask)
    }

    func testNothingFoundSaysSoAndChangesNothing() async throws {
        for result in [nil, MaskBitmap.blank] {
            let (lib, ids) = try open(1, FakeDetector(result: result))
            let id = ids[0]
            let writes = lib.sidecarWrites
            let added = await lib.selectAuto(.subject, for: id)
            XCTAssertNil(added)
            XCTAssertEqual(lib.autoMaskMessage, "No subject found")
            XCTAssertEqual(lib.recipe(for: id).masks, [])
            XCTAssertFalse(lib.canUndo, "no step")
            XCTAssertEqual(lib.sidecarWrites, writes, "no write")
            // The next photo clears the message.
            lib.selection = nil
            XCTAssertNil(lib.autoMaskMessage)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("p0.png"))
        }
    }

    func testAPhotoSwitchedMidRunGetsNothingAndTheCommandIsOffWhileItRuns() async throws {
        let gate = Gate()
        let (lib, ids) = try open(2, FakeDetector(result: topHalf, gate: gate))
        let ctx = CommandContext(library: lib)
        let command = AppCommand.command(.selectSubject)
        XCTAssertTrue(command.isEnabled(ctx))
        let run = Task { await lib.selectAuto(.subject, for: ids[0]) }
        while !lib.autoMaskDetecting { await Task.yield() }
        XCTAssertFalse(command.isEnabled(ctx), "off while a detection runs")
        let second = await lib.selectAuto(.subject, for: ids[0])
        XCTAssertNil(second, "one run at a time")
        lib.selection = ids[1]
        await gate.release()
        let added = await run.value
        XCTAssertNil(added)
        XCTAssertEqual(lib.recipe(for: ids[0]).masks, [], "the photo left behind gets nothing")
        XCTAssertEqual(lib.recipe(for: ids[1]).masks, [], "nor the photo now shown")
        XCTAssertNil(lib.autoMaskMessage)
        XCTAssertNil(lib.selectedMask)
        XCTAssertTrue(command.isEnabled(ctx), "on again once it ends")
        // Back on the first photo before the late result: still dropped.
        let gate2 = Gate()
        lib.selection = ids[0]
        lib.autoMaskDetector = FakeDetector(result: topHalf, gate: gate2)
        let run2 = Task { await lib.selectAuto(.subject, for: ids[0]) }
        while !lib.autoMaskDetecting { await Task.yield() }
        lib.selection = ids[1]
        lib.selection = ids[0]
        await gate2.release()
        let late = await run2.value
        XCTAssertNil(late, "an A-B-A switch still drops the run")
        XCTAssertEqual(lib.recipe(for: ids[0]).masks, [])
    }

    // MARK: MaskBitmap(pixelBuffer:)

    /// A `width` x `height` buffer of `format` with the top half 1, the
    /// bottom 0, written through each row's own `bytesPerRow`.
    private func topHalfBuffer(_ format: OSType, width: Int = 30, height: Int = 20) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, nil, &out), kCVReturnSuccess)
        let buffer = try XCTUnwrap(out)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
            for x in 0..<width {
                if format == kCVPixelFormatType_OneComponent8 {
                    row.assumingMemoryBound(to: UInt8.self)[x] = y < height / 2 ? 255 : 0
                } else {
                    row.assumingMemoryBound(to: Float32.self)[x] = y < height / 2 ? 1 : 0
                }
            }
        }
        return buffer
    }

    func testAPixelBufferKeepsRowZeroAtTheTopInBothFormats() throws {
        for format in [kCVPixelFormatType_OneComponent8, kCVPixelFormatType_OneComponent32Float] {
            let bitmap = try XCTUnwrap(MaskBitmap(pixelBuffer: try topHalfBuffer(format)))
            XCTAssertEqual(bitmap.width, 30)
            XCTAssertEqual(bitmap.height, 20)
            XCTAssertEqual(bitmap.weight(at: MaskPoint(x: 0.5, y: 0.2)), 1, "format \(format): top")
            XCTAssertEqual(bitmap.weight(at: MaskPoint(x: 0.5, y: 0.8)), 0, "format \(format): bottom")
            XCTAssertEqual(bitmap.value(x: 3, y: 0), 1)
            XCTAssertEqual(bitmap.value(x: 3, y: 19), 0)
        }
        // Another format is refused.
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &out)
        XCTAssertNil(MaskBitmap(pixelBuffer: try XCTUnwrap(out)))
    }

    // MARK: Real Vision

    /// An RGB figure `width` x `height` as displayed: a shaded red disc
    /// centred at (`cx`, `cy`) (fractions) of radius `r` (fraction of the
    /// short side) on flat grey. Stored rotated for EXIF orientation 6 when
    /// `orientation6` (display = stored turned 90° clockwise).
    private func writeFigure(_ name: String, width: Int, height: Int, cx: Double, cy: Double, r: Double,
                             orientation6: Bool) throws -> URL {
        let sw = orientation6 ? height : width, sh = orientation6 ? width : height
        var px = [UInt8](repeating: 255, count: sw * sh * 4)
        let radius = r * Double(min(width, height))
        let ox = cx * Double(width), oy = cy * Double(height)
        for sy in 0..<sh {
            for sx in 0..<sw {
                // Displayed (x, y) of stored (sx, sy).
                let x = orientation6 ? width - 1 - sy : sx
                let y = orientation6 ? sx : sy
                let dx = Double(x) + 0.5 - ox, dy = Double(y) + 0.5 - oy
                let d = (dx * dx + dy * dy).squareRoot() / radius
                var rgb: (Double, Double, Double) = (0.5, 0.5, 0.5)
                if d <= 1 {
                    // Lit from the upper left.
                    let lx = (dx + dy) / (radius * 2.83) + 0.5
                    let shade = 1 - 0.55 * min(max(lx, 0), 1)
                    rgb = (0.95 * shade, 0.1 * shade, 0.08 * shade)
                }
                let i = (sy * sw + sx) * 4
                px[i] = UInt8(rgb.0 * 255); px[i + 1] = UInt8(rgb.1 * 255); px[i + 2] = UInt8(rgb.2 * 255)
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: &px, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(ctx.makeImage())
        let url = folder.appendingPathComponent(name)
        let type = orientation6 ? UTType.jpeg : UTType.png
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        let props: [CFString: Any] = orientation6
            ? [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.95] : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// Vision on `url`'s oriented decode; skips (with the reason) when the
    /// host has no model: the request throws or finds no instance.
    nonisolated private static func detect(_ url: URL) async throws -> MaskBitmap {
        let image = try XCTUnwrap(ImageLoading.downsampledCGImage(url, maxPixelSize: VisionDetector.inputPixelSize))
        let found: MaskBitmap?
        do {
            found = try await VisionDetector().subject(in: image)
        } catch {
            throw XCTSkip("Vision foreground request failed on this host: \(error)")
        }
        guard let found else { throw XCTSkip("Vision found no foreground instance on this host") }
        return found
    }

    func testVisionFindsADrawnDiscWhereItIsDisplayedIncludingEXIFOrientation() async throws {
        let centred = try writeFigure("disc.png", width: 1024, height: 1024, cx: 0.5, cy: 0.5, r: 0.28,
                                      orientation6: false)
        let mask = try await Self.detect(centred)
        XCTAssertGreaterThan(mask.weight(at: MaskPoint(x: 0.5, y: 0.5)), 0.5, "centre")
        for (x, y) in [(0.03, 0.03), (0.97, 0.03), (0.03, 0.97), (0.97, 0.97)] {
            XCTAssertLessThan(mask.weight(at: MaskPoint(x: x, y: y)), 0.1, "corner \(x), \(y)")
        }

        // Displayed 1024 x 768 with the disc up and left; stored on its side.
        let turned = try writeFigure("turned.jpg", width: 1024, height: 768, cx: 0.3, cy: 0.35, r: 0.22,
                                     orientation6: true)
        let m = try await Self.detect(turned)
        XCTAssertGreaterThan(m.width, m.height, "the mask is in the displayed frame")
        XCTAssertGreaterThan(m.weight(at: MaskPoint(x: 0.3, y: 0.35)), 0.5, "the disc where it is displayed")
        XCTAssertLessThan(m.weight(at: MaskPoint(x: 0.7, y: 0.65)), 0.1, "not mirrored")
        XCTAssertLessThan(m.weight(at: MaskPoint(x: 0.35, y: 0.7)), 0.1, "not transposed")
        for (x, y) in [(0.97, 0.03), (0.03, 0.97), (0.97, 0.97)] {
            XCTAssertLessThan(m.weight(at: MaskPoint(x: x, y: y)), 0.1, "corner \(x), \(y)")
        }
    }
}
