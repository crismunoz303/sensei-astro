import SwiftUI
import PhotosUI
import Photos

@MainActor
final class PhotoLabStore: ObservableObject {
    struct EditState: Equatable {
        let recipe: PhotoRecipe
        let intent: PhotoIntent
        let automatic: Bool
        let strength: Double
    }
    @Published private(set) var project: PhotoProject?
    @Published private(set) var projects: [PhotoProject] = []
    @Published private(set) var original: UIImage?
    @Published private(set) var edited: UIImage?
    @Published private(set) var before: PhotoMeasurement?
    @Published private(set) var after: PhotoMeasurement?
    @Published var recipe = PhotoRecipe.identity { didSet { if !installing && oldValue != recipe { schedulePreview() } } }
    @Published var intent = PhotoIntent.astro { didSet { if !installing && oldValue != intent { schedulePreview() } } }
    @Published var automaticProcessing = true { didSet { if !installing && oldValue != automaticProcessing { schedulePreview() } } }
    @Published var automaticStrength = 1.0 { didSet { if !installing && oldValue != automaticStrength { schedulePreview() } } }
    @Published var format = LabExportFormat.png
    @Published private(set) var operation: String?
    @Published private(set) var rendering = false
    @Published private(set) var previewCurrent = true
    @Published private(set) var undoStack: [EditState] = []
    @Published private(set) var redoStack: [EditState] = []
    @Published var error: String?
    @Published var message: String?
    @Published private(set) var exportResult: LabExport?
    @Published private(set) var originalExport: URL?
    private let pipeline = PhotoPipeline()
    private var previewTask: Task<Void, Never>?
    private var revision = UUID()
    private var installing = false
    private var restored = false
    var busy: Bool { operation != nil }
    var advice: PhotoAdvice? { before.map { PhotoAdvice.make($0, intent: intent) } }

    func restore() async {
        guard !restored else { return }; restored = true
        do {
            projects = try await pipeline.projects()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--photo-ui-test"), projects.isEmpty {
                // Deterministic test chart. Never included in the Release app or user projects.
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240))
                let image = renderer.image { context in
                    for x in 0..<320 {
                        UIColor(white: CGFloat(x+10)/1600, alpha: 1).setFill()
                        context.fill(CGRect(x: x, y: 0, width: 1, height: 240))
                    }
                }
                if let bytes = image.pngData() { try await install(pipeline.importData(bytes), automaticStart: true) }
                return
            }
            #endif
            if let latest = projects.first { await open(latest) }
        } catch { self.error = error.localizedDescription }
    }

    func importPhoto(_ item: PhotosPickerItem) async {
        guard !busy else { return }
        operation = "Preserving your original…"; error = nil
        defer { operation = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw LabError.invalid("Photos did not provide an image. Try Files or download the image from iCloud first.") }
            try await install(pipeline.importData(data), automaticStart: true)
        } catch { self.error = error.localizedDescription }
    }

    func importFile(_ url: URL) async {
        guard !busy else { return }
        operation = "Reading and verifying your file…"; error = nil
        defer { operation = nil }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 100 * 1024 * 1024 else { throw LabError.invalid("Choose an image smaller than 100 MB.") }
                return try Data(contentsOf: url)
            }.value
            try await install(pipeline.importData(data), automaticStart: true)
        } catch { self.error = error.localizedDescription }
    }

    func open(_ saved: PhotoProject) async {
        guard !busy else { return }
        operation = "Opening your saved project…"; error = nil
        defer { operation = nil }
        do { try await install(pipeline.open(saved)) }
        catch { self.error = error.localizedDescription }
    }

    private func install(_ loaded: LabLoadedPhoto, automaticStart: Bool = false) async throws {
        previewTask?.cancel(); revision = UUID(); installing = true
        project = loaded.project
        original = UIImage(cgImage: loaded.preview); edited = original
        before = loaded.measurement; after = loaded.measurement
        intent = loaded.project.intent
        automaticProcessing = loaded.project.automaticProcessingDisabled != true && loaded.project.astroPlan != nil
        automaticStrength = loaded.project.boundedAutomaticStrength
        message = nil
        recipe = loaded.project.recipe.bounded
        if automaticStart {
            message = loaded.project.astroPlan == nil
                ? "This image did not contain enough usable samples for an automatic plan; manual controls remain available."
                : "Astrophotography development applied from measured source pixels. Your original remains unchanged."
        }
        undoStack = []; redoStack = []; exportResult = nil; originalExport = nil
        installing = false
        projects = try await pipeline.projects()
        schedulePreview(preserveMessage: automaticStart)
    }

    func rememberAdjustment() {
        if undoStack.last != editState { undoStack.append(editState) }
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack = []
    }
    func applyAdvice() { guard let advice else { return }; rememberAdjustment(); recipe = advice.recipe }
    func reset() { rememberAdjustment(); recipe = .identity }
    private var editState: EditState {
        EditState(recipe: recipe, intent: intent, automatic: automaticProcessing, strength: automaticStrength)
    }
    private func installEdit(_ value: EditState) {
        installing = true
        recipe = value.recipe; intent = value.intent
        automaticProcessing = value.automatic; automaticStrength = value.strength
        installing = false
        schedulePreview()
    }
    func setAutomatic(_ enabled: Bool) { rememberAdjustment(); automaticProcessing = enabled }
    func setIntent(_ value: PhotoIntent) {
        rememberAdjustment()
        installEdit(EditState(recipe: recipe, intent: value,
            automatic: value == .astro && project?.astroPlan != nil, strength: automaticStrength))
    }
    func resetAll() {
        rememberAdjustment()
        installEdit(EditState(recipe: .identity, intent: intent, automatic: false, strength: 1))
    }
    func undo() { guard let value = undoStack.popLast() else { return }; redoStack.append(editState); installEdit(value) }
    func redo() { guard let value = redoStack.popLast() else { return }; undoStack.append(editState); installEdit(value) }

    private func snapshot() -> PhotoProject? {
        guard var p = project else { return nil }
        p.recipe = recipe.bounded; p.intent = intent; p.updated = Date()
        p.automaticProcessingDisabled = !automaticProcessing
        p.automaticStrength = automaticStrength
        return p
    }

    private func schedulePreview(preserveMessage: Bool = false) {
        guard let p = snapshot() else { return }
        previewTask?.cancel(); let ticket = UUID(); revision = ticket
        rendering = true; previewCurrent = false; exportResult = nil
        if !preserveMessage { message = nil }
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                try Task.checkCancellation()
                try await pipeline.save(p)
                let result = try await pipeline.render(p)
                try Task.checkCancellation()
                guard ticket == revision, project?.id == p.id else { return }
                edited = UIImage(cgImage: result.image); after = result.measurement
                project = p; rendering = false; previewCurrent = true
                projects = try await pipeline.projects()
            } catch is CancellationError { }
            catch {
                guard ticket == revision else { return }
                rendering = false; self.error = error.localizedDescription
            }
        }
    }

    func flush() async {
        guard let p = snapshot() else { return }
        do { try await pipeline.save(p) } catch { self.error = error.localizedDescription }
    }

    func detail(region: Int) async throws -> LabDetail {
        guard let p = snapshot() else { throw LabError.invalid("Import a photo first.") }
        return try await pipeline.inspect(p, region: region)
    }

    func prepareExport(saveToPhotos: Bool) async {
        guard !busy, previewCurrent, let p = snapshot() else { return }
        operation = "Rendering and checking the full-resolution image…"; error = nil; message = nil
        defer { operation = nil }
        do {
            try await pipeline.save(p)
            let result = try await pipeline.export(p, format: format)
            exportResult = result
            if saveToPhotos {
                let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard authorization == .authorized || authorization == .limited else {
                    throw LabError.invalid("Photos access was not granted. Your export is ready below: save it to Files, or allow Photos access in iPhone Settings.")
                }
                operation = "Waiting for Photos to confirm the save…"
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = result.imageURL.lastPathComponent
                    request.addResource(with: .photo, fileURL: result.imageURL, options: options)
                }
                message = "Photos confirmed that your edited copy was saved."
            } else { message = "Full-resolution export verified. Share the image and its edit report below." }
        } catch { self.error = error.localizedDescription }
    }

    func prepareOriginal() async {
        guard !busy, let p = project else { return }
        operation = "Verifying original bytes…"; error = nil
        defer { operation = nil }
        do { originalExport = try await pipeline.originalCopy(p) }
        catch { self.error = error.localizedDescription }
    }
}
