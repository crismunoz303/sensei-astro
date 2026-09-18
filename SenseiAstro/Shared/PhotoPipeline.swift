#if canImport(CoreImage)
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Foundation

enum LabError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum LabExportFormat: String, CaseIterable, Identifiable, Codable {
    case png = "PNG"
    case tiff = "16-bit TIFF"
    var id: String { rawValue }
    var suffix: String { self == .png ? "png" : "tiff" }
}

struct PhotoProject: Codable, Identifiable {
    let id: UUID
    let created: Date
    let sha256: String
    let sourceExtension: String
    let sourceBytes: Int
    let width: Int
    let height: Int
    let sourceDepth: Int
    var recipe: PhotoRecipe
    var intent: PhotoIntent
    var updated: Date
    var astroPlan: AstroAutoPlan?
    var automaticProcessingDisabled: Bool?
    var automaticStrength: Double? = nil

    var boundedAutomaticStrength: Double {
        guard let value = automaticStrength, value.isFinite else { return 1 }
        return min(1, max(0, value))
    }
}

struct LabLoadedPhoto {
    let project: PhotoProject
    let preview: CGImage
    let measurement: PhotoMeasurement
}

struct LabRenderedPhoto {
    let image: CGImage
    let measurement: PhotoMeasurement
}

struct LabDetail {
    let original: CGImage
    let edited: CGImage
    let width: Int
    let height: Int
}

struct LabExport: Identifiable {
    let id = UUID()
    let imageURL: URL
    let reportURL: URL
    let originalSHA256: String
    let width: Int
    let height: Int
}

/// Serialized, off-main image work. No networking; only source-derived mathematical filters.
actor PhotoPipeline {
    private let root: URL
    private let context = CIContext(options: [.cacheIntermediates: false, .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var cachedPreview: (UUID, CGImage)?
    private let manager = FileManager.default
    static let engineVersion = "astro-develop-1.8.0"

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrueEdit", isDirectory: true)
    }

    func projects() throws -> [PhotoProject] {
        try prepareRoot()
        return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { url -> PhotoProject? in
                guard UUID(uuidString: url.lastPathComponent) != nil,
                      let data = try? Data(contentsOf: url.appendingPathComponent("project.json")) else { return nil }
                return try? JSONDecoder().decode(PhotoProject.self, from: data)
            }.sorted { $0.updated > $1.updated }
    }

    func importData(_ data: Data) throws -> LabLoadedPhoto {
        guard !data.isEmpty, data.count <= 100 * 1024 * 1024 else {
            throw LabError.invalid("Choose an image smaller than 100 MB. The original has not been changed.")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeID = CGImageSourceGetType(source),
              let type = UTType(typeID as String),
              [UTType.jpeg, .png, .heic, .tiff].contains(where: { type.conforms(to: $0) }),
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw LabError.invalid("Choose a single JPEG, PNG, HEIC, or TIFF image. FITS, RAW, animated and multi-page files need a dedicated pipeline and are not supported yet.")
        }
        guard width > 0, height > 0, width <= 20_000, height <= 20_000, width * height <= 25_000_000 else {
            throw LabError.invalid("This mobile build supports up to 25 megapixels. Export a smaller working copy; keep your master file.")
        }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let swapped = (5...8).contains(orientation)
        let digest = Self.hash(data)
        if let existing = try projects().first(where: { $0.sha256 == digest }) { return try open(existing) }
        // Decode and analyze before committing a project; invalid files never create one.
        let preview = try thumbnail(source, maxPixel: 1400)
        let analysis = try analyze(preview)
        let project = PhotoProject(id: UUID(), created: Date(), sha256: digest,
            sourceExtension: type.preferredFilenameExtension ?? "image", sourceBytes: data.count,
            width: swapped ? height : width, height: swapped ? width : height,
            sourceDepth: props[kCGImagePropertyDepth] as? Int ?? 8,
            recipe: .identity, intent: .astro, updated: Date(), astroPlan: analysis.plan,
            automaticProcessingDisabled: false)
        try manager.createDirectory(at: directory(project), withIntermediateDirectories: true)
        try data.write(to: sourceURL(project), options: .atomic)
        guard Self.hash(try Data(contentsOf: sourceURL(project))) == digest else {
            throw LabError.invalid("Original-file verification failed. Import stopped.")
        }
        try save(project)
        cachedPreview = (project.id, preview)
        return LabLoadedPhoto(project: project, preview: preview, measurement: analysis.measurement)
    }

    func open(_ project: PhotoProject) throws -> LabLoadedPhoto {
        try verify(project)
        guard let source = CGImageSourceCreateWithURL(sourceURL(project) as CFURL, nil) else { throw LabError.invalid("The saved source cannot be decoded.") }
        let preview = try thumbnail(source, maxPixel: 1400)
        let analysis = try analyze(preview)
        var upgraded = project
        if upgraded.astroPlan?.planVersion != 3 ||
            upgraded.astroPlan?.backgroundCoefficients.allSatisfy({ $0.count == 10 }) != true {
            upgraded.astroPlan = analysis.plan
            // Reanalysis must not undo the user's choice to disable processing.
            upgraded.updated = Date()
            try save(upgraded)
        }
        cachedPreview = (upgraded.id, preview)
        return LabLoadedPhoto(project: upgraded, preview: preview, measurement: analysis.measurement)
    }

    func save(_ project: PhotoProject) throws {
        var value = project
        value.recipe = value.recipe.bounded
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory(project).appendingPathComponent("project.json"), options: .atomic)
    }

    func render(_ project: PhotoProject) throws -> LabRenderedPhoto {
        try Task.checkCancellation()
        let preview: CGImage
        if let cachedPreview, cachedPreview.0 == project.id { preview = cachedPreview.1 }
        else { preview = try open(project).preview }
        let result = try renderImage(CIImage(cgImage: preview), recipe: project.recipe,
            autoPlan: project.automaticProcessingDisabled == true ? nil : project.astroPlan,
            automaticStrength: project.boundedAutomaticStrength)
        try Task.checkCancellation()
        return LabRenderedPhoto(image: result, measurement: try measure(result))
    }

    func originalCopy(_ project: PhotoProject) throws -> URL {
        try verify(project)
        let folder = try exportFolder()
        let url = folder.appendingPathComponent("Original-\(project.sha256.prefix(10)).\(project.sourceExtension)")
        try manager.copyItem(at: sourceURL(project), to: url)
        return url
    }

    func inspect(_ project: PhotoProject, region: Int) throws -> LabDetail {
        try verify(project); try Task.checkCancellation()
        guard let input = CIImage(contentsOf: sourceURL(project), options: [.applyOrientationProperty: true]) else {
            throw LabError.invalid("The source could not be opened for detail inspection.")
        }
        let area = input.extent
        let w = min(1024, area.width), h = min(1024, area.height)
        let cell = min(8, max(0, region))
        let rect = CGRect(x: area.minX + (area.width-w)*CGFloat(cell%3)/2,
            y: area.minY + (area.height-h)*CGFloat(2-cell/3)/2, width: w, height: h).integral
        let output = try process(input, recipe: project.recipe.bounded,
            autoPlan: project.automaticProcessingDisabled == true ? nil : project.astroPlan,
            automaticStrength: project.boundedAutomaticStrength)
        guard let original = context.createCGImage(input, from: rect, format: .RGBA8, colorSpace: colorSpace),
              let edited = context.createCGImage(output, from: rect, format: .RGBA8, colorSpace: colorSpace) else {
            throw LabError.invalid("Detail rendering failed. Your original remains saved.")
        }
        try Task.checkCancellation()
        return LabDetail(original: original, edited: edited, width: original.width, height: original.height)
    }

    func export(_ project: PhotoProject, format: LabExportFormat) throws -> LabExport {
        try verify(project)
        try Task.checkCancellation()
        guard let input = CIImage(contentsOf: sourceURL(project), options: [.applyOrientationProperty: true]) else {
            throw LabError.invalid("The original could not be decoded for export.")
        }
        let activePlan = project.automaticProcessingDisabled == true || project.boundedAutomaticStrength == 0 ? nil : project.astroPlan
        let output = try process(input, recipe: project.recipe.bounded, autoPlan: activePlan,
            automaticStrength: project.boundedAutomaticStrength).settingProperties([:])
        let bytes: Data?
        switch format {
        case .png: bytes = context.pngRepresentation(of: output, format: .RGBA8, colorSpace: colorSpace)
        case .tiff: bytes = context.tiffRepresentation(of: output, format: .RGBA16, colorSpace: colorSpace)
        }
        guard let bytes, let encoded = CGImageSourceCreateWithData(bytes as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any],
              props[kCGImagePropertyPixelWidth] as? Int == project.width,
              props[kCGImagePropertyPixelHeight] as? Int == project.height else {
            throw LabError.invalid("Export validation failed. No finished image was saved.")
        }
        if format == .tiff && props[kCGImagePropertyDepth] as? Int != 16 {
            throw LabError.invalid("The TIFF encoder did not produce the requested 16-bit file.")
        }
        try Task.checkCancellation()
        let folder = try exportFolder()
        let name = "Sensei-\(project.sha256.prefix(10))"
        let imageURL = folder.appendingPathComponent("\(name).\(format.suffix)")
        let reportURL = folder.appendingPathComponent("\(name)-recipe.json")
        try bytes.write(to: imageURL, options: .atomic)
        try verify(project)
        struct Audit: Encodable {
            let engine = PhotoPipeline.engineVersion
            let exportedAt = Date()
            let project: PhotoProject
            let format: LabExportFormat
            let outputSHA256: String
            let operations: [String]
            let notes = ["Original imported bytes verified unchanged using full SHA-256.",
                "Output uses sRGB. EXIF orientation is baked in; composition is not cropped or warped.",
                "No original GPS/EXIF metadata copied into the export.",
                "No generative models, object replacement, or learned detail reconstruction.",
                "Conventional filters can still suppress real detail or introduce artifacts; inspect at 100%.",
                "16-bit output does not recover precision or detail absent from the input."]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let operations = (activePlan?.operations ?? ["Automatic astrophotography processing disabled"])
            + [String(format: "Automatic development blend strength: %.3f", project.boundedAutomaticStrength)]
            + project.recipe.bounded.operations
        try encoder.encode(Audit(project: project, format: format, outputSHA256: Self.hash(bytes), operations: operations))
            .write(to: reportURL, options: .atomic)
        return LabExport(imageURL: imageURL, reportURL: reportURL, originalSHA256: project.sha256, width: project.width, height: project.height)
    }

    // Internal so deterministic macOS regression tests exercise the actual iPhone processing code.
    func renderImage(_ source: CIImage, recipe: PhotoRecipe, autoPlan: AstroAutoPlan? = nil, automaticStrength: Double = 1) throws -> CGImage {
        let output = try process(source, recipe: recipe.bounded, autoPlan: autoPlan, automaticStrength: automaticStrength)
        guard let image = context.createCGImage(output, from: source.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw LabError.invalid("Rendering failed. The original is safe.")
        }
        return image
    }

    private func process(_ source: CIImage, recipe: PhotoRecipe, autoPlan: AstroAutoPlan?, automaticStrength: Double = 1) throws -> CIImage {
        let strength = automaticStrength.isFinite ? min(1, max(0, automaticStrength)) : 1
        guard recipe.hasAdjustments || (autoPlan != nil && strength > 0) else { return source }
        var result = source
        func filter(_ name: String, _ params: [String: Any]) throws {
            var values = params; values[kCIInputImageKey] = result
            guard let output = CIFilter(name: name, parameters: values)?.outputImage else {
                throw LabError.invalid("Required photo operation \(name) is unavailable. Export stopped.")
            }
            result = output
        }
        if let plan = autoPlan, strength > 0 {
            result = try automaticDevelop(result, plan: plan)
            if strength < 1 {
                guard let blend = CIFilter(name: "CIDissolveTransition", parameters: [
                    kCIInputImageKey: source, kCIInputTargetImageKey: result,
                    kCIInputTimeKey: strength])?.outputImage else {
                    throw LabError.invalid("Processing-strength blend failed. Your original is safe.")
                }
                result = blend.cropped(to: source.extent)
            }
        }
        if recipe.exposure != 0 { try filter("CIExposureAdjust", [kCIInputEVKey: recipe.exposure]) }
        if recipe.warmth != 0 {
            try filter("CIColorMatrix", ["inputRVector": CIVector(x: 1+recipe.warmth, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1-recipe.warmth, w: 0)])
        }
        if recipe.midtones != 0 {
            try filter("CIToneCurve", ["inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25+recipe.midtones),
                "inputPoint2": CIVector(x: 0.5, y: 0.5+recipe.midtones*0.7),
                "inputPoint3": CIVector(x: 0.75, y: 0.75+recipe.midtones*0.25),
                "inputPoint4": CIVector(x: 1, y: 1)])
        }
        if recipe.contrast != 1 || recipe.saturation != 1 {
            try filter("CIColorControls", [kCIInputContrastKey: recipe.contrast, kCIInputSaturationKey: recipe.saturation])
        }
        if recipe.denoise > 0 { try filter("CINoiseReduction", ["inputNoiseLevel": recipe.denoise, "inputSharpness": 0]) }
        if recipe.sharpen > 0 { try filter("CISharpenLuminance", [kCIInputSharpnessKey: recipe.sharpen]) }
        if recipe.protectHighlights {
            // Mask from this source, not a star classifier: restore the brightest source channels.
            let n = 16
            var cube = [Float](); cube.reserveCapacity(n*n*n*4)
            for b in 0..<n { for g in 0..<n { for r in 0..<n {
                let v = Double(max(r, max(g,b))) / Double(n-1)
                let t = min(1, max(0, (v - 0.65) / 0.30))
                let m = Float(t*t*(3-2*t))
                cube.append(contentsOf: [m,m,m,1])
            } } }
            let data = cube.withUnsafeBytes { Data($0) }
            guard let mask = CIFilter(name: "CIColorCubeWithColorSpace", parameters: [kCIInputImageKey: source,
                "inputCubeDimension": n, "inputCubeData": data, "inputColorSpace": colorSpace])?.outputImage,
                  let blended = CIFilter(name: "CIBlendWithMask", parameters: [kCIInputImageKey: source,
                    kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask])?.outputImage else {
                throw LabError.invalid("Highlight protection failed. No unprotected export was produced.")
            }
            result = blended
        }
        return result.cropped(to: source.extent)
    }

    private func automaticDevelop(_ source: CIImage, plan: AstroAutoPlan) throws -> CIImage {
        guard plan.backgroundCoefficients.count == 3,
              plan.backgroundCoefficients.allSatisfy({ $0.count == 10 }),
              plan.backgroundReference.count == 3, plan.channelGains.count == 3 else {
            throw LabError.invalid("The saved automatic processing plan is invalid. Your original is safe.")
        }
        let gridWidth = 64, gridHeight = 64
        var correction = [Float](repeating: 0, count: gridWidth * gridHeight * 4)
        for y in 0..<gridHeight { for x in 0..<gridWidth {
            let nx = (Double(x) + 0.5) / Double(gridWidth)
            let ny = 1 - (Double(y) + 0.5) / Double(gridHeight)
            let basis = [1.0, nx, ny, nx*nx, nx*ny, ny*ny,
                nx*nx*nx, nx*nx*ny, nx*ny*ny, ny*ny*ny]
            let i = (y * gridWidth + x) * 4
            for channel in 0..<3 {
                let background = zip(plan.backgroundCoefficients[channel], basis).reduce(0) { $0 + $1.0 * $1.1 }
                correction[i + channel] = Float(plan.backgroundReference[channel] - background)
            }
            // Keep the correction field transparent so addition preserves the
            // source alpha instead of replacing it with an opaque foreground.
            correction[i + 3] = 0
        } }
        let correctionData = correction.withUnsafeBytes { Data($0) }
        var field = CIImage(bitmapData: correctionData, bytesPerRow: gridWidth * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: gridWidth, height: gridHeight), format: .RGBAf, colorSpace: colorSpace)
        field = field.transformed(by: CGAffineTransform(scaleX: source.extent.width / CGFloat(gridWidth),
            y: source.extent.height / CGFloat(gridHeight)))
            .transformed(by: CGAffineTransform(translationX: source.extent.minX, y: source.extent.minY))
            .cropped(to: source.extent)
        guard var result = CIFilter(name: "CIAdditionCompositing", parameters: [kCIInputImageKey: field,
            kCIInputBackgroundImageKey: source])?.outputImage?.cropped(to: source.extent) else {
            throw LabError.invalid("Background correction could not be rendered.")
        }

        let span = max(0.05, plan.whitePoint - plan.blackPoint)
        let scales = plan.channelGains.map { $0 / span }
        let bias = -plan.blackPoint / span
        guard let normalized = CIFilter(name: "CIColorMatrix", parameters: [kCIInputImageKey: result,
            "inputRVector": CIVector(x: scales[0], y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scales[1], z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scales[2], w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])?.outputImage else {
            throw LabError.invalid("Sky normalization could not be rendered.")
        }
        result = normalized.cropped(to: source.extent)

        // Two restrained conventional denoise passes target only the low-signal
        // background. Nebulae and star cores are restored through measured masks.
        if plan.noiseLevel > 0,
           let denoised = CIFilter(name: "CINoiseReduction", parameters: [kCIInputImageKey: result,
                "inputNoiseLevel": min(0.05, plan.noiseLevel * 1.15), "inputSharpness": 0.04])?.outputImage,
           let secondPass = CIFilter(name: "CINoiseReduction", parameters: [kCIInputImageKey: denoised,
                "inputNoiseLevel": min(0.035, plan.noiseLevel * 0.72), "inputSharpness": 0])?.outputImage,
           let mask = intensityMask(result, low: 0.12, high: 0.42, inverted: true),
           let blended = CIFilter(name: "CIBlendWithMask", parameters: [kCIInputImageKey: denoised,
                kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask])?.outputImage {
            // The second pass contributes only half strength, reducing
            // low-signal mottling without turning faint structures waxy.
            if let halfMask = scaledMask(mask, amount: 0.5),
               let twiceBlended = CIFilter(name: "CIBlendWithMask", parameters: [kCIInputImageKey: secondPass,
                    kCIInputBackgroundImageKey: blended, kCIInputMaskImageKey: halfMask])?.outputImage {
                result = twiceBlended.cropped(to: source.extent)
            } else {
                result = blended.cropped(to: source.extent)
            }
        }

        // Professional astro workflows treat luminance and chroma noise
        // separately. This pass is limited to measured low-signal background;
        // the existing signal mask prevents color detail from being smeared.
        if let chroma = plan.chromaNoiseLevel, chroma > 0,
           let reduced = CIFilter(name: "CIColorControls", parameters: [
                kCIInputImageKey: result,
                kCIInputSaturationKey: 1 - min(0.24, chroma * 4.0),
                kCIInputContrastKey: 1.0])?.outputImage,
           let skyMask = intensityMask(result, low: 0.10, high: 0.34, inverted: true),
           let mask = scaledMask(skyMask, amount: 0.82),
           let blended = CIFilter(name: "CIBlendWithMask", parameters: [
                kCIInputImageKey: reduced, kCIInputBackgroundImageKey: result,
                kCIInputMaskImageKey: mask])?.outputImage {
            result = blended.cropped(to: source.extent)
        }

        if let amount = plan.asinhStretch, amount.isFinite, amount > 0,
           let linked = luminanceStretch(result, amount: amount,
                gain: plan.displayGain ?? 1,
                highlightProtection: plan.highlightProtectionPoint ?? 0.68) {
            result = linked.cropped(to: source.extent)
        } else {
            guard let stretched = CIFilter(name: "CIGammaAdjust", parameters: [kCIInputImageKey: result,
                "inputPower": min(0.96, max(0.68, plan.gamma))])?.outputImage else {
                throw LabError.invalid("Nonlinear signal stretch could not be rendered.")
            }
            result = stretched.cropped(to: source.extent)
        }

        if plan.asinhStretch == nil, let gain = plan.displayGain, gain.isFinite, gain != 1,
           let balanced = CIFilter(name: "CIColorMatrix", parameters: [kCIInputImageKey: result,
                "inputRVector": CIVector(x: min(1.12, max(0.48, gain)), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: min(1.12, max(0.48, gain)), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: min(1.12, max(0.48, gain)), w: 0)])?.outputImage {
            result = balanced.cropped(to: source.extent)
        }

        // Separate fine and broad scales reveal existing structure. Both are
        // source-masked so bright star cores cannot be sharpened into halos.
        if let fine = CIFilter(name: "CIUnsharpMask", parameters: [kCIInputImageKey: result,
            kCIInputRadiusKey: 1.15, kCIInputIntensityKey: 0.16])?.outputImage,
           let fineMask = intensityMask(result, low: 0.10, high: 0.68, inverted: false),
           let starProtection = intensityMask(result, low: 0.52, high: 0.84, inverted: true),
           let activeMask = multipliedMask(fineMask, starProtection),
           let fineBlend = CIFilter(name: "CIBlendWithMask", parameters: [kCIInputImageKey: fine,
                kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: activeMask])?.outputImage {
            result = fineBlend.cropped(to: source.extent)
        }

        let radius = min(28.0, max(4.0, Double(max(source.extent.width, source.extent.height)) / 175.0))
        if let enhanced = CIFilter(name: "CIUnsharpMask", parameters: [kCIInputImageKey: result,
            kCIInputRadiusKey: radius, kCIInputIntensityKey: min(0.32, max(0, plan.localContrast))])?.outputImage,
           let signal = intensityMask(result, low: 0.055, high: 0.24, inverted: false),
           let stars = intensityMask(result, low: 0.46, high: 0.80, inverted: true),
           let mask = multipliedMask(signal, stars),
           let blended = CIFilter(name: "CIBlendWithMask", parameters: [kCIInputImageKey: enhanced,
            kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask])?.outputImage {
            result = blended.cropped(to: source.extent)
        }

        if plan.saturation != 1,
           let colored = CIFilter(name: "CIColorControls", parameters: [kCIInputImageKey: result,
            kCIInputSaturationKey: min(1.32, max(0.9, plan.saturation)), kCIInputContrastKey: 1.0])?.outputImage,
           let signal = intensityMask(result, low: 0.045, high: 0.20, inverted: false),
           let highlights = intensityMask(result, low: 0.50, high: 0.88, inverted: true),
           let mask = multipliedMask(signal, highlights),
           let blended = CIFilter(name: "CIBlendWithMask", parameters: [kCIInputImageKey: colored,
            kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask])?.outputImage {
            result = blended.cropped(to: source.extent)
        }

        // Exact bright source pixels are the safest available reference for
        // stars and luminous cores. Blend only their brightest range back so
        // the automatic stretch cannot create additional clipping or star bloat.
        if let bright = intensityMask(source, low: 0.78, high: 0.98, inverted: false),
           let protected = CIFilter(name: "CIBlendWithMask", parameters: [
                kCIInputImageKey: source, kCIInputBackgroundImageKey: result,
                kCIInputMaskImageKey: bright])?.outputImage {
            result = protected.cropped(to: source.extent)
        }
        return result
    }

    /// A compact 3D LUT applies one human-weighted luminance curve to RGB.
    /// It preserves channel ratios, progressively returns to identity in the
    /// highlights, and rescales only when a component would otherwise clip.
    private func luminanceStretch(_ image: CIImage, amount: Double, gain: Double,
        highlightProtection: Double) -> CIImage? {
        let n = 32
        let d = Double(n - 1)
        let strength = min(64, max(0.1, amount))
        let outputGain = min(1.12, max(0.35, gain))
        let protection = min(0.88, max(0.35, highlightProtection))
        var cube: [Float] = []; cube.reserveCapacity(n*n*n*4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let rgb = [Double(r)/d, Double(g)/d, Double(b)/d]
            let luma = 0.2126*rgb[0] + 0.7152*rgb[1] + 0.0722*rgb[2]
            let stretched = asinh(strength*luma) / asinh(strength) * outputGain
            let t = min(1, max(0, (luma-protection) / max(0.01, 0.96-protection)))
            let smooth = t*t*(3-2*t)
            let mapped = stretched*(1-smooth) + luma*smooth
            var output = rgb.map { $0 * mapped / max(luma, 1.0/65535.0) }
            let peak = output.max() ?? 1
            if peak > 1 { output = output.map { $0 / peak } }
            cube.append(contentsOf: output.map { Float(min(1, max(0, $0))) } + [1])
        } } }
        let data = cube.withUnsafeBytes { Data($0) }
        return CIFilter(name: "CIColorCubeWithColorSpace", parameters: [
            kCIInputImageKey: image, "inputCubeDimension": n,
            "inputCubeData": data, "inputColorSpace": colorSpace])?.outputImage
    }

    private func multipliedMask(_ first: CIImage, _ second: CIImage) -> CIImage? {
        CIFilter(name: "CIMultiplyCompositing", parameters: [kCIInputImageKey: first,
            kCIInputBackgroundImageKey: second])?.outputImage
    }

    private func scaledMask(_ mask: CIImage, amount: Double) -> CIImage? {
        let value = min(1, max(0, amount))
        return CIFilter(name: "CIColorMatrix", parameters: [kCIInputImageKey: mask,
            "inputRVector": CIVector(x: value, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: value, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: value, w: 0)])?.outputImage
    }

    private func intensityMask(_ image: CIImage, low: Double, high: Double, inverted: Bool) -> CIImage? {
        let n = 16
        var cube: [Float] = []; cube.reserveCapacity(n*n*n*4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let luma = 0.2126 * Double(r) / Double(n-1) + 0.7152 * Double(g) / Double(n-1) + 0.0722 * Double(b) / Double(n-1)
            let t = min(1, max(0, (luma - low) / max(0.001, high - low)))
            let smooth = t*t*(3-2*t)
            let value = Float(inverted ? 1-smooth : smooth)
            cube.append(contentsOf: [value, value, value, 1])
        } } }
        let data = cube.withUnsafeBytes { Data($0) }
        return CIFilter(name: "CIColorCubeWithColorSpace", parameters: [kCIInputImageKey: image,
            "inputCubeDimension": n, "inputCubeData": data, "inputColorSpace": colorSpace])?.outputImage
    }

    private func analyze(_ image: CGImage) throws -> (measurement: PhotoMeasurement, plan: AstroAutoPlan?) {
        let scale = min(1, 1024.0 / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width)*scale)), h = max(1, Int(Double(image.height)*scale))
        let bytes = try rgba(image, width: w, height: h)
        guard let measurement = PhotoMeasurement.measure(rgba: bytes, width: w, height: h) else {
            throw LabError.invalid("Image analysis failed; no guessed settings were applied.")
        }
        return (measurement, AstroAutoPlan.analyze(rgba: bytes, width: w, height: h))
    }

    private func measure(_ image: CGImage) throws -> PhotoMeasurement {
        let scale = min(1, 384.0 / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width)*scale)), h = max(1, Int(Double(image.height)*scale))
        let bytes = try rgba(image, width: w, height: h)
        guard let m = PhotoMeasurement.measure(rgba: bytes, width: w, height: h) else { throw LabError.invalid("Image analysis failed; no guessed settings were applied.") }
        return m
    }

    private func rgba(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width*height*4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw LabError.invalid("The image could not be sampled for analysis.") }
        return bytes
    }

    private func thumbnail(_ source: CGImageSource, maxPixel: Int) throws -> CGImage {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw LabError.invalid("The image preview cannot be decoded.") }
        return image
    }

    private func verify(_ p: PhotoProject) throws {
        guard Self.hash(try Data(contentsOf: sourceURL(p))) == p.sha256 else {
            throw LabError.invalid("Source checksum mismatch. Processing stopped to protect your original.")
        }
    }
    private func prepareRoot() throws { try manager.createDirectory(at: root, withIntermediateDirectories: true) }
    private func directory(_ p: PhotoProject) -> URL { root.appendingPathComponent(p.id.uuidString, isDirectory: true) }
    private func sourceURL(_ p: PhotoProject) -> URL { directory(p).appendingPathComponent("source.\(p.sourceExtension)") }
    private func exportFolder() throws -> URL {
        let url = root.appendingPathComponent("Exports", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
#endif
