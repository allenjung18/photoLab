import XCTest
import CoreImage
@testable import PhotoLab

/// `LookMatch`: solving the global values that make a photo measure like a
/// target, through the real chain. Every image is built in memory.
final class LookMatchTests: XCTestCase {
    /// A synthetic photo with a photo's continuous spread, at a size whose
    /// analysis frame is the full 512 px: brightness ramps down the frame,
    /// hue goes once round the wheel across it, and saturation rises from
    /// near grey at the left edge to 0.6 at the right. (`syntheticImage`'s
    /// flat bands would put whole bands on a grade-range boundary, so a
    /// one-step move could jump the cost.)
    private func master() -> CIImage {
        let w = 768, h = 512
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let hue = Double(x) / Double(w) * 6
                let sat = 0.05 + 0.55 * Double(x) / Double(w - 1)
                let v = 0.06 + 0.9 * Double(y) / Double(h - 1)
                // HSV to RGB.
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
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// A known look: warm, contrasty, desaturated.
    private var knownLook: Recipe {
        var r = Recipe.neutral
        r.set(.temperature, to: 40)
        r.set(.contrast, to: 35)
        r.set(.saturation, to: -45)
        return r
    }

    private func describe(_ v: [AdjustmentKind: Double]) -> String {
        LookMatch.kinds.map { "\($0.rawValue)=\(v[$0]!)" }.joined(separator: " ")
    }

    /// The photo rendered through the known look is the target; solved from
    /// the neutral photo, the distance falls by at least 80% and the values
    /// point the way the look went: warmer, more contrast, less saturation.
    func testSolvesAKnownLookWarmContrastyDesaturated() throws {
        let m = master()
        let target = try XCTUnwrap(ImageStats.of(master: m, recipe: knownLook))
        let before = try XCTUnwrap(ImageStats.of(master: m, recipe: .neutral))
        let values = try XCTUnwrap(LookMatch.values(target: target, master: m, recipe: .neutral))
        let after = try XCTUnwrap(ImageStats.of(master: m, recipe: LookMatch.applying(values, to: .neutral)))

        // The yardstick is the standard distance, whatever the solver weighs.
        let d0 = target.distance(to: before, weights: .standard)
        let d1 = target.distance(to: after, weights: .standard)
        let warmth = { (s: ImageStats) in s.mean.red - s.mean.blue }
        print("LOOKMATCH known look: distance \(d0) -> \(d1); warmth \(warmth(before)) -> \(warmth(after)) of \(warmth(target)); \(describe(values))")
        XCTAssertLessThanOrEqual(d1, 0.2 * d0, "the distance falls by at least 80%")
        XCTAssertEqual(warmth(after), warmth(target), accuracy: 0.25 * abs(warmth(target) - warmth(before)),
                       "the matched frame's warmth (mean red − blue) within a quarter of the cast of the target's")
        XCTAssertGreaterThan(values[.temperature]!, 0, "temperature solved warm")
        XCTAssertGreaterThan(values[.contrast]!, 0, "contrast solved up")
        XCTAssertLessThan(values[.saturation]!, 0, "saturation solved down")
        for kind in LookMatch.kinds {
            XCTAssertTrue(kind.range.contains(values[kind]!), "\(kind) inside its range")
            let s = LookMatch.step(of: kind)
            XCTAssertEqual(values[kind]! / s, (values[kind]! / s).rounded(), accuracy: 1e-9, "\(kind) on its slider grid")
            let perUnit = (1 / s).rounded()
            XCTAssertEqual(values[kind]!, (values[kind]! * perUnit).rounded() / perUnit,
                           "\(kind) exactly as AutoTone rounds it, no float noise")
        }
    }

    /// The photo as its own target: every value within one step of neutral.
    func testOwnTargetStaysNeutral() throws {
        let m = master()
        let target = try XCTUnwrap(ImageStats.of(master: m, recipe: .neutral))
        let values = try XCTUnwrap(LookMatch.values(target: target, master: m, recipe: .neutral))
        for kind in LookMatch.kinds {
            XCTAssertEqual(values[kind]!, kind.neutral, accuracy: LookMatch.step(of: kind) + 1e-9,
                           "\(kind) within one step of neutral")
        }
    }

    /// Idempotent: solving twice gives the same values, and solving again
    /// from the matched recipe (its twelve set) gives them too, since the
    /// search starts from `base`, which other kinds pass through untouched.
    func testRunningTwiceGivesTheSameValues() throws {
        let m = master()
        let target = try XCTUnwrap(ImageStats.of(master: m, recipe: knownLook))
        var start = Recipe.neutral
        start.set(.clarity, to: 10)
        let first = try XCTUnwrap(LookMatch.values(target: target, master: m, recipe: start))
        let matched = LookMatch.applying(first, to: start)
        let second = try XCTUnwrap(LookMatch.values(target: target, master: m, recipe: matched))
        XCTAssertEqual(first, second)
        let again = try XCTUnwrap(LookMatch.values(target: target, master: m, recipe: start))
        XCTAssertEqual(first, again, "the same input solves to the same values")
        XCTAssertEqual(LookMatch.base(matched), LookMatch.base(start))
        XCTAssertEqual(matched.value(of: .clarity), 10, "a kind outside the twelve is kept")
    }

    /// `base`, `applying` and `mask` cover exactly the twelve kinds.
    func testBaseApplyingAndMaskCoverTheKinds() {
        XCTAssertEqual(LookMatch.kinds.count, 12)
        XCTAssertEqual(LookMatch.mask.kinds, Set(LookMatch.kinds))
        var r = Recipe.neutral
        for kind in LookMatch.kinds { r.set(kind, to: 5) }
        r.setEnabled(.contrast, false)
        r.set(.highlights, to: -20)
        let b = LookMatch.base(r)
        for kind in LookMatch.kinds {
            XCTAssertEqual(b.value(of: kind), kind.neutral)
            XCTAssertTrue(b.isEnabled(kind))
        }
        XCTAssertEqual(b.value(of: .highlights), -20)
        let a = LookMatch.applying([.exposure: 0.35], to: b)
        XCTAssertEqual(a.value(of: .exposure), 0.35)
        XCTAssertEqual(a.value(of: .contrast), 0)
    }

    /// A whole solve of a 512 px analysis frame finishes in under 4 s, best
    /// of up to three runs (`assertFrameBudget`).
    func testWholeSolveUnderBudget() throws {
        let m = master()
        let target = try XCTUnwrap(ImageStats.of(master: m, recipe: knownLook))
        var load = loadAverage()
        var best = Double.infinity
        var attempts = 0
        repeat {
            attempts += 1
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = LookMatch.values(target: target, master: m, recipe: .neutral)
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            load = max(load, loadAverage())
        } while best >= frameBudgetBound(LookMatchTests.budget, load: load) && attempts < 3
        print(String(format: "BENCH-LOOKMATCH 768×512: best %.0f ms of %d, load %.2f", best, attempts, load))
        try assertFrameBudget(best, bound: LookMatchTests.budget, load: load, "a whole LookMatch solve")
    }

    static let budget = 4000.0
}
