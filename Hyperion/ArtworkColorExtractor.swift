// ADDED: Task 9 — extracts a dominant accent colour from album artwork for per-album theming.
import UIKit
import SwiftUI

// Runs off the main actor so image pixel analysis doesn't block the UI thread.
actor ArtworkColorExtractor {

    static let shared = ArtworkColorExtractor()
    private init() {}

    // Down-sample the image to 8×8 to find a representative palette cheaply.
    private static let sampleSize = CGSize(width: 8, height: 8)

    /// Returns the most saturated, non-background pixel colour in the image.
    /// Falls back to `.roonAccent` when no suitable colour is found.
    func extract(from image: UIImage) -> Color {
        guard let cgImage = image.cgImage else { return .roonAccent }
        let pixels = renderPixels(cgImage)
        return dominantAccent(from: pixels) ?? .roonAccent
    }

    // MARK: - Private

    private func renderPixels(_ cgImage: CGImage) -> [(r: Float, g: Float, b: Float)] {
        let w = Int(Self.sampleSize.width)
        let h = Int(Self.sampleSize.height)
        var data = [UInt8](repeating: 0, count: w * h * 4) // RGBA
        guard let ctx = CGContext(
            data:             &data,
            width:            w,
            height:           h,
            bitsPerComponent: 8,
            bytesPerRow:      w * 4,
            space:            CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:       CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: Self.sampleSize))

        var pixels: [(r: Float, g: Float, b: Float)] = []
        pixels.reserveCapacity(w * h)
        for i in stride(from: 0, to: data.count, by: 4) {
            let a = Float(data[i + 3]) / 255
            guard a > 0.5 else { continue } // skip transparent/near-transparent pixels
            // Undo premultiplication: stored bytes = actual * alpha, so divide by alpha.
            pixels.append((
                r: Float(data[i])     / (255 * a),
                g: Float(data[i + 1]) / (255 * a),
                b: Float(data[i + 2]) / (255 * a)
            ))
        }
        return pixels
    }

    private func dominantAccent(from pixels: [(r: Float, g: Float, b: Float)]) -> Color? {
        // Pick the pixel with the highest HSL saturation that isn't too dark or too bright.
        var best: (hue: Float, sat: Float, lit: Float)?

        for px in pixels {
            let (h, s, l) = rgbToHsl(px.r, px.g, px.b)
            guard s > 0.3, l > 0.15, l < 0.85 else { continue } // skip grey/black/white
            if best.map({ s > $0.sat }) ?? true { best = (h, s, l) }
        }

        guard let chosen = best else { return nil }
        // Normalise lightness to ~0.55 so the colour is always legible on dark backgrounds.
        return Color(hue: Double(chosen.hue),
                     saturation: Double(min(1, chosen.sat * 1.2)),
                     brightness: Double(max(0.45, min(0.75, chosen.lit + 0.1))))
    }

    private func rgbToHsl(_ r: Float, _ g: Float, _ b: Float) -> (h: Float, s: Float, l: Float) {
        let cMax = max(r, g, b)
        let cMin = min(r, g, b)
        let delta = cMax - cMin
        let l = (cMax + cMin) / 2

        guard delta > 0 else { return (0, 0, l) }

        let s = l > 0.5 ? delta / (2 - cMax - cMin) : delta / (cMax + cMin)

        let h: Float
        switch cMax {
        case r: h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) / 6
        case g: h = ((b - r) / delta + 2) / 6
        default: h = ((r - g) / delta + 4) / 6
        }

        return (h < 0 ? h + 1 : h, s, l)
    }
}
