import XCTest
import CoreImage
import ImageIO
@testable import PhotoLab

/// The export watermark: drawn as the last stage of `Renderer.render`, at
/// the chosen corner (or the centre), sized by the OUTPUT's short side
/// (after the resize), absent when nil or blank, carried by
/// `ExportOptions` (options stored before the field decode with nil) and
/// never by Save to Photos.
final class WatermarkTests: XCTestCase {
    private let renderer = Renderer.shared

    private func black(width: Int, height: Int) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func mark(_ position: Watermark.Position, size: Double = 0.08, opacity: Double = 1) -> Watermark {
        Watermark(text: "MARK", position: position, size: size, opacity: opacity)
    }

    /// The pixels of `cg` redrawn into a known RGBA8 sRGB layout, rows top
    /// first.
    private func pixels(_ cg: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = CGContext(data: &px, width: cg.width, height: cg.height, bitsPerComponent: 8,
                            bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return px
    }

    /// The brightest channel value inside `rect` (top-left origin, pixels).
    private func brightest(_ cg: CGImage, in rect: CGRect) -> UInt8 {
        let px = pixels(cg)
        var best: UInt8 = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let i = (y * cg.width + x) * 4
                best = max(best, px[i], px[i + 1], px[i + 2])
            }
        }
        return best
    }

    /// The number of rows holding a pixel brighter than 128: the drawn
    /// text's height.
    private func litRows(_ cg: CGImage) -> Int {
        let px = pixels(cg)
        var rows = 0
        for y in 0..<cg.height {
            for x in 0..<cg.width where max(px[(y * cg.width + x) * 4], px[(y * cg.width + x) * 4 + 1]) > 128 {
                rows += 1
                break
            }
        }
        return rows
    }

    private func quadrant(_ position: Watermark.Position, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        switch position {
        case .topLeft: return CGRect(x: 0, y: 0, width: w, height: h)
        case .topRight: return CGRect(x: w, y: 0, width: w, height: h)
        case .bottomLeft: return CGRect(x: 0, y: h, width: w, height: h)
        case .bottomRight: return CGRect(x: w, y: h, width: w, height: h)
        case .center: return CGRect(x: w / 2, y: h / 2, width: w, height: h)
        }
    }

    private func opposite(_ position: Watermark.Position) -> Watermark.Position {
        switch position {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        case .center: return .center
        }
    }

    // MARK: Position

    /// A white mark on a 400x300 black render brightens the chosen corner
    /// and leaves the opposite corner black; the centre mark lights the
    /// middle and leaves all four corners black.
    func testTheMarkBrightensTheChosenCornerAndLeavesTheOppositeBlack() throws {
        for position in Watermark.Position.allCases {
            let r = try XCTUnwrap(renderer.render(black(width: 400, height: 300), recipe: .neutral,
                                                  watermark: mark(position)))
            XCTAssertEqual(r.image.width, 400)
            XCTAssertEqual(r.image.height, 300)
            XCTAssertGreaterThan(brightest(r.image, in: quadrant(position, width: 400, height: 300)), 200,
                                 "\(position): the chosen place is lit")
            if position == .center {
                for corner in [Watermark.Position.topLeft, .topRight, .bottomLeft, .bottomRight] {
                    let q = quadrant(corner, width: 400, height: 300).insetBy(dx: 0, dy: 0)
                    let outer = CGRect(x: corner == .topLeft || corner == .bottomLeft ? q.minX : q.maxX - 60,
                                       y: corner == .topLeft || corner == .topRight ? q.minY : q.maxY - 40,
                                       width: 60, height: 40)
                    XCTAssertEqual(brightest(r.image, in: outer), 0, "center: the \(corner) corner stays black")
                }
            } else {
                XCTAssertEqual(brightest(r.image, in: quadrant(opposite(position), width: 400, height: 300)), 0,
                               "\(position): the opposite corner stays black")
            }
        }
    }

    /// The margin is 2% of the short side: a top-left mark's lit pixels
    /// start no nearer the edges than that.
    func testTheMarkKeepsTheMarginFromTheEdges() throws {
        let r = try XCTUnwrap(renderer.render(black(width: 400, height: 300), recipe: .neutral, watermark: mark(.topLeft)))
        let margin = CGFloat(300) * CGFloat(Watermark.marginFraction) // 6 px
        XCTAssertLessThan(brightest(r.image, in: CGRect(x: 0, y: 0, width: 400, height: margin - 1)), 129,
                          "nothing bright above the margin")
        XCTAssertLessThan(brightest(r.image, in: CGRect(x: 0, y: 0, width: margin - 1, height: 300)), 129,
                          "nothing bright left of the margin")
    }

    // MARK: Size

    /// The size is a fraction of the RESIZED output's short side: the same
    /// options on an 800x600 render and on that render resized to 400 px
    /// give a mark half as tall.
    func testTheMarksHeightScalesWithTheResizedOutputsShortSide() throws {
        let full = try XCTUnwrap(renderer.render(black(width: 800, height: 600), recipe: .neutral,
                                                 watermark: mark(.center, size: 0.08)))
        let half = try XCTUnwrap(renderer.render(black(width: 800, height: 600), recipe: .neutral,
                                                 resize: .longSide(400), watermark: mark(.center, size: 0.08)))
        XCTAssertEqual(half.image.width, 400)
        let a = litRows(full.image), b = litRows(half.image)
        XCTAssertGreaterThan(b, 5)
        XCTAssertEqual(Double(a) / Double(b), 2, accuracy: 0.25, "lit rows \(a) at 600 short side, \(b) at 300")
        // And the size control itself moves it.
        let bigger = try XCTUnwrap(renderer.render(black(width: 800, height: 600), recipe: .neutral,
                                                   watermark: mark(.center, size: 0.12)))
        XCTAssertGreaterThan(litRows(bigger.image), a)
    }

    /// Opacity scales the mark: 0.3 is dimmer than 1. (Core Image composites
    /// in linear light, so 30% white over black reads about 141 in sRGB.)
    func testOpacityDimsTheMark() throws {
        let strong = try XCTUnwrap(renderer.render(black(width: 400, height: 300), recipe: .neutral,
                                                   watermark: mark(.center, opacity: 1)))
        let faint = try XCTUnwrap(renderer.render(black(width: 400, height: 300), recipe: .neutral,
                                                  watermark: mark(.center, opacity: 0.3)))
        let all = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertGreaterThan(brightest(strong.image, in: all), 240)
        XCTAssertLessThan(brightest(faint.image, in: all), 180)
        XCTAssertGreaterThan(brightest(faint.image, in: all), 40)
    }

    // MARK: Absent

    /// A nil watermark, blank text and whitespace text are pixel-identical
    /// to a render with no watermark argument at all (today's output).
    func testANilOrBlankWatermarkIsPixelIdenticalToTodaysOutput() throws {
        let source = CIImage(cgImage: syntheticImage(width: 320, height: 240))
        var recipe = Recipe.neutral
        recipe[.exposure] = Adjustment(kind: .exposure, value: 0.4)
        let today = try XCTUnwrap(renderer.render(source, recipe: recipe, resize: .longSide(200)))
        for wm in [nil, Watermark(text: ""), Watermark(text: "   \n\t ")] {
            let r = try XCTUnwrap(renderer.render(source, recipe: recipe, resize: .longSide(200), watermark: wm))
            XCTAssertEqual(pixels(r.image), pixels(today.image), "\(String(describing: wm)) changes nothing")
        }
        XCTAssertTrue(Watermark(text: " \n ").isBlank)
        XCTAssertEqual(Watermark(text: " a\nb ").cleanText, "a b")
    }

    /// The 1:1 loupe's region render ignores a watermark.
    func testARegionRenderIgnoresTheWatermark() throws {
        let region = Renderer.Region(center: CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 100))
        let r = try XCTUnwrap(renderer.render(black(width: 400, height: 300), recipe: .neutral, region: region,
                                              watermark: mark(.topLeft)))
        XCTAssertEqual(brightest(r.image, in: CGRect(x: 0, y: 0, width: 100, height: 100)), 0)
    }

    // MARK: Options

    /// Options stored by a build before the watermark decode with nil; a
    /// watermark round-trips; a stored watermark missing fields takes the
    /// defaults.
    func testOldStoredOptionsDecodeWithNoWatermarkAndANewOneRoundTrips() throws {
        let stored = #"{"format":"heic","quality":0.8,"resize":{"longSide":{"_0":2048}},"keepMetadata":false,"suffix":"-web","collision":"overwrite"}"#
        let old = try JSONDecoder().decode(ExportOptions.self, from: Data(stored.utf8))
        XCTAssertNil(old.watermark)
        XCTAssertEqual(old.format, .heic)
        XCTAssertEqual(old.resize, .longSide(2048))
        XCTAssertEqual(old.suffix, "-web")
        XCTAssertEqual(old.collision, .overwrite)

        var o = ExportOptions()
        o.watermark = Watermark(text: "© A. Jung", position: .topRight, size: 0.05, opacity: 0.8)
        XCTAssertEqual(try JSONDecoder().decode(ExportOptions.self, from: JSONEncoder().encode(o)), o)
        XCTAssertNil(try JSONDecoder().decode(ExportOptions.self, from: JSONEncoder().encode(ExportOptions())).watermark)

        let partial = try JSONDecoder().decode(Watermark.self, from: Data(#"{"text":"x"}"#.utf8))
        XCTAssertEqual(partial, Watermark(text: "x"))
        XCTAssertEqual(partial.position, .bottomRight)
        XCTAssertEqual(partial.size, 0.035)
        XCTAssertEqual(partial.opacity, 0.6)
        XCTAssertNil(ExportOptions.default.watermark)
    }

    /// Save to Photos never carries a watermark.
    func testSaveToPhotosOptionsHaveNoWatermark() {
        XCTAssertNil(PhotosSource.saveOptions.watermark)
    }

    // MARK: Through the export

    /// A folder export writes the mark: the exported JPEG's chosen corner is
    /// lit and the opposite one dark.
    func testAFolderExportWritesTheMark() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-watermark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let src = base.appendingPathComponent("black.png")
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(src as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        var options = ExportOptions()
        options.watermark = mark(.bottomLeft)
        let outcome = try Exporter.export(src, recipe: .neutral, into: base.appendingPathComponent("out"), options: options)
        guard case .written(let out) = outcome else { return XCTFail("\(outcome)") }
        let read = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(read, 0, nil))
        XCTAssertGreaterThan(brightest(cg, in: quadrant(.bottomLeft, width: 400, height: 300)), 200)
        XCTAssertLessThan(brightest(cg, in: quadrant(.topRight, width: 400, height: 300)), 16, "JPEG noise only")
    }
}
