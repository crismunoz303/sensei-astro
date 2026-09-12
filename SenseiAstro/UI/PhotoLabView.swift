import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import PhotosUI
import SwiftUI
import UIKit

private struct EditRecipe: Equatable {
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var vibrance: Double = 0
    var noise: Double = 0
    var sharpness: Double = 0

    static let original = EditRecipe()
}

struct PhotoLabView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var sourceData: Data?
    @State private var originalImage: UIImage?
    @State private var editedImage: UIImage?
    @State private var recipe = EditRecipe.original
    @State private var suggestedRecipe = EditRecipe.original
    @State private var showOriginal = false
    @State private var isProcessing = false
    @State private var saveMessage: String?

    var body: some View {
        ZStack {
            AstroTheme.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    labHeader
                    if let originalImage {
                        photoStage(originalImage)
                        integrityPanel
                        specialistPanel
                        adjustmentPanel
                        actionRow
                    } else {
                        emptyState
                    }
                }
                .padding()
            }
        }
        .navigationTitle("True Edit Lab")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { _, item in Task { await importPhoto(item) } }
        .onChange(of: recipe) { _, _ in renderPreview() }
    }

    private var labHeader: some View {
        HStack {
            Label("SENSEI // TRUE EDIT ENGINE", systemImage: "wand.and.stars.inverse")
                .font(.caption.bold().monospaced())
                .foregroundStyle(AstroTheme.text)
            Spacer()
            Text("NON-GENERATIVE")
                .font(.caption2.bold().monospaced())
                .foregroundStyle(AstroTheme.green)
        }
    }

    private var emptyState: some View {
        AstroPanel {
            VStack(spacing: 16) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 48))
                    .foregroundStyle(AstroTheme.red)
                Text("IMPORT YOUR REAL PHOTO")
                    .font(.title3.bold().monospaced())
                    .foregroundStyle(AstroTheme.text)
                Text("Your original remains untouched. True Edit only creates a reversible adjustment recipe and a separate finished copy.")
                    .font(.subheadline)
                    .foregroundStyle(AstroTheme.muted)
                    .multilineTextAlignment(.center)
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("CHOOSE PHOTO", systemImage: "photo.on.rectangle")
                        .font(.headline.bold().monospaced())
                        .frame(maxWidth: .infinity)
                        .padding(13)
                        .foregroundStyle(.white)
                        .background(AstroTheme.red, in: RoundedRectangle(cornerRadius: 13))
                }
            }
        }
    }

    private func photoStage(_ original: UIImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: showOriginal ? original : (editedImage ?? original))
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 390)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(AstroTheme.red.opacity(0.35)))
            Text(showOriginal ? "ORIGINAL" : "EDITED COPY")
                .font(.caption2.bold().monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(AstroTheme.text)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(9)
        }
        .onLongPressGesture(minimumDuration: 0.05, pressing: { showOriginal = $0 }, perform: {})
        .accessibilityLabel(showOriginal ? "Original photograph" : "Edited preview")
        .accessibilityHint("Press and hold to compare with the original")
    }

    private var integrityPanel: some View {
        AstroPanel {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("ORIGINAL LOCKED", systemImage: "lock.fill")
                        .font(.caption.bold().monospaced())
                        .foregroundStyle(AstroTheme.green)
                    Spacer()
                    if let originalImage {
                        Text("\(Int(originalImage.size.width)) × \(Int(originalImage.size.height))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(AstroTheme.muted)
                    }
                }
                Text("SOURCE ID // \(sourceID)")
                    .font(.caption2.bold().monospaced())
                    .foregroundStyle(AstroTheme.muted)
                Text("No generative fill • No invented objects • No source overwrite")
                    .font(.caption)
                    .foregroundStyle(AstroTheme.text)
            }
        }
    }

    private var specialistPanel: some View {
        AstroPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("SPECIALIST RECOMMENDATION")
                        .font(.caption.bold().monospaced())
                        .foregroundStyle(AstroTheme.red)
                    Spacer()
                    if isProcessing { ProgressView().tint(AstroTheme.red) }
                }
                Text(recommendationSummary)
                    .font(.subheadline)
                    .foregroundStyle(AstroTheme.text)
                Button {
                    recipe = suggestedRecipe
                } label: {
                    Label("APPLY RECOMMENDATION", systemImage: "checkmark.shield.fill")
                        .font(.caption.bold().monospaced())
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(AstroTheme.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                }
                .foregroundStyle(AstroTheme.red)
            }
        }
    }

    private var adjustmentPanel: some View {
        AstroPanel {
            VStack(spacing: 12) {
                Text("REVERSIBLE ADJUSTMENTS")
                    .font(.caption.bold().monospaced())
                    .foregroundStyle(AstroTheme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                editSlider("EXPOSURE", value: $recipe.exposure, range: -1...1, baseline: 0)
                editSlider("BRIGHTNESS", value: $recipe.brightness, range: -0.2...0.2, baseline: 0)
                editSlider("CONTRAST", value: $recipe.contrast, range: 0.75...1.35, baseline: 1)
                editSlider("SATURATION", value: $recipe.saturation, range: 0.6...1.4, baseline: 1)
                editSlider("VIBRANCE", value: $recipe.vibrance, range: -0.5...0.8, baseline: 0)
                editSlider("DENOISE", value: $recipe.noise, range: 0...0.08, baseline: 0)
                editSlider("SHARPNESS", value: $recipe.sharpness, range: 0...0.7, baseline: 0)
            }
        }
    }

    private func editSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, baseline: Double) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.caption2.bold().monospaced()).foregroundStyle(AstroTheme.muted)
                Spacer()
                Text(String(format: "%+.2f", value.wrappedValue - baseline))
                    .font(.caption2.bold().monospaced())
                    .foregroundStyle(AstroTheme.text)
            }
            Slider(value: value, in: range).tint(AstroTheme.red)
        }
    }

    private var actionRow: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                Button("RESET") { recipe = .original }
                    .buttonStyle(LabButtonStyle(color: AstroTheme.panel))
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Text("NEW PHOTO")
                }
                .buttonStyle(LabButtonStyle(color: AstroTheme.panel))
            }
            Button {
                guard let image = editedImage ?? originalImage else { return }
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                saveMessage = "Finished copy saved. Original was not changed."
            } label: {
                Label("SAVE FINISHED COPY", systemImage: "square.and.arrow.down.fill")
            }
            .buttonStyle(LabButtonStyle(color: AstroTheme.red))
            if let saveMessage {
                Text(saveMessage).font(.caption).foregroundStyle(AstroTheme.green)
            }
        }
        .font(.caption.bold().monospaced())
    }

    private var sourceID: String {
        guard let sourceData else { return "NONE" }
        return SHA256.hash(data: sourceData).prefix(5).map { String(format: "%02x", $0) }.joined().uppercased()
    }

    private var recommendationSummary: String {
        guard originalImage != nil else { return "Import a photo to begin." }
        let exposure = suggestedRecipe.exposure >= 0 ? "lift" : "reduce"
        return "Measured from this photograph: \(exposure) exposure, protect color, apply restrained noise reduction, and avoid aggressive sharpening. Hold the preview to audit against the untouched source."
    }

    @MainActor
    private func importPhoto(_ item: PhotosPickerItem?) async {
        guard let data = try? await item?.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        sourceData = data
        originalImage = image
        isProcessing = true
        saveMessage = nil
        let suggestion = PhotoFinishingEngine.suggest(for: image)
        suggestedRecipe = suggestion
        recipe = suggestion
        isProcessing = false
    }

    private func renderPreview() {
        guard let originalImage else { return }
        isProcessing = true
        editedImage = PhotoFinishingEngine.render(originalImage, recipe: recipe)
        isProcessing = false
    }
}

private struct LabButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(12)
            .foregroundStyle(AstroTheme.text)
            .background(color.opacity(configuration.isPressed ? 0.65 : 1), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AstroTheme.red.opacity(0.35)))
    }
}

private enum PhotoFinishingEngine {
    private static let context = CIContext(options: [.cacheIntermediates: true])

    static func suggest(for image: UIImage) -> EditRecipe {
        guard let input = CIImage(image: image), let average = averageRGBA(input) else {
            return EditRecipe(exposure: 0.08, contrast: 1.06, saturation: 1.02, vibrance: 0.08, noise: 0.025, sharpness: 0.15)
        }
        let luminance = 0.2126 * average.r + 0.7152 * average.g + 0.0722 * average.b
        let target = luminance < 0.16 ? 0.19 : min(0.48, luminance)
        let exposure = min(0.65, max(-0.35, log2(max(0.01, target) / max(0.01, luminance))))
        let colorSpread = max(average.r, average.g, average.b) - min(average.r, average.g, average.b)
        return EditRecipe(
            exposure: exposure,
            brightness: 0,
            contrast: luminance < 0.25 ? 1.08 : 1.03,
            saturation: colorSpread < 0.08 ? 1.07 : 1.02,
            vibrance: colorSpread < 0.08 ? 0.14 : 0.06,
            noise: luminance < 0.25 ? 0.035 : 0.018,
            sharpness: luminance < 0.25 ? 0.12 : 0.18
        )
    }

    static func render(_ image: UIImage, recipe: EditRecipe) -> UIImage? {
        guard let original = CIImage(image: image) else { return image }
        var output = original

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = output
        exposure.ev = Float(recipe.exposure)
        output = exposure.outputImage ?? output

        let color = CIFilter.colorControls()
        color.inputImage = output
        color.brightness = Float(recipe.brightness)
        color.contrast = Float(recipe.contrast)
        color.saturation = Float(recipe.saturation)
        output = color.outputImage ?? output

        let vibrance = CIFilter.vibrance()
        vibrance.inputImage = output
        vibrance.amount = Float(recipe.vibrance)
        output = vibrance.outputImage ?? output

        if recipe.noise > 0 {
            let denoise = CIFilter.noiseReduction()
            denoise.inputImage = output
            denoise.noiseLevel = Float(recipe.noise)
            denoise.sharpness = 0.25
            output = denoise.outputImage ?? output
        }

        if recipe.sharpness > 0 {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = output
            sharpen.sharpness = Float(recipe.sharpness)
            output = sharpen.outputImage ?? output
        }

        output = output.cropped(to: original.extent)
        guard let cgImage = context.createCGImage(output, from: original.extent) else { return image }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func averageRGBA(_ image: CIImage) -> (r: Double, g: Double, b: Double, a: Double)? {
        let average = CIFilter.areaAverage()
        average.inputImage = image
        average.extent = image.extent
        guard let output = average.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Double(bitmap[0]) / 255, Double(bitmap[1]) / 255, Double(bitmap[2]) / 255, Double(bitmap[3]) / 255)
    }
}
