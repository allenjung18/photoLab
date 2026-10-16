import XCTest
import CoreImage
import CoreGraphics
import simd
@testable import PhotoLab

/// The lens corrections (`AdjustmentKind.lensDistortion`, `.lensVignette`,
/// `LensMath`, `LensCorrection`): first in the chain, the frame's extent
/// kept, no empty edge, a known barrel warp straightened, and the lens
/// vignette a radial gain over the whole pre-crop frame.
final class LensCorrectionTests: XCTestCase {
    let renderer = Renderer.shared
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func recipe(_ values: [(AdjustmentKind, Double)]) -> Recipe {
        var r = Recipe.neutral
        for (kind, value) in values { r.set(kind, to: value) }
        return r
    }

    private func render(_ r: Recipe, _ source: CIImage, max: Int? = nil) throws -> CGImage {
        try XCTUnwrap(renderer.render(source, recipe: r, maxPixelSize: max)).image
    }

    /// RGBA bytes of a top-down CGImage.
    private func bytes(_ cg: CGImage) -> (UnsafePointer<UInt8>, Int, CFData) {
        let data = cg.dataProvider!.data!
        return (CFDataGetBytePtr(data)!, cg.bytesPerRow, data)
    }

    private func solid(_ v: CGFloat, width: Int, height: Int) -> CIImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return CIImage(cgImage: ctx.makeImage()!)
    }

    // MARK: Model

    func testTheLensKindsComeFirstInTheirOwnSectionAndTravelWithTheLook() {
        let all = AdjustmentKind.allCases
        XCTAssertEqual(Array(all.prefix(3)), [.lensDistortion, .lensVignette, .rotate], "first, before rotate")
        XCTAssertEqual(AdjustmentKind.Section.lens.kinds, [.lensDistortion, .lensVignette])
        XCTAssertEqual(AdjustmentKind.Section.lens.title, "Lens Corrections")
        let sections = AdjustmentKind.Section.allCases
        XCTAssertEqual(sections.firstIndex(of: .lens), sections.firstIndex(of: .effects)! + 1)
        XCTAssertEqual(sections.firstIndex(of: .geometry), sections.firstIndex(of: .lens)! + 1)
        XCTAssertEqual(AdjustmentKind.lensDistortion.label, "Distortion")
        XCTAssertEqual(AdjustmentKind.lensVignette.label, "Vignetting")
        for kind in AdjustmentKind.Section.lens.kinds {
            XCTAssertEqual(kind.range, -100...100); XCTAssertEqual(kind.neutral, 0); XCTAssertNil(kind.group)
            XCTAssertTrue(SyncMask.look.contains(kind)); XCTAssertTrue(SyncMask.grade.contains(kind))
            XCTAssertFalse(LocalMask.kinds.contains(kind), "a mask never carries a lens correction")
        }
        XCTAssertEqual(AdjustmentKind.geometryKinds, [.rotate, .cropLeft, .cropTop, .cropRight, .cropBottom])
        let lens = recipe([(.lensDistortion, 40), (.lensVignette, -25), (.cropLeft, 10)])
        let applied = Preset(name: "Lens", from: lens).apply(to: .neutral)
        XCTAssertEqual(applied.value(of: .lensDistortion), 40)
        XCTAssertEqual(applied.value(of: .lensVignette), -25)
        XCTAssertEqual(applied.value(of: .cropLeft), 0, "a preset still carries no geometry")
        XCTAssertEqual(Recipe.neutral.syncing(.look, from: lens).value(of: .lensDistortion), 40)
        XCTAssertTrue(LensCorrection.isAvailable, "both kernels compile from the Metal source")
    }

    /// Plus corrects barrel (samples nearer the centre), minus pincushion.
    func testTheSignOfEachSlider() {
        XCTAssertLessThan(LensMath.k(for: 100), 0)
        XCTAssertGreaterThan(LensMath.k(for: -100), 0)
        XCTAssertEqual(LensMath.k(for: 0), 0)
        let corner = SIMD2(0.6, 0.8)
        let s = LensMath.scale(k: LensMath.k(for: 100), width: 3000, height: 2000)
        let plain = corner * s
        XCTAssertLessThan(simd_length(LensMath.source(of: corner, k: LensMath.k(for: 100), scale: s)), simd_length(plain),
                          "+ pulls the edges in")
        XCTAssertGreaterThan(LensMath.vignetteGain(value: 100, radius: 1), 1.9)
        XCTAssertLessThan(LensMath.vignetteGain(value: -100, radius: 1), 0.6)
        XCTAssertEqual(LensMath.vignetteGain(value: 100, radius: 0), 1)
    }

    /// The fill zoom: every border point reads at least a pixel inside the
    /// source, and the zoom is tight (one percent more and some border point
    /// reads outside).
    func testTheFillZoomKeepsTheBorderInsideAndIsTight() {
        for (w, h) in [(3000.0, 2000.0), (2000.0, 3000.0), (1000.0, 1000.0), (640.0, 360.0)] {
            for value in [-100.0, -40, -5, 5, 40, 100] {
                let k = LensMath.k(for: value)
                let s = LensMath.scale(k: k, width: w, height: h)
                let hd = hypot(w, h) / 2
                func worstOvershoot(_ s: Double) -> Double {
                    var worst = -Double.infinity
                    for i in 0...400 {
                        let t = Double(i) / 400 * 2 - 1
                        for p in [SIMD2(w / 2, t * h / 2), SIMD2(-w / 2, t * h / 2), SIMD2(t * w / 2, h / 2), SIMD2(t * w / 2, -h / 2)] {
                            let src = LensMath.source(of: p / hd, k: k, scale: s) * hd
                            worst = max(worst, abs(src.x) - w / 2, abs(src.y) - h / 2)
                        }
                    }
                    return worst
                }
                XCTAssertLessThanOrEqual(worstOvershoot(s), -0.99, "\(w)x\(h) at \(value): border inside by a pixel")
                XCTAssertGreaterThan(worstOvershoot(s * 1.01), 0, "\(w)x\(h) at \(value): the zoom is tight")
            }
        }
    }

    // MARK: Render

    func testOutputExtentEqualsInputExtent() {
        for (w, h) in [(1200, 800), (800, 1200), (900, 900)] {
            let src = solid(0.5, width: w, height: h).transformed(by: CGAffineTransform(translationX: 17, y: -9))
            for value in [-100.0, -33, 33, 100] {
                for kind in AdjustmentKind.Section.lens.kinds {
                    let out = renderer.apply(recipe([(kind, value)]), to: src)
                    XCTAssertEqual(out.extent, src.extent, "\(kind) \(value) on \(w)x\(h)")
                }
            }
        }
    }

    /// At ±100 every pixel of the four edges is the source's gray, opaque:
    /// no transparent or black border where the warp would read outside.
    func testNoEmptyPixelAlongTheEdgesAtTheExtremes() throws {
        for (w, h) in [(1200, 800), (700, 1000), (800, 800)] {
            let src = solid(0.5, width: w, height: h)
            let gray = try render(.neutral, src)
            let (g, _, gd) = bytes(gray)
            let expected = Int(g[0])
            withExtendedLifetime(gd) {}
            for value in [-100.0, 100] {
                for extra in [[], [(AdjustmentKind.lensVignette, value)]] {
                    let out = try render(recipe([(.lensDistortion, value)] + extra), src)
                    XCTAssertEqual(out.width, w); XCTAssertEqual(out.height, h)
                    let (p, bpr, data) = bytes(out)
                    var bad: [(Int, Int, Int, Int)] = []
                    var edge: [(Int, Int)] = []
                    for x in 0..<w { edge.append((x, 0)); edge.append((x, h - 1)) }
                    for y in 0..<h { edge.append((0, y)); edge.append((w - 1, y)) }
                    for (x, y) in edge {
                        let i = y * bpr + x * 4
                        let alpha = Int(p[i + 3]), v = Int(p[i])
                        let ok = alpha == 255 && (extra.isEmpty ? abs(v - expected) <= 2 : v > 20)
                        if !ok { bad.append((x, y, v, alpha)) }
                    }
                    withExtendedLifetime(data) {}
                    XCTAssertTrue(bad.isEmpty, "\(w)x\(h) distortion \(value)\(extra.isEmpty ? "" : " + vignetting"): \(bad.count) empty edge pixels, first \(bad.prefix(3))")
                }
            }
        }
    }

    // MARK: Straightening a known barrel warp

    /// Distance from `v` to the nearest line of a grid at `spacing` around 0.
    private func lineDistance(_ v: Double, spacing: Double) -> Double {
        abs(v - (v / spacing).rounded() * spacing)
    }

    /// A grid of 4-px white lines every `spacing` px around the centre, drawn
    /// through the forward barrel warp that slider `value` corrects: the
    /// distorted point of an undistorted `p` is `p (1 + k |p|²)` (k < 0, the
    /// edges pulled in), so each output pixel solves for `p` by Newton's
    /// method and shades by its distance to the nearest line.
    private func barrelGrid(width w: Int, height h: Int, value: Double, spacing: Double) -> CIImage {
        let k = LensMath.k(for: value)
        let hd = hypot(Double(w), Double(h)) / 2
        let cx = Double(w) / 2, cy = Double(h) / 2
        var buf = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let dx = (Double(x) + 0.5 - cx) / hd, dy = (Double(y) + 0.5 - cy) / hd
                let rd = (dx * dx + dy * dy).squareRoot()
                var ru = rd
                for _ in 0..<8 { ru -= (ru * (1 + k * ru * ru) - rd) / (1 + 3 * k * ru * ru) }
                let f = rd > 0 ? ru / rd : 1
                let ux = dx * f * hd, uy = dy * f * hd
                let d = min(lineDistance(ux, spacing: spacing), lineDistance(uy, spacing: spacing))
                let v = UInt8(255 * min(1, max(0, 2.5 - d)))
                let i = (y * w + x) * 4
                buf[i] = v; buf[i + 1] = v; buf[i + 2] = v
            }
        }
        let provider = CGDataProvider(data: Data(buf) as CFData)!
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: sRGB,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return CIImage(cgImage: cg)
    }

    /// The worst distance, in pixels, of each horizontal grid line's
    /// brightness centroid (per column) from where a straight line belongs:
    /// the undistorted line `y_u` drawn at `y_u / s` about the centre. Columns
    /// near a vertical line are skipped.
    private func worstHorizontalDeviation(_ cg: CGImage, spacing: Double, s: Double) -> Double {
        let (p, bpr, data) = bytes(cg)
        defer { withExtendedLifetime(data) {} }
        let w = cg.width, h = cg.height
        let cx = Double(w) / 2, cy = Double(h) / 2
        let step = spacing / s
        var worst = 0.0
        var n = -Int(cy / step)
        while Double(n) * step <= cy {
            let expected = cy + Double(n) * step
            n += 1
            guard expected > 12, expected < Double(h) - 12 else { continue }
            for x in Swift.stride(from: 8, to: w - 8, by: 6) {
                let px = Double(x) + 0.5 - cx
                guard lineDistance(px, spacing: step) > 10 else { continue }
                var sum = 0.0, weight = 0.0
                for y in max(0, Int(expected) - 30)...min(h - 1, Int(expected) + 30) {
                    let v = Double(p[y * bpr + x * 4])
                    sum += (Double(y) + 0.5) * v; weight += v
                }
                guard weight > 0 else { worst = .infinity; continue }
                worst = max(worst, abs(sum / weight - expected))
            }
        }
        return worst
    }

    /// A grid bowed by the barrel warp of slider +50 is straight again
    /// under +50: every horizontal line within one pixel of straight at
    /// 2400 px, and the same at the preview's half size (the warp scales with
    /// the image). Uncorrected, the outer lines are far off.
    func testABarrelBowedGridStraightensUnderTheMatchingDistortion() throws {
        let value = 50.0, spacing = 160.0
        let (w, h) = (2400, 1600)
        let bowed = barrelGrid(width: w, height: h, value: value, spacing: spacing)
        let uncorrected = try render(.neutral, bowed)
        XCTAssertGreaterThan(worstHorizontalDeviation(uncorrected, spacing: spacing, s: 1), 10, "the warp bows the grid")
        let s = LensMath.scale(k: LensMath.k(for: value), width: Double(w), height: Double(h))
        let corrected = try render(recipe([(.lensDistortion, value)]), bowed)
        let full = worstHorizontalDeviation(corrected, spacing: spacing, s: s)
        XCTAssertLessThanOrEqual(full, 1, "straight to within 1 px at 2400 px (worst \(full))")
        let preview = try render(recipe([(.lensDistortion, value)]), bowed, max: 1200)
        XCTAssertEqual(preview.width, 1200)
        let half = worstHorizontalDeviation(preview, spacing: spacing / 2, s: s)
        XCTAssertLessThanOrEqual(half, 1, "the preview's half-size render is straight too (worst \(half))")
    }

    // MARK: Lens vignette

    /// +60 lifts the corners, -60 darkens them, the centre stays within one
    /// level; the gain is over the whole pre-crop frame (a crop shows the
    /// same pixels it shows uncropped), apart from the Effects vignette.
    func testLensVignetteBrightensTheCornersAndLeavesTheCentre() throws {
        let (w, h) = (1200, 800)
        let src = solid(0.4, width: w, height: h)
        let plain = try render(.neutral, src)
        func at(_ cg: CGImage, _ x: Int, _ y: Int) -> Int {
            let (p, bpr, data) = bytes(cg)
            defer { withExtendedLifetime(data) {} }
            return Int(p[y * bpr + x * 4])
        }
        let base = at(plain, w / 2, h / 2)
        let up = try render(recipe([(.lensVignette, 60)]), src)
        let down = try render(recipe([(.lensVignette, -60)]), src)
        for (x, y) in [(w / 2, h / 2), (w / 2 - 1, h / 2 - 1)] {
            XCTAssertLessThanOrEqual(abs(at(up, x, y) - base), 1, "the centre stays")
            XCTAssertLessThanOrEqual(abs(at(down, x, y) - base), 1, "the centre stays")
        }
        for (x, y) in [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)] {
            XCTAssertGreaterThan(at(up, x, y), base + 20, "+ brightens the corner (\(x), \(y))")
            XCTAssertLessThan(at(down, x, y), base - 20, "- darkens the corner (\(x), \(y))")
        }
        // Pre-crop: the crop cuts the vignetted full frame, so its left edge
        // (near the frame's centre column) is barely lifted and its right
        // corners are lifted like the uncropped ones.
        var cropped = recipe([(.lensVignette, 60), (.cropLeft, 40)])
        let cut = try render(cropped, src)
        let offset = w - cut.width
        XCTAssertLessThanOrEqual(abs(at(cut, cut.width - 3, 2) - at(up, w - 3, 2)), 1)
        XCTAssertLessThanOrEqual(abs(at(cut, 2, cut.height / 2) - at(up, offset + 2, h / 2)), 1)
        XCTAssertLessThan(at(cut, 2, cut.height / 2), base + 6, "the crop's left edge sits near the frame's centre")
        // The Effects vignette is post-crop and separate: on the same crop it
        // lifts the crop's own left corners too.
        cropped.set(.lensVignette, to: 0); cropped.set(.vignette, to: 60)
        let effects = try render(cropped, src)
        XCTAssertGreaterThan(at(effects, 2, 2), base + 10, "the Effects vignette follows the crop")
    }
}
