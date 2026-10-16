import Foundation
import CryptoKit
import ImageIO
import Compression

// MARK: - Local adjustments: the data model

/// A point in the SOURCE frame: the photo as decoded, before the recipe's
/// rotate and crop, origin top-left, `x` a fraction of the width and `y` of
/// the height (0...1 spans the photo; a gradient's end may lie outside it).
/// Pinning masks to the source is what keeps one on the same pixels under
/// any later crop, rotate, preview size or 1:1 window.
struct MaskPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

/// The two radii of a radial mask's ellipse, each a fraction of the source's
/// LONG side (not of its own axis), so equal radii are a circle on any
/// aspect ratio.
struct MaskRadii: Codable, Hashable {
    var x: Double
    var y: Double
}

/// One brush stroke: a path through source-frame points, painted (or, with
/// `erase`, removed) at `radius` (a fraction of the source long side), with
/// a soft edge `feather` (0 hard ... 1 all soft) and a `flow` (0...1, how
/// much one pass lays down).
struct BrushStroke: Codable, Hashable {
    var points: [MaskPoint]
    var radius: Double
    var feather: Double
    var flow: Double
    var erase: Bool = false
}

/// Where a local adjustment applies. Geometry is in the source frame
/// (`MaskPoint`, `MaskRadii`), never the view or the cropped frame.
enum MaskShape: Hashable {
    /// A graduated filter: full effect at `start`, fading to none at `end`,
    /// constant along the perpendicular.
    case linear(start: MaskPoint, end: MaskPoint)
    /// An ellipse at `center` with `radii`, turned by `angle` (degrees);
    /// full effect inside the inner ellipse (radii x (1 - feather)), easing
    /// to none at the outer one. `feather` is 0...1.
    case radial(center: MaskPoint, radii: MaskRadii, angle: Double, feather: Double)
    /// Painted strokes, in order (a later erase removes an earlier paint).
    case brush([BrushStroke])
    /// An automatic mask: a detected bitmap over the source frame, refined
    /// by brush strokes on top (`AutoMask`).
    case auto(AutoMask)
}

/// What an automatic mask selects. The detection that fills the bitmap
/// lives elsewhere; the kind names it in the list and in the sidecar.
enum AutoMaskKind: String, Codable, Hashable, CaseIterable {
    case subject, person, sky
}

/// An automatic mask: `bitmap` (the detected weights over the whole source
/// frame) with `strokes` applied over it by `BrushRaster`'s rule (paint adds,
/// clipped at 1; erase multiplies down), so a detection can be refined by hand.
struct AutoMask: Codable, Hashable {
    var kind: AutoMaskKind
    var bitmap: MaskBitmap
    var strokes: [BrushStroke] = []

    init(kind: AutoMaskKind, bitmap: MaskBitmap, strokes: [BrushStroke] = []) {
        self.kind = kind
        self.bitmap = bitmap
        self.strokes = strokes
    }
}

/// An automatic mask's weights: an 8-bit grey raster over the SOURCE frame
/// (row 0 the top, 255 = weight 1), stretched onto the source whatever its
/// own size, so it lands on the same pixels under any crop, rotate, preview
/// size or 1:1 window (`MaskRender` places it as it places a brush raster).
///
/// It is stored in the recipe as an 8-bit grey PNG (`png`, base64 in the
/// sidecar JSON) and identified by `digest`, the SHA-256 of its size and
/// PIXELS (never of the PNG bytes): two bitmaps are equal, and hash alike,
/// when their pixels are, however the PNG was encoded. Recipes compare masks
/// on every edit, so equality costs a digest compare, not a pixel walk.
struct MaskBitmap: Hashable, @unchecked Sendable {
    /// The largest long side kept; a larger raster is box-filtered down to
    /// it (`init(gray:width:height:)`), aspect kept. A 2048 px soft mask is a
    /// PNG of tens of kilobytes; the source's own resolution would be MBs in
    /// every sidecar.
    static let maxLongSide = 2048

    let width: Int
    let height: Int
    /// One byte per pixel, rows top-down, `width * height` bytes.
    let pixels: Data
    /// The PNG the sidecar carries (8-bit grey, no alpha).
    let png: Data
    /// Hex SHA-256 of the width, height and pixels.
    let digest: String
    /// True when every pixel is 0: the mask selects nothing.
    let isBlank: Bool

    /// A 1x1 all-zero bitmap: an automatic mask with nothing detected yet.
    static let blank = MaskBitmap(gray: [0], width: 1, height: 1)

    /// A bitmap of `gray` (`width * height` bytes, rows top-down; missing
    /// bytes read 0, extra are ignored), box-filtered down to `maxLongSide`
    /// on the long side when larger. Sizes below 1 become 1.
    init(gray: [UInt8], width: Int, height: Int) {
        let w = max(1, width), h = max(1, height)
        var bytes = gray
        if bytes.count != w * h {
            bytes = Array(bytes.prefix(w * h)) + [UInt8](repeating: 0, count: max(0, w * h - bytes.count))
        }
        let size = Self.fittedSize(width: w, height: h)
        if size.width != w || size.height != h {
            bytes = Self.downscale(bytes, width: w, height: h, to: size.width, size.height)
        }
        self.init(validated: Data(bytes), width: size.width, height: size.height,
                  png: Self.encodePNG(bytes, width: size.width, height: size.height))
    }

    private init(validated pixels: Data, width: Int, height: Int, png: Data) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.png = png
        self.digest = Self.digest(of: pixels, width: width, height: height)
        self.isBlank = !pixels.contains { $0 != 0 }
    }

    /// The size `width` x `height` is kept at: itself, or scaled down to
    /// `maxLongSide` on the long side (rounded, at least 1).
    static func fittedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let long = max(width, height)
        guard long > maxLongSide else { return (width, height) }
        let s = Double(maxLongSide) / Double(long)
        return (max(1, Int((Double(width) * s).rounded())), max(1, Int((Double(height) * s).rounded())))
    }

    /// The weight at the centre of pixel (x, y), 0...1.
    func value(x: Int, y: Int) -> Double {
        let xi = min(max(x, 0), width - 1), yi = min(max(y, 0), height - 1)
        return Double(pixels[pixels.startIndex + yi * width + xi]) / 255
    }

    /// The weight at `point` (source frame fractions, top-left): bilinear
    /// between pixel centres (pixel i's centre at (i + 0.5) / width), the
    /// edge pixels held beyond the outer centres.
    func weight(at point: MaskPoint) -> Double {
        let fx = point.x * Double(width) - 0.5, fy = point.y * Double(height) - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let top = value(x: x0, y: y0) * (1 - tx) + value(x: x0 + 1, y: y0) * tx
        let bottom = value(x: x0, y: y0 + 1) * (1 - tx) + value(x: x0 + 1, y: y0 + 1) * tx
        return top * (1 - ty) + bottom * ty
    }

    /// The bitmap at `width` x `height`: each pixel `weight(at:)` its
    /// centre, rounded to 8 bits.
    func resampled(width w: Int, height h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(0, w * h))
        for y in 0..<h {
            for x in 0..<w {
                let v = weight(at: MaskPoint(x: (Double(x) + 0.5) / Double(w), y: (Double(y) + 0.5) / Double(h)))
                out[y * w + x] = UInt8(min(max((v * 255).rounded(), 0), 255))
            }
        }
        return out
    }

    static func == (a: MaskBitmap, b: MaskBitmap) -> Bool {
        a.width == b.width && a.height == b.height && a.digest == b.digest
    }

    func hash(into hasher: inout Hasher) { hasher.combine(digest) }

    static func digest(of pixels: Data, width: Int, height: Int) -> String {
        var h = SHA256()
        withUnsafeBytes(of: UInt32(width).littleEndian) { h.update(bufferPointer: $0) }
        withUnsafeBytes(of: UInt32(height).littleEndian) { h.update(bufferPointer: $0) }
        h.update(data: pixels)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// An exact box filter: each output pixel the area-weighted mean of the
    /// source pixels it covers (separable, rows then columns), rounded.
    static func downscale(_ src: [UInt8], width: Int, height: Int, to nw: Int, _ nh: Int) -> [UInt8] {
        // Per output index, the source indices it overlaps and their weights.
        func taps(_ n: Int, _ m: Int) -> [[(Int, Float)]] {
            let s = Double(n) / Double(m)
            return (0..<m).map { d in
                let a = Double(d) * s, b = Double(d + 1) * s
                var out: [(Int, Float)] = []
                var i = Int(a.rounded(.down))
                while Double(i) < b, i < n {
                    let w = min(b, Double(i + 1)) - max(a, Double(i))
                    if w > 0 { out.append((i, Float(w / s))) }
                    i += 1
                }
                return out
            }
        }
        let tx = taps(width, nw), ty = taps(height, nh)
        var mid = [Float](repeating: 0, count: nw * height)
        src.withUnsafeBufferPointer { s in
            mid.withUnsafeMutableBufferPointer { m in
                for y in 0..<height {
                    let row = y * width, orow = y * nw
                    for x in 0..<nw {
                        var v: Float = 0
                        for (i, w) in tx[x] { v += Float(s[row + i]) * w }
                        m[orow + x] = v
                    }
                }
            }
        }
        var out = [UInt8](repeating: 0, count: nw * nh)
        mid.withUnsafeBufferPointer { m in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<nh {
                    let orow = y * nw
                    for x in 0..<nw {
                        var v: Float = 0
                        for (j, w) in ty[y] { v += m[j * nw + x] * w }
                        o[orow + x] = UInt8(min(max(v.rounded(), 0), 255))
                    }
                }
            }
        }
        return out
    }

    /// `bytes` as an 8-bit grey PNG (no alpha, no colour profile: the
    /// values are weights), written here rather than by ImageIO: each row
    /// takes the PNG filter whose output has the smallest sum of magnitudes
    /// (the libpng heuristic), and the rows are deflated by the Compression
    /// framework. ImageIO's PNG encoder wrote a soft-edged 2048 px disc at
    /// 193 KB, 257 KB once base64 in a sidecar; this one keeps that sidecar
    /// under 200 KB (`AutoMaskModelTests`).
    static func encodePNG(_ bytes: [UInt8], width: Int, height: Int) -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity((width + 1) * height)
        var prev = [UInt8](repeating: 0, count: width)
        var cand = [[UInt8]](repeating: [UInt8](repeating: 0, count: width), count: 5)
        bytes.withUnsafeBufferPointer { src in
            for y in 0..<height {
                let row = Array(src[(y * width)..<((y + 1) * width)])
                var best = 0, bestCost = Int.max
                for f in 0..<5 {
                    var cost = 0
                    for x in 0..<width {
                        let a = x > 0 ? Int(row[x - 1]) : 0, b = Int(prev[x]), c = x > 0 ? Int(prev[x - 1]) : 0
                        let pred: Int
                        switch f {
                        case 0: pred = 0
                        case 1: pred = a
                        case 2: pred = b
                        case 3: pred = (a + b) / 2
                        default:
                            let p = a + b - c, pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                            pred = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                        }
                        let v = UInt8(truncatingIfNeeded: Int(row[x]) - pred)
                        cand[f][x] = v
                        cost += v < 128 ? Int(v) : 256 - Int(v)
                    }
                    if cost < bestCost { bestCost = cost; best = f }
                }
                raw.append(UInt8(best))
                raw.append(contentsOf: cand[best])
                prev = row
            }
        }
        // zlib: header, raw deflate, Adler-32 (big-endian).
        var deflated = [UInt8](repeating: 0, count: raw.count + raw.count / 8 + 1024)
        let n = compression_encode_buffer(&deflated, deflated.count, raw, raw.count, nil, COMPRESSION_ZLIB)
        guard n > 0 else { return Data() }
        var zlib: [UInt8] = [0x78, 0x9C]
        zlib.append(contentsOf: deflated[0..<n])
        var s1: UInt32 = 1, s2: UInt32 = 0
        for chunk in stride(from: 0, to: raw.count, by: 5552) {
            for v in raw[chunk..<min(chunk + 5552, raw.count)] { s1 &+= UInt32(v); s2 &+= s1 }
            s1 %= 65521
            s2 %= 65521
        }
        zlib.append(contentsOf: Self.bigEndian((s2 << 16) | s1))

        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        func chunk(_ type: String, _ body: [UInt8]) {
            let t = Array(type.utf8)
            out.append(contentsOf: Self.bigEndian(UInt32(body.count)))
            out.append(contentsOf: t)
            out.append(contentsOf: body)
            out.append(contentsOf: Self.bigEndian(Self.crc32(t + body)))
        }
        // IHDR: size, bit depth 8, colour type 0 (grey), deflate, adaptive filters, no interlace.
        chunk("IHDR", Self.bigEndian(UInt32(width)) + Self.bigEndian(UInt32(height)) + [8, 0, 0, 0, 0])
        chunk("IDAT", zlib)
        chunk("IEND", [])
        return Data(out)
    }

    private static func bigEndian(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// The pixels of an 8-bit grey PNG, rows top-down, read as stored (no
    /// colour matching); nil for anything else or a size other than
    /// `width` x `height`.
    static func decodePNG(_ png: Data, width: Int, height: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height,
              image.bitsPerComponent == 8, image.bitsPerPixel == 8,
              image.colorSpace?.model == .monochrome,
              let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data)
        else { return nil }
        let rowBytes = image.bytesPerRow
        guard rowBytes >= width, CFDataGetLength(data) >= rowBytes * (height - 1) + width else { return nil }
        var out = Data(count: width * height)
        out.withUnsafeMutableBytes { o in
            let dst = o.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width { dst[y * width + x] = base[y * rowBytes + x] }
            }
        }
        return out
    }
}

/// The sidecar form: `{"width": …, "height": …, "png": "<base64>"}`. The
/// digest is not stored; it is taken from the decoded pixels, so a file
/// cannot claim another bitmap's identity.
extension MaskBitmap: Codable {
    private enum CodingKeys: String, CodingKey { case width, height, png }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let width = try c.decode(Int.self, forKey: .width), height = try c.decode(Int.self, forKey: .height)
        let png = try c.decode(Data.self, forKey: .png)
        guard width > 0, height > 0, max(width, height) <= Self.maxLongSide,
              let pixels = Self.decodePNG(png, width: width, height: height) else {
            throw DecodingError.dataCorruptedError(forKey: .png, in: c,
                                                   debugDescription: "not an 8-bit grey PNG of \(width)x\(height) within \(Self.maxLongSide) px")
        }
        self.init(validated: pixels, width: width, height: height, png: png)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(png, forKey: .png)
    }
}

/// The sidecar form of a shape: one object with a `type` and that type's
/// fields (`{"type": "linear", "start": …, "end": …}`), so the file reads
/// plainly and a new shape is a new `type`.
extension MaskShape: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, start, end, center, radii, angle, feather, strokes, kind, bitmap
    }

    private enum Kind: String, Codable { case linear, radial, brush, auto }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .linear:
            self = .linear(start: try c.decode(MaskPoint.self, forKey: .start),
                           end: try c.decode(MaskPoint.self, forKey: .end))
        case .radial:
            self = .radial(center: try c.decode(MaskPoint.self, forKey: .center),
                           radii: try c.decode(MaskRadii.self, forKey: .radii),
                           angle: try c.decode(Double.self, forKey: .angle),
                           feather: try c.decode(Double.self, forKey: .feather))
        case .brush:
            self = .brush(try c.decode([BrushStroke].self, forKey: .strokes))
        case .auto:
            self = .auto(AutoMask(kind: try c.decode(AutoMaskKind.self, forKey: .kind),
                                  bitmap: try c.decode(MaskBitmap.self, forKey: .bitmap),
                                  strokes: try c.decodeIfPresent([BrushStroke].self, forKey: .strokes) ?? []))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .linear(let start, let end):
            try c.encode(Kind.linear, forKey: .type)
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
        case .radial(let center, let radii, let angle, let feather):
            try c.encode(Kind.radial, forKey: .type)
            try c.encode(center, forKey: .center)
            try c.encode(radii, forKey: .radii)
            try c.encode(angle, forKey: .angle)
            try c.encode(feather, forKey: .feather)
        case .brush(let strokes):
            try c.encode(Kind.brush, forKey: .type)
            try c.encode(strokes, forKey: .strokes)
        case .auto(let auto):
            try c.encode(Kind.auto, forKey: .type)
            try c.encode(auto.kind, forKey: .kind)
            try c.encode(auto.bitmap, forKey: .bitmap)
            try c.encode(auto.strokes, forKey: .strokes)
        }
    }
}

/// One local adjustment: a shape and the adjustments it applies where the
/// shape's weight is above zero. It holds only `LocalMask.kinds`; the
/// renderer applies them through the global chain blended by the mask.
/// Masks live in `Recipe.masks`, so undo, the sidecar, Photos adjustment
/// data and `Library.setRecipe` (the one writer) carry them with no path of
/// their own.
struct LocalMask: Codable, Hashable, Identifiable {
    /// The kinds a mask can carry, in chain order. An explicit list: a new
    /// global kind does not become a local one by being added to
    /// `AdjustmentKind`.
    static let kinds: [AdjustmentKind] =
        [.exposure, .temperature, .tint, .contrast, .highlights, .shadows, .saturation]
    private static let kindSet = Set(kinds)

    var id: UUID
    var shape: MaskShape
    /// Only kinds in `LocalMask.kinds`; a missing kind reads as neutral.
    var adjustments: [Adjustment]
    var enabled: Bool
    /// Applies where the shape does not (weight 1 - w).
    var inverted: Bool

    /// A mask over `shape`; adjustments outside `LocalMask.kinds` are dropped.
    init(id: UUID = UUID(), shape: MaskShape, adjustments: [Adjustment] = [],
         enabled: Bool = true, inverted: Bool = false) {
        self.id = id
        self.shape = shape
        self.adjustments = adjustments.filter { Self.kindSet.contains($0.kind) }
        self.enabled = enabled
        self.inverted = inverted
    }

    private enum CodingKeys: String, CodingKey { case id, shape, adjustments, enabled, inverted }

    /// A file's mask, with any kind outside `LocalMask.kinds` dropped as
    /// `init` drops it, so a hand-edited sidecar cannot smuggle crop or HSL
    /// into a mask.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  shape: try c.decode(MaskShape.self, forKey: .shape),
                  adjustments: try c.decodeIfPresent([Adjustment].self, forKey: .adjustments) ?? [],
                  enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                  inverted: try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? false)
    }

    static func allows(_ kind: AdjustmentKind) -> Bool { kindSet.contains(kind) }

    /// The entry for `kind` (neutral when absent). Setting a kind outside
    /// `LocalMask.kinds` is ignored.
    subscript(kind: AdjustmentKind) -> Adjustment {
        get { adjustments.first { $0.kind == kind } ?? Adjustment(kind: kind, value: kind.neutral) }
        set {
            guard Self.allows(kind) else { return }
            if let i = adjustments.firstIndex(where: { $0.kind == kind }) {
                adjustments[i] = newValue
            } else {
                adjustments.append(newValue)
            }
        }
    }

    func value(of kind: AdjustmentKind) -> Double { self[kind].value }
    mutating func set(_ kind: AdjustmentKind, to value: Double) { self[kind].value = value }

    /// The canonical form: every kind of `LocalMask.kinds` once, in that
    /// order, so two masks that render the same compare equal whatever order
    /// a sidecar listed them in.
    var normalized: LocalMask {
        var out = self
        out.adjustments = Self.kinds.map { self[$0] }
        return out
    }

    /// True when rendering this mask would change nothing: switched off, or
    /// every adjustment a no-op (whatever its shape or inversion).
    var isNoop: Bool { !enabled || adjustments.allSatisfy(\.isNoop) }

    /// The render-side recipe of the mask: its adjustments as a global
    /// recipe, which the renderer applies under the mask.
    var recipe: Recipe { Recipe(adjustments: adjustments) }
}

// MARK: - Mask weights: the maths the renderer draws

/// The weight of a mask at a point, 0 (no effect) ... 1 (full effect): the
/// pure statement of what `MaskRender` draws with Core Image, so the shapes
/// are testable without a render and the on-canvas handles (a later chunk)
/// can read them. Distances are measured in pixels of the source, scaled by
/// its long side, so a perpendicular is perpendicular on screen and equal
/// radii are a circle on any aspect ratio; hence the source `size`.
enum MaskMath {
    /// `mask`'s weight at `point` (source frame) over a source of `size`
    /// pixels: the shape's weight, or 1 minus it when `inverted`; a
    /// disabled mask still has its weight (the renderer skips it).
    static func weight(of mask: LocalMask, at point: MaskPoint, in size: CGSize) -> Double {
        let w = weight(of: mask.shape, at: point, in: size)
        return mask.inverted ? 1 - w : w
    }

    /// The shape's own weight (no inversion).
    /// - linear: 1 at and before `start`, 0 at and beyond `end`, a straight
    ///   ramp between, constant along the perpendicular to start -> end. A
    ///   zero-length gradient weighs 0.
    /// - radial: 1 inside the inner ellipse (radii x (1 - feather)), 0 at
    ///   and outside the outer one (radii), a straight ramp in normalised
    ///   radius between; the ellipse is turned clockwise on screen by
    ///   `angle` degrees. A zero radius weighs 0.
    /// - brush: `BrushRaster.weight(of:at:in:)` (dabs along each stroke,
    ///   flow and feather, paint adding and erase multiplying down).
    /// - auto: the bitmap sampled bilinearly (`MaskBitmap.weight(at:)`),
    ///   then its strokes applied over that by the brush's rule.
    static func weight(of shape: MaskShape, at point: MaskPoint, in size: CGSize) -> Double {
        let long = max(Double(size.width), Double(size.height))
        guard long > 0 else { return 0 }
        let sx = Double(size.width) / long, sy = Double(size.height) / long
        let px = point.x * sx, py = point.y * sy
        switch shape {
        case .linear(let start, let end):
            let ax = start.x * sx, ay = start.y * sy
            let dx = end.x * sx - ax, dy = end.y * sy - ay
            let len2 = dx * dx + dy * dy
            guard len2 > 0 else { return 0 }
            let t = ((px - ax) * dx + (py - ay) * dy) / len2
            return min(max(1 - t, 0), 1)
        case .radial(let center, let radii, let angle, let feather):
            guard radii.x > 0, radii.y > 0 else { return 0 }
            let d = ellipseRadius(px - center.x * sx, py - center.y * sy, radii: radii, angle: angle)
            let f = min(max(feather, 0), 1)
            if d >= 1 { return 0 }
            if d <= 1 - f { return 1 }
            return (1 - d) / f
        case .brush(let strokes):
            return BrushRaster.weight(of: strokes, at: point, in: size)
        case .auto(let auto):
            return BrushRaster.weight(of: auto.strokes, at: point, in: size, over: auto.bitmap.weight(at: point))
        }
    }

    /// The normalised radius of offset (dx, dy) (long-side units, y down)
    /// in an ellipse of `radii` turned clockwise on screen by `angle`
    /// degrees: 1 on the ellipse, below 1 inside.
    static func ellipseRadius(_ dx: Double, _ dy: Double, radii: MaskRadii, angle: Double) -> Double {
        let a = angle * .pi / 180
        // Into the ellipse's own axes: turn the offset back by `angle`.
        let u = dx * cos(a) + dy * sin(a)
        let v = -dx * sin(a) + dy * cos(a)
        return ((u / radii.x) * (u / radii.x) + (v / radii.y) * (v / radii.y)).squareRoot()
    }
}

// MARK: - View to source: where a mask point sits on the loupe

extension MaskMath {
    /// Where the loupe draws the rendered frame (after rotate and crop), in
    /// view points: scaled into a fit rect (`ZoomMath.fitRect`), or the 1:1
    /// window, `region` pixels of a frame `frame` pixels in size drawn
    /// unscaled at `displayScale` and centred in `pane` (as
    /// `ZoomMath.point(forClick:region:frame:pane:displayScale:)` reads it,
    /// without its snap to a pixel centre).
    enum Viewport: Equatable {
        case fit(CGRect)
        case window(region: CGRect, frame: CGSize, pane: CGSize, displayScale: CGFloat)

        /// A point normalised in the rendered frame (0...1, top-left) to view points.
        func view(_ f: CGPoint) -> CGPoint {
            switch self {
            case .fit(let r):
                return CGPoint(x: r.minX + f.x * r.width, y: r.minY + f.y * r.height)
            case .window(let region, let frame, let pane, let scale):
                let shown = Self.shownOrigin(region: region, pane: pane, displayScale: scale)
                return CGPoint(x: shown.x + (f.x * frame.width - region.minX) / scale,
                               y: shown.y + (f.y * frame.height - region.minY) / scale)
            }
        }

        /// The inverse of `view`; nil for an empty fit rect or frame.
        func frame(_ v: CGPoint) -> CGPoint? {
            switch self {
            case .fit(let r):
                guard r.width > 0, r.height > 0 else { return nil }
                return CGPoint(x: (v.x - r.minX) / r.width, y: (v.y - r.minY) / r.height)
            case .window(let region, let frame, let pane, let scale):
                guard frame.width > 0, frame.height > 0, scale > 0 else { return nil }
                let shown = Self.shownOrigin(region: region, pane: pane, displayScale: scale)
                return CGPoint(x: (region.minX + (v.x - shown.x) * scale) / frame.width,
                               y: (region.minY + (v.y - shown.y) * scale) / frame.height)
            }
        }

        /// The top-left of the 1:1 window as drawn, centred in the pane.
        private static func shownOrigin(region: CGRect, pane: CGSize, displayScale: CGFloat) -> CGPoint {
            CGPoint(x: (pane.width - region.width / displayScale) / 2,
                    y: (pane.height - region.height / displayScale) / 2)
        }
    }

    /// The recipe geometry a mask point goes through to reach the screen:
    /// the source's size (only its aspect is used), the rotate stage's turn
    /// (degrees, clockwise-positive on screen) and the crop insets of the
    /// rotated frame. Mirrors `Renderer`'s chain order (rotate, then crop)
    /// and its rotate stage: the turn about the centre, then the largest
    /// same-aspect rectangle inside the turned frame. The renderer also
    /// takes one pixel off each side of that rectangle; at a render's size
    /// that is under a pixel of the frame, so it is left out here.
    struct Geometry: Equatable {
        var source: CGSize
        var rotate: Double
        var crop: CropMath.Crop

        init(source: CGSize, rotate: Double = 0, crop: CropMath.Crop = .none) {
            self.source = source
            self.rotate = rotate
            self.crop = crop
        }

        /// The geometry `recipe` renders over a source of `source`.
        init(recipe: Recipe, source: CGSize) {
            self.init(source: source, rotate: recipe.effective(.rotate), crop: CropMath.crop(of: recipe))
        }

        /// The inscribed rectangle's scale: its sides over the source's.
        var inscribedScale: Double {
            let w = Double(source.width), h = Double(source.height)
            let t = rotate * .pi / 180
            let c = abs(cos(t)), s = abs(sin(t))
            guard w > 0, h > 0 else { return 1 }
            return min(w / (w * c + h * s), h / (w * s + h * c))
        }
    }

    /// A source point to the rendered frame, normalised (0...1 spans the
    /// frame shown, top-left): turned about the source's centre, then
    /// placed in the inscribed rectangle, then in the crop.
    static func frame(_ p: MaskPoint, _ g: Geometry) -> CGPoint {
        let w = Double(g.source.width), h = Double(g.source.height)
        let t = g.rotate * .pi / 180
        let dx = (p.x - 0.5) * w, dy = (p.y - 0.5) * h
        // Clockwise on screen with y down.
        let qx = dx * cos(t) - dy * sin(t), qy = dx * sin(t) + dy * cos(t)
        let s = g.inscribedScale
        let rx = qx / (w * s) + 0.5, ry = qy / (h * s) + 0.5
        let k = g.crop.rect
        return CGPoint(x: (rx - Double(k.minX)) / Double(k.width), y: (ry - Double(k.minY)) / Double(k.height))
    }

    /// The inverse of `frame`: a point of the rendered frame back to the
    /// source (the crop undone, then the inscribed inset, then the turn).
    static func source(_ f: CGPoint, _ g: Geometry) -> MaskPoint {
        let w = Double(g.source.width), h = Double(g.source.height)
        let k = g.crop.rect
        let rx = Double(k.minX) + Double(f.x) * Double(k.width)
        let ry = Double(k.minY) + Double(f.y) * Double(k.height)
        let s = g.inscribedScale
        let qx = (rx - 0.5) * w * s, qy = (ry - 0.5) * h * s
        let t = g.rotate * .pi / 180
        // The turn undone: rotate back by -t.
        let dx = qx * cos(t) + qy * sin(t), dy = -qx * sin(t) + qy * cos(t)
        return MaskPoint(x: dx / w + 0.5, y: dy / h + 0.5)
    }

    /// A source point to view points on the loupe.
    static func sourceToView(_ p: MaskPoint, _ g: Geometry, _ viewport: Viewport) -> CGPoint {
        viewport.view(frame(p, g))
    }

    /// A view point on the loupe to the source frame; nil when the viewport
    /// is empty. Points off the photo map too (a gradient's end may lie
    /// outside it).
    static func viewToSource(_ v: CGPoint, _ g: Geometry, _ viewport: Viewport) -> MaskPoint? {
        viewport.frame(v).map { source($0, g) }
    }
}
