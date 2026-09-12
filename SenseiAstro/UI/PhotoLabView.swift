import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct PhotoLabView: View {
    @StateObject private var lab = PhotoLabStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var pickerItem: PhotosPickerItem?
    @State private var filePicker = false
    @State private var showOriginal = false
    @State private var showProjects = false
    @State private var inspector = false

    var body: some View {
        ZStack {
            AstroTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        eyebrow("SENSEI / PHOTO LAB")
                        Text("Your light.\nYour photograph.").font(.largeTitle.bold())
                        Text("Measured adjustments. Nothing imagined.").foregroundStyle(AstroTheme.muted)
                    }
                    if let operation = lab.operation { ProgressView(operation).tint(AstroTheme.red).font(.subheadline).accessibilityIdentifier("labOperation") }
                    if let error = lab.error { notice(error, color: AstroTheme.amber) }
                    if let message = lab.message { notice(message, color: AstroTheme.green) }
                    if lab.original != nil {
                        stage
                        measurements
                        advice
                        adjustments
                        exportPanel
                        integrity
                    } else {
                        AstroPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: "camera.aperture").font(.system(size: 38)).foregroundStyle(AstroTheme.red)
                                Text("Start with your original").font(.title2.bold())
                        Text("Import a photo or Seestar image export. It is measured and given a conservative starting edit automatically; your source is saved unchanged.")
                                Text("JPEG, PNG, HEIC and single-image TIFF · up to 25 MP / 100 MB. FITS and RAW are not supported in this build.").font(.caption).foregroundStyle(AstroTheme.muted)
                            }
                        }
                    }
                    HStack {
                        PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current) {
                            Label("Photos", systemImage: "photo.on.rectangle")
                        }.buttonStyle(LabActionStyle(primary: true)).accessibilityIdentifier("importPhotos")
                        Button { filePicker = true } label: { Label("Files", systemImage: "folder") }
                            .buttonStyle(LabActionStyle()).accessibilityIdentifier("importFiles")
                    }.disabled(lab.busy || lab.rendering)
                    Text("Photo processing stays on this iPhone. No photo upload, image generation, or replacement imagery.")
                        .font(.caption).foregroundStyle(AstroTheme.muted)
                }.padding(18)
            }
        }
        .foregroundStyle(AstroTheme.text)
        .navigationTitle("True Edit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { showProjects = true } label: { Label("Projects", systemImage: "square.stack") }
                .disabled(lab.busy || lab.rendering).accessibilityIdentifier("savedProjects")
        } }
        .task { await lab.restore() }
        .onChange(of: pickerItem) { _, item in if let item { Task { await lab.importPhoto(item) } } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await lab.flush() } } }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.jpeg, .png, .heic, .tiff]) { result in
            switch result {
            case .success(let url): Task { await lab.importFile(url) }
            case .failure(let error): lab.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $showProjects) { projects }
        .sheet(isPresented: $inspector) {
            if let original = lab.original, let edited = lab.edited {
                LabInspector(original: original, edited: edited, loadDetail: { try await lab.detail(region: $0) })
            }
        }
    }

    private var stage: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                Image(uiImage: (showOriginal ? lab.original : lab.edited) ?? UIImage())
                    .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 440)
                    .background(.black).clipShape(RoundedRectangle(cornerRadius: 16))
                Text(showOriginal ? "ORIGINAL" : (lab.recipe.hasAdjustments ? "EDITED PREVIEW" : "NO ADJUSTMENTS"))
                    .font(.caption2.monospaced().bold()).padding(8).background(.black.opacity(0.8), in: Capsule()).padding(10)
            }
            HStack {
                Button { showOriginal.toggle() } label: {
                    Label(showOriginal ? "Show edit" : "Show original", systemImage: "circle.lefthalf.filled")
                }.accessibilityIdentifier("compareOriginal")
                Spacer()
                Button { inspector = true } label: { Label("Inspect", systemImage: "arrow.up.left.and.arrow.down.right") }.accessibilityIdentifier("inspectSource")
            }.font(.subheadline.bold())
            if lab.rendering { ProgressView("Updating preview…").tint(AstroTheme.red).font(.caption) }
            Text("Preview: up to 1,400 px. Export uses your full source resolution.")
                .font(.caption2).foregroundStyle(AstroTheme.muted)
        }
    }

    private var measurements: some View {
        AstroPanel {
            VStack(alignment: .leading, spacing: 10) {
                eyebrow("SIGNAL CHECK")
                if let before = lab.before, let after = lab.after {
                    LabHistogram(before: before.histogram, after: after.histogram).frame(height: 74)
                    HStack { Text("Gray: original"); Spacer(); Text("Red: preview") }.font(.caption2).foregroundStyle(AstroTheme.muted)
                    measurementRow("Median brightness", before.median, after.median)
                    measurementRow("Near-clipped channels", before.clippedHighlights, after.clippedHighlights)
                    measurementRow("Near-black pixels", before.crushedBlacks, after.crushedBlacks)
                    if after.clippedHighlights > before.clippedHighlights + 0.001 {
                        notice("The edit increases highlight clipping. Reduce exposure or contrast and inspect bright stars.", color: AstroTheme.amber)
                    }
                    if after.crushedBlacks > before.crushedBlacks + 0.005 {
                        notice("The edit increases black clipping. Faint detail may be lost.", color: AstroTheme.amber)
                    }
                    Text("Sampled sRGB preview, not a scientific SNR measurement. Downsampling can hide tiny stars and clipped pixels; inspect the full export.")
                        .font(.caption2).foregroundStyle(AstroTheme.muted)
                }
            }
        }
    }

    private var advice: some View {
        AstroPanel {
            VStack(alignment: .leading, spacing: 12) {
                eyebrow("GUIDED START")
                Picker("Photo type", selection: $lab.intent) {
                    ForEach(PhotoIntent.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if let advice = lab.advice {
                    ForEach(advice.reasons, id: \.self) { Text($0).font(.subheadline) }
                    ForEach(advice.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(AstroTheme.amber) }
                    Button("Reapply measured starting point") { lab.applyAdvice() }.buttonStyle(LabActionStyle(primary: true)).accessibilityIdentifier("applyAdvice")
                }
                Text("Recommendations use measured pixels and conservative rules. They are not a trained AI specialist or a guarantee of the best edit.")
                    .font(.caption2).foregroundStyle(AstroTheme.muted)
            }
        }.disabled(lab.busy)
    }

    private var adjustments: some View {
        AstroPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    eyebrow("YOUR RECIPE")
                    Spacer()
                    Button { lab.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(lab.undoStack.isEmpty).accessibilityLabel("Undo")
                    Button { lab.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(lab.redoStack.isEmpty).accessibilityLabel("Redo")
                }
                adjustment("Exposure · EV", $lab.recipe.exposure, -1...1)
                adjustment("Midtone lift", $lab.recipe.midtones, 0...0.16)
                adjustment("Contrast", $lab.recipe.contrast, 0.9...1.15)
                adjustment("Saturation", $lab.recipe.saturation, 0...1.3)
                adjustment("Red / blue balance", $lab.recipe.warmth, -0.1...0.1)
                Toggle("Protect bright source pixels", isOn: Binding(get: { lab.recipe.protectHighlights }, set: {
                    lab.rememberAdjustment(); lab.recipe.protectHighlights = $0
                })).font(.subheadline)
                Text("Blends original highlights back into the edit. This is a brightness mask, not star detection or color calibration.").font(.caption2).foregroundStyle(AstroTheme.muted)
                DisclosureGroup("Detail controls") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Inspect carefully: conventional denoise can remove real faint signal; sharpening can create halos. Both start off.").font(.caption).foregroundStyle(AstroTheme.amber)
                        adjustment("Denoise", $lab.recipe.denoise, 0...0.04)
                        adjustment("Sharpen", $lab.recipe.sharpen, 0...0.4)
                    }.padding(.top, 10)
                }
                Button("Reset all adjustments") { lab.reset() }.font(.subheadline)
            }
        }.disabled(lab.busy)
    }

    private var exportPanel: some View {
        AstroPanel {
            VStack(alignment: .leading, spacing: 12) {
                eyebrow("FINISH & EXPORT")
                Picker("Export format", selection: $lab.format) {
                    ForEach(LabExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(lab.busy)
                Text(lab.format == .png ? "Lossless 8-bit sRGB copy for sharing." : "16-bit sRGB TIFF for further editing. A larger bit depth cannot recover detail missing from a JPEG.")
                    .font(.caption).foregroundStyle(AstroTheme.muted)
                Button { Task { await lab.prepareExport(saveToPhotos: true) } } label: { Label("Save edited copy to Photos", systemImage: "square.and.arrow.down") }
                    .buttonStyle(LabActionStyle(primary: true)).disabled(lab.busy || !lab.previewCurrent)
                Button { Task { await lab.prepareExport(saveToPhotos: false) } } label: { Label("Prepare image + edit report", systemImage: "doc.text") }
                    .buttonStyle(LabActionStyle()).disabled(lab.busy || !lab.previewCurrent).accessibilityIdentifier("prepareExport")
                if let result = lab.exportResult {
                    Text("Verified \(result.width) × \(result.height) · sRGB").font(.caption.bold()).foregroundStyle(AstroTheme.green).accessibilityIdentifier("exportVerified")
                    ShareLink(items: [result.imageURL, result.reportURL]) { Label("Share / Save to Files", systemImage: "square.and.arrow.up") }
                    Text("The report records every operation and full source/output checksums. Location metadata is omitted from edited exports.")
                        .font(.caption2).foregroundStyle(AstroTheme.muted)
                }
            }
        }
    }

    private var integrity: some View {
        DisclosureGroup("Original & edit record") {
            VStack(alignment: .leading, spacing: 10) {
                if let p = lab.project {
                    Text("\(p.width) × \(p.height) · \(p.sourceDepth)-bit source · \(p.sourceExtension.uppercased())").font(.caption.bold())
                    Text("SHA-256\n\(p.sha256)").font(.caption2.monospaced()).textSelection(.enabled)
                    ForEach(lab.recipe.bounded.operations, id: \.self) { Text($0).font(.caption) }
                    Text("Your imported bytes and recipe are saved on this phone. Deleting the app deletes local projects; keep a separate backup. Photos may supply a previously edited version—use Files when you need an exact master.")
                        .font(.caption).foregroundStyle(AstroTheme.muted)
                    Button("Prepare unchanged original backup") { Task { await lab.prepareOriginal() } }.disabled(lab.busy)
                    if let url = lab.originalExport { ShareLink(item: url) { Label("Save original backup", systemImage: "square.and.arrow.up") } }
                }
            }.padding(.top, 12)
        }
    }

    private var projects: some View {
        NavigationStack {
            List(lab.projects) { p in
                Button {
                    showProjects = false; Task { await lab.open(p) }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(p.created.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        Text("\(p.width) × \(p.height) · \(p.sourceExtension.uppercased()) · \(p.sha256.prefix(8))").font(.caption.monospaced())
                        Text(p.recipe.hasAdjustments ? "Saved edit recipe" : "Original preserved").font(.caption).foregroundStyle(AstroTheme.muted)
                    }
                }
            }
            .overlay { if lab.projects.isEmpty { ContentUnavailableView("No saved projects", systemImage: "photo", description: Text("Import a photo to begin.")) } }
            .navigationTitle("Your projects")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showProjects = false } } }
        }.tint(AstroTheme.red).preferredColorScheme(.dark)
    }

    private func adjustment(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(spacing: 3) {
            HStack { Text(title); Spacer(); Text(value.wrappedValue, format: .number.precision(.fractionLength(3))).monospacedDigit() }.font(.caption)
            Slider(value: value, in: range, onEditingChanged: { if $0 { lab.rememberAdjustment() } }).accessibilityLabel(title)
        }
    }
    private func measurementRow(_ title: String, _ a: Double, _ b: Double) -> some View {
        HStack { Text(title); Spacer(); Text(String(format: "%.2f%% → %.2f%%", a*100, b*100)).monospacedDigit() }.font(.caption)
    }
    private func eyebrow(_ value: String) -> some View { Text(value).font(.caption.monospaced().bold()).foregroundStyle(AstroTheme.red) }
    private func notice(_ value: String, color: Color) -> some View {
        Text(value).font(.subheadline).foregroundStyle(color).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct LabActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 13).padding(.horizontal, 8)
            .background(primary ? AstroTheme.crimson : AstroTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(AstroTheme.text).opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

private struct LabHistogram: View {
    let before: [Int]
    let after: [Int]
    var body: some View {
        Canvas { context, size in
            let maximum = log1p(Double(max(before.max() ?? 0, after.max() ?? 0)))
            guard maximum > 0 else { return }
            for (values, color) in [(before, Color.gray.opacity(0.55)), (after, AstroTheme.red.opacity(0.7))] {
                var path = Path(); path.move(to: CGPoint(x: 0, y: size.height))
                for (i, count) in values.enumerated() {
                    path.addLine(to: CGPoint(x: Double(i) / 255 * size.width, y: size.height * (1-log1p(Double(count))/maximum)))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                context.fill(path, with: .color(color))
            }
        }.accessibilityLabel("Logarithmic brightness histogram. Numerical comparison below.")
    }
}

private struct LabInspector: View {
    let original: UIImage
    let edited: UIImage
    let loadDetail: (Int) async throws -> LabDetail
    @Environment(\.dismiss) private var dismiss
    @State private var showOriginal = false
    @State private var sourceDetail = false
    @State private var region = 4
    @State private var detail: LabDetail?
    @State private var detailError: String?
    @State private var loading = false
    private let regions = ["Top left", "Top center", "Top right", "Middle left", "Center", "Middle right", "Bottom left", "Bottom center", "Bottom right"]
    private var displayed: UIImage {
        if sourceDetail, let detail { return UIImage(cgImage: showOriginal ? detail.original : detail.edited) }
        return showOriginal ? original : edited
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("Inspection mode", selection: $sourceDetail) {
                    Text("Whole preview").tag(false)
                    Text("Source detail").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal)
                if sourceDetail {
                    Picker("Region", selection: $region) {
                        ForEach(0..<9, id: \.self) { Text(regions[$0]).tag($0) }
                    }.pickerStyle(.menu)
                }
                if loading { ProgressView("Reading source pixels…").tint(AstroTheme.red) }
                if let detailError { Text(detailError).font(.caption).foregroundStyle(AstroTheme.amber) }
                LabZoomView(image: displayed).id("\(sourceDetail)-\(region)")
                Toggle("Show original", isOn: $showOriginal).padding(.horizontal)
                Text(sourceDetail && detail != nil ? "\(detail!.width) × \(detail!.height) source-pixel region. Pinch to inspect stars and halos. This crop is for inspection only; export keeps your full composition." : "Pinch and pan. Switch to Source detail to inspect original-resolution regions.")
                    .font(.caption).foregroundStyle(AstroTheme.muted).padding()
            }.background(.black).navigationTitle(showOriginal ? "Original" : "Edited preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(AstroTheme.red)
            .task(id: "\(sourceDetail)-\(region)") {
                guard sourceDetail else { loading = false; return }
                loading = true; detail = nil; detailError = nil
                do {
                    let result = try await loadDetail(region)
                    try Task.checkCancellation(); detail = result; loading = false
                } catch is CancellationError { }
                catch { detailError = error.localizedDescription; loading = false }
            }
    }
}

private struct LabZoomView: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let view = UIScrollView(); view.delegate = context.coordinator
        view.minimumZoomScale = 1; view.maximumZoomScale = 6; view.backgroundColor = .black
        context.coordinator.imageView.contentMode = .scaleAspectFit
        context.coordinator.imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(context.coordinator.imageView)
        return view
    }
    func updateUIView(_ view: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        if view.zoomScale == 1 {
            context.coordinator.imageView.frame = view.bounds
            view.contentSize = view.bounds.size
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
