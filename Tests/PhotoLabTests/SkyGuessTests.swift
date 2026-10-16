import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
@testable import PhotoLab

/// Select Sky (guess) (SkyGuess.swift, `Library.selectAuto(.sky, for:)`): a
/// colour score times a position prior, kept where connected to the top
/// edge, blurred; every image is drawn here, and no test needs Vision (the
/// horizon is passed in, or a fake detector returns it).
@MainActor
final class SkyGuessTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-skyguess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Drawing

    typealias RGB = (UInt8, UInt8, UInt8)
    static let green: RGB = (60, 140, 60)
    static let lightBlue: RGB = (135, 195, 240)

    /// A sky blue from deeper at the top (t 0) to paler at the horizon (t 1).
    static func blue(_ t: Double) -> RGB {
        (UInt8(90 + 80 * t), UInt8(150 + 60 * t), UInt8(230 + 15 * t))
    }

    /// A `w` x `h` sRGB image, row 0 the top, each pixel from `color`.
    static func image(_ w: Int = 400, _ h: Int = 300, _ color: (Int, Int) -> RGB) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let c = color(x, y), i = (y * w + x) * 4
                bytes[i] = c.0; bytes[i + 1] = c.1; bytes[i + 2] = c.2
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// The mean weight (0...1) of `bitmap` over rows `rows` and columns `cols`.
    private func mean(_ bitmap: MaskBitmap, rows: Range<Int>, cols: Range<Int>? = nil) -> Double {
        let cols = cols ?? 0..<bitmap.width
        let px = [UInt8](bitmap.pixels)
        var sum = 0.0
        for y in rows { for x in cols { sum += Double(px[y * bitmap.width + x]) } }
        return sum / Double(rows.count * cols.count) / 255
    }

    private func value(_ bitmap: MaskBitmap, _ x: Int, _ y: Int) -> Double {
        Double([UInt8](bitmap.pixels)[y * bitmap.width + x]) / 255
    }

    // MARK: The guess

    func testABlueGradientOverGreenIsTheSkyAndTheGreenIsNot() throws {
        let img = Self.image { _, y in y < 120 ? Self.blue(Double(y) / 120) : Self.green }
        let sky = try XCTUnwrap(SkyGuess.mask(in: img, horizon: nil))
        XCTAssertEqual(sky.width, 400)
        XCTAssertEqual(sky.height, 300)
        XCTAssertGreaterThan(mean(sky, rows: 0..<120), 0.9, "the blue top 40%")
        XCTAssertLessThan(mean(sky, rows: 120..<300), 0.05, "the green below")
    }

    func testABlueRectangleNotTouchingTheSkyStaysZero() throws {
        // Sky over the top 30%, a band of green, a blue rectangle low in the
        // frame that the prior alone would keep (horizon at the bottom edge).
        let img = Self.image { x, y in
            if y < 90 { return Self.blue(Double(y) / 90) }
            if (225..<270).contains(y) && (120..<280).contains(x) { return Self.lightBlue }
            return Self.green
        }
        let sky = try XCTUnwrap(SkyGuess.mask(in: img, horizon: SkyGuess.Horizon(centerY: 1, angle: 0)))
        XCTAssertGreaterThan(mean(sky, rows: 0..<90), 0.9)
        XCTAssertLessThan(mean(sky, rows: 228..<267, cols: 123..<277), 0.01,
                          "blue but not connected to the top edge: not sky")
    }

    func testAnOvercastGreyWhiteTopIsSelected() throws {
        let img = Self.image { _, y in y < 120 ? (235, 235, 238) : Self.green }
        let sky = try XCTUnwrap(SkyGuess.mask(in: img, horizon: nil))
        XCTAssertGreaterThan(mean(sky, rows: 0..<120), 0.9)
        XCTAssertLessThan(mean(sky, rows: 120..<300), 0.05)
    }

    func testAnAllGreenFrameOrASliverOfSkyIsNil() {
        XCTAssertNil(SkyGuess.mask(in: Self.image { _, _ in Self.green }, horizon: nil))
        // Three rows of 300 (1%): under the 2% floor.
        XCTAssertNil(SkyGuess.mask(in: Self.image { _, y in y < 3 ? Self.lightBlue : Self.green }, horizon: nil))
    }

    func testATiltedHorizonCutsTheGuessAlongIt() throws {
        // All blue: only the horizon decides. It rises to the right.
        let img = Self.image { _, _ in Self.lightBlue }
        let horizon = SkyGuess.Horizon(centerY: 0.5, angle: 0.3)
        let sky = try XCTUnwrap(SkyGuess.mask(in: img, horizon: horizon))
        let blur = 6
        for x in stride(from: 0, to: 400, by: 20) {
            let hy = horizon.y(atColumn: Double(x) + 0.5, width: 400, height: 300)
            let below = Int(hy.rounded(.up)) + blur
            if below < 300 {
                XCTAssertLessThan(mean(sky, rows: below..<300, cols: x..<(x + 1)), 0.001, "column \(x) below its horizon")
            }
            XCTAssertGreaterThan(value(sky, x, Int(hy * 0.3)), 0.9, "column \(x) well above its horizon")
        }
        // Row 160 is under a level horizon at 0.5 but above this one on the left.
        XCTAssertGreaterThan(value(sky, 40, 160), 0.3, "left: the horizon is lower")
        XCTAssertEqual(value(sky, 360, 160), 0, "right: the horizon is higher")
        let level = try XCTUnwrap(SkyGuess.mask(in: img, horizon: SkyGuess.Horizon(centerY: 0.5, angle: 0)))
        XCTAssertEqual(value(level, 40, 160), 0, "a level line at 0.5 keeps nothing at row 160")
    }

    func testTheScoreAndPrior() {
        XCTAssertEqual(SkyGuess.score(r: 0.35, g: 0.59, b: 0.9), 1, "blue")
        XCTAssertEqual(SkyGuess.score(r: 0.92, g: 0.92, b: 0.93), 1, "overcast")
        XCTAssertEqual(SkyGuess.score(r: 0.05, g: 0.1, b: 0.4), 0, "too dark")
        XCTAssertEqual(SkyGuess.score(r: 0.5, g: 0.5, b: 0.52), 0, "mid grey")
        XCTAssertEqual(SkyGuess.score(r: 0.6, g: 0.4, b: 0.9), 0, "violet, hue past 250")
        let level = SkyGuess.Horizon.level
        XCTAssertEqual(SkyGuess.prior(x: 0, y: 0, width: 100, height: 100, horizon: level), 1, accuracy: 0.01)
        XCTAssertEqual(SkyGuess.prior(x: 50, y: 70, width: 100, height: 100, horizon: level), 0)
        XCTAssertEqual(SkyGuess.prior(x: 50, y: 90, width: 100, height: 100, horizon: level), 0)
    }

    func testALargeImageIsAnalysedAtMost512Pixels() throws {
        let img = Self.image(1200, 900) { _, y in y < 360 ? Self.blue(Double(y) / 360) : Self.green }
        let sky = try XCTUnwrap(SkyGuess.mask(in: img, horizon: nil))
        XCTAssertEqual(sky.width, 512)
        XCTAssertEqual(sky.height, 384)
    }

    // MARK: The flow

    private struct FakeDetector: AutoMaskDetector {
        var horizon: SkyGuess.Horizon?
        func subject(in image: CGImage) async throws -> MaskBitmap? { nil }
        func person(in image: CGImage) async throws -> MaskBitmap? { nil }
        func faces(in image: CGImage) async throws -> [VNFaceObservation] { [] }
        func horizon(in image: CGImage) async throws -> SkyGuess.Horizon? { horizon }
    }

    private func open(_ img: CGImage, _ detector: FakeDetector) throws -> (Library, Photo.ID) {
        let url = folder.appendingPathComponent("p0.png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let id = try XCTUnwrap(lib.photos.first?.id)
        lib.selection = id
        lib.loupe = true
        lib.autoMaskDetector = detector
        return (lib, id)
    }

    func testSelectSkyAddsOneSkyMaskAlongTheDetectorsHorizonInOneUndoStep() async throws {
        let img = Self.image { _, _ in Self.lightBlue }
        let (lib, id) = try open(img, FakeDetector(horizon: SkyGuess.Horizon(centerY: 0.3, angle: 0)))
        let writes = lib.sidecarWrites
        let maskID = try await XCTUnwrapAsync(await lib.selectAuto(.sky, for: id))
        let masks = lib.recipe(for: id).masks
        XCTAssertEqual(masks.count, 1)
        guard case .auto(let auto) = masks[0].shape else { return XCTFail("not automatic") }
        XCTAssertEqual(auto.kind, .sky)
        XCTAssertEqual(MaskKind.names(of: masks)[maskID], "Sky 1")
        XCTAssertEqual(lib.selectedMask, maskID)
        XCTAssertEqual(lib.sidecarWrites, writes + 1)
        XCTAssertNil(lib.autoMaskMessage)
        // The detector's horizon (30% down), not the 70% default.
        XCTAssertEqual(mean(auto.bitmap, rows: 100..<300), 0, accuracy: 0.001)
        XCTAssertGreaterThan(mean(auto.bitmap, rows: 0..<40), 0.9)
        lib.undo()
        XCTAssertEqual(lib.recipe(for: id).masks, [], "one undo step")
    }

    func testNoSkySaysSoAndChangesNothing() async throws {
        let (lib, id) = try open(Self.image { _, _ in Self.green }, FakeDetector())
        let writes = lib.sidecarWrites
        let none = await lib.selectAuto(.sky, for: id)
        XCTAssertNil(none)
        XCTAssertEqual(lib.autoMaskMessage, "No sky found")
        XCTAssertEqual(lib.recipe(for: id).masks, [])
        XCTAssertEqual(lib.sidecarWrites, writes)
    }

    func testTheCommandHasNoKeyAndNeedsTheLoupe() throws {
        let (lib, _) = try open(Self.image { _, _ in Self.green }, FakeDetector())
        let ctx = CommandContext(library: lib)
        let command = AppCommand.command(.selectSky)
        XCTAssertEqual(command.title, "Select Sky (guess)")
        XCTAssertNil(command.key)
        XCTAssertTrue(command.isEnabled(ctx))
        lib.loupe = false
        XCTAssertFalse(command.isEnabled(ctx))
    }
}

/// `XCTUnwrap` for an optional already awaited.
private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
