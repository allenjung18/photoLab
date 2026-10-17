import XCTest
import CoreImage
@testable import PhotoLab

/// Noise reduction: `luminanceNoise` smooths brightness noise and grows
/// with the slider, `colorNoise` blurs the colour only (the luminance and
/// the edge stay), both sit at the head of Detail and run after the crop and
/// before exposure, and a Lightroom preset's noise settings map onto them.
/// Every picture is synthetic and seeded, so the measures repeat.
final class NoiseReductionTests: XCTestCase {
    let renderer = Renderer.shared
    private let width = 256, height = 128

    /// Dark left half (0.3), bright right half (0.7), edge at x = 128, plus
    /// seeded noise: `chroma` moves red and blue apart (luminance nearly
    /// unchanged), `luma` moves all three channels together.
    private func noisy(chroma: Double = 0, luma: Double = 0) -> CIImage {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func rand() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(1 << 31) * 2 - 1
        }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let base = x < width / 2 ? 0.3 : 0.7
                // Luminance noise as a sum of three uniforms: bell-shaped, many levels, like a sensor's.
                let c = rand() * chroma, l = (rand() + rand() + rand()) / 3 * luma * 1.7
                let rgb = [base + l + c, base + l, base + l - c]
                for k in 0..<3 { bytes[(y * width + x) * 4 + k] = UInt8(max(0, min(255, (rgb[k] * 255).rounded()))) }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return CIImage(cgImage: cg)
    }

    private func render(_ source: CIImage, _ kind: AdjustmentKind, _ value: Double) throws -> CGImage {
        var r = Recipe.neutral
        r.set(kind, to: value)
        return try XCTUnwrap(renderer.render(source, recipe: r)).image
    }

    /// Per-pixel values over a flat block of the dark half (away from the edge and the borders).
    private func flat(_ cg: CGImage, _ f: (Double, Double, Double) -> Double) -> [Double] {
        let data = CFDataGetBytePtr(cg.dataProvider!.data)!
        var out: [Double] = []
        for y in 16..<(cg.height - 16) {
            for x in 16..<(cg.width / 2 - 16) {
                let i = y * cg.bytesPerRow + x * 4
                out.append(f(Double(data[i]), Double(data[i + 1]), Double(data[i + 2])))
            }
        }
        return out
    }

    private func std(_ v: [Double]) -> Double {
        let m = v.reduce(0, +) / Double(v.count)
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
    }

    private func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }

    /// Mean green just right of the edge minus just left of it: the step a blur would flatten.
    private func edgeStep(_ cg: CGImage) -> Double {
        let data = CFDataGetBytePtr(cg.dataProvider!.data)!
        func column(_ x: Int) -> Double {
            (16..<(cg.height - 16)).map { Double(data[$0 * cg.bytesPerRow + x * 4 + 1]) }.reduce(0, +) / Double(cg.height - 32)
        }
        let mid = cg.width / 2
        return column(mid + 1) - column(mid - 2)
    }

    // MARK: Model

    func testTheNoiseKindsHeadDetailAndRunAfterTheCropBeforeExposure() {
        let all = AdjustmentKind.allCases
        let i = all.firstIndex(of: .luminanceNoise)!, j = all.firstIndex(of: .colorNoise)!
        XCTAssertEqual(j, i + 1)
        XCTAssertGreaterThan(i, all.firstIndex(of: .cropBottom)!, "after the crop")
        XCTAssertLessThan(j, all.firstIndex(of: .exposure)!, "before exposure lifts the shadows")
        XCTAssertEqual(Array(AdjustmentKind.Section.detail.kinds.prefix(2)), [.luminanceNoise, .colorNoise])
        for kind in [AdjustmentKind.luminanceNoise, .colorNoise] {
            XCTAssertEqual(kind.range, 0...100)
            XCTAssertNil(kind.group)
            XCTAssertEqual(kind.format(40), "40")
        }
        XCTAssertEqual(AdjustmentKind.luminanceNoise.label, "Noise reduction")
        XCTAssertEqual(AdjustmentKind.colorNoise.label, "Color noise")
    }

    // MARK: Render

    func testColorNoiseBlursTheColourAndKeepsTheLuminanceAndTheEdge() throws {
        let src = noisy(chroma: 0.12)
        let off = try render(src, .colorNoise, 0)
        let on = try render(src, .colorNoise, 100)
        let chroma = { (r: Double, _: Double, b: Double) in r - b }
        let before = std(flat(off, chroma)), after = std(flat(on, chroma))
        XCTAssertGreaterThan(before, 20, "the source really is colour-noisy: \(before)")
        XCTAssertLessThan(after, before * 0.5, "colour noise halved at least: \(before) -> \(after)")
        let lum = { (r: Double, g: Double, b: Double) in 0.2126 * r + 0.7152 * g + 0.0722 * b }
        XCTAssertEqual(mean(flat(on, lum)), mean(flat(off, lum)), accuracy: 3, "the brightness stays")
        XCTAssertEqual(edgeStep(on), edgeStep(off), accuracy: edgeStep(off) * 0.05, "the edge stays sharp")
    }

    func testNoiseReductionSmoothsLuminanceNoiseAndGrowsWithTheSlider() throws {
        let src = noisy(luma: 0.06)
        let green = { (_: Double, g: Double, _: Double) in g }
        let s0 = std(flat(try render(src, .luminanceNoise, 0), green))
        let s50 = std(flat(try render(src, .luminanceNoise, 50), green))
        let s100Image = try render(src, .luminanceNoise, 100)
        let s100 = std(flat(s100Image, green))
        XCTAssertGreaterThan(s0, 5, "the source really is noisy: \(s0)")
        XCTAssertLessThan(s50, s0, "50 smooths: \(s0) -> \(s50)")
        XCTAssertLessThan(s100, s0 * 0.7, "100 cuts the noise by 30% or more: \(s0) -> \(s100)")
        XCTAssertLessThan(s100, s50 * 0.9, "and clearly more than 50 does (the slider's top half works): \(s50) -> \(s100)")
        let offStep = edgeStep(try render(src, .luminanceNoise, 0))
        XCTAssertGreaterThan(edgeStep(s100Image), offStep * 0.8, "the edge survives: \(offStep) -> \(edgeStep(s100Image))")
    }

    func testColorNoiseKeepsTheColoursInPlaceAfterACrop() throws {
        // Red left, blue right, boundary at x = 128, under a 20% crop: the
        // quarter-size blur must land back exactly where it came from.
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        let src = CIImage(cgImage: ctx.makeImage()!)
        var r = Recipe.neutral
        r.set(.cropLeft, to: 20)
        r.set(.cropBottom, to: 20)
        r.set(.colorNoise, to: 100)
        let cg = try XCTUnwrap(renderer.render(src, recipe: r)).image
        let data = CFDataGetBytePtr(cg.dataProvider!.data)!
        let boundary = width / 2 - Int((Double(width) * 0.2).rounded())  // where x = 128 lands after the crop
        let y = cg.height / 2
        for (x, redSide) in [(boundary - 6, true), (boundary + 6, false), (4, true), (cg.width - 4, false)] {
            let i = y * cg.bytesPerRow + x * 4
            let red = Int(data[i]), blue = Int(data[i + 2])
            XCTAssertEqual(red > blue, redSide, "x \(x) (boundary \(boundary)): r \(red) b \(blue)")
        }
    }

    func testBothAtZeroAreTheIdentityAndTheSizeHolds() throws {
        let src = noisy(chroma: 0.1, luma: 0.05)
        let neutral = try XCTUnwrap(renderer.render(src, recipe: .neutral)).image
        for kind in [AdjustmentKind.luminanceNoise, .colorNoise] {
            XCTAssertEqual(maxDiff(try render(src, kind, 0), neutral), 0, "\(kind) at 0")
            let on = try render(src, kind, 100)
            XCTAssertEqual([on.width, on.height], [width, height], "\(kind) keeps the size")
        }
    }

    // MARK: Lightroom presets

    func testAPresetsNoiseSettingsMapAndTheColourDefaultIsNoChange() throws {
        func parse(_ attributes: String) throws -> XMPImport {
            let text = """
                <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" \(attributes)/>
                </rdf:RDF></x:xmpmeta>
                """
            return try XMPPreset.parse(Data(text.utf8), fileName: "nr.xmp")
        }
        let r = try parse(#"crs:LuminanceSmoothing="40" crs:ColorNoiseReduction="60""#)
        XCTAssertEqual(r.recipe.value(of: .luminanceNoise), 40)
        XCTAssertEqual(r.recipe.value(of: .colorNoise), 60)
        XCTAssertEqual(r.unsupported, [], "noise reduction is no longer listed as unsupported")

        let d = try parse(#"crs:ColorNoiseReduction="25" crs:Exposure2012="+0.20""#)
        XCTAssertEqual(d.recipe.value(of: .colorNoise), 0, "Lightroom's default 25 changes nothing here")
        XCTAssertEqual(d.unsupported, [])
    }
}

/// Mid-drag the loupe leaves noise reduction out (`Recipe.draft`,
/// `Library.previewRecipe`), so a drag keeps to the 60 Hz budget with every
/// slider on; the saved recipe, an export and the frame at mouse-up keep it.
@MainActor
final class NoiseReductionDragTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolab-nr-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var denoised: Recipe {
        var r = Recipe.neutral
        r.set(.luminanceNoise, to: 40)
        r.set(.colorNoise, to: 30)
        r.set(.exposure, to: 0.2)
        return r
    }

    func testTheDraftDropsNoiseReductionOnlyOnceSomethingElseMoves() {
        let before = denoised
        XCTAssertEqual(before.draft(since: before), before, "a press that moved nothing swaps nothing")

        var moved = before
        moved.set(.exposure, to: 0.5)
        let d = moved.draft(since: before)
        XCTAssertEqual(d.value(of: .luminanceNoise), 0)
        XCTAssertEqual(d.value(of: .colorNoise), 0)
        XCTAssertEqual(d.value(of: .exposure), 0.5, "the moving slider is rendered")

        var nr = before
        nr.set(.luminanceNoise, to: 60)
        XCTAssertEqual(nr.draft(since: before), nr, "dragging noise reduction itself shows it live")

        var plain = Recipe.neutral
        plain.set(.exposure, to: 0.1)
        var plainMoved = plain
        plainMoved.set(.exposure, to: 0.3)
        XCTAssertEqual(plainMoved.draft(since: plain), plainMoved, "no noise reduction, nothing to drop")
    }

    func testTheLoupeRecipeDropsItMidDragAndTheSavedRecipeNever() throws {
        let url = folder.appendingPathComponent("n.png")
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let lib = Library(rememberFolder: false)
        lib.open(folder)
        let photo = try XCTUnwrap(lib.photos.first).id
        lib.selection = photo
        lib.setRecipe(denoised, for: photo)
        XCTAssertEqual(lib.previewRecipe(for: photo), denoised, "no drag: the loupe renders it all")

        lib.beginEdit(photo)
        var r = denoised
        r.set(.exposure, to: 0.6)
        lib.setRecipe(r, for: photo)
        XCTAssertEqual(lib.previewRecipe(for: photo).value(of: .luminanceNoise), 0, "mid-drag: left out")
        XCTAssertEqual(lib.recipe(for: photo).value(of: .luminanceNoise), 40, "the recipe itself keeps it")
        lib.endEdit(photo)

        XCTAssertEqual(lib.previewRecipe(for: photo), r, "mouse-up: back in the frame")
        XCTAssertEqual(try SidecarStore(folder: folder).load(for: photo), r, "and in the sidecar")
    }
}
