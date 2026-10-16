import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

// MARK: - Helpers

/// A synthetic bitmap: `f(x, y)` per pixel, rows top-down.
private func bitmap(_ width: Int, _ height: Int, _ f: (Int, Int) -> UInt8) -> MaskBitmap {
    var g = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height { for x in 0..<width { g[y * width + x] = f(x, y) } }
    return MaskBitmap(gray: g, width: width, height: height)
}

private func autoMask(_ b: MaskBitmap, kind: AutoMaskKind = .subject, strokes: [BrushStroke] = [],
                      ev: Double = 1) -> LocalMask {
    LocalMask(shape: .auto(AutoMask(kind: kind, bitmap: b, strokes: strokes)),
              adjustments: [Adjustment(kind: .exposure, value: ev)])
}

private func p(_ x: Double, _ y: Double) -> MaskPoint { MaskPoint(x: x, y: y) }

/// sRGB-encoded 0...255 to linear 0...1.
private func linear(_ v: Double) -> Double {
    let c = v / 255
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

/// The green channel of an RGBA8 image, read once: (x, y) top-down.
private func greens(_ cg: CGImage) -> (Int, Int) -> Double {
    let data = cg.dataProvider?.data
    let bytes = data.map { [UInt8](Data(referencing: $0 as NSData)) } ?? []
    let row = cg.bytesPerRow
    return { x, y in bytes.isEmpty ? 0 : Double(bytes[y * row + x * 4 + 1]) }
}

/// The automatic mask's model: the bitmap's identity, its weight, where it
/// renders through crop and rotate at two sizes, and its sidecar format.
final class AutoMaskModelTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-automask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Weight

    func testALeftHalfWhiteBitmapWeighsOneOnTheLeftAndZeroOnTheRight() {
        let b = bitmap(200, 100) { x, _ in x < 100 ? 255 : 0 }
        let size = CGSize(width: 3000, height: 2000)
        let mask = autoMask(b)
        XCTAssertEqual(MaskMath.weight(of: mask, at: p(0.25, 0.5), in: size), 1, accuracy: 1e-9)
        XCTAssertEqual(MaskMath.weight(of: mask, at: p(0.75, 0.5), in: size), 0, accuracy: 1e-9)
        // Bilinear between the two pixel centres either side of the edge.
        XCTAssertEqual(MaskMath.weight(of: mask, at: p(0.5, 0.5), in: size), 0.5, accuracy: 1e-9)
        var inverted = mask
        inverted.inverted = true
        XCTAssertEqual(MaskMath.weight(of: inverted, at: p(0.25, 0.5), in: size), 0, accuracy: 1e-9)
        // Strokes over the bitmap by the brush's rule: an erase takes the
        // left down, a paint brings the right up.
        let erase = BrushStroke(points: [p(0.25, 0.5)], radius: 0.05, feather: 0, flow: 1, erase: true)
        let paint = BrushStroke(points: [p(0.75, 0.5)], radius: 0.05, feather: 0, flow: 1)
        let refined = autoMask(b, strokes: [erase, paint])
        XCTAssertEqual(MaskMath.weight(of: refined, at: p(0.25, 0.5), in: size), 0, accuracy: 1e-9)
        XCTAssertEqual(MaskMath.weight(of: refined, at: p(0.75, 0.5), in: size), 1, accuracy: 1e-9)
        XCTAssertEqual(MaskMath.weight(of: refined, at: p(0.1, 0.1), in: size), 1, accuracy: 1e-9, "untouched left")
    }

    func testABitmapAboveTheCapIsBoxFilteredDownWithItsEdgeKept() {
        let b = bitmap(6000, 4000) { x, _ in x < 3000 ? 255 : 0 }
        XCTAssertEqual(b.width, 2048)
        XCTAssertEqual(b.height, 1365)
        XCTAssertEqual(b.value(x: 1023, y: 700), 1, accuracy: 1e-9)
        XCTAssertEqual(b.value(x: 1024, y: 700), 0, accuracy: 1e-9)
        let small = bitmap(300, 200) { _, _ in 9 }
        XCTAssertEqual(small.width, 300, "under the cap: kept as given")
    }

    // MARK: Render

    /// The bitmap's edges land on the same source pixels in a 2600 px
    /// preview and a full-size 6000x4000 export, through a 7.5 degree
    /// rotate and a crop: a vertical edge on the same source column, a
    /// horizontal one (top 30%, which a row flip would move to 70%) on the
    /// same source row, each within 2 source pixels.
    func testTheEdgeLandsOnTheSameSourcePixelsInAPreviewAndAFullSizeExport() throws {
        let renderer = Renderer.shared
        let w = 6000, h = 4000
        let source = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        var geometry = Recipe.neutral
        geometry.set(.rotate, to: 7.5)
        geometry.set(.cropLeft, to: 12)
        geometry.set(.cropBottom, to: 8)
        let vertical = bitmap(w, h) { x, _ in x < 3000 ? 255 : 0 }
        let horizontal = bitmap(w, h) { _, y in y < 1200 ? 255 : 0 }

        for maxPixelSize in [2600, nil] as [Int?] {
            let label = maxPixelSize.map { "preview \($0)" } ?? "export"
            for (b, isVertical) in [(vertical, true), (horizontal, false)] {
                var r = geometry
                r.masks = [autoMask(b)]
                let plain = try XCTUnwrap(renderer.render(source, recipe: geometry, maxPixelSize: maxPixelSize)).image
                let out = try XCTUnwrap(renderer.render(source, recipe: r, maxPixelSize: maxPixelSize)).image
                XCTAssertEqual(out.width, plain.width)
                let fw = out.width, fh = out.height
                // Walk the middle row (vertical edge) or column (horizontal
                // edge) and find where the lift falls to half, in linear light
                // (the blend is linear in the weight there).
                let n = isVertical ? fw : fh
                let gOut = greens(out), gPlain = greens(plain)
                func at(_ i: Int) -> (Double, Double) {
                    let (x, y) = isVertical ? (i, fh / 2) : (fw / 2, i)
                    return (linear(gOut(x, y)), linear(gPlain(x, y)))
                }
                let (lit0, base0) = at(4)
                let half = (lit0 + base0) / 2
                XCTAssertGreaterThan(lit0, base0 * 1.5, "\(label): lifted before the edge")
                var crossing: Double?
                var prev = at(0).0
                for i in 1..<n {
                    let v = at(i).0
                    if prev >= half, v < half {
                        crossing = Double(i - 1) + (prev - half) / (prev - v)
                        break
                    }
                    prev = v
                }
                let c = try XCTUnwrap(crossing, "\(label): an edge in the frame")
                // Pixel centre to the normalised frame, then back to the source.
                let f = isVertical ? CGPoint(x: (c + 0.5) / Double(fw), y: 0.5)
                                   : CGPoint(x: 0.5, y: (c + 0.5) / Double(fh))
                let g = MaskMath.Geometry(recipe: r, source: CGSize(width: w, height: h))
                let s = MaskMath.source(f, g)
                if isVertical {
                    XCTAssertEqual(s.x * Double(w), 3000, accuracy: 2, "\(label): vertical edge on source column 3000")
                } else {
                    XCTAssertEqual(s.y * Double(h), 1200, accuracy: 2, "\(label): horizontal edge on source row 1200")
                }
            }
        }
    }

    /// The drawn mask (before geometry) is `MaskMath`'s weight: the bitmap
    /// with its strokes over it, pixel for pixel, rows top-down, whether the
    /// bitmap is the extent's size, smaller and of another aspect, or the
    /// 1x1 blank with a paint stroke (the strokes are laid down at the
    /// extent's size, not the bitmap's).
    func testTheDrawnAutomaticMaskIsMaskMathsWeight() throws {
        let w = 120, h = 80
        let strokes = [
            BrushStroke(points: [p(0.1, 0.2), p(0.6, 0.7)], radius: 0.08, feather: 0.6, flow: 0.8, erase: true),
            BrushStroke(points: [p(0.8, 0.2)], radius: 0.1, feather: 0.3, flow: 0.7),
        ]
        let cases: [(String, MaskShape)] = [
            ("extent-size bitmap", .auto(AutoMask(kind: .subject, bitmap: bitmap(w, h) { x, y in UInt8(min(255, x * 2 + y)) },
                                                  strokes: strokes))),
            ("small square bitmap", .auto(AutoMask(kind: .subject, bitmap: bitmap(30, 30) { x, y in UInt8(min(255, x * 8 + y)) },
                                                   strokes: strokes))),
            ("small bitmap, no strokes", .auto(AutoMask(kind: .sky, bitmap: bitmap(40, 30) { _, y in y < 10 ? 255 : 0 }))),
            ("blank with a paint stroke", .auto(AutoMask(kind: .subject, bitmap: .blank, strokes: [strokes[1]]))),
        ]
        for (name, shape) in cases { try assertDrawnIsWeight(shape, w, h, name) }
    }

    private func assertDrawnIsWeight(_ shape: MaskShape, _ w: Int, _ h: Int, _ name: String) throws {
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        let image = try XCTUnwrap(MaskRender.image(for: shape, over: extent))
        var buf = [Float](repeating: 0, count: w * h * 4)
        Renderer.shared.context.render(image, toBitmap: &buf, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: nil)
        var worst = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let got = Double(buf[(y * w + x) * 4 + 1])
                let want = MaskMath.weight(of: shape, at: p((Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h)),
                                           in: CGSize(width: w, height: h))
                worst = max(worst, abs(got - want))
            }
        }
        XCTAssertLessThan(worst, 0.01, "\(name): drawn vs MaskMath")
    }

    func testAnAllZeroBitmapRendersNothing() throws {
        let zero = autoMask(bitmap(64, 48) { _, _ in 0 })
        XCTAssertFalse(MaskRender.renders(zero))
        XCTAssertNil(MaskRender.image(for: zero.shape, over: CGRect(x: 0, y: 0, width: 64, height: 48)))
        XCTAssertTrue(MaskRender.renders(autoMask(bitmap(64, 48) { x, _ in x == 3 ? 1 : 0 })))
        XCTAssertFalse(MaskRender.renders(autoMask(.blank)))
        // A paint stroke over a blank bitmap draws; an erase alone does not.
        let paint = BrushStroke(points: [p(0.5, 0.5)], radius: 0.1, feather: 0, flow: 1)
        XCTAssertTrue(MaskRender.renders(autoMask(.blank, strokes: [paint])))
        var erase = paint
        erase.erase = true
        XCTAssertFalse(MaskRender.renders(autoMask(.blank, strokes: [erase])))
    }

    // MARK: Identity

    /// Equality and hashing are the pixels' digest, not the PNG's bytes: the
    /// same pixels encoded another way (interlaced) are equal; one pixel
    /// changed is not.
    func testEqualityIgnoresPNGReencoding() throws {
        let b = bitmap(96, 64) { x, y in UInt8((x * 7 + y * 3) % 256) }
        let other = try interlacedPNG([UInt8](b.pixels), width: 96, height: 64)
        XCTAssertNotEqual(other, b.png, "a different file")
        let json = #"{"width":96,"height":64,"png":"\#(other.base64EncodedString())"}"#
        let decoded = try JSONDecoder().decode(MaskBitmap.self, from: Data(json.utf8))
        XCTAssertNotEqual(decoded.png, b.png)
        XCTAssertEqual(decoded, b)
        XCTAssertEqual(decoded.hashValue, b.hashValue)
        XCTAssertEqual(decoded.digest, b.digest)
        var changed = [UInt8](b.pixels)
        changed[500] &+= 1
        XCTAssertNotEqual(MaskBitmap(gray: changed, width: 96, height: 64), b)
    }

    func testABitmapThatIsNotAGreyPNGOfItsSizeDoesNotDecode() {
        let b = bitmap(16, 8) { _, _ in 200 }
        let wrongSize = #"{"width":8,"height":8,"png":"\#(b.png.base64EncodedString())"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(MaskBitmap.self, from: Data(wrongSize.utf8)))
        let notPNG = #"{"width":16,"height":8,"png":"AAAA"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(MaskBitmap.self, from: Data(notPNG.utf8)))
    }

    // MARK: Sidecar

    func testASidecarRoundTripsAnAutomaticMask() throws {
        let photo = folder.appendingPathComponent("a.jpg")
        let store = SidecarStore(folder: folder)
        var r = Recipe.neutral
        let stroke = BrushStroke(points: [p(0.2, 0.3), p(0.4, 0.35)], radius: 0.03, feather: 0.5, flow: 0.8, erase: true)
        r.masks = [autoMask(bitmap(300, 200) { x, y in UInt8((x + y) % 256) }, kind: .person, strokes: [stroke]),
                   autoMask(bitmap(40, 30) { _, y in y < 10 ? 255 : 0 }, kind: .sky)]
        try store.save(r, for: photo)
        XCTAssertEqual(try store.load(for: photo), r)
        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent(".photolab/a.jpg.json"))) as? [String: Any]
        XCTAssertEqual(raw?["version"] as? Int, 3)
        let masks = (raw?["recipe"] as? [String: Any])?["masks"] as? [[String: Any]]
        let shape = masks?.first?["shape"] as? [String: Any]
        XCTAssertEqual(shape?["type"] as? String, "auto")
        XCTAssertEqual(shape?["kind"] as? String, "person")
        // A file without strokes reads as none.
        let json = #"{"type":"auto","kind":"subject","bitmap":{"width":1,"height":1,"png":"\#(MaskBitmap.blank.png.base64EncodedString())"}}"#
        XCTAssertEqual(try JSONDecoder().decode(MaskShape.self, from: Data(json.utf8)),
                       .auto(AutoMask(kind: .subject, bitmap: .blank)))
    }

    func testTheFormatIsVersion3OnlyWithAnAutomaticMask() throws {
        var r = Recipe.neutral
        r.set(.exposure, to: 0.5)
        XCTAssertEqual(Sidecar.version(for: r), 1)
        r.masks = [LocalMask(shape: .brush([]), adjustments: [Adjustment(kind: .exposure, value: 1)])]
        XCTAssertEqual(Sidecar.version(for: r), 2)
        XCTAssertEqual(try PhotosAdjustment(recipe: r, name: "a.jpg").formatVersion, "2")
        r.masks.append(autoMask(.blank))
        XCTAssertEqual(Sidecar.version(for: r), 3)
        XCTAssertEqual(try PhotosAdjustment(recipe: r, name: "a.jpg").formatVersion, "3")
        XCTAssertEqual(Sidecar.currentVersion, 3)
        XCTAssertTrue(PhotosAdjustment.canHandle(identifier: PhotosAdjustment.formatIdentifier, version: "3"))
        XCTAssertEqual(try PhotosAdjustment(recipe: r, name: "a.jpg").recipe(), r)
    }

    /// Format 1 and 2 files are written byte for byte as before automatic
    /// masks existed: the v2 golden below (the masks to the end of the file)
    /// was written by the build before them. The sliders above it are left
    /// out of the golden so a new adjustment kind does not break it.
    func testFormat1And2FilesAreUnchanged() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var r = Recipe.neutral
        r.set(.exposure, to: 0.5)
        let v1 = try SidecarStore.encode(Sidecar(version: Sidecar.version(for: r), original: "a.jpg", updated: date, recipe: r))
        let s1 = String(decoding: v1, as: UTF8.self)
        XCTAssertTrue(s1.hasSuffix("  \"updated\" : \"2027-01-15T08:00:00Z\",\n  \"version\" : 1\n}"), s1)
        XCTAssertFalse(s1.contains("\"masks\""))
        r.masks = [LocalMask(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!,
                             shape: .brush([BrushStroke(points: [p(0.25, 0.5)], radius: 0.125, feather: 0.5, flow: 1)]),
                             adjustments: [Adjustment(kind: .exposure, value: 1)])]
        let v2 = try SidecarStore.encode(Sidecar(version: Sidecar.version(for: r), original: "a.jpg", updated: date, recipe: r))
        let s2 = String(decoding: v2, as: UTF8.self)
        let tail = try XCTUnwrap(s2.range(of: "    \"masks\" : [")).lowerBound
        XCTAssertEqual(String(s2[tail...]), Self.golden2)
    }

    /// A soft-edged disc at the full 2048 px keeps the sidecar small.
    func testASoft2048DiscKeepsTheSidecarUnder200KB() throws {
        let n = 2048
        let b = bitmap(n, n) { x, y in
            let d = hypot(Double(x) + 0.5 - 1024, Double(y) + 0.5 - 1024)
            let t = min(max((800 - d) / 200, 0), 1)  // 1 inside 600 px, 0 beyond 800
            return UInt8((t * t * (3 - 2 * t) * 255).rounded())
        }
        XCTAssertEqual(b.width, 2048)
        let photo = folder.appendingPathComponent("disc.jpg")
        var r = Recipe.neutral
        r.masks = [autoMask(b)]
        try SidecarStore(folder: folder).save(r, for: photo)
        let file = folder.appendingPathComponent(".photolab/disc.jpg.json")
        let bytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        XCTAssertLessThan(bytes, 200_000, "sidecar \(bytes) bytes")
        XCTAssertEqual(try SidecarStore(folder: folder).load(for: photo), r)
    }

    // MARK: Panel and overlay

    func testAutomaticMasksAreNamedByKindAndHaveNoHandles() {
        let masks = [autoMask(.blank, kind: .subject), LocalMask(shape: MaskKind.linear.defaultShape),
                     autoMask(.blank, kind: .person), autoMask(.blank, kind: .sky), autoMask(.blank, kind: .subject)]
        let names = MaskKind.names(of: masks)
        XCTAssertEqual(masks.map { names[$0.id] }, ["Subject 1", "Linear 1", "Person 1", "Sky 1", "Subject 2"])
        XCTAssertEqual([MaskKind.subject, .person, .sky].map(\.title), ["Subject", "Person", "Sky"])
        XCTAssertEqual(MaskKind(masks[2].shape), .person)
        XCTAssertTrue(MaskHandles.positions(of: masks[0].shape, size: CGSize(width: 300, height: 200)).isEmpty)
        XCTAssertNil(MaskHandles.placed(.subject, from: p(0.1, 0.1), to: p(0.3, 0.3), size: CGSize(width: 300, height: 200)))
    }

    // MARK: Fixtures

    private func interlacedPNG(_ bytes: [UInt8], width: Int, height: Int) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false,
                                          intent: .defaultIntent))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        let props = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGInterlaceType: 1]] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    static let golden2 = """
        "masks" : [
          {
            "adjustments" : [
              {
                "enabled" : true,
                "kind" : "exposure",
                "value" : 1
              }
            ],
            "enabled" : true,
            "id" : "00000000-0000-0000-0000-0000000000AB",
            "inverted" : false,
            "shape" : {
              "strokes" : [
                {
                  "erase" : false,
                  "feather" : 0.5,
                  "flow" : 1,
                  "points" : [
                    {
                      "x" : 0.25,
                      "y" : 0.5
                    }
                  ],
                  "radius" : 0.125
                }
              ],
              "type" : "brush"
            }
          }
        ]
      },
      "updated" : "2027-01-15T08:00:00Z",
      "version" : 2
    }
    """
}
