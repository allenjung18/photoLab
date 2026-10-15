import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoLab

/// Export options on the one `Exporter.export` path: JPEG quality moves the
/// file size, resize gives an exact long side and never upscales, the
/// source's camera EXIF travels with the orientation reset to upright, HEIC
/// and TIFF round-trip, the collision policy holds and the original is
/// never written. Every folder is a temp directory.
final class ExportTests: XCTestCase {
    private var base: URL!
    private var folder: URL!
    private var outDir: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-export-\(UUID().uuidString)", isDirectory: true)
        folder = base.appendingPathComponent("photos", isDirectory: true)
        outDir = base.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
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
        try Exporter.export(ids[1], recipe: .neutral, into: outDir)

        var o = ExportOptions()
        o.collision = .skip
        o.format = .heic
        o.suffix = ""
        let queue = ExportQueue()
        lib.selectAll()
        // HEIC names do not collide with the JPEG: all three written.
        queue.start(lib.exportItems(for: lib.batchTargets), into: outDir, options: o)
        await queue.wait()
        XCTAssertEqual(queue.state, .finished)
        XCTAssertEqual(queue.done, 3)
        XCTAssertEqual(queue.exported.map(\.lastPathComponent), ["p0.heic", "p1.heic", "p2.heic"])
        XCTAssertTrue(queue.skipped.isEmpty)

        // The same run again with Skip: nothing written, three skipped.
        queue.dismiss()
        queue.start(lib.exportItems(for: lib.batchTargets), into: outDir, options: o)
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
        queue.start(lib.exportItems(for: lib.batchTargets), into: outDir, options: o)
        await queue.wait()
        XCTAssertEqual(queue.done, 2)
        XCTAssertEqual(queue.skipped.map(\.lastPathComponent), ["p1.jpg"])
        XCTAssertEqual(queue.exported.map(\.lastPathComponent), ["p0.jpg", "p2.jpg"])

        // The sheet's request and the kept options (no UserDefaults: remember is off).
        queue.dismiss()
        XCTAssertNil(queue.request)
        queue.requestExport(lib.exportItems(for: [ids[0]]))
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
}
