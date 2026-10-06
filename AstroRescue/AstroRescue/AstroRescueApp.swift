import SwiftUI
import Photos
import Vision
import UIKit
import CryptoKit
import UniformTypeIdentifiers

@main
struct AstroRescueApp: App {
    @StateObject private var model = RescueViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}

struct AstroCandidate: Identifiable, Hashable {
    enum Category: String, CaseIterable {
        case moon = "Moon"
        case planets = "Planets"
        case deepSky = "Deep Sky"
        case starFields = "Star Fields"
        case other = "Other Astro"

        var folderName: String { rawValue.replacingOccurrences(of: " ", with: "_") }
    }

    let id: String
    let asset: PHAsset
    let filename: String
    let createdAt: Date?
    let confidence: Double
    let category: Category
    let reason: String

    static func == (lhs: AstroCandidate, rhs: AstroCandidate) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct OffloadRecord: Identifiable {
    let id = UUID()
    let assetID: String
    let filename: String
    let destinationPath: String
    let bytes: Int64
    let sha256: String
    let verified: Bool
}

@MainActor
final class RescueViewModel: ObservableObject {
    @Published var candidates: [AstroCandidate] = []
    @Published var selectedIDs: Set<String> = []
    @Published var verifiedAssetIDs: Set<String> = []

    @Published var isScanning = false
    @Published var scanProgress = 0.0
    @Published var scanFoundCount = 0

    @Published var isOffloading = false
    @Published var offloadProgress = 0.0
    @Published var statusMessage = ""

    @Published var destinationURL: URL?
    @Published var showAlert = false
    @Published var alertMessage = ""

    private var scanTask: Task<Void, Never>?

    var deviceStorage: (used: Int64, free: Int64, total: Int64)? {
        StorageInfo.snapshot(path: NSHomeDirectory())
    }

    var usbStorage: (used: Int64, free: Int64, total: Int64)? {
        guard let destinationURL else { return nil }
        return StorageInfo.snapshot(path: destinationURL.path)
    }

    var usbName: String {
        destinationURL?.lastPathComponent ?? "No USB folder selected"
    }

    func chooseDestination(_ url: URL) {
        destinationURL = url
    }

    func scanPhotos() async {
        guard !isScanning else { return }

        let status = await requestPhotoAccess()
        guard status == .authorized || status == .limited else {
            present("Photos access is required. Allow access when iOS asks, then scan again.")
            return
        }

        candidates = []
        selectedIDs = []
        scanProgress = 0
        scanFoundCount = 0
        isScanning = true

        scanTask = Task { [weak self] in
            guard let self else { return }

            let result = await PhotoScanner.scan { progress, found in
                Task { @MainActor in
                    self.scanProgress = progress
                    self.scanFoundCount = found
                }
            }

            guard !Task.isCancelled else {
                self.isScanning = false
                self.statusMessage = "Scan stopped"
                return
            }

            self.candidates = result
            self.selectedIDs = Set(result.map(\.id))
            self.scanProgress = 1
            self.scanFoundCount = result.count
            self.isScanning = false

            if result.isEmpty {
                self.present("No likely astrophotography was found. Nothing was changed.")
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        statusMessage = "Scan stopped"
    }

    func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func toggleAll() {
        if selectedIDs.count == candidates.count {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(candidates.map(\.id))
        }
    }

    func offloadSelected() async {
        guard !isOffloading else { return }
        guard let root = destinationURL else {
            present("Choose a folder on your external USB drive first.")
            return
        }

        let chosen = candidates.filter { selectedIDs.contains($0.id) }
        guard !chosen.isEmpty else {
            present("Select at least one photo to offload.")
            return
        }

        let scoped = root.startAccessingSecurityScopedResource()
        defer {
            if scoped { root.stopAccessingSecurityScopedResource() }
            isOffloading = false
        }

        isOffloading = true
        offloadProgress = 0
        verifiedAssetIDs = []
        var failed: [String] = []

        for (index, candidate) in chosen.enumerated() {
            if Task.isCancelled { break }

            statusMessage = "Copying \(candidate.filename)"
            do {
                let record = try await Offloader.offload(candidate, to: root)
                if record.verified {
                    verifiedAssetIDs.insert(candidate.id)
                } else {
                    failed.append(candidate.filename)
                }
            } catch {
                failed.append("\(candidate.filename): \(error.localizedDescription)")
            }

            offloadProgress = Double(index + 1) / Double(chosen.count)
        }

        if failed.isEmpty {
            statusMessage = "Verified backup complete"
            present("\(verifiedAssetIDs.count) photo(s) were copied to USB and verified. Nothing has been deleted from your iPhone.")
        } else {
            statusMessage = "Finished with \(failed.count) error(s)"
            present("Some files could not be verified, so they were NOT marked safe to delete.\n\n" + failed.prefix(4).joined(separator: "\n"))
        }
    }

    func deleteVerified() async {
        let ids = Array(verifiedAssetIDs)
        guard !ids.isEmpty else { return }

        do {
            try await PhotoDeletion.delete(ids: ids)
            candidates.removeAll { ids.contains($0.id) }
            selectedIDs.subtract(ids)
            verifiedAssetIDs.removeAll()
            present("Deletion request completed. iOS may keep those files in Recently Deleted until you empty that album.")
        } catch {
            present(error.localizedDescription)
        }
    }

    private func requestPhotoAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
        }
    }

    func present(_ text: String) {
        alertMessage = text
        showAlert = true
    }
}

enum StorageInfo {
    static func snapshot(path: String) -> (used: Int64, free: Int64, total: Int64)? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let totalNumber = attrs[.systemSize] as? NSNumber,
              let freeNumber = attrs[.systemFreeSize] as? NSNumber else {
            return nil
        }
        let total = totalNumber.int64Value
        let free = freeNumber.int64Value
        return (max(total - free, 0), free, total)
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum PhotoScanner {
    static let imageManager = PHCachingImageManager()

    static func scan(progress: @escaping (Double, Int) -> Void) async -> [AstroCandidate] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        var result: [AstroCandidate] = []
        let total = max(assets.count, 1)

        for index in 0..<assets.count {
            if Task.isCancelled { break }

            let asset = assets.object(at: index)
            let resource = preferredResource(for: asset)
            let filename = resource?.originalFilename ?? "Photo-\(asset.localIdentifier.prefix(8))"

            if let match = filenameMatch(filename) {
                result.append(
                    AstroCandidate(
                        id: asset.localIdentifier,
                        asset: asset,
                        filename: filename,
                        createdAt: asset.creationDate,
                        confidence: match.confidence,
                        category: match.category,
                        reason: match.reason
                    )
                )
            } else if let cgImage = await thumbnailCGImage(for: asset),
                      let match = visionMatch(cgImage) {
                result.append(
                    AstroCandidate(
                        id: asset.localIdentifier,
                        asset: asset,
                        filename: filename,
                        createdAt: asset.creationDate,
                        confidence: match.confidence,
                        category: match.category,
                        reason: match.reason
                    )
                )
            }

            if index % 8 == 0 || index == assets.count - 1 {
                progress(Double(index + 1) / Double(total), result.count)
                await Task.yield()
            }
        }

        return result
    }

    static func preferredResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first
    }

    static func filenameMatch(_ filename: String) -> (confidence: Double, category: AstroCandidate.Category, reason: String)? {
        let lower = filename.lowercased()

        let moon = ["moon", "lunar", "eclipse"]
        let planets = ["saturn", "jupiter", "mars", "venus", "mercury", "uranus", "neptune"]
        let deep = ["nebula", "galaxy", "seestar", "stacked", "pleiades", "orion", "andromeda", "ngc", "ic1805", "ic_1805", "ngc1499", "ngc_1499", "ngc7000", "ngc_7000", "m31", "m42", "m45"]
        let stars = ["milkyway", "milky_way", "starfield", "star_field", "stars"]

        if let k = moon.first(where: { lower.contains($0) }) {
            return (0.99, .moon, "Filename contains \(k)")
        }
        if let k = planets.first(where: { lower.contains($0) }) {
            return (0.99, .planets, "Filename contains \(k)")
        }
        if let k = deep.first(where: { lower.contains($0) }) {
            return (0.97, .deepSky, "Filename contains \(k)")
        }
        if let k = stars.first(where: { lower.contains($0) }) {
            return (0.92, .starFields, "Filename contains \(k)")
        }

        if lower.range(of: #"\b(m|ngc|ic)[ _-]?\d{1,5}\b"#, options: .regularExpression) != nil {
            return (0.95, .deepSky, "Filename resembles an astronomy catalog target")
        }

        return nil
    }

    static func visionMatch(_ cgImage: CGImage) -> (confidence: Double, category: AstroCandidate.Category, reason: String)? {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)

        do {
            try handler.perform([request])
            let observations = request.results ?? []

            for observation in observations.prefix(30) {
                let label = observation.identifier.lowercased()
                let confidence = Double(observation.confidence)

                if label.contains("moon") || label.contains("lunar") {
                    if confidence >= 0.55 { return (confidence, .moon, "Vision: \(observation.identifier)") }
                }

                if label.contains("planet") || label.contains("saturn") || label.contains("jupiter") {
                    if confidence >= 0.55 { return (confidence, .planets, "Vision: \(observation.identifier)") }
                }

                if label.contains("galaxy") || label.contains("nebula") || label.contains("outer space") || label.contains("astronomy") {
                    if confidence >= 0.50 { return (confidence, .deepSky, "Vision: \(observation.identifier)") }
                }

                if label.contains("night sky") || label.contains("starry sky") || label == "star" || label.contains("milky way") {
                    if confidence >= 0.58 { return (confidence, .starFields, "Vision: \(observation.identifier)") }
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    static func thumbnailCGImage(for asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false

            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 512, height: 512),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image?.cgImage)
            }
        }
    }
}

enum Offloader {
    enum OffloadError: LocalizedError {
        case noOriginalResource
        case verificationFailed
        case destinationUnavailable

        var errorDescription: String? {
            switch self {
            case .noOriginalResource: return "Original photo resource was unavailable."
            case .verificationFailed: return "The USB copy did not match the source SHA-256."
            case .destinationUnavailable: return "The USB destination could not be created."
            }
        }
    }

    static func offload(_ candidate: AstroCandidate, to root: URL) async throws -> OffloadRecord {
        guard let resource = PhotoScanner.preferredResource(for: candidate.asset) else {
            throw OffloadError.noOriginalResource
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: candidate.createdAt ?? Date())

        let folder = root
            .appendingPathComponent("AstroRescue", isDirectory: true)
            .appendingPathComponent(candidate.category.folderName, isDirectory: true)
            .appendingPathComponent(date, isDirectory: true)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let destination = uniqueURL(in: folder, preferredName: resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        let sourceHash = try await hash(resource: resource, options: options)
        let destinationHash = try fileHash(destination)

        guard sourceHash == destinationHash else {
            try? FileManager.default.removeItem(at: destination)
            throw OffloadError.verificationFailed
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        return OffloadRecord(
            assetID: candidate.id,
            filename: resource.originalFilename,
            destinationPath: destination.path,
            bytes: bytes,
            sha256: destinationHash,
            verified: true
        )
    }

    static func hash(resource: PHAssetResource, options: PHAssetResourceRequestOptions) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var hasher = SHA256()

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { data in
                    hasher.update(data: data)
                },
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                        continuation.resume(returning: digest)
                    }
                }
            )
        }
    }

    static func fileHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func uniqueURL(in folder: URL, preferredName: String) -> URL {
        let cleanName = preferredName.isEmpty ? "AstroPhoto.jpg" : preferredName
        let base = (cleanName as NSString).deletingPathExtension
        let ext = (cleanName as NSString).pathExtension

        var candidate = folder.appendingPathComponent(cleanName)
        var index = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = folder.appendingPathComponent(next)
            index += 1
        }

        return candidate
    }
}

enum PhotoDeletion {
    static func delete(ids: [String]) async throws {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard fetch.count > 0 else { return }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(fetch)
        }
    }
}

struct DirectoryPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

struct PhotoThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay { ProgressView() }
                    .task { await load() }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func load() async {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 160, height: 160),
                contentMode: .aspectFill,
                options: options
            ) { value, _ in
                Task { @MainActor in
                    image = value
                    continuation.resume()
                }
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: RescueViewModel
    @State private var showPicker = false
    @State private var showReview = false
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    introCard
                    storageCard
                    usbCard
                    scanCard
                    safetyCard
                }
                .padding()
            }
            .navigationTitle("AstroRescue")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPicker) {
                DirectoryPicker { url in
                    model.chooseDestination(url)
                    showPicker = false
                } onCancel: {
                    showPicker = false
                }
            }
            .sheet(isPresented: $showReview) {
                NavigationStack {
                    ReviewView()
                }
                .environmentObject(model)
            }
            .alert("Delete verified iPhone originals?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Continue", role: .destructive) {
                    Task { await model.deleteVerified() }
                }
            } message: {
                Text("Only Photos items with SHA-256 verified USB copies are included. iOS will still control and confirm the deletion.")
            }
            .alert("AstroRescue", isPresented: $model.showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.alertMessage)
            }
        }
    }

    private var introCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
            Text("Find the astro. Save the originals. Free the space.")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text("AstroRescue never edits your photos and never deletes automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var storageCard: some View {
        GroupBox {
            if let s = model.deviceStorage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("iPhone")
                        Spacer()
                        Text("\(StorageInfo.format(s.used)) / \(StorageInfo.format(s.total))")
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(s.used), total: Double(max(s.total, 1)))
                    Text("\(StorageInfo.format(s.free)) free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Storage information unavailable")
            }
        } label: {
            Label("Phone Storage", systemImage: "iphone")
        }
    }

    private var usbCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.usbName)
                    .font(.subheadline.weight(.semibold))

                if let s = model.usbStorage {
                    Text("\(StorageInfo.format(s.free)) free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Plug in your Amazon Basics USB and choose a folder on it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(model.destinationURL == nil ? "Choose USB Folder" : "Change USB Folder") {
                    showPicker = true
                }
                .buttonStyle(.bordered)
            }
        } label: {
            Label("USB Destination", systemImage: "externaldrive")
        }
    }

    private var scanCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Scans Apple Photos using original filenames plus Apple's on-device Vision classifier. Every result is reviewed by you.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if model.isScanning {
                    ProgressView(value: model.scanProgress)
                    Text("\(Int(model.scanProgress * 100))% • \(model.scanFoundCount) likely astro photos found")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Stop Scan", role: .destructive) {
                        model.cancelScan()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task {
                            await model.scanPhotos()
                            if !model.candidates.isEmpty { showReview = true }
                        }
                    } label: {
                        Label("Scan for Astrophotography", systemImage: "sparkles.magnifyingglass")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)

                    if !model.candidates.isEmpty {
                        Button("Review \(model.candidates.count) Results") {
                            showReview = true
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if !model.verifiedAssetIDs.isEmpty {
                    Divider()
                    Label("\(model.verifiedAssetIDs.count) item(s) verified on USB", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)

                    Button("Free Their iPhone Space", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        } label: {
            Label("Astro Offload", systemImage: "moon.stars.fill")
        }
    }

    private var safetyCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Label("No automatic deletion", systemImage: "hand.raised.fill")
                Label("Original resource copied to USB", systemImage: "doc.on.doc")
                Label("Source and USB copy SHA-256 checked", systemImage: "checkmark.shield")
                Label("No generative image processing", systemImage: "photo.badge.checkmark")
            }
            .font(.footnote)
        } label: {
            Label("Safety", systemImage: "shield.lefthalf.filled")
        }
    }
}

struct ReviewView: View {
    @EnvironmentObject private var model: RescueViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            List(model.candidates) { candidate in
                Button {
                    model.toggle(candidate.id)
                } label: {
                    HStack(spacing: 12) {
                        PhotoThumbnail(asset: candidate.asset)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.filename)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(candidate.category.rawValue)
                                .font(.caption)
                            Text("\(Int(candidate.confidence * 100))% • \(candidate.reason)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Image(systemName: model.selectedIDs.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(model.selectedIDs.contains(candidate.id) ? .blue : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 10) {
                if model.isOffloading {
                    ProgressView(value: model.offloadProgress)
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(model.selectedIDs.count == model.candidates.count ? "Deselect All" : "Select All") {
                        model.toggleAll()
                    }
                    Spacer()
                    Text("\(model.selectedIDs.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await model.offloadSelected() }
                } label: {
                    Label("Offload \(model.selectedIDs.count) to USB", systemImage: "externaldrive.badge.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedIDs.isEmpty || model.destinationURL == nil || model.isOffloading)
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Review Astro Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
        }
    }
}
