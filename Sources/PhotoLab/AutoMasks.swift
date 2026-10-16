import Foundation
import CoreGraphics
import CoreVideo
import Vision

/// Finds what an automatic mask selects in a decoded image. The image is the
/// photo's oriented decode (`ImageLoading.downsampledCGImage`, EXIF applied,
/// so row 0 is the top of the photo as displayed), and the bitmap returned
/// covers that whole frame, which is the source frame `MaskBitmap` is defined
/// over. `Library.selectAuto` calls it off the main actor; a test replaces it
/// (`Library.autoMaskDetector`) with a fake.
protocol AutoMaskDetector: Sendable {
    /// The photo's main subject (the foreground), or nil when there is none.
    func subject(in image: CGImage) async throws -> MaskBitmap?
    /// Every person in the photo merged into one mask, or nil when there is none.
    func person(in image: CGImage) async throws -> MaskBitmap?
    /// One observation per face found (Vision's normalised, bottom-left
    /// `boundingBox` and its `roll`); empty when there is none.
    func faces(in image: CGImage) async throws -> [VNFaceObservation]
}

/// The on-device detector: Apple Vision, run on this Mac with no network.
/// Subject is `VNGenerateForegroundInstanceMaskRequest` (macOS 14) with every
/// instance it finds merged into one mask, scaled to the input image
/// (`generateScaledMaskForImage(forInstances:from:)`), so a person holding
/// a dog selects both, as Lightroom's Select Subject does. Person is
/// `VNGeneratePersonInstanceMaskRequest` (macOS 14) the same way, every
/// person merged; faces are `VNDetectFaceRectanglesRequest`.
struct VisionDetector: AutoMaskDetector {
    /// The long side, in pixels, of the decode a detection runs on: the
    /// bitmap's own cap (`MaskBitmap.maxLongSide`), so nothing is detected
    /// finer than it can be stored.
    static let inputPixelSize = MaskBitmap.maxLongSide

    func subject(in image: CGImage) async throws -> MaskBitmap? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return try Self.merged(request.results?.first, from: handler)
    }

    func person(in image: CGImage) async throws -> MaskBitmap? {
        let request = VNGeneratePersonInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return try Self.merged(request.results?.first, from: handler)
    }

    func faces(in image: CGImage) async throws -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    /// Every instance of `observation` merged into one bitmap the size of
    /// the handler's image; nil when there is none or it is blank.
    private static func merged(_ observation: VNInstanceMaskObservation?,
                               from handler: VNImageRequestHandler) throws -> MaskBitmap? {
        guard let observation, !observation.allInstances.isEmpty else { return nil }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        guard let bitmap = MaskBitmap(pixelBuffer: buffer), !bitmap.isBlank else { return nil }
        return bitmap
    }
}

/// A detected face as a radial mask (Select Faces, `Library.selectFaces`).
enum FaceMasks {
    /// How far the ellipse reaches past the face box: radii are this times
    /// half the box, so the feathered edge falls outside the face and the
    /// full-effect core (radii x (1 - `feather`)) still covers most of it.
    static let margin = 1.4
    /// The new mask's feather.
    static let feather = 0.4

    /// A `.radial` over the face whose Vision `boundingBox` (normalised,
    /// origin BOTTOM-left) was found in an image of `imageSize` pixels (the
    /// oriented decode, so the source frame). The centre is flipped to the
    /// top-left origin of `MaskPoint`; the radii are the box's half width and
    /// half height in pixels over the long side (`MaskRadii`'s unit) times
    /// `margin`; the angle is `-roll` in degrees, since Vision's roll turns
    /// counter-clockwise and a radial's angle clockwise on screen. No roll
    /// is angle 0.
    static func radial(for boundingBox: CGRect, roll: Double?, imageSize: CGSize) -> MaskShape {
        let w = Double(imageSize.width), h = Double(imageSize.height)
        let long = max(w, h, 1)
        let center = MaskPoint(x: Double(boundingBox.midX), y: 1 - Double(boundingBox.midY))
        let radii = MaskRadii(x: Double(boundingBox.width) * w / long / 2 * margin,
                              y: Double(boundingBox.height) * h / long / 2 * margin)
        let angle = -(roll ?? 0) * 180 / .pi
        return .radial(center: center, radii: radii, angle: angle, feather: feather)
    }
}

extension MaskBitmap {
    /// A bitmap of a one-channel pixel buffer, row 0 the top (a
    /// `CVPixelBuffer`'s memory order, which is also Vision's mask order for
    /// a `CGImage` input): `kCVPixelFormatType_OneComponent8` as it is,
    /// `kCVPixelFormatType_OneComponent32Float` clamped to 0...1 and rounded
    /// to 8 bits. Padding at a row's end (`bytesPerRow`) is skipped. Nil for
    /// any other format or an empty buffer. Larger than `maxLongSide` is
    /// box-filtered down by `init(gray:width:height:)`.
    init?(pixelBuffer buffer: CVPixelBuffer) {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent8 || format == kCVPixelFormatType_OneComponent32Float else {
            return nil
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var gray = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
            if format == kCVPixelFormatType_OneComponent8 {
                let p = row.assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { gray[y * width + x] = p[x] }
            } else {
                let p = row.assumingMemoryBound(to: Float32.self)
                for x in 0..<width {
                    let v = p[x].isNaN ? 0 : min(max(p[x], 0), 1)
                    gray[y * width + x] = UInt8((v * 255).rounded())
                }
            }
        }
        self.init(gray: gray, width: width, height: height)
    }
}

/// `Library.selectAuto`'s decode found no image in the original.
struct AutoMaskUnreadable: Error {}
