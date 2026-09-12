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

/// A deterministic, source-measured astrophotography development plan.
/// Coefficients model the large-scale sRGB background as
/// 1, x, y, x², xy, y². Nothing here can synthesize image content.
struct AstroAutoPlan: Codable, Equatable {
    let backgroundCoefficients: [[Double]]
    let backgroundReference: [Double]
    let channelGains: [Double]
    let blackPoint: Double
    let whitePoint: Double
    let gamma: Double
    let noiseLevel: Double
    let localContrast: Double
    let saturation: Double
    let skyLevel: Double
    let skySigma: Double
    let sampledTiles: Int

    var operations: [String] {
        let gainText = channelGains.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        return [
            "Sigma-clipped quadratic background model from \(sampledTiles) low-signal tiles",
            "Per-channel sky neutralization; gains \(gainText)",
            String(format: "Measured black/white normalization: %.4f / %.4f", blackPoint, whitePoint),
            String(format: "Controlled nonlinear stretch: gamma %.3f", gamma),
            String(format: "Background-masked conventional noise reduction: %.4f", noiseLevel),
            String(format: "Star-protected local contrast: %.3f", localContrast),
            String(format: "Highlight-safe color enhancement: %.3f", saturation),
        ]
    }

    static func analyze(rgba: [UInt8], width: Int, height: Int) -> AstroAutoPlan? {
        guard width >= 24, height >= 24, width <= 2048, height <= 2048,
              rgba.count == width * height * 4 else { return nil }
        let columns = 18, rows = 12
        struct Tile { let x, y: Double; let rgb: [Double]; let luma: Double }
        var tiles: [Tile] = []
        for ty in 0..<rows { for tx in 0..<columns {
            let x0 = tx * width / columns, x1 = max(x0 + 1, (tx + 1) * width / columns)
            let y0 = ty * height / rows, y1 = max(y0 + 1, (ty + 1) * height / rows)
            var channels = [[Double](), [Double](), [Double]()]
            let sx = max(1, (x1 - x0) / 10), sy = max(1, (y1 - y0) / 10)
            for py in stride(from: y0, to: min(height, y1), by: sy) {
                for px in stride(from: x0, to: min(width, x1), by: sx) {
                    let i = (py * width + px) * 4
                    guard rgba[i + 3] >= 250 else { continue }
                    channels[0].append(Double(rgba[i]) / 255)
                    channels[1].append(Double(rgba[i + 1]) / 255)
                    channels[2].append(Double(rgba[i + 2]) / 255)
                }
            }
            guard channels[0].count >= 8 else { continue }
            let rgb = channels.map { percentile($0.sorted(), 0.5) }
            let l = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
            tiles.append(Tile(x: (Double(tx) + 0.5) / Double(columns), y: (Double(ty) + 0.5) / Double(rows), rgb: rgb, luma: l))
        } }
        guard tiles.count >= 30 else { return nil }
        let ordered = tiles.sorted { $0.luma < $1.luma }
        var selected = Array(ordered.prefix(max(24, Int(Double(ordered.count) * 0.42))))
        var coefficients = (0..<3).map { channel in
            fit(selected.map { ($0.x, $0.y, $0.rgb[channel]) })
        }
        guard coefficients.allSatisfy({ $0.count == 6 }) else { return nil }

        // Reject bright nebulosity, stars and residual hot tiles by model residual, then refit.
        for _ in 0..<2 {
            let residuals = selected.map { tile -> Double in
                let predicted = (0..<3).map { evaluate(coefficients[$0], tile.x, tile.y) }
                return abs((0.2126 * (tile.rgb[0] - predicted[0]) + 0.7152 * (tile.rgb[1] - predicted[1]) + 0.0722 * (tile.rgb[2] - predicted[2])))
            }
            let med = percentile(residuals.sorted(), 0.5)
            let mad = percentile(residuals.map { abs($0 - med) }.sorted(), 0.5) + 1.0 / 4096
            let kept = zip(selected, residuals).filter { $0.1 <= med + 3.5 * 1.4826 * mad }.map(\.0)
            if kept.count >= 20 { selected = kept }
            coefficients = (0..<3).map { channel in fit(selected.map { ($0.x, $0.y, $0.rgb[channel]) }) }
        }

        let center = (0..<3).map { min(0.8, max(0, evaluate(coefficients[$0], 0.5, 0.5))) }
        let neutral = percentile(center.sorted(), 0.5)
        let gains = center.map { min(1.35, max(0.75, neutral / max($0, 1.0 / 255))) }
        var luminance: [Double] = []
        luminance.reserveCapacity(min(width * height, 300_000))
        let step = max(1, Int(sqrt(Double(width * height) / 250_000)))
        for py in stride(from: 0, to: height, by: step) {
            for px in stride(from: 0, to: width, by: step) {
                let i = (py * width + px) * 4
                guard rgba[i + 3] >= 250 else { continue }
                let x = (Double(px) + 0.5) / Double(width), y = (Double(py) + 0.5) / Double(height)
                var c = [Double](repeating: 0, count: 3)
                for channel in 0..<3 {
                    let raw = Double(rgba[i + channel]) / 255
                    c[channel] = max(0, (raw - evaluate(coefficients[channel], x, y) + center[channel]) * gains[channel])
                }
                luminance.append(0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2])
            }
        }
        guard luminance.count > 100 else { return nil }
        let sorted = luminance.sorted()
        let skyPool = Array(sorted.prefix(max(50, Int(Double(sorted.count) * 0.58))))
        let sky = percentile(skyPool, 0.5)
        let sigma = 1.4826 * percentile(skyPool.map { abs($0 - sky) }.sorted(), 0.5)
        let black = min(sky * 0.88, max(0, min(percentile(sorted, 0.012), sky - 2.15 * sigma)))
        let white = max(black + 0.25, min(1, max(0.72, percentile(sorted, 0.9995))))
        let headroom = max(0, 1 - percentile(sorted, 0.999))
        let gamma = min(0.90, max(0.74, 0.84 - min(0.08, max(0, (0.11 - sky) * 0.45))))
        return AstroAutoPlan(backgroundCoefficients: coefficients, backgroundReference: center,
            channelGains: gains, blackPoint: black, whitePoint: white, gamma: gamma,
            noiseLevel: min(0.035, max(0.006, sigma * 0.55)),
            localContrast: headroom < 0.02 ? 0.12 : 0.22,
            saturation: headroom < 0.02 ? 1.08 : 1.16,
            skyLevel: sky, skySigma: sigma, sampledTiles: selected.count)
    }

    private static func evaluate(_ c: [Double], _ x: Double, _ y: Double) -> Double {
        guard c.count == 6 else { return 0 }
        return c[0] + c[1] * x + c[2] * y + c[3] * x * x + c[4] * x * y + c[5] * y * y
    }

    private static func fit(_ samples: [(Double, Double, Double)]) -> [Double] {
        var a = Array(repeating: Array(repeating: 0.0, count: 7), count: 6)
        for (x, y, value) in samples {
            let v = [1.0, x, y, x*x, x*y, y*y]
            for r in 0..<6 {
                for c in 0..<6 { a[r][c] += v[r] * v[c] }
                a[r][6] += v[r] * value
            }
        }
        for pivot in 0..<6 {
            guard let row = (pivot..<6).max(by: { abs(a[$0][pivot]) < abs(a[$1][pivot]) }), abs(a[row][pivot]) > 1e-10 else { return [] }
            if row != pivot { a.swapAt(row, pivot) }
            let d = a[pivot][pivot]
            for c in pivot..<7 { a[pivot][c] /= d }
            for r in 0..<6 where r != pivot {
                let m = a[r][pivot]
                for c in pivot..<7 { a[r][c] -= m * a[pivot][c] }
            }
        }
        return a.map { $0[6] }
    }

    private static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        return values[min(values.count - 1, max(0, Int(Double(values.count - 1) * q)))]
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
        if m.backgroundSpread > 0.06 { warnings.append("Strong large-scale variation was detected. Compare the modeled correction carefully so real extended structure is not mistaken for sky glow.") }
        if m.fineVariation > 0.01 { warnings.append("Fine-scale variation is present; stars, texture, and noise all contribute. Do not treat this as a pure noise estimate.") }
        return PhotoAdvice(recipe: recipe.bounded, reasons: reasons, warnings: warnings)
    }
}
