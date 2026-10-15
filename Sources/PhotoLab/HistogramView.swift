import SwiftUI

/// The panel's histogram: red, green and blue bins drawn additively over a
/// gray luminance curve, with Lightroom's two clipping triangles (shadows
/// left, highlights right) lit when more than 0.1 % of the frame's pixels
/// clip. Either triangle toggles the clipping overlay on the preview, as
/// `J` does.
struct HistogramView: View {
    let histogram: Histogram?
    @Binding var showClipping: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                triangle(lit: histogram?.shadowsClipped ?? false, fraction: histogram?.shadowClipping,
                         name: "Shadow", color: .blue)
                Spacer()
                Text("Histogram")
                    .font(.callout.weight(.semibold))
                    .help(histogram.map { String(format: "%d px, computed in %.1f ms", $0.pixelCount, $0.milliseconds) } ?? "Waiting for a frame")
                Spacer()
                triangle(lit: histogram?.highlightsClipped ?? false, fraction: histogram?.highlightClipping,
                         name: "Highlight", color: .red)
            }
            Canvas(rendersAsynchronously: true) { context, size in
                guard let histogram else { return }
                let peak = Self.peak(of: histogram)
                context.fill(Self.path(histogram.luminance, peak: peak, in: size), with: .color(.gray.opacity(0.45)))
                context.blendMode = .plusLighter
                context.fill(Self.path(histogram.red, peak: peak, in: size), with: .color(.red.opacity(0.55)))
                context.fill(Self.path(histogram.green, peak: peak, in: size), with: .color(.green.opacity(0.55)))
                context.fill(Self.path(histogram.blue, peak: peak, in: size), with: .color(.blue.opacity(0.55)))
            }
            .frame(height: 72)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.08)))
            .accessibilityLabel("Histogram")
        }
    }

    private func triangle(lit: Bool, fraction: Double?, name: String, color: Color) -> some View {
        Button { showClipping.toggle() } label: {
            Image(systemName: "triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(lit ? color : Color.secondary.opacity(0.35))
                .padding(3)
                .background(showClipping ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(Self.help(name: name, fraction: fraction, on: showClipping))
        .accessibilityLabel("\(name) clipping")
        .accessibilityValue(lit ? "clipping" : "none")
    }

    static func help(name: String, fraction: Double?, on: Bool) -> String {
        let amount = fraction.map { String(format: "%.2f %% of pixels", $0 * 100) } ?? "no frame yet"
        return "\(name) clipping: \(amount). Click or press J to \(on ? "hide" : "show") the overlay."
    }

    /// The tallest bin of any channel, ignoring the two end bins so a blown
    /// sky or a crushed shadow does not flatten the rest of the curve.
    static func peak(of h: Histogram) -> Int {
        var peak = 1
        for bins in [h.red, h.green, h.blue, h.luminance] where bins.count > 2 {
            for v in bins[1..<(bins.count - 1)] where v > peak { peak = v }
        }
        return peak
    }

    /// A filled curve: bin i at x = i / (bins − 1), height clipped to the top.
    static func path(_ bins: [Int], peak: Int, in size: CGSize) -> Path {
        var path = Path()
        guard bins.count > 1, size.width > 0, size.height > 0 else { return path }
        let step = size.width / CGFloat(bins.count - 1)
        path.move(to: CGPoint(x: 0, y: size.height))
        for (i, v) in bins.enumerated() {
            let h = min(1, CGFloat(v) / CGFloat(peak)) * (size.height - 2)
            path.addLine(to: CGPoint(x: CGFloat(i) * step, y: size.height - h))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }
}
