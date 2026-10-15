import XCTest
import CoreImage
import ImageIO
@testable import PhotoLab

/// Mean RGB of a CGImage (RGBA8), sampling every `stride`-th pixel.
func meanRGB(_ cg: CGImage, stride: Int = 1) -> (r: Double, g: Double, b: Double) {
    guard let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return (0, 0, 0) }
    let bpr = cg.bytesPerRow, w = cg.width, h = cg.height
    var r = 0.0, g = 0.0, b = 0.0, n = 0.0
    var y = 0
    while y < h {
        var x = 0
        while x < w {
            let i = y * bpr + x * 4
            r += Double(p[i]); g += Double(p[i + 1]); b += Double(p[i + 2]); n += 1
            x += stride
        }
        y += stride
    }
    return (r / n, g / n, b / n)
}

/// Largest per-channel difference between two same-sized RGBA8 images.
func maxDiff(_ a: CGImage, _ b: CGImage) -> Int {
    guard let da = a.dataProvider?.data, let pa = CFDataGetBytePtr(da),
          let db = b.dataProvider?.data, let pb = CFDataGetBytePtr(db),
          a.width == b.width, a.height == b.height else { return Int.max }
    var worst = 0
    for y in 0..<a.height {
        for x in 0..<a.width {
            for c in 0..<3 {
                let d = abs(Int(pa[y * a.bytesPerRow + x * 4 + c]) - Int(pb[y * b.bytesPerRow + x * 4 + c]))
                if d > worst { worst = d }
            }
        }
    }
    return worst
}

/// A synthetic photo: a horizontal luminance ramp with colored bands, so
/// every test sees both neutral and saturated pixels. `space` is the color
/// space the bitmap is drawn in and tagged with (sRGB unless asked; Display
/// P3 for a wide-gamut source).
func syntheticImage(width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let colors = [CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1),
                  CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
    let bands: [(CGFloat, CGFloat, CGFloat)] = [(0.8, 0.2, 0.2), (0.2, 0.8, 0.2), (0.2, 0.2, 0.8), (0.7, 0.6, 0.2)]
    let bandH = CGFloat(height) / 8
    for (i, c) in bands.enumerated() {
        ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: CGFloat(i) * bandH, width: CGFloat(width), height: bandH * 0.8))
    }
    return ctx.makeImage()!
}

/// The 24 MP photo the timing tests decode: `PHOTOLAB_BENCH_IMAGE` when set
/// (a real file), else a synthetic 6000×4000 JPEG written once to the temp
/// directory.
func bench24MPImageURL() throws -> URL {
    if let path = ProcessInfo.processInfo.environment["PHOTOLAB_BENCH_IMAGE"] {
        return URL(fileURLWithPath: path)
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("photolab-bench-24mp.jpg")
    if !FileManager.default.fileExists(atPath: url.path) {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, syntheticImage(width: 6000, height: 4000), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
    return url
}

// MARK: - Timed gates under load

/// `bound` scaled by the load above `quietLoad` (1× at or under it).
func frameBudgetBound(_ bound: Double, load: Double, quietLoad: Double = 4) -> Double {
    bound * (load.isNaN ? 1 : max(1, load / quietLoad))
}

/// The 1-minute load average, or NaN when it cannot be read.
func loadAverage() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) >= 1 ? loads[0] : .nan
}

/// The verdict of a timed render gate at the current load. `bound` is the
/// gate as written and holds up to `quietLoad` (a clean box idles at 2–4;
/// on 2026-10-15 every red of the 16 ms gate came at a 1-minute load of
/// 7.3 or more from sibling builds, every pass at 5.3 or less, and nothing
/// in the render path had changed). Above `quietLoad` the bound scales with
/// `load / quietLoad`, so a sibling build cannot fail the suite on load
/// alone; above `skipLoad` (3× quiet, where the scaled bound would be three
/// frames) a miss is an `XCTSkip` that prints the numbers, never a red: the
/// box cannot measure a frame budget then. A pass at any load stands.
/// Returns the bound used. A timed test measures up to three times and
/// gates the best (`frameBudgetBound` is the bound to retry against): a
/// sibling build's compile burst is seconds long and rarely covers three
/// sweeps, while a slower chain misses all three.
@discardableResult
func assertFrameBudget(_ measured: Double, bound: Double, load: Double, _ what: String,
                       quietLoad: Double = 4, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
    let scaled = frameBudgetBound(bound, load: load, quietLoad: quietLoad)
    guard measured >= scaled else { return scaled }
    let message = String(format: "%@: %.1f ms against %.0f ms (scaled from %.0f at load %.2f)", what, measured, scaled, bound, load)
    if load > quietLoad * 3 {
        throw XCTSkip("load \(String(format: "%.2f", load)) is above \(quietLoad * 3): the frame budget cannot be measured on this box now — \(message)")
    }
    XCTFail(message, file: file, line: line)
    return scaled
}
