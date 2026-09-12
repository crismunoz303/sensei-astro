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
    private let context = CIContext(options: [.cacheIntermediates: false, .workingFormat: CIFormat.RGBAh])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var cachedPreview: (UUID, CGImage)?
    private let manager = FileManager.default
    static let engineVersion = "true-edit-1.3.0"

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
        let project = PhotoProject(id: UUID(), created: Date(), sha256: digest,
            sourceExtension: type.preferredFilenameExtension ?? "image", sourceBytes: data.count,
            width: swapped ? height : width, height: swapped ? width : height,
            sourceDepth: props[kCGImagePropertyDepth] as? Int ?? 8,
            recipe: .identity, intent: .astro, updated: Date())
        // Decode before committing a project; invalid files never create a usable project.
        let preview = try thumbnail(source, maxPixel: 1400)
        let measurement = try measure(preview)
        try manager.createDirectory(at: directory(project), withIntermediateDirectories: true)
        try data.write(to: sourceURL(project), options: .atomic)
        guard Self.hash(try Data(contentsOf: sourceURL(project))) == digest else {
            throw LabError.invalid("Original-file verification failed. Import stopped.")
        }
        try save(project)
        cachedPreview = (project.id, preview)
        return LabLoadedPhoto(project: project, preview: preview, measurement: measurement)
    }

    func open(_ project: PhotoProject) throws -> LabLoadedPhoto {
        try verify(project)
        guard let source = CGImageSourceCreateWithURL(sourceURL(project) as CFURL, nil) else { throw LabError.invalid("The saved source cannot be decoded.") }
        let preview = try thumbnail(source, maxPixel: 1400)
        cachedPreview = (project.id, preview)
        return LabLoadedPhoto(project: project, preview: preview, measurement: try measure(preview))
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
        let result = try renderImage(CIImage(cgImage: preview), recipe: project.recipe)
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
        let output = try process(input, recipe: project.recipe.bounded)
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
        let output = try process(input, recipe: project.recipe.bounded).settingProperties([:])
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
        try encoder.encode(Audit(project: project, format: format, outputSHA256: Self.hash(bytes), operations: project.recipe.bounded.operations))
            .write(to: reportURL, options: .atomic)
        return LabExport(imageURL: imageURL, reportURL: reportURL, originalSHA256: project.sha256, width: project.width, height: project.height)
    }

    // Internal so deterministic macOS regression tests exercise the actual iPhone processing code.
    func renderImage(_ source: CIImage, recipe: PhotoRecipe) throws -> CGImage {
        let output = try process(source, recipe: recipe.bounded)
        guard let image = context.createCGImage(output, from: source.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw LabError.invalid("Rendering failed. The original is safe.")
        }
        return image
    }

    private func process(_ source: CIImage, recipe: PhotoRecipe) throws -> CIImage {
        guard recipe.hasAdjustments else { return source }
        var result = source
        func filter(_ name: String, _ params: [String: Any]) throws {
            var values = params; values[kCIInputImageKey] = result
            guard let output = CIFilter(name: name, parameters: values)?.outputImage else {
                throw LabError.invalid("Required photo operation \(name) is unavailable. Export stopped.")
            }
            result = output
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

    private func measure(_ image: CGImage) throws -> PhotoMeasurement {
        let scale = min(1, 384.0 / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width)*scale)), h = max(1, Int(Double(image.height)*scale))
        var bytes = [UInt8](repeating: 0, count: w*h*4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok, let m = PhotoMeasurement.measure(rgba: bytes, width: w, height: h) else { throw LabError.invalid("Image analysis failed; no guessed settings were applied.") }
        return m
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
