import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText

/// An optional line of text drawn over an export: white with a soft dark
/// shadow, at a corner or the centre, sized as a fraction of the output's
/// short side so it reads the same at every export size. Carried as
/// `ExportOptions.watermark` and drawn by `Renderer.render(_:recipe:maxPixelSize:resize:region:watermark:)`
/// as the chain's LAST stage, after the resize, so a folder export and a
/// Photos export take it through the one render path. The loupe, the preset
/// strip, thumbnails and Save to Photos (`PhotosSource.saveOptions`) never
/// pass one. Blank or whitespace text draws nothing.
struct Watermark: Codable, Hashable, Sendable {
    enum Position: String, Codable, CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight, center

        var label: String {
            switch self {
            case .topLeft: return "Top Left"
            case .topRight: return "Top Right"
            case .bottomLeft: return "Bottom Left"
            case .bottomRight: return "Bottom Right"
            case .center: return "Center"
            }
        }
    }

    /// The sheet's size slider and the clamp `clampedSize` applies.
    static let sizeRange: ClosedRange<Double> = 0.01...0.15
    /// The sheet's opacity slider and the clamp `clampedOpacity` applies.
    static let opacityRange: ClosedRange<Double> = 0.1...1.0
    /// The gap between the text and the frame's edges, a fraction of the
    /// output's short side.
    static let marginFraction: Double = 0.02

    var text: String = ""
    var position: Position = .bottomRight
    /// The text's height (the font's ascent plus descent) as a fraction of
    /// the output's short side.
    var size: Double = 0.035
    var opacity: Double = 0.6

    init(text: String = "", position: Position = .bottomRight, size: Double = 0.035, opacity: Double = 0.6) {
        self.text = text
        self.position = position
        self.size = size
        self.opacity = opacity
    }

    /// A stored watermark missing a field takes that field's default, so a
    /// mark saved by a build with fewer fields still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Watermark()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? d.text
        position = try c.decodeIfPresent(Position.self, forKey: .position) ?? d.position
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
    }

    /// The text on one line: trimmed, newlines as spaces.
    var cleanText: String {
        text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Nothing to draw.
    var isBlank: Bool { cleanText.isEmpty }

    var clampedSize: Double { min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) }
    var clampedOpacity: Double { min(max(opacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound) }

    /// Where the text's box (`textSize`, its typographic width by ascent
    /// plus descent) sits in `frame`, in Core Image's bottom-left
    /// coordinates: `margin` in from the two edges of `position`'s corner,
    /// or centred.
    static func origin(for position: Position, textSize: CGSize, in frame: CGRect, margin: CGFloat) -> CGPoint {
        let left = frame.minX + margin
        let right = frame.maxX - margin - textSize.width
        let bottom = frame.minY + margin
        let top = frame.maxY - margin - textSize.height
        switch position {
        case .topLeft: return CGPoint(x: left, y: top)
        case .topRight: return CGPoint(x: right, y: top)
        case .bottomLeft: return CGPoint(x: left, y: bottom)
        case .bottomRight: return CGPoint(x: right, y: bottom)
        case .center: return CGPoint(x: frame.midX - textSize.width / 2, y: frame.midY - textSize.height / 2)
        }
    }

    /// `image` with the mark composited source-over inside `frame` (the
    /// output rect); `image` unchanged when the text is blank or cannot be
    /// drawn. The font size is `clampedSize` of the short side, made
    /// smaller when the line would not fit between the margins.
    func composite(over image: CIImage, in frame: CGRect) -> CIImage {
        let text = cleanText
        guard !text.isEmpty, frame.width >= 1, frame.height >= 1 else { return image }
        let short = min(frame.width, frame.height)
        let margin = (short * Self.marginFraction).rounded()
        var line = Self.line(text, fontSize: short * clampedSize)
        let available = frame.width - 2 * margin
        if line.size.width > available, available > 1 {
            line = Self.line(text, fontSize: short * clampedSize * available / line.size.width)
        }
        guard line.size.width >= 1, line.size.height >= 1,
              let mark = Self.draw(line, opacity: clampedOpacity) else { return image }
        let at = Self.origin(for: position, textSize: line.size, in: frame, margin: margin)
        let placed = mark.image.transformed(by: CGAffineTransform(
            translationX: (at.x - mark.inset).rounded(), y: (at.y - mark.inset).rounded()))
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = placed
        over.backgroundImage = image
        return over.outputImage?.cropped(to: image.extent) ?? image
    }

    private struct Line {
        let ctLine: CTLine
        let descent: CGFloat
        /// Typographic width by ascent plus descent.
        let size: CGSize
    }

    private static func line(_ text: String, fontSize: CGFloat) -> Line {
        let font = CTFontCreateUIFontForLanguage(.system, max(1, fontSize), nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, max(1, fontSize), nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let ct = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ct, &ascent, &descent, &leading))
        return Line(ctLine: ct, descent: descent, size: CGSize(width: width.rounded(.up), height: (ascent + descent).rounded(.up)))
    }

    /// The line drawn white with its shadow at `opacity` into a bitmap
    /// `inset` pixels larger on every side (room for the shadow), as a
    /// CIImage whose origin is the bitmap's bottom-left.
    private static func draw(_ line: Line, opacity: Double) -> (image: CIImage, inset: CGFloat)? {
        let h = line.size.height
        let blur = max(1, h * 0.12)
        let offset = max(1, h * 0.04)
        let inset = (blur * 2 + offset).rounded(.up)
        let width = Int(line.size.width + 2 * inset), height = Int(h + 2 * inset)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setAlpha(CGFloat(opacity))
        ctx.setShadow(offset: CGSize(width: 0, height: -offset), blur: blur,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.textPosition = CGPoint(x: inset, y: inset + line.descent)
        CTLineDraw(line.ctLine, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return (CIImage(cgImage: cg), inset)
    }
}
