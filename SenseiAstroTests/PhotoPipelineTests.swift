import XCTest
import Foundation
@testable import SenseiAstroCore

final class PhotoAnalysisTests: XCTestCase {
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

    func testEveryConventionalOperationCanRenderWithoutChangingGeometry() async throws {
        let engine = PhotoPipeline(root: root)
        var p = try await engine.importData(fixture()).project
        p.recipe = PhotoRecipe(exposure: 0.1, midtones: 0.04, contrast: 1.02, saturation: 1.1, warmth: 0.02, denoise: 0.01, sharpen: 0.15, protectHighlights: true)
        let result = try await engine.render(p)
        XCTAssertEqual(result.image.width, p.width); XCTAssertEqual(result.image.height, p.height)
        XCTAssertTrue(result.measurement.median.isFinite)
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
