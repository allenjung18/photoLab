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
/// every test sees both neutral and saturated pixels.
func syntheticImage(width: Int, height: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
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
