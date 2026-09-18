import XCTest
import Foundation
@testable import SenseiAstroCore

final class PhotoAnalysisTests: XCTestCase {
    func testAstroPlanModelsAColorGradientAndProducesBoundedDevelopment() throws {
        let width = 180, height = 120
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let gradient = Double(x) / Double(width - 1) * 28 + Double(y) / Double(height - 1) * 12
            rgba[i] = UInt8(min(250, 19 + Int(gradient)))
            rgba[i + 1] = UInt8(min(250, 16 + Int(gradient * 0.82)))
            rgba[i + 2] = UInt8(min(250, 24 + Int(gradient * 1.08)))
            if (x * 17 + y * 31) % 401 == 0 { rgba[i] = 230; rgba[i + 1] = 225; rgba[i + 2] = 245 }
        } }
        let plan = try XCTUnwrap(AstroAutoPlan.analyze(rgba: rgba, width: width, height: height))
        XCTAssertEqual(plan.backgroundCoefficients.count, 3)
        XCTAssertTrue(plan.backgroundCoefficients.allSatisfy { $0.count == 10 && $0.allSatisfy(\.isFinite) })
        XCTAssertEqual(plan.channelGains.count, 3)
        XCTAssertTrue(plan.channelGains.allSatisfy { (0.75...1.35).contains($0) })
        XCTAssertGreaterThan(plan.whitePoint, plan.blackPoint)
        XCTAssertTrue((0.68...0.96).contains(plan.gamma))
        XCTAssertGreaterThanOrEqual(plan.sampledTiles, 20)
        XCTAssertEqual(plan.planVersion, 3)
        XCTAssertTrue((0.42...1.08).contains(try XCTUnwrap(plan.displayGain)))
        XCTAssertTrue((5...48).contains(try XCTUnwrap(plan.asinhStretch)))
        XCTAssertTrue((0.48...0.78).contains(try XCTUnwrap(plan.highlightProtectionPoint)))
        XCTAssertTrue((0.008...0.055).contains(try XCTUnwrap(plan.chromaNoiseLevel)))
        XCTAssertLessThanOrEqual(plan.blackPoint, max(0, plan.skyLevel - max(2.4 * plan.skySigma, 2.0 / 255.0)) + 0.000_001)
        XCTAssertTrue(plan.operations.joined().contains("cubic background"))
        XCTAssertTrue(plan.operations.joined().contains("Luminance-linked asinh"))
    }
    func testBlackSkyDoesNotTriggerAutomaticExposure() throws {
        let m = try XCTUnwrap(PhotoMeasurement.measure(rgba: Array(repeating: [UInt8(0),0,0,255], count: 64).flatMap { $0 }, width: 8, height: 8))
        XCTAssertEqual(m.crushedBlacks, 1)
        XCTAssertEqual(m.histogram.reduce(0,+), 64)
        XCTAssertEqual(PhotoAdvice.make(m, intent: .astro).recipe, .identity)
    }
    func testClippedColorChannelBlocksAutomaticLift() throws {
        let m = try XCTUnwrap(PhotoMeasurement.measure(rgba: Array(repeating: [UInt8(255),0,0,255], count: 16).flatMap { $0 }, width: 4, height: 4))
        XCTAssertEqual(m.clippedHighlights, 1)
        XCTAssertFalse(PhotoAdvice.make(m, intent: .astro).recipe.hasAdjustments)
    }
    func testTransparentPixelsAreExcludedAndInvalidBuffersRejected() throws {
        XCTAssertNil(PhotoMeasurement.measure(rgba: [], width: 0, height: 0))
        XCTAssertNil(PhotoMeasurement.measure(rgba: [0], width: 2, height: 2))
        XCTAssertNil(PhotoMeasurement.measure(rgba: [0,0,0,0], width: 1, height: 1))
        let m = try XCTUnwrap(PhotoMeasurement.measure(rgba: [255,255,255,0, 40,40,40,255], width: 2, height: 1))
        XCTAssertEqual(m.samples, 1); XCTAssertEqual(m.clippedHighlights, 0)
    }
    func testSuggestionsDoNotInventColorOrDetail() throws {
        let m = try XCTUnwrap(PhotoMeasurement.measure(rgba: Array(repeating: [UInt8(15),15,15,255], count: 64).flatMap { $0 }, width: 8, height: 8))
        let advice = PhotoAdvice.make(m, intent: .astro)
        XCTAssertGreaterThan(advice.recipe.midtones, 0)
        XCTAssertEqual(advice.recipe.exposure, 0)
        XCTAssertEqual(advice.recipe.saturation, 1)
        XCTAssertEqual(advice.recipe.warmth, 0)
        XCTAssertEqual(advice.recipe.denoise, 0)
        XCTAssertEqual(advice.recipe.sharpen, 0)
        XCTAssertTrue(advice.recipe.protectHighlights)
    }
    func testInvalidRecipeValuesBecomeSafeFiniteValues() {
        var r = PhotoRecipe.identity
        r.exposure = .infinity; r.saturation = .nan; r.sharpen = 900; r.denoise = -20
        XCTAssertEqual(r.bounded.exposure, 0); XCTAssertEqual(r.bounded.saturation, 1)
        XCTAssertEqual(r.bounded.sharpen, 0.4); XCTAssertEqual(r.bounded.denoise, 0)
    }

    func testAdaptivePlanHandlesExtendedNebulaAndDenseStarScenes() throws {
        let width = 144, height = 96
        for extended in [false, true] {
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let i = (y*width+x)*4
                let dx = Double(x-width/2), dy = Double(y-height/2)
                let glow = extended ? Int(70 * exp(-(dx*dx/1500 + dy*dy/500))) : 0
                let star = !extended && (x*23+y*41)%733 == 0 ? 210 : 0
                rgba[i] = UInt8(min(250, 13 + glow + star))
                rgba[i+1] = UInt8(min(250, 15 + glow/2 + star))
                rgba[i+2] = UInt8(min(250, 20 + glow/3 + star))
            } }
            let plan = try XCTUnwrap(AstroAutoPlan.analyze(rgba: rgba, width: width, height: height))
            XCTAssertEqual(plan.planVersion, 3)
            XCTAssertNotNil(plan.asinhStretch)
            XCTAssertNotNil(plan.highlightProtectionPoint)
            XCTAssertNotNil(plan.chromaNoiseLevel)
        }
    }
}

#if canImport(CoreImage)
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class PhotoPipelineTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SenseiPhotoTests-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testOriginalBytesSurviveEditExportAndRestart() async throws {
        let engine = PhotoPipeline(root: root)
        let source = try fixture()
        var p = try await engine.importData(source).project
        p.recipe.midtones = 0.04; p.recipe.saturation = 1.08
        try await engine.save(p)
        let export = try await engine.export(p, format: .png)
        XCTAssertEqual(export.width, 64); XCTAssertEqual(export.height, 48)
        let original = try await engine.originalCopy(p)
        XCTAssertEqual(try Data(contentsOf: original), source)
        let restored = PhotoPipeline(root: root)
        let projects = try await restored.projects()
        let opened = try await restored.open(XCTUnwrap(projects.first))
        XCTAssertEqual(opened.project.recipe, p.recipe)
        XCTAssertNotNil(opened.project.astroPlan)
        XCTAssertEqual(opened.project.sha256.count, 64)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: export.reportURL)) as? [String: Any])
        XCTAssertNotNil(report["outputSHA256"])
    }

    func testDuplicateImportRetainsExistingRecipe() async throws {
        let engine = PhotoPipeline(root: root), source = try fixture()
        var p = try await engine.importData(source).project
        p.recipe.exposure = 0.2; try await engine.save(p)
        let again = try await engine.importData(source)
        XCTAssertEqual(again.project.id, p.id); XCTAssertEqual(again.project.recipe, p.recipe)
    }

    func testTIFFExportIsReally16BitAndHasNoGPS() async throws {
        let engine = PhotoPipeline(root: root)
        let p = try await engine.importData(fixture()).project
        let export = try await engine.export(p, format: .tiff)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(export.imageURL as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyDepth] as? Int, 16)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
    }

    func testRotatedSourceHasCorrectPreviewAndExportDimensions() async throws {
        let engine = PhotoPipeline(root: root)
        let loaded = try await engine.importData(fixture(orientation: 6))
        XCTAssertEqual(loaded.project.width, 48); XCTAssertEqual(loaded.project.height, 64)
        XCTAssertEqual(loaded.preview.width, 48); XCTAssertEqual(loaded.preview.height, 64)
        let export = try await engine.export(loaded.project, format: .png)
        XCTAssertEqual(export.width, 48); XCTAssertEqual(export.height, 64)
    }

    func testIdentityAndResetHaveIdenticalRenderedPixels() async throws {
        let engine = PhotoPipeline(root: root)
        var p = try await engine.importData(fixture()).project
        let baseline = try await engine.render(p)
        p.recipe.exposure = 0.3
        let edited = try await engine.render(p)
        XCTAssertNotEqual(edited.measurement.median, baseline.measurement.median)
        p.recipe = .identity
        let reset = try await engine.render(p)
        XCTAssertEqual(reset.image.dataProvider?.data as Data?, baseline.image.dataProvider?.data as Data?)
    }

    func testAutomaticAstroDevelopmentChangesPreviewAndCanBeDisabled() async throws {
        let engine = PhotoPipeline(root: root)
        var p = try await engine.importData(fixture()).project
        XCTAssertNotNil(p.astroPlan)
        let developed = try await engine.render(p)
        p.automaticProcessingDisabled = true
        let neutral = try await engine.render(p)
        XCTAssertNotEqual(developed.image.dataProvider?.data as Data?, neutral.image.dataProvider?.data as Data?)
        XCTAssertEqual(neutral.image.width, p.width)
        XCTAssertEqual(neutral.image.height, p.height)
        XCTAssertLessThan(developed.measurement.crushedBlacks, 0.08,
            "Automatic development must not repeat the prior crushed-sky failure.")
    }

    func testEveryConventionalOperationCanRenderWithoutChangingGeometry() async throws {
        let engine = PhotoPipeline(root: root)
        var p = try await engine.importData(fixture()).project
        p.recipe = PhotoRecipe(exposure: 0.1, midtones: 0.04, contrast: 1.02, saturation: 1.1, warmth: 0.02, denoise: 0.01, sharpen: 0.15, protectHighlights: true)
        let result = try await engine.render(p)
        XCTAssertEqual(result.image.width, p.width); XCTAssertEqual(result.image.height, p.height)
        XCTAssertTrue(result.measurement.median.isFinite)
    }

    func testAutomaticStrengthZeroIsNeutralAndHalfIsDistinct() async throws {
        let engine = PhotoPipeline(root: root)
        var p = try await engine.importData(fixture()).project
        let full = try await engine.render(p)
        p.automaticStrength = 0.5
        let half = try await engine.render(p)
        p.automaticStrength = 0
        let zero = try await engine.render(p)
        p.automaticProcessingDisabled = true
        let disabled = try await engine.render(p)
        XCTAssertEqual(zero.image.dataProvider?.data as Data?, disabled.image.dataProvider?.data as Data?)
        XCTAssertNotEqual(half.image.dataProvider?.data as Data?, full.image.dataProvider?.data as Data?)
        XCTAssertNotEqual(half.image.dataProvider?.data as Data?, zero.image.dataProvider?.data as Data?)
        XCTAssertEqual(half.image.width, p.width)
    }

    func testStrengthPersistsAndIsRecordedInExport() async throws {
        let engine = PhotoPipeline(root: root)
        var p = try await engine.importData(fixture()).project
        p.automaticStrength = 0.4
        try await engine.save(p)
        let restarted = PhotoPipeline(root: root)
        let saved = try await restarted.projects()
        let restored = try await restarted.open(XCTUnwrap(saved.first))
        XCTAssertEqual(restored.project.boundedAutomaticStrength, 0.4)
        let exported = try await restarted.export(restored.project, format: .png)
        let audit = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported.reportURL)) as? [String: Any])
        XCTAssertTrue((audit["operations"] as? [String])?.contains("Automatic development blend strength: 0.400") == true)
        p.automaticStrength = .nan
        XCTAssertEqual(p.boundedAutomaticStrength, 1)
        p.automaticStrength = -1
        XCTAssertEqual(p.boundedAutomaticStrength, 0)
        p.automaticStrength = 2
        XCTAssertEqual(p.boundedAutomaticStrength, 1)
    }

    func testReanalysisPreservesDisabledProcessingAndOldProjectCompatibility() async throws {
        let engine = PhotoPipeline(root: root)
        var p = try await engine.importData(fixture()).project
        p.astroPlan = nil
        p.automaticProcessingDisabled = true
        let opened = try await engine.open(p)
        XCTAssertEqual(opened.project.automaticProcessingDisabled, true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(opened.project)) as? [String: Any])
        json.removeValue(forKey: "automaticStrength")
        if var oldPlan = json["astroPlan"] as? [String: Any] {
            oldPlan.removeValue(forKey: "asinhStretch")
            oldPlan.removeValue(forKey: "highlightProtectionPoint")
            oldPlan.removeValue(forKey: "chromaNoiseLevel")
            json["astroPlan"] = oldPlan
        }
        let old = try JSONDecoder().decode(PhotoProject.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.boundedAutomaticStrength, 1)
        XCTAssertNil(old.astroPlan?.asinhStretch)
    }

    func testCorruptedOriginalStopsExport() async throws {
        let engine = PhotoPipeline(root: root)
        let p = try await engine.importData(fixture()).project
        let source = root.appendingPathComponent(p.id.uuidString).appendingPathComponent("source.\(p.sourceExtension)")
        try Data([1,2,3]).write(to: source)
        do { _ = try await engine.export(p, format: .png); XCTFail("A damaged original must not export") }
        catch { XCTAssertTrue(error.localizedDescription.contains("checksum")) }
    }

    func testInvalidInputDoesNotCreateProject() async throws {
        let engine = PhotoPipeline(root: root)
        do { _ = try await engine.importData(Data([1,2,3])); XCTFail("Invalid image accepted") } catch { }
        let projects = try await engine.projects()
        XCTAssertTrue(projects.isEmpty)
    }

    func testSourceDetailUsesFullResolutionAndDoesNotRewriteSource() async throws {
        let engine = PhotoPipeline(root: root)
        let source = try fixture()
        var p = try await engine.importData(source).project
        p.recipe.exposure = 0.2
        let detail = try await engine.inspect(p, region: 4)
        XCTAssertEqual(detail.width, 64); XCTAssertEqual(detail.height, 48)
        XCTAssertEqual(detail.original.width, detail.edited.width)
        XCTAssertEqual(detail.original.height, detail.edited.height)
        let copy = try await engine.originalCopy(p)
        XCTAssertEqual(try Data(contentsOf: copy), source)
    }

    func testHighlightProtectionRetainsBrightSourceDuringExposureReduction() async throws {
        let engine = PhotoPipeline(root: root)
        let source = CIImage(color: CIColor(red: 0.99, green: 0.99, blue: 0.99)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let baseline = try await engine.renderImage(source, recipe: .identity)
        var recipe = PhotoRecipe.identity; recipe.exposure = -1
        let protected = try await engine.renderImage(source, recipe: recipe)
        recipe.protectHighlights = false
        let unprotected = try await engine.renderImage(source, recipe: recipe)
        func brightness(_ image: CGImage) -> Double {
            let data = image.dataProvider!.data! as Data
            return Double(data[0])
        }
        XCTAssertLessThan(abs(brightness(protected)-brightness(baseline)), 3)
        XCTAssertGreaterThan(brightness(protected)-brightness(unprotected), 30)
    }

    func testAutomaticDevelopmentDoesNotAddBrightSourceClipping() async throws {
        let width = 96, height = 64
        var pixels = [UInt8](repeating: 255, count: width*height*4)
        for y in 0..<height { for x in 0..<width {
            let i = (y*width+x)*4
            let dx = Double(x-width/2), dy = Double(y-height/2)
            let glow = Int(100 * exp(-(dx*dx+dy*dy)/260))
            pixels[i] = UInt8(min(250, 11+glow)); pixels[i+1] = UInt8(min(250, 14+glow)); pixels[i+2] = UInt8(min(250, 19+glow/2))
            if abs(x-width/2) <= 1 && abs(y-height/2) <= 1 { pixels[i] = 250; pixels[i+1] = 250; pixels[i+2] = 250 }
        } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let cg = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let plan = try XCTUnwrap(AstroAutoPlan.analyze(rgba: pixels, width: width, height: height))
        let rendered = try await PhotoPipeline(root: root).renderImage(CIImage(cgImage: cg), recipe: .identity, autoPlan: plan)
        let output = [UInt8](rendered.dataProvider!.data! as Data)
        let before = try XCTUnwrap(PhotoMeasurement.measure(rgba: pixels, width: width, height: height))
        let after = try XCTUnwrap(PhotoMeasurement.measure(rgba: output, width: width, height: height))
        XCTAssertLessThanOrEqual(after.clippedHighlights, before.clippedHighlights + 0.001)
        XCTAssertGreaterThan(after.median, before.median)
    }

    func testAllEXIFOrientationsPreserveExpectedGeometry() async throws {
        let engine = PhotoPipeline(root: root)
        for orientation in 1...8 {
            let p = try await engine.importData(fixture(orientation: orientation)).project
            let exported = try await engine.export(p, format: .png)
            XCTAssertEqual(exported.width, orientation >= 5 ? 48 : 64)
            XCTAssertEqual(exported.height, orientation >= 5 ? 64 : 48)
        }
    }

    private func fixture(orientation: Int = 1) throws -> Data {
        let width = 64, height = 48
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y*width+x)*4
            pixels[i] = UInt8(10+x*2); pixels[i+1] = UInt8(15+y*2); pixels[i+2] = 25
        } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 33.0, kCGImagePropertyGPSLatitudeRef: "N"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
#endif
