import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Photos
@testable import PhotoLab

/// Export options on the one `Exporter.export` path: JPEG quality moves the
/// file size, resize gives an exact long side and never upscales, the
/// source's camera EXIF travels with the orientation reset to upright, HEIC
/// and TIFF round-trip, the collision policy holds and the original is
/// never written. Every folder is a temp directory. The Photos target runs
/// against `FakePhotosWriter`; one real import is opt-in.
@MainActor
final class ExportTests: XCTestCase {
    private var base: URL!
    private var folder: URL!
    private var outDir: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-export-\(UUID().uuidString)", isDirectory: true)
        folder = base.appendingPathComponent("photos", isDirectory: true)
        outDir = base.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Helpers

    /// Writes `image` as `name` in the photo folder with the given
    /// properties (metadata for the writer) and container type.
    @discardableResult
    private func writeSource(_ name: String, _ image: CGImage, type: UTType = .png,
                             properties: [CFString: Any]? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, properties as CFDictionary?)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func gray(_ level: CGFloat, width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Left half dark, right half bright: tells orientation apart.
    private func halves(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return ctx.makeImage()!
    }

    private func fileSize(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    /// Decodes a written file to RGBA8 (row 0 = top).
    private func decode(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func meanGray(_ cg: CGImage) -> Double {
        let m = meanRGB(cg)
        return (m.r + m.g + m.b) / 3
    }

    /// Mean gray of rows `rows` of an RGBA8 image.
    private func meanGray(_ cg: CGImage, rows: Range<Int>) throws -> Double {
        let data = try XCTUnwrap(cg.dataProvider?.data)
        let p = try XCTUnwrap(CFDataGetBytePtr(data))
        var sum = 0.0, n = 0.0
        for y in rows {
            for x in 0..<cg.width {
                let i = y * cg.bytesPerRow + x * 4
                sum += (Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2])) / 3
                n += 1
            }
        }
        return sum / n
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func containerType(_ url: URL) throws -> String {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceGetType(source) as String?)
    }

    private func sizeOf(_ url: URL) throws -> (Int, Int) {
        let p = try properties(url)
        return (try XCTUnwrap(p[kCGImagePropertyPixelWidth] as? Int), try XCTUnwrap(p[kCGImagePropertyPixelHeight] as? Int))
    }

    private func assertSize(_ url: URL, _ width: Int, _ height: Int, _ note: String = "",
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let got = try sizeOf(url)
        XCTAssertTrue(got == (width, height), "\(note) \(url.lastPathComponent): \(got), expected \(width)×\(height)", file: file, line: line)
    }

    // MARK: Quality

    func testJPEGQualityChangesTheFileSizeMonotonically() throws {
        let src = try writeSource("ramp.png", syntheticImage(width: 256, height: 256))
        var sizes: [Int] = []
        for q in [0.3, 0.6, 0.9] {
            var o = ExportOptions()
            o.quality = q
            o.suffix = "-q\(Int(q * 100))"
            let out = try Exporter.export(src, recipe: .neutral, into: outDir, options: o)
            guard case .written(let url) = out else { return XCTFail("\(out)") }
            XCTAssertEqual(url.lastPathComponent, "ramp-q\(Int(q * 100)).jpg")
            XCTAssertEqual(try containerType(url), UTType.jpeg.identifier)
            sizes.append(try fileSize(url))
        }
        XCTAssertLessThan(sizes[0], sizes[1], "quality 0.3 < 0.6: \(sizes)")
        XCTAssertLessThan(sizes[1], sizes[2], "quality 0.6 < 0.9: \(sizes)")
        // Out of range is clamped, not refused.
        var o = ExportOptions()
        o.quality = 7
        XCTAssertEqual(o.clampedQuality, 1)
        o.quality = -1
        XCTAssertEqual(o.clampedQuality, ExportOptions.qualityRange.lowerBound)
    }

    /// The sheet's slider and the writer's clamp share `qualityRange`: the
    /// floor is the 30% the slider shows, so a stored quality below it is
    /// written at the slider's floor, never at a value the sheet cannot set.
    func testQualityFloorIsTheSlidersThirtyPercent() {
        XCTAssertEqual(ExportOptions.qualityRange, 0.3...1.0)
        var o = ExportOptions()
        XCTAssertTrue(ExportOptions.qualityRange.contains(o.quality), "the default is on the slider")
        o.quality = 0.1
        XCTAssertEqual(o.clampedQuality, 0.3, accuracy: 1e-9)
        o.quality = 0.3
        XCTAssertEqual(o.clampedQuality, 0.3, accuracy: 1e-9)
    }


    // MARK: Resize

    func testResizeGivesAnExactLongSideWorksInPercentAndNeverUpscales() throws {
        let src = try writeSource("wide.png", syntheticImage(width: 300, height: 200))
        let sourceMean = meanGray(try decode(src))

        func export(_ resize: OutputSize?, recipe: Recipe = .neutral, suffix: String) throws -> URL {
            var o = ExportOptions()
            o.resize = resize
            o.suffix = suffix
            o.quality = 1
            let out = try Exporter.export(src, recipe: recipe, into: outDir, options: o)
            guard case .written(let url) = out else { XCTFail("\(out)"); throw Exporter.Failure.cannotWrite(src) }
            return url
        }

        let asIs = try export(nil, suffix: "-full")
        try assertSize(asIs, 300, 200)

        let half = try export(.longSide(150), suffix: "-150")
        try assertSize(half, 150, 100)
        XCTAssertEqual(meanGray(try decode(half)), sourceMean, accuracy: 6, "a downscale keeps the picture, no black edge")

        let odd = try export(.longSide(100), suffix: "-100")
        try assertSize(odd, 100, 67)

        let pct = try export(.percent(50), suffix: "-50pct")
        try assertSize(pct, 150, 100)

        let bigger = try export(.longSide(1000), suffix: "-1000")
        try assertSize(bigger, 300, 200, "never upscaled")
        let morePct = try export(.percent(150), suffix: "-150pct")
        try assertSize(morePct, 300, 200, "never upscaled")
        let same = try export(.longSide(300), suffix: "-300")
        try assertSize(same, 300, 200, "the same size is left alone")

        // The resize applies AFTER the crop: a 25 % + 25 % side crop leaves
        // 150×200, a portrait, so the long side is the height.
        var cropped = Recipe.neutral
        cropped.set(.cropLeft, to: 25)
        cropped.set(.cropRight, to: 25)
        let croppedFull = try export(nil, recipe: cropped, suffix: "-crop")
        try assertSize(croppedFull, 150, 200)
        let croppedSmall = try export(.longSide(100), recipe: cropped, suffix: "-crop100")
        try assertSize(croppedSmall, 75, 100)

        XCTAssertNil(OutputSize.longSide(0).size(fitting: CGSize(width: 10, height: 5)), "nothing below one pixel")
        XCTAssertEqual(OutputSize.percent(10).size(fitting: CGSize(width: 10, height: 5)), CGSize(width: 1, height: 1))
    }

    /// The rotate stage insets its crop one pixel inside the rotated frame
    /// at the size it renders (`Renderer.stage`, `.rotate`); an export renders
    /// at full resolution and resizes after. A flat gray exported rotated at a
    /// 2048 px long side must keep every border pixel within 8 levels of the
    /// source's own gray as it decodes: a darker one is the rotated frame's
    /// antialiased edge (or the transparent outside, if the resize stopped
    /// clamping) carried through the downscale. The source is large enough
    /// that every angle renders above 2048 px (45° keeps 57 % of the side),
    /// so each export really is resized.
    func testAResizedRotatedExportHasNoDarkBorder() throws {
        let src = try writeSource("flat.png", gray(0.6, width: 4800, height: 3200))
        let level = meanGray(try decode(src))
        for degrees in [3.0, 15.0, 45.0, -20.0] {
            var recipe = Recipe.neutral
            recipe.set(.rotate, to: degrees)
            var o = ExportOptions()
            o.format = .tiff
            o.resize = .longSide(2048)
            o.suffix = "-rot\(Int(degrees))"
            let written = try Exporter.export(src, recipe: recipe, into: outDir, options: o)
            guard case .written(let url) = written else { XCTFail("rotate \(degrees)°: \(written)"); continue }
            let out = try decode(url)
            XCTAssertEqual(max(out.width, out.height), 2048, "rotate \(degrees)°: the long side is the asked size")
            XCTAssertEqual(Double(out.width) / Double(out.height), 1.5, accuracy: 0.01, "rotate \(degrees)° keeps the aspect")
            let data = try XCTUnwrap(out.dataProvider?.data)
            let p = try XCTUnwrap(CFDataGetBytePtr(data))
            var darkest = 255.0, at = (0, 0)
            func look(_ x: Int, _ y: Int) {
                let i = y * out.bytesPerRow + x * 4
                let l = (Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2])) / 3
                if l < darkest { darkest = l; at = (x, y) }
            }
            for x in 0..<out.width { look(x, 0); look(x, out.height - 1) }
            for y in 0..<out.height { look(0, y); look(out.width - 1, y) }
            XCTAssertGreaterThan(darkest, level - 8, "rotate \(degrees)° at 2048 px: border pixel \(at) is \(darkest), the source is \(level)")
        }
    }

    // MARK: Metadata

    func testExportKeepsTheCameraEXIFWithOrientationNormalisedInEveryFormat() throws {
        // A 32×16 picture tagged orientation 6: displayed upright it is 16×32
        // with the dark half (the source's left) on top.
        let src = try writeSource("cam.jpg", halves(width: 32, height: 16), type: .jpeg, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "T-1",
                                             kCGImagePropertyTIFFOrientation: 6],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:15 12:34:56",
                                             kCGImagePropertyExifLensModel: "50mm F1.8",
                                             kCGImagePropertyExifFNumber: 2.8,
                                             kCGImagePropertyExifISOSpeedRatings: [400]],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.6, kCGImagePropertyGPSLatitudeRef: "N"],
        ])
        let sp = try properties(src)
        XCTAssertEqual(sp[kCGImagePropertyOrientation] as? Int, 6, "the source really is tagged rotated")
        try assertSize(src, 32, 16)

        for format in ExportOptions.Format.allCases {
            var o = ExportOptions()
            o.format = format
            o.quality = 1
            let out = try Exporter.export(src, recipe: .neutral, into: outDir, options: o)
            guard case .written(let url) = out else { return XCTFail("\(out)") }
            XCTAssertEqual(url.pathExtension, format.fileExtension)
            XCTAssertEqual(try containerType(url), format.utType.identifier)
            try assertSize(url, 16, 32, "\(format): rendered upright")

            let p = try properties(url)
            let orientation = p[kCGImagePropertyOrientation] as? Int
            XCTAssertTrue(orientation == nil || orientation == 1, "\(format): orientation \(String(describing: orientation))")
            let tiff = try XCTUnwrap(p[kCGImagePropertyTIFFDictionary] as? [CFString: Any], "\(format) has a TIFF block")
            XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "TestCam", "\(format)")
            XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "T-1", "\(format)")
            let tiffOrientation = tiff[kCGImagePropertyTIFFOrientation] as? Int
            XCTAssertTrue(tiffOrientation == nil || tiffOrientation == 1, "\(format): TIFF orientation \(String(describing: tiffOrientation))")
            let exif = try XCTUnwrap(p[kCGImagePropertyExifDictionary] as? [CFString: Any], "\(format) has an EXIF block")
            XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:10:15 12:34:56", "\(format)")
            XCTAssertEqual(exif[kCGImagePropertyExifLensModel] as? String, "50mm F1.8", "\(format)")
            XCTAssertEqual(try XCTUnwrap(exif[kCGImagePropertyExifFNumber] as? Double), 2.8, accuracy: 0.01, "\(format)")
            XCTAssertEqual(exif[kCGImagePropertyExifPixelXDimension] as? Int, 16, "\(format): pixel dimension is the output's")
            XCTAssertEqual(exif[kCGImagePropertyExifPixelYDimension] as? Int, 32, "\(format)")
            let gps = try XCTUnwrap(p[kCGImagePropertyGPSDictionary] as? [CFString: Any], "\(format) has GPS")
            XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLatitude] as? Double), 47.6, accuracy: 0.001, "\(format)")

            // Upright in the pixels too: dark on top, bright below, and a
            // viewer applying the (reset) orientation sees the same.
            let cg = try decode(url)
            XCTAssertLessThan(try meanGray(cg, rows: 0..<16), 60, "\(format): top is the dark half")
            XCTAssertGreaterThan(try meanGray(cg, rows: 16..<32), 190, "\(format): bottom is the bright half")
        }

        // Metadata off: the camera block is gone, the picture is the same.
        var plain = ExportOptions()
        plain.keepMetadata = false
        plain.suffix = "-plain"
        let out = try Exporter.export(src, recipe: .neutral, into: outDir, options: plain)
        guard case .written(let url) = out else { return XCTFail("\(out)") }
        let p = try properties(url)
        XCTAssertNil((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake])
        XCTAssertNil((p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(p[kCGImagePropertyGPSDictionary])
        try assertSize(url, 16, 32)

        // Metadata off and a resize: the EXIF pixel dimensions follow the resize when on.
        var small = ExportOptions()
        small.resize = .longSide(8)
        small.suffix = "-small"
        guard case .written(let smallURL) = try Exporter.export(src, recipe: .neutral, into: outDir, options: small) else { return XCTFail() }
        let se = try XCTUnwrap(try properties(smallURL)[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(se[kCGImagePropertyExifPixelXDimension] as? Int, 4)
        XCTAssertEqual(se[kCGImagePropertyExifPixelYDimension] as? Int, 8)
    }

    func testRemoveLocationDropsGPSAndIPTCPlaceButKeepsTheDateCameraAndKeywords() throws {
        let src = try writeSource("trip.jpg", gray(0.5, width: 16, height: 16), type: .jpeg, properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:15 12:34:56"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.6, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Seattle",
                                             kCGImagePropertyIPTCCountryPrimaryLocationName: "USA"],
        ])
        XCTAssertNotNil(try properties(src)[kCGImagePropertyGPSDictionary], "the source really has GPS")

        var o = ExportOptions()
        o.removeLocation = true
        guard case .written(let url) = try Exporter.export(src, recipe: .neutral, into: outDir, options: o,
                                                           keywords: ["family"]) else { return XCTFail() }
        let p = try properties(url)
        XCTAssertNil(p[kCGImagePropertyGPSDictionary], "GPS is removed")
        let iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        XCTAssertNil(iptc?[kCGImagePropertyIPTCCity], "the IPTC city is removed")
        XCTAssertNil(iptc?[kCGImagePropertyIPTCCountryPrimaryLocationName], "the IPTC country is removed")
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCKeywords] as? [String], ["family"], "keywords still travel")
        XCTAssertEqual((p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String,
                       "2026:10:15 12:34:56", "the capture date still travels")
        XCTAssertEqual((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String,
                       "TestCam", "the camera still travels")

        // Off (nil, an older options file): the location travels as before.
        var keep = ExportOptions()
        keep.suffix = "-keep"
        guard case .written(let kept) = try Exporter.export(src, recipe: .neutral, into: outDir, options: keep) else { return XCTFail() }
        XCTAssertNotNil(try properties(kept)[kCGImagePropertyGPSDictionary], "GPS is kept when the option is off")
    }

    func testOptionsSavedWithoutRemoveLocationDecodeWithItOff() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ExportOptions())) as! [String: Any]
        json.removeValue(forKey: "removeLocation")
        let o = try JSONDecoder().decode(ExportOptions.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(o.removesLocation)
    }

    // MARK: HEIC / TIFF

    func testHEICAndTIFFRoundTripAndOpenLikeTheJPEG() throws {
        let src = try writeSource("ramp.png", syntheticImage(width: 256, height: 256))
        var urls: [ExportOptions.Format: URL] = [:]
        for format in ExportOptions.Format.allCases {
            var o = ExportOptions()
            o.format = format
            o.quality = 0.95
            guard case .written(let url) = try Exporter.export(src, recipe: .neutral, into: outDir, options: o) else { return XCTFail() }
            urls[format] = url
            XCTAssertEqual(try containerType(url), format.utType.identifier, "\(format)")
            try assertSize(url, 256, 256, "\(format)")
        }
        XCTAssertEqual(Set(urls.values.map(\.lastPathComponent)), ["ramp.jpg", "ramp.heic", "ramp.tif"])
        let jpeg = meanGray(try decode(urls[.jpeg]!))
        let heic = meanGray(try decode(urls[.heic]!))
        let tiff = meanGray(try decode(urls[.tiff]!))
        XCTAssertEqual(heic, jpeg, accuracy: 3, "HEIC decodes to the same picture")
        XCTAssertEqual(tiff, jpeg, accuracy: 3, "TIFF decodes to the same picture")
        XCTAssertLessThanOrEqual(maxDiff(try decode(urls[.tiff]!), try decode(src)), 2, "TIFF is lossless (sRGB round trip)")
        XCTAssertLessThan(try fileSize(urls[.tiff]!), 256 * 256 * 3 * 6 / 10, "TIFF is LZW compressed, not raw")
        let tp = try properties(urls[.tiff]!)
        XCTAssertEqual((tp[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFCompression] as? Int, 5)
        // No format carries an alpha channel: the renderer's RGBA frame is
        // written opaque, so a TIFF opens as a photo, never as transparency.
        for (format, url) in urls {
            let p = try properties(url)
            XCTAssertEqual(p[kCGImagePropertyHasAlpha] as? Bool ?? false, false, "\(format) export has an alpha channel")
            XCTAssertEqual(p[kCGImagePropertyDepth] as? Int, 8, "\(format)")
        }
        XCTAssertEqual(try decode(urls[.tiff]!).width, 256)


        // Exposure goes through the one renderer in every format.
        var bright = Recipe.neutral
        bright.set(.exposure, to: 2)
        for format in ExportOptions.Format.allCases {
            var o = ExportOptions()
            o.format = format
            o.suffix = "-bright"
            guard case .written(let url) = try Exporter.export(src, recipe: bright, into: outDir, options: o) else { return XCTFail() }
            XCTAssertGreaterThan(meanGray(try decode(url)), jpeg + 40, "\(format)")
        }
    }

    // MARK: Collision policy

    func testCollisionPolicyNumberSkipOverwriteAndTheOriginalIsNeverWritten() throws {
        let src = try writeSource("p.png", gray(0.3, width: 24, height: 24))
        let outFiles = { try FileManager.default.contentsOfDirectory(atPath: self.outDir.path).sorted() }

        guard case .written(let first) = try Exporter.export(src, recipe: .neutral, into: outDir) else { return XCTFail() }
        XCTAssertEqual(first.lastPathComponent, "p.jpg")
        let firstBytes = try Data(contentsOf: first)

        // Default: a number, nothing replaced.
        guard case .written(let second) = try Exporter.export(src, recipe: .neutral, into: outDir) else { return XCTFail() }
        XCTAssertEqual(second.lastPathComponent, "p 2.jpg")
        XCTAssertEqual(try outFiles(), ["p 2.jpg", "p.jpg"])

        // Skip: the file stays, the photo is reported skipped, nothing new.
        var skip = ExportOptions()
        skip.collision = .skip
        XCTAssertEqual(try Exporter.export(src, recipe: .neutral, into: outDir, options: skip), .skipped(first))
        XCTAssertEqual(try outFiles(), ["p 2.jpg", "p.jpg"])
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)

        // Overwrite: the same name, new contents, no extra file.
        var overwrite = ExportOptions()
        overwrite.collision = .overwrite
        var bright = Recipe.neutral
        bright.set(.exposure, to: 2)
        XCTAssertEqual(try Exporter.export(src, recipe: bright, into: outDir, options: overwrite), .written(first))
        XCTAssertEqual(try outFiles(), ["p 2.jpg", "p.jpg"], "no partial file left behind")
        XCTAssertNotEqual(try Data(contentsOf: first), firstBytes)
        XCTAssertGreaterThan(meanGray(try decode(first)), meanGray(try decode(second)) + 60)

        // The original is never written: exporting a JPEG into its own
        // folder with Overwrite is refused, with Skip it is skipped, with a
        // number it becomes `<name> 2.jpg`.
        let own = try writeSource("q.jpg", gray(0.5, width: 24, height: 24), type: .jpeg)
        let ownBytes = try Data(contentsOf: own)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertThrowsError(try Exporter.export(own, recipe: bright, into: folder, options: overwrite)) { error in
            guard case Exporter.Failure.isTheOriginal(let u)? = error as? Exporter.Failure else { return XCTFail("\(error)") }
            XCTAssertEqual(u, own)
        }
        XCTAssertEqual(try Data(contentsOf: own), ownBytes, "untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), before)
        XCTAssertEqual(try Exporter.export(own, recipe: bright, into: folder, options: skip), .skipped(own))
        XCTAssertEqual(try Data(contentsOf: own), ownBytes)
        guard case .written(let numbered) = try Exporter.export(own, recipe: bright, into: folder) else { return XCTFail() }
        XCTAssertEqual(numbered.lastPathComponent, "q 2.jpg")
        XCTAssertEqual(try Data(contentsOf: own), ownBytes)
    }

    @MainActor
    func testTheQueueCountsSkippedFilesAndPassesTheOptionsThrough() async throws {
        for i in 0..<3 { try writeSource("p\(i).png", gray(0.3, width: 16, height: 16)) }
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let ids = lib.photos.map(\.id)
        // p1 already exported once.
        try Exporter.export(try XCTUnwrap(ids[1].fileURL), recipe: .neutral, into: outDir)

        var o = ExportOptions()
        o.collision = .skip
        o.format = .heic
        o.suffix = ""
        let queue = ExportQueue()
        lib.selectAll()
        // HEIC names do not collide with the JPEG: all three written.
        queue.start(try await lib.exportItems(for: lib.batchTargets), into: outDir, options: o)
        await queue.wait()
        XCTAssertEqual(queue.state, .finished)
        XCTAssertEqual(queue.done, 3)
        XCTAssertEqual(queue.exported.map(\.lastPathComponent), ["p0.heic", "p1.heic", "p2.heic"])
        XCTAssertTrue(queue.skipped.isEmpty)

        // The same run again with Skip: nothing written, three skipped.
        queue.dismiss()
        queue.start(try await lib.exportItems(for: lib.batchTargets), into: outDir, options: o)
        await queue.wait()
        XCTAssertEqual(queue.state, .finished)
        XCTAssertEqual(queue.done, 0)
        XCTAssertEqual(queue.skipped.map(\.lastPathComponent), ["p0.heic", "p1.heic", "p2.heic"])
        XCTAssertEqual(queue.completed, 3)
        XCTAssertTrue(queue.failures.isEmpty)
        XCTAssertEqual(queue.folder, outDir)

        // JPEG with Skip: p1.jpg exists, the other two are written.
        o.format = .jpeg
        queue.dismiss()
        queue.start(try await lib.exportItems(for: lib.batchTargets), into: outDir, options: o)
        await queue.wait()
        XCTAssertEqual(queue.done, 2)
        XCTAssertEqual(queue.skipped.map(\.lastPathComponent), ["p1.jpg"])
        XCTAssertEqual(queue.exported.map(\.lastPathComponent), ["p0.jpg", "p2.jpg"])

        // The sheet's request and the kept options (no UserDefaults: remember is off).
        queue.dismiss()
        XCTAssertNil(queue.request)
        queue.requestExport(try await lib.exportItems(for: [ids[0]]))
        XCTAssertEqual(queue.request?.items.count, 1)
        var kept = ExportOptions()
        kept.resize = .percent(50)
        kept.quality = 0.75
        queue.keep(folder: outDir, options: kept)
        XCTAssertEqual(queue.options, kept)
        XCTAssertNil(UserDefaults.standard.data(forKey: "exportOptions"), "a test queue never writes defaults")
    }

    // MARK: Names and options

    func testFileNameSuffixExtensionAndOptionsRoundTrip() throws {
        let src = URL(fileURLWithPath: "/tmp/x/DSC06727.ARW")
        var o = ExportOptions()
        XCTAssertEqual(o.fileName(for: src), "DSC06727.jpg")
        o.suffix = "-edit"
        XCTAssertEqual(o.fileName(for: src), "DSC06727-edit.jpg")
        XCTAssertEqual(o.fileName(for: src, number: 2), "DSC06727-edit 2.jpg")
        o.format = .heic
        XCTAssertEqual(o.fileName(for: src), "DSC06727-edit.heic")
        o.format = .tiff
        XCTAssertEqual(o.fileName(for: src), "DSC06727-edit.tif")
        o.suffix = " a/b:c\n"
        XCTAssertEqual(o.cleanSuffix, " abc", "nothing a file name cannot hold")

        // destination(for:in:options:) honours the policy.
        let src2 = try writeSource("p.png", gray(0.3, width: 8, height: 8))
        var e = ExportOptions()
        e.suffix = "-edit"
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: outDir.appendingPathComponent("p-edit.jpg"))
        XCTAssertEqual(Exporter.destination(for: src2, in: outDir, options: e).lastPathComponent, "p-edit 2.jpg")
        e.collision = .skip
        XCTAssertEqual(Exporter.destination(for: src2, in: outDir, options: e).lastPathComponent, "p-edit.jpg")
        e.collision = .overwrite
        XCTAssertEqual(Exporter.destination(for: src2, in: outDir, options: e).lastPathComponent, "p-edit.jpg")

        // Codable round trip, resize included.
        for resize in [nil, OutputSize.longSide(2048), OutputSize.percent(50)] {
            var r = ExportOptions()
            r.format = .heic
            r.quality = 0.8
            r.resize = resize
            r.keepMetadata = false
            r.suffix = "-web"
            r.collision = .overwrite
            let data = try JSONEncoder().encode(r)
            XCTAssertEqual(try JSONDecoder().decode(ExportOptions.self, from: data), r)
        }
        XCTAssertEqual(ExportOptions.default, ExportOptions())
    }


    /// A case-variant of the original: `X.JPG` exported as JPEG into its own
    /// folder is destined for `X.jpg`, a different string for the same file
    /// on a case-insensitive volume. The identity compare (resolved URL),
    /// not the string, is what refuses it.
    // MARK: One render path — the preview and the export agree on colour

    /// The loupe renders `Renderer.previewMaster` (an ImageIO downsample)
    /// and the export renders `Renderer.fullResolution` (the full decode),
    /// both through `Renderer.render` with the same recipe. For a Display P3
    /// HEIC and an sRGB JPEG, the mean colour of the preview frame and of the
    /// exported TIFF (lossless, read back the same way) agree to within
    /// 1/255 per channel, on a recipe that moves every channel.
    func testPreviewAndExportAgreeOnColourForAP3HEICAndAJPEG() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let sources = [
            try writeSource("wide.heic", syntheticImage(width: 1200, height: 800, space: p3), type: .heic),
            try writeSource("narrow.jpg", syntheticImage(width: 1200, height: 800), type: .jpeg),
        ]
        var recipe = Recipe.neutral
        recipe.set(.exposure, to: 0.4); recipe.set(.temperature, to: 20); recipe.set(.contrast, to: 15)
        recipe.set(.saturation, to: 20); recipe.set(.highlights, to: -30); recipe.set(.vignette, to: -20)
        var o = ExportOptions()
        o.format = .tiff
        for src in sources {
            let master = try XCTUnwrap(Renderer.previewMaster(src, maxPixelSize: 600))
            let preview = try XCTUnwrap(Renderer.shared.render(master, recipe: recipe, maxPixelSize: 600)).image
            let plain = try XCTUnwrap(Renderer.shared.render(master, recipe: .neutral, maxPixelSize: 600)).image
            XCTAssertEqual(max(preview.width, preview.height), 600, src.lastPathComponent)
            guard case .written(let url) = try Exporter.export(src, recipe: recipe, into: outDir, options: o) else { return XCTFail(src.lastPathComponent) }
            let exported = try decode(url)
            XCTAssertEqual((exported.width, exported.height) == (1200, 800), true, "\(src.lastPathComponent): \(exported.width)×\(exported.height)")
            let a = meanRGB(try redrawn(preview)), b = meanRGB(exported), n = meanRGB(try redrawn(plain))
            print(String(format: "COLOUR-AGREE %@: preview %.2f %.2f %.2f vs export %.2f %.2f %.2f (neutral %.2f %.2f %.2f)",
                         src.lastPathComponent, a.r, a.g, a.b, b.r, b.g, b.b, n.r, n.g, n.b))
            XCTAssertGreaterThan(abs(a.r - n.r) + abs(a.g - n.g) + abs(a.b - n.b), 15, "\(src.lastPathComponent): the recipe moved the picture")
            for (c, d) in [("R", a.r - b.r), ("G", a.g - b.g), ("B", a.b - b.b)] {
                XCTAssertLessThanOrEqual(abs(d), 1, String(format: "%@ %@: preview %.2f vs export %.2f", src.lastPathComponent, c, c == "R" ? a.r : c == "G" ? a.g : a.b, c == "R" ? b.r : c == "G" ? b.g : b.b))
            }
        }
    }

    /// `image` drawn into an sRGB RGBA8 bitmap, the way `decode` reads a
    /// written file, so a P3 frame and its P3 export are compared in one space.
    private func redrawn(_ image: CGImage) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try XCTUnwrap(ctx.makeImage())
    }

    func testExportingTheOriginalUnderACaseVariantNameIsRefused() throws {
        let own = try writeSource("X.JPG", gray(0.5, width: 24, height: 24), type: .jpeg)
        let ownBytes = try Data(contentsOf: own)
        var overwrite = ExportOptions()
        overwrite.collision = .overwrite
        let target = Exporter.destination(for: own, in: folder, options: overwrite)
        XCTAssertEqual(target.lastPathComponent, "X.jpg")
        XCTAssertNotEqual(target.path, own.path, "the strings differ; only the file identity can tell")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: target.path),
                          "case-sensitive volume: X.jpg is a different file here")

        var bright = Recipe.neutral
        bright.set(.exposure, to: 2)
        XCTAssertThrowsError(try Exporter.export(own, recipe: bright, into: folder, options: overwrite)) { error in
            guard case Exporter.Failure.isTheOriginal(let u)? = error as? Exporter.Failure else { return XCTFail("\(error)") }
            XCTAssertEqual(u, own)
        }
        XCTAssertEqual(try Data(contentsOf: own), ownBytes, "untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["X.JPG"], "no partial, no X.jpg")
    }

    /// Overwrite never lands on another photo of the open library: `x.png`
    /// exported as JPEG with no suffix into its own folder would replace the
    /// library's `x.jpg`. The queue counts it failed and names the file;
    /// both originals keep their bytes. The guard is that narrow: Add a
    /// number writes `x 2.jpg` beside them, and Overwrite into another folder
    /// still replaces a plain earlier export.
    @MainActor
    func testOverwriteOntoAnotherLibraryOriginalIsRefused() async throws {
        let png = try writeSource("x.png", gray(0.2, width: 24, height: 24))
        let jpg = try writeSource("x.jpg", gray(0.8, width: 24, height: 24), type: .jpeg)
        let pngBytes = try Data(contentsOf: png), jpgBytes = try Data(contentsOf: jpg)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let pngID = try XCTUnwrap(lib.photos.first { $0.fileURL?.lastPathComponent == "x.png" }?.id)
        XCTAssertEqual(lib.photos.count, 2)

        var overwrite = ExportOptions()
        overwrite.collision = .overwrite
        overwrite.format = .jpeg
        overwrite.suffix = ""
        let items = try await lib.exportItems(for: [pngID])
        XCTAssertEqual(Exporter.destination(for: png, in: folder, options: overwrite).lastPathComponent, "x.jpg")

        let queue = ExportQueue()
        queue.start(items, into: folder, options: overwrite)
        await queue.wait()
        XCTAssertEqual(queue.state, .finished)
        XCTAssertEqual(queue.done, 0)
        XCTAssertEqual(queue.failures.count, 1)
        XCTAssertEqual(queue.failures.first?.source.lastPathComponent, "x.png")
        XCTAssertEqual(queue.failures.first?.message, "x.jpg is an original in the library; it is never overwritten.")
        XCTAssertEqual(queue.completed, 1)
        XCTAssertEqual(try Data(contentsOf: png), pngBytes, "the exported photo untouched")
        XCTAssertEqual(try Data(contentsOf: jpg), jpgBytes, "the other original untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { !$0.hasPrefix(".") }.sorted(), ["x.jpg", "x.png"], "no partial, no new file")

        XCTAssertThrowsError(try Exporter.export(png, recipe: .neutral, into: folder, options: overwrite,
                                                 protected: items[0].protected)) { error in
            guard case Exporter.Failure.isALibraryOriginal(let u)? = error as? Exporter.Failure else { return XCTFail("\(error)") }
            XCTAssertEqual(u.lastPathComponent, "x.jpg")
        }
        XCTAssertEqual(try Data(contentsOf: jpg), jpgBytes)

        // Add a number: written beside both originals.
        var number = overwrite
        number.collision = .number
        guard case .written(let numbered) = try Exporter.export(png, recipe: .neutral, into: folder, options: number,
                                                                 protected: items[0].protected) else { return XCTFail() }
        XCTAssertEqual(numbered.lastPathComponent, "x 2.jpg")
        XCTAssertEqual(try Data(contentsOf: jpg), jpgBytes)

        // Overwrite outside the library: an earlier export is replaced.
        try Exporter.export(png, recipe: .neutral, into: outDir, options: overwrite, protected: items[0].protected)
        let earlier = try Data(contentsOf: outDir.appendingPathComponent("x.jpg"))
        var bright = Recipe.neutral
        bright.set(.exposure, to: 2)
        XCTAssertEqual(try Exporter.export(png, recipe: bright, into: outDir, options: overwrite, protected: items[0].protected),
                       .written(outDir.appendingPathComponent("x.jpg")))
        XCTAssertNotEqual(try Data(contentsOf: outDir.appendingPathComponent("x.jpg")), earlier)
    }

    /// The library's original is matched as a file, not by spelling:
    /// `y.png` exported as `y.jpg` onto the library's `Y.JPG` (one file on a
    /// case-insensitive volume) is refused too. (The resolved path already
    /// canonicalises the case; the hard-link test below needs the identity.)
    @MainActor
    func testOverwriteOntoACaseVariantOfALibraryOriginalIsRefused() async throws {
        let png = try writeSource("y.png", gray(0.2, width: 24, height: 24))
        let jpg = try writeSource("Y.JPG", gray(0.8, width: 24, height: 24), type: .jpeg)
        let jpgBytes = try Data(contentsOf: jpg)
        var overwrite = ExportOptions()
        overwrite.collision = .overwrite
        overwrite.format = .jpeg
        overwrite.suffix = ""
        let target = Exporter.destination(for: png, in: folder, options: overwrite)
        XCTAssertEqual(target.lastPathComponent, "y.jpg")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: target.path),
                          "case-sensitive volume: y.jpg is a different file here")
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let pngID = try XCTUnwrap(lib.photos.first { $0.fileURL?.lastPathComponent == "y.png" }?.id)
        let items = try await lib.exportItems(for: [pngID])
        XCTAssertThrowsError(try Exporter.export(png, recipe: .neutral, into: folder, options: overwrite,
                                                 protected: items[0].protected)) { error in
            guard case Exporter.Failure.isALibraryOriginal? = error as? Exporter.Failure else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: jpg), jpgBytes, "untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { !$0.hasPrefix(".") }.sorted(), ["Y.JPG", "y.png"])
    }

    /// A second name for a library original (a hard link in the export
    /// folder) is that original: matched by `fileResourceIdentifier`, the
    /// Overwrite is refused and the shared bytes stay.
    @MainActor
    func testOverwriteOntoAHardLinkOfALibraryOriginalIsRefused() async throws {
        let png = try writeSource("z.png", gray(0.2, width: 24, height: 24))
        let jpg = try writeSource("z.jpg", gray(0.8, width: 24, height: 24), type: .jpeg)
        let jpgBytes = try Data(contentsOf: jpg)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let link = outDir.appendingPathComponent("z.jpg")
        try FileManager.default.linkItem(at: jpg, to: link)
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let pngID = try XCTUnwrap(lib.photos.first { $0.fileURL?.lastPathComponent == "z.png" }?.id)
        let items = try await lib.exportItems(for: [pngID])
        var overwrite = ExportOptions()
        overwrite.collision = .overwrite
        overwrite.format = .jpeg
        overwrite.suffix = ""
        XCTAssertThrowsError(try Exporter.export(png, recipe: .neutral, into: outDir, options: overwrite,
                                                 protected: items[0].protected)) { error in
            guard case Exporter.Failure.isALibraryOriginal(let u)? = error as? Exporter.Failure else { return XCTFail("\(error)") }
            XCTAssertEqual(u.lastPathComponent, "z.jpg")
        }
        XCTAssertEqual(try Data(contentsOf: link), jpgBytes, "the link still holds the original")
        XCTAssertEqual(try Data(contentsOf: jpg), jpgBytes)
        XCTAssertTrue(Exporter.isSameFile(link, jpg))
        XCTAssertFalse(Exporter.isSameFile(png, jpg))
    }
}

// MARK: - Export back into Photos

/// A `PhotosWriter` that imports nothing: it reads each file it is handed
/// (so a test sees what `Exporter.export` wrote), notes how many files sat
/// beside it in the staging directory, and returns `fake-<n>`. `failOn`
/// holds the 1-based import calls that throw.
final class FakePhotosWriter: PhotosWriter, @unchecked Sendable {
    struct Import: Equatable {
        let id: String
        let album: String?
        let name: String
        let pixelWidth: Int
        /// Files in the staging directory at the import, the one handed over included.
        let staged: Int
    }

    struct Refused: LocalizedError {
        var errorDescription: String? { "the fake writer refused it" }
    }

    private let lock = NSLock()
    private var log: [Import] = []
    private var calls = 0
    let status: PhotosAuthorization
    let failOn: Set<Int>

    init(status: PhotosAuthorization = .authorized, failOn: Set<Int> = []) {
        self.status = status
        self.failOn = failOn
    }

    var imports: [Import] { lock.lock(); defer { lock.unlock() }; return log }

    func authorizationStatus() -> PhotosAuthorization { status }

    func requestAuthorization() async -> PhotosAuthorization {
        XCTFail("a test never prompts")
        return status
    }

    func importImage(at url: URL, intoAlbum album: String?) async throws -> String {
        let width = CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyPixelWidth] as? Int ?? -1
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count) ?? -1
        return try record(album: album, name: url.lastPathComponent, pixelWidth: width, staged: staged)
    }

    private func record(album: String?, name: String, pixelWidth: Int, staged: Int) throws -> String {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        if failOn.contains(calls) { throw Refused() }
        let id = "fake-\(calls)"
        log.append(Import(id: id, album: album, name: name, pixelWidth: pixelWidth, staged: staged))
        return id
    }
}

extension ExportTests {
    private func photosRun(_ writer: FakePhotosWriter, album: String?, options: ExportOptions = .default,
                           count: Int = 3) async throws -> (ExportQueue, URL) {
        for i in 0..<count { try writeSource("p\(i).png", gray(0.3, width: 16, height: 16)) }
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.selectAll()
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let queue = ExportQueue(photos: writer, stagingDirectory: staging)
        queue.start(try await lib.exportItems(for: lib.batchTargets), to: .photosLibrary(album: album), options: options)
        await queue.wait()
        return (queue, staging)
    }

    private func stagedFiles(_ staging: URL) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: staging.path) else { return [] }
        return e.compactMap { $0 as? String }
    }

    func testAPhotosRunImportsEveryItemIntoTheNamedAlbumAndLeavesNothingStaged() async throws {
        let writer = FakePhotosWriter()
        var o = ExportOptions()
        o.resize = .longSide(8)
        o.suffix = "-edit"
        o.collision = .skip // ignored for Photos: every import is new
        let (queue, staging) = try await photosRun(writer, album: "Holiday", options: o)

        XCTAssertEqual(queue.state, .finished)
        XCTAssertEqual(queue.done, 3)
        XCTAssertEqual(queue.imported, ["fake-1", "fake-2", "fake-3"])
        XCTAssertEqual(writer.imports.map(\.id), queue.imported)
        XCTAssertEqual(writer.imports.map(\.album), ["Holiday", "Holiday", "Holiday"], "all in the named album")
        XCTAssertEqual(writer.imports.map(\.name), ["p0-edit.jpg", "p1-edit.jpg", "p2-edit.jpg"], "rendered by Exporter.export per the options")
        XCTAssertEqual(writer.imports.map(\.pixelWidth), [8, 8, 8], "the resize reached the file")
        XCTAssertEqual(writer.imports.map(\.staged), [1, 1, 1], "each staged file goes before the next is written")
        XCTAssertTrue(queue.exported.isEmpty)
        XCTAssertTrue(queue.skipped.isEmpty)
        XCTAssertTrue(queue.failures.isEmpty)
        XCTAssertEqual(stagedFiles(staging), [], "the staging directory is left empty")
        XCTAssertEqual(queue.target, .photosLibrary(album: "Holiday"))
        XCTAssertNil(queue.folder, "a Photos run sets no folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDir.path), "nothing written outside staging")
    }

    func testAWriterFailureCountsAsAFailureAndTheRunContinues() async throws {
        let writer = FakePhotosWriter(failOn: [2])
        let (queue, staging) = try await photosRun(writer, album: ExportTarget.defaultAlbum)

        XCTAssertEqual(queue.state, .finished)
        XCTAssertEqual(queue.done, 2)
        XCTAssertEqual(queue.imported, ["fake-1", "fake-3"])
        XCTAssertEqual(queue.failures.map(\.source.lastPathComponent), ["p1.png"])
        XCTAssertEqual(queue.failures.first?.message, "the fake writer refused it")
        XCTAssertEqual(queue.completed, 3)
        XCTAssertEqual(writer.imports.map(\.album), ["PhotoLab", "PhotoLab"])
        XCTAssertEqual(stagedFiles(staging), [], "the refused file is removed too")
    }

    func testNoAlbumMeansTheLibraryOnlyAndKeepRemembersTheTarget() async throws {
        let writer = FakePhotosWriter()
        let (queue, staging) = try await photosRun(writer, album: nil, count: 1)
        XCTAssertEqual(writer.imports.map(\.album), [nil])
        XCTAssertEqual(queue.imported, ["fake-1"])
        XCTAssertEqual(stagedFiles(staging), [])

        // The album field: trimmed, empty = none; the bar's names.
        XCTAssertNil(ExportTarget.album(from: "  \n"))
        XCTAssertEqual(ExportTarget.album(from: " Trips "), "Trips")
        XCTAssertEqual(ExportTarget.photosLibrary(album: nil).displayName, "Photos")
        XCTAssertEqual(ExportTarget.photosLibrary(album: "Trips").displayName, "Photos › Trips")
        XCTAssertEqual(ExportTarget.folder(outDir).displayName, "export")

        // keep: a Photos target keeps the album and the kind, never the folder.
        XCTAssertEqual(queue.album, ExportTarget.defaultAlbum)
        XCTAssertFalse(queue.prefersPhotos)
        queue.dismiss()
        queue.keep(folder: outDir, options: .default)
        queue.keep(target: .photosLibrary(album: "Trips"), options: .default)
        XCTAssertEqual(queue.album, "Trips")
        XCTAssertTrue(queue.prefersPhotos)
        XCTAssertEqual(queue.folder, outDir, "the folder stays for the next folder run")
        queue.keep(folder: outDir, options: .default)
        XCTAssertFalse(queue.prefersPhotos)
        XCTAssertEqual(queue.album, "Trips")
        XCTAssertNil(UserDefaults.standard.object(forKey: "exportPhotosAlbum"), "a test queue never writes defaults")
        XCTAssertNil(UserDefaults.standard.object(forKey: "exportTarget"))
    }

    // MARK: The real library (opt-in: authorized AND PHOTOLAB_PHOTOS_WRITE=1)

    /// Adds a real photo to the library, so it runs only when asked for and
    /// never prompts: an `xctest` host is not authorized and skips.
    func testRealImportAddsA16PixelJPEGToTheTestAlbum() async throws {
        guard ProcessInfo.processInfo.environment["PHOTOLAB_PHOTOS_WRITE"] == "1" else {
            throw XCTSkip("set PHOTOLAB_PHOTOS_WRITE=1 (from an authorized bundle) to import a real photo")
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized else {
            throw XCTSkip("Photos access is \(status.rawValue), not authorized, for this test host")
        }
        let file = base.appendingPathComponent("photolab-test.jpg")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, gray(0.5, width: 16, height: 16), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let id = try await PhotoKitLive().importImage(at: file, intoAlbum: "PhotoLab Tests")
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
        XCTAssertEqual(asset.pixelWidth, 16)
        let album = try XCTUnwrap(PhotoKitLive.regularAlbum(titled: "PhotoLab Tests"))
        let inAlbum = PHAsset.fetchAssets(in: album, options: nil)
        var ids: [String] = []
        inAlbum.enumerateObjects { a, _, _ in ids.append(a.localIdentifier) }
        XCTAssertTrue(ids.contains(id), "the new asset is in the album")
    }
}

// MARK: Export names of Photos originals

/// A PhotoKit stand-in with two image assets whose originals are real PNGs.
private final class NamedPhotoKit: PhotoKitClient, @unchecked Sendable {
    static let album = PhotosAlbum(id: "ALB/L0/040", title: "Trip", count: 2, isRecents: false)
    static let list = [PhotosAsset(id: "A/L0/001", originalFilename: "IMG_0001.PNG"),
                       PhotosAsset(id: "B/L0/001", originalFilename: "Holiday photo.PNG")]
    func authorizationStatus() -> PhotosAuthorization { .authorized }
    func requestAuthorization() async -> PhotosAuthorization { .authorized }
    func albums() -> [PhotosAlbum] { [Self.album] }
    func assets(in album: PhotosAlbum) -> [PhotosAsset] { Self.list }
    func originalFilename(of assetID: String) -> String? { Self.list.first { $0.id == assetID }?.originalFilename }
    func thumbnail(for assetID: String, maxPixelSize: Int) -> NSImage? { nil }
    func writeOriginal(of assetID: String, to url: URL) async throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, syntheticImage(width: 16, height: 16), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
    func hasAdjustments(_ assetID: String) -> Bool { false }
    func adjustment(of assetID: String) async throws -> PhotosAdjustment? { nil }
    func saveEdit(_ adjustment: PhotosAdjustment, to assetID: String,
                  render: @escaping @Sendable (URL) throws -> Void) async throws {
        throw PhotosError.cannotEdit(assetID)
    }
}

extension ExportTests {
    private func photosLibrary() -> Library {
        let access = PhotosAccess(client: NamedPhotoKit(),
                                  sidecarDirectory: base.appendingPathComponent("sidecars", isDirectory: true),
                                  originalsDirectory: base.appendingPathComponent("originals", isDirectory: true))
        let lib = Library(rememberFolder: false)
        lib.open(album: NamedPhotoKit.album, access: access)
        return lib
    }

    /// A Photos-sourced item exports as `<original name><suffix>.<ext>`,
    /// never the cache copy's id, to a folder and to the Photos library.
    func testAPhotosItemIsNamedFromItsOriginalFilenameNotTheCacheCopy() async throws {
        let lib = photosLibrary()
        lib.selectAll()
        let items = try await lib.exportItems(for: lib.batchTargets)
        XCTAssertEqual(items.compactMap(\.name).sorted(), ["Holiday photo.PNG", "IMG_0001.PNG"])
        XCTAssertTrue(items.allSatisfy { $0.source.lastPathComponent.contains("L0") }, "the source is the cache copy")

        var o = ExportOptions()
        o.suffix = "-edit"
        let q = ExportQueue(photos: FakePhotosWriter(), stagingDirectory: base.appendingPathComponent("staging"))
        q.start(items, into: outDir, options: o)
        await q.wait()
        XCTAssertEqual(q.state, .finished)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outDir.path).sorted(),
                       ["Holiday photo-edit.jpg", "IMG_0001-edit.jpg"])

        let writer = FakePhotosWriter()
        let p = ExportQueue(photos: writer, stagingDirectory: base.appendingPathComponent("staging"))
        p.start(items, to: .photosLibrary(album: nil), options: o)
        await p.wait()
        XCTAssertEqual(writer.imports.map(\.name).sorted(), ["Holiday photo-edit.jpg", "IMG_0001-edit.jpg"])

        // The sheet's preview and the collision counter follow the same name.
        XCTAssertEqual(o.fileName(for: items[0].source, name: items[0].name), items[0].name!.replacingOccurrences(of: ".PNG", with: "-edit.jpg"))
        XCTAssertEqual(o.fileName(for: items[0].source, name: "IMG_0001.PNG", number: 2), "IMG_0001-edit 2.jpg")
    }

    /// A folder photo carries no name and keeps its file's.
    func testAFolderItemCarriesNoNameAndKeepsItsFileName() async throws {
        try writeSource("p0.png", gray(0.3, width: 16, height: 16))
        let lib = Library(rememberFolder: false)
        lib.open(folder)
        lib.selectAll()
        let items = try await lib.exportItems(for: lib.batchTargets)
        XCTAssertEqual(items.map(\.name), [nil])
    }
}
