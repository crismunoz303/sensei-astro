import Foundation

enum PhotoIntent: String, Codable, CaseIterable, Identifiable {
    case astro = "Astrophotography"
    case natural = "Everyday photo"
    var id: String { rawValue }
}

/// Only numerical operations are representable. There is no image-generation tool.
struct PhotoRecipe: Codable, Equatable {
    var exposure: Double = 0
    var midtones: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var warmth: Double = 0
    var denoise: Double = 0
    var sharpen: Double = 0
    var protectHighlights = true
    static let identity = PhotoRecipe()

    var bounded: PhotoRecipe {
        var r = self
        r.exposure = Self.clamp(exposure, -1...1, fallback: 0)
        r.midtones = Self.clamp(midtones, 0...0.16, fallback: 0)
        r.contrast = Self.clamp(contrast, 0.9...1.15, fallback: 1)
        r.saturation = Self.clamp(saturation, 0...1.3, fallback: 1)
        r.warmth = Self.clamp(warmth, -0.1...0.1, fallback: 0)
        r.denoise = Self.clamp(denoise, 0...0.04, fallback: 0)
        r.sharpen = Self.clamp(sharpen, 0...0.4, fallback: 0)
        return r
    }

    var hasAdjustments: Bool {
        exposure != 0 || midtones != 0 || contrast != 1 || saturation != 1 || warmth != 0 || denoise != 0 || sharpen != 0
    }

    var operations: [String] {
        var result: [String] = []
        if exposure != 0 { result.append(String(format: "Exposure: %+.2f EV", exposure)) }
        if midtones != 0 { result.append(String(format: "Midtone curve lift: %.3f", midtones)) }
        if contrast != 1 { result.append(String(format: "Contrast: %.3f", contrast)) }
        if saturation != 1 { result.append(String(format: "Saturation: %.3f", saturation)) }
        if warmth != 0 { result.append(String(format: "Relative red/blue balance: %+.3f (not color calibration)", warmth)) }
        if denoise != 0 { result.append(String(format: "Conventional spatial denoise: %.3f; may remove faint signal", denoise)) }
        if sharpen != 0 { result.append(String(format: "Luminance sharpening: %.3f; may introduce halos", sharpen)) }
        if hasAdjustments && protectHighlights { result.append("Blend original bright pixels back through a source-derived highlight mask") }
        return result.isEmpty ? ["No adjustments; source decoded and color-managed for output"] : result
    }

    private static func clamp(_ v: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        v.isFinite ? min(range.upperBound, max(range.lowerBound, v)) : fallback
    }
}

struct PhotoMeasurement: Codable, Equatable {
    let histogram: [Int]
    let samples: Int
    let median: Double
    let percentile99: Double
    let clippedHighlights: Double
    let crushedBlacks: Double
    let fineVariation: Double
    let backgroundSpread: Double

    /// Measurements describe an sRGB preview, not calibrated astronomical signal.
    static func measure(rgba: [UInt8], width: Int, height: Int) -> PhotoMeasurement? {
        guard width > 0, height > 0, width <= 2048, height <= 2048,
              rgba.count == width * height * 4 else { return nil }
        var histogram = [Int](repeating: 0, count: 256)
        var tiles = [[Double]](repeating: [], count: 16)
        var luma = [Double](repeating: 0, count: width * height)
        var valid = [Bool](repeating: false, count: width * height)
        var clipped = 0, black = 0, count = 0
        for i in 0..<(width * height) where rgba[i * 4 + 3] >= 250 {
            let p = i * 4
            let r = Double(rgba[p]) / 255, g = Double(rgba[p+1]) / 255, b = Double(rgba[p+2]) / 255
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            luma[i] = y
            valid[i] = true
            histogram[min(255, Int((y * 255).rounded()))] += 1
            let tx = min(3, (i % width) * 4 / width), ty = min(3, (i / width) * 4 / height)
            tiles[ty * 4 + tx].append(y)
            if max(r, max(g, b)) >= 254.0 / 255 { clipped += 1 }
            if max(r, max(g, b)) <= 1.0 / 255 { black += 1 }
            count += 1
        }
        guard count > 0 else { return nil }
        let sorted = zip(luma, valid).compactMap { $0.1 ? $0.0 : nil }.sorted()
        var detail: [Double] = []
        if width >= 2 && height >= 2 {
            for y in stride(from: 0, to: height-1, by: 2) {
                for x in stride(from: 0, to: width-1, by: 2) {
                    let i = y * width + x
                    if valid[i] && valid[i+1] && valid[i+width] && valid[i+width+1] {
                        detail.append(abs(luma[i] - luma[i+1] - luma[i+width] + luma[i+width+1]) / 2)
                    }
                }
            }
        }
        let tileMedians = tiles.filter { !$0.isEmpty }.map { quantile($0.sorted(), 0.5) }
        return PhotoMeasurement(histogram: histogram, samples: count,
            median: quantile(sorted, 0.5), percentile99: quantile(sorted, 0.99),
            clippedHighlights: Double(clipped) / Double(count), crushedBlacks: Double(black) / Double(count),
            fineVariation: quantile(detail.sorted(), 0.5) / 0.67449,
            backgroundSpread: (tileMedians.max() ?? 0) - (tileMedians.min() ?? 0))
    }

    private static func quantile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        return values[min(values.count-1, max(0, Int(Double(values.count-1) * q)))]
    }
}

struct PhotoAdvice {
    let recipe: PhotoRecipe
    let reasons: [String]
    let warnings: [String]

    static func make(_ m: PhotoMeasurement, intent: PhotoIntent) -> PhotoAdvice {
        var recipe = PhotoRecipe.identity
        var reasons: [String] = [], warnings: [String] = []
        if intent == .astro {
            // A black sky is expected, not proof of underexposure. Keep black/white endpoints.
            if m.median > 0.005 && m.median < 0.16 && m.percentile99 < 0.9 && m.clippedHighlights < 0.001 {
                recipe.midtones = min(0.065, (0.16 - m.median) * 0.4)
                reasons.append("A small midtone lift may reveal existing faint signal; black and white curve endpoints stay fixed.")
            } else {
                reasons.append("No automatic brightness lift: dark sky is normal, and highlight headroom may be limited.")
            }
            reasons.append("Color balance stays unchanged; this preview cannot tell light pollution from real nebula color.")
        } else if m.median > 0.01 && m.median < 0.32 && m.percentile99 < 0.88 && m.clippedHighlights < 0.001 {
            recipe.exposure = min(0.3, max(0, log2(0.32 / m.median)))
            reasons.append("The median is dark with some highlight headroom; try a restrained exposure increase.")
        } else {
            reasons.append("Keep the current exposure; the histogram does not justify a confident automatic change.")
        }
        reasons.append("Denoise and sharpening stay off until you inspect fine detail. Brightness alone cannot measure noise.")
        if m.clippedHighlights > 0.001 { warnings.append("Some sampled color channels are already clipped. Lost detail cannot be recovered from this file.") }
        if m.crushedBlacks > 0.01 { warnings.append("Some sampled pixels are already black. A lift may expose compression, not real detail.") }
        if m.backgroundSpread > 0.06 { warnings.append("Uneven brightness detected. It may be real structure, vignetting, or a gradient; no automatic subtraction is applied.") }
        if m.fineVariation > 0.01 { warnings.append("Fine-scale variation is present; stars, texture, and noise all contribute. Do not treat this as a pure noise estimate.") }
        return PhotoAdvice(recipe: recipe.bounded, reasons: reasons, warnings: warnings)
    }
}
