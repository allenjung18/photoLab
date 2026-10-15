import Foundation
import Accelerate
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// The 256-bin histogram of one rendered frame (the chain's 8-bit output at
/// preview size): red, green, blue and Rec. 709 luma, with the two clipping
/// fractions behind the panel's triangles.
///
/// Clipping is per pixel, on the frame's own 8-bit values: a pixel is
/// **blown** when any channel is ≥ 254 and **crushed** when any channel is
/// ≤ 1 (Lightroom's rule for the triangles: one clipped channel is lost
/// information). The same rule drives `ClippingOverlay`, so the overlay
/// paints exactly the pixels the fractions count. Computed with vImage
/// rather than `CIAreaHistogram`: the bins are exact integer counts that sum
/// to the pixel count, and they bin the displayed sRGB-encoded bytes, not a
/// working-space float.
struct Histogram: Sendable, Equatable {
    static let bins = 256
    /// A triangle lights above this fraction of the frame's pixels.
    static let warningThreshold = 0.001
    /// The 8-bit values that count as clipped.
    static let highlightLevel: UInt8 = 254
    static let shadowLevel: UInt8 = 1

    let red: [Int]
    let green: [Int]
    let blue: [Int]
    let luminance: [Int]
    let pixelCount: Int
    /// Fraction of pixels with any channel ≥ `highlightLevel`.
    let highlightClipping: Double
    /// Fraction of pixels with any channel ≤ `shadowLevel`.
    let shadowClipping: Double
    /// Wall time of the computation, ms.
    let milliseconds: Double

    var highlightsClipped: Bool { highlightClipping > Self.warningThreshold }
    var shadowsClipped: Bool { shadowClipping > Self.warningThreshold }

    // MARK: Computation

    /// The histogram of `frame`. Any CGImage is accepted; one that is not
    /// 8-bit RGBA in memory is redrawn once. Synchronous, a few milliseconds
    /// for a 4 MP frame; call off the main thread.
    static func compute(_ frame: CGImage) -> Histogram? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let pixels = RGBA8Pixels(frame) else { return nil }
        let w = pixels.width, h = pixels.height
        let count = w * h
        guard count > 0 else { return nil }

        var channels = [[vImagePixelCount]](repeating: [vImagePixelCount](repeating: 0, count: bins), count: 4)
        var luma = [vImagePixelCount](repeating: 0, count: bins)
        var codes = [vImagePixelCount](repeating: 0, count: bins)

        let ok = pixels.withBuffer { src -> Bool in
            var src = src
            // Scratch of the frame's size, reused for the luma and the code pass.
            var scratch = vImage_Buffer()
            guard vImageBuffer_Init(&scratch, src.height, src.width, 32, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
            defer { free(scratch.data) }

            // 1. Per-channel histograms (bytes in memory: R G B A).
            guard histogram(of: &src, into: &channels) else { return false }

            // 2. Luma: out[0] = (2126 R + 7152 G + 722 B) / 10000.
            var lumaMatrix = [Int16](repeating: 0, count: 16)
            lumaMatrix[0 * 4 + 0] = 2126
            lumaMatrix[1 * 4 + 0] = 7152
            lumaMatrix[2 * 4 + 0] = 722
            guard vImageMatrixMultiply_ARGB8888(&src, &scratch, lumaMatrix, 10000, nil, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
            var lumaChannels = [[vImagePixelCount]](repeating: [vImagePixelCount](repeating: 0, count: bins), count: 4)
            guard histogram(of: &scratch, into: &lumaChannels) else { return false }
            luma = lumaChannels[0]

            // 3. Clipping codes: each channel maps to 64 (blown), 8 (crushed)
            //    or 0, then the three are summed into byte 0 (≤ 216, no
            //    clamp), so one histogram of that byte gives the per-pixel
            //    "any channel" counts. The sum is decoded with slack: the
            //    matrix multiply lands one below the exact sum (192 → 191, a
            //    32767/32768 fixed-point factor), and the codes are 8 apart.
            var table = [Pixel_8](repeating: 0, count: bins)
            for v in 0..<bins {
                if v >= Int(highlightLevel) { table[v] = 64 } else if v <= Int(shadowLevel) { table[v] = 8 }
            }
            let zero = [Pixel_8](repeating: 0, count: bins)
            guard vImageTableLookUp_ARGB8888(&src, &scratch, table, table, table, zero, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
            var sumMatrix = [Int16](repeating: 0, count: 16)
            sumMatrix[0 * 4 + 0] = 1
            sumMatrix[1 * 4 + 0] = 1
            sumMatrix[2 * 4 + 0] = 1
            guard vImageMatrixMultiply_ARGB8888(&scratch, &scratch, sumMatrix, 1, nil, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
            var codeChannels = [[vImagePixelCount]](repeating: [vImagePixelCount](repeating: 0, count: bins), count: 4)
            guard histogram(of: &scratch, into: &codeChannels) else { return false }
            codes = codeChannels[0]
            return true
        }
        guard ok else { return nil }

        var blown = 0, crushed = 0
        for (code, n) in codes.enumerated() where n > 0 {
            let blownChannels = (code + 4) / 64
            let crushedChannels = ((code + 4) % 64) / 8
            if blownChannels >= 1 { blown += Int(n) }
            if crushedChannels >= 1 { crushed += Int(n) }
        }
        let toInt: ([vImagePixelCount]) -> [Int] = { $0.map { Int($0) } }
        let red: [Int] = toInt(channels[0])
        let green: [Int] = toInt(channels[1])
        let blue: [Int] = toInt(channels[2])
        let luminance: [Int] = toInt(luma)
        let highlight: Double = Double(blown) / Double(count)
        let shadow: Double = Double(crushed) / Double(count)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let ms: Double = Double(t1 - t0) / 1_000_000
        return Histogram(red: red, green: green, blue: blue, luminance: luminance, pixelCount: count,
                         highlightClipping: highlight, shadowClipping: shadow, milliseconds: ms)
    }

    /// Four 256-bin histograms of `buffer`, one per byte position.
    private static func histogram(of buffer: inout vImage_Buffer, into channels: inout [[vImagePixelCount]]) -> Bool {
        let planes = UnsafeMutablePointer<vImagePixelCount>.allocate(capacity: 4 * bins)
        planes.initialize(repeating: 0, count: 4 * bins)
        defer { planes.deallocate() }
        var table: [UnsafeMutablePointer<vImagePixelCount>?] = (0..<4).map { planes + $0 * bins }
        let err = vImageHistogramCalculation_ARGB8888(&buffer, &table, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { return false }
        for c in 0..<4 {
            channels[c] = Array(UnsafeBufferPointer(start: planes + c * bins, count: bins))
        }
        return true
    }
}

/// The bytes of a CGImage as tightly described 8-bit RGBA rows: the frame's
/// own backing store when it already has that layout, else one redraw.
struct RGBA8Pixels {
    let data: CFData
    let width: Int
    let height: Int
    let bytesPerRow: Int

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        if Self.isRGBA8(image), let d = image.dataProvider?.data, CFDataGetLength(d) >= image.bytesPerRow * image.height {
            data = d
            bytesPerRow = image.bytesPerRow
            return
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let redrawn = ctx.makeImage(), let d = redrawn.dataProvider?.data else { return nil }
        data = d
        bytesPerRow = redrawn.bytesPerRow
    }

    /// 8 bits per channel, four channels, R G B A in memory order.
    static func isRGBA8(_ image: CGImage) -> Bool {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32 else { return false }
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        guard order == [] || order == .byteOrder32Big else { return false }
        switch image.alphaInfo {
        case .premultipliedLast, .last, .noneSkipLast: return true
        default: return false
        }
    }

    func withBuffer<T>(_ body: (vImage_Buffer) -> T) -> T {
        let p = UnsafeMutableRawPointer(mutating: CFDataGetBytePtr(data))
        return body(vImage_Buffer(data: p, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow))
    }

    /// The RGBA bytes of pixel (x, y).
    func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let p = CFDataGetBytePtr(data)!
        let i = y * bytesPerRow + x * 4
        return (p[i], p[i + 1], p[i + 2], p[i + 3])
    }
}

/// The clipping warning on the preview (`J`): red over blown pixels, blue
/// over crushed ones, every other pixel the frame's own. One Core Image
/// stage composed over the rendered 8-bit frame, so it reads the same values
/// `Histogram` counts, never a second render of the recipe.
enum ClippingOverlay {
    static let blown = CIColor(red: 1, green: 0, blue: 0)
    static let crushed = CIColor(red: 0, green: 0, blue: 1)

    /// `frame` with the overlay painted over its clipped pixels, in the
    /// frame's color space. Synchronous; call off the main thread.
    static func compose(over frame: CGImage, context: CIContext) -> CGImage? {
        // Untagged in and out: the thresholds sit between the frame's own
        // 8-bit levels, which a color match to the working space would move.
        let source = CIImage(cgImage: frame, options: [.colorSpace: NSNull()])
        let extent = source.extent
        let hi = anyChannelAbove(Double(Histogram.highlightLevel) - 0.5, in: source)
        let lo = anyChannelBelow(Double(Histogram.shadowLevel) + 0.5, in: source)
        let blue = CIImage(color: crushed).cropped(to: extent)
        let red = CIImage(color: blown).cropped(to: extent)
        var out = source
        let b = CIFilter.blendWithMask()
        b.inputImage = blue
        b.backgroundImage = out
        b.maskImage = lo
        out = b.outputImage ?? out
        let r = CIFilter.blendWithMask()
        r.inputImage = red
        r.backgroundImage = out
        r.maskImage = hi
        out = r.outputImage ?? out
        let rect = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        guard let cg = context.createCGImage(out, from: rect, format: .RGBA8, colorSpace: nil) else { return nil }
        guard let space = frame.colorSpace, let tagged = cg.copy(colorSpace: space) else { return cg }
        return tagged
    }

    /// A 0/1 gray mask: 1 where any channel's 8-bit value is above `level`.
    private static func anyChannelAbove(_ level: Double, in image: CIImage) -> CIImage {
        // (v − t) × 4096, clamped to 0…1: a step at t, exact for 8-bit levels.
        let t = CGFloat(level / 255)
        let gain: CGFloat = 4096
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.biasVector = CIVector(x: -t * gain, y: -t * gain, z: -t * gain, w: 1)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = m.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        let anyOf = CIFilter.maximumComponent()
        anyOf.inputImage = clamp.outputImage
        return anyOf.outputImage ?? image
    }

    /// A 0/1 gray mask: 1 where any channel's 8-bit value is below `level`.
    private static func anyChannelBelow(_ level: Double, in image: CIImage) -> CIImage {
        let t = CGFloat(level / 255)
        let gain: CGFloat = 4096
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: -gain, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: -gain, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: -gain, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.biasVector = CIVector(x: t * gain, y: t * gain, z: t * gain, w: 1)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = m.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        let anyOf = CIFilter.maximumComponent()
        anyOf.inputImage = clamp.outputImage
        return anyOf.outputImage ?? image
    }
}
