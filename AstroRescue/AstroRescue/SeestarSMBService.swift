import Foundation
import CryptoKit
import SMBClient

struct SeestarFolder: Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
}

struct SeestarStorageInfo {
    let free: Int64
    let total: Int64
}

struct SeestarBackupSummary {
    let verifiedFolderPaths: Set<String>
    let filesCopied: Int
    let bytesCopied: Int64
    let failedFolders: [String]
}

private final class HTTPStreamDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum DownloadError: LocalizedError {
        case badResponse(Int)
        case cannotOpenDestination
        case incomplete(expected: UInt64, actual: UInt64)

        var errorDescription: String? {
            switch self {
            case .badResponse(let code):
                return "Seestar HTTP server returned status \(code)."
            case .cannotOpenDestination:
                return "Could not open the USB destination for writing."
            case .incomplete(let expected, let actual):
                return "Transfer ended early (\(actual) of \(expected) bytes)."
            }
        }
    }

    private let destination: URL
    private let expectedSize: UInt64
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var byteCount: UInt64 = 0
    private var continuation: CheckedContinuation<(UInt64, String), Error>?
    private var storedError: Error?
    private var session: URLSession?

    init(destination: URL, expectedSize: UInt64) {
        self.destination = destination
        self.expectedSize = expectedSize
        super.init()
    }

    func download(from url: URL) async throws -> (UInt64, String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        fm.createFile(atPath: destination.path, contents: nil)

        guard let file = FileHandle(forWritingAtPath: destination.path) else {
            throw DownloadError.cannotOpenDestination
        }
        handle = file

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("close", forHTTPHeaderField: "Connection")
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            storedError = DownloadError.badResponse(http.statusCode)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard storedError == nil else { return }
        do {
            try handle?.write(contentsOf: data)
            hasher.update(data: data)
            byteCount += UInt64(data.count)
        } catch {
            storedError = error
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        try? handle?.close()
        handle = nil

        let resultError = storedError ?? error
        session.finishTasksAndInvalidate()
        self.session = nil

        if let resultError {
            continuation?.resume(throwing: resultError)
            continuation = nil
            return
        }

        if expectedSize > 0, byteCount != expectedSize {
            continuation?.resume(
                throwing: DownloadError.incomplete(expected: expectedSize, actual: byteCount)
            )
            continuation = nil
            return
        }

        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        continuation?.resume(returning: (byteCount, hash))
        continuation = nil
    }
}

final class SeestarSMBService: @unchecked Sendable {
    enum ServiceError: LocalizedError {
        case badHost
        case noClient
        case noEMMCShare
        case noMyWorks
        case verificationFailed(String)
        case badHTTPURL

        var errorDescription: String? {
            switch self {
            case .badHost:
                return "That Seestar IP address is not valid."
            case .noClient:
                return "Seestar is not connected."
            case .noEMMCShare:
                return "Connected to the Seestar, but the EMMC Images share could not be opened."
            case .noMyWorks:
                return "Connected to the Seestar, but MyWorks was not found."
            case .verificationFailed(let name):
                return "Verification failed for \(name). The USB copy was removed and the Seestar original was kept."
            case .badHTTPURL:
                return "Could not create the Seestar download URL."
            }
        }
    }

    private let shareName = "EMMC Images"
    private let myWorksPath = "MyWorks"
    private var host: String?

    func connect(host: String) async throws -> (folders: [SeestarFolder], storage: SeestarStorageInfo?) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ServiceError.badHost }
        self.host = clean

        let smb = try await makeClient(host: clean)
        defer {
            Task {
                _ = try? await smb.disconnectShare()
                _ = try? await smb.logoff()
            }
        }

        let root = try await smb.listDirectory(path: myWorksPath)
        let folders = root
            .filter { $0.isDirectory && !$0.name.hasPrefix(".") }
            .map { SeestarFolder(name: $0.name, path: "\(myWorksPath)/\($0.name)") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if folders.isEmpty {
            let exists = (try? await smb.existDirectory(path: myWorksPath)) ?? false
            if !exists { throw ServiceError.noMyWorks }
        }

        var storage: SeestarStorageInfo?
        if let free = try? await smb.availableSpace() {
            storage = SeestarStorageInfo(free: Int64(free), total: 0)
        }

        return (folders, storage)
    }

    func backup(
        folders: [SeestarFolder],
        to usbRoot: URL,
        progress: @escaping @Sendable (_ status: String, _ completedFiles: Int, _ totalFiles: Int, _ bytesCopied: Int64) -> Void
    ) async throws -> SeestarBackupSummary {
        guard let host else { throw ServiceError.noClient }

        var inventory: [(folder: SeestarFolder, remotePath: String, relativePath: String, size: UInt64)] = []
        var failedFolders: [String] = []

        for folder in folders {
            progress("Indexing \(folder.name)…", inventory.count, max(inventory.count + 1, 1), 0)

            do {
                let files = try await inventoryForFolderWithRetry(folder, host: host)
                inventory.append(contentsOf: files)
            } catch {
                failedFolders.append(folder.name)
            }
        }

        let totalFiles = inventory.count
        var completed = 0
        var copiedBytes: Int64 = 0
        var verifiedFolders = Set(folders.map(\.path))

        for failed in failedFolders {
            if let folder = folders.first(where: { $0.name == failed }) {
                verifiedFolders.remove(folder.path)
            }
        }

        let groupedCounts = Dictionary(grouping: inventory, by: { $0.folder.path })
            .mapValues(\.count)
        var completedPerFolder: [String: Int] = [:]

        for item in inventory {
            progress(
                "Copying \(item.folder.name) • \((item.relativePath as NSString).lastPathComponent)",
                completed,
                max(totalFiles, 1),
                copiedBytes
            )

            let folderRoot = usbRoot
                .appendingPathComponent("Seestar Direct", isDirectory: true)
                .appendingPathComponent(item.folder.name, isDirectory: true)

            let destination = folderRoot.appendingPathComponent(item.relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            do {
                let result = try await copyHTTPWithRetry(
                    host: host,
                    remotePath: item.remotePath,
                    remoteSize: item.size,
                    destination: destination
                )

                copiedBytes += result.bytes
                completed += 1
                completedPerFolder[item.folder.path, default: 0] += 1

                progress(
                    "Verified \((item.relativePath as NSString).lastPathComponent)",
                    completed,
                    max(totalFiles, 1),
                    copiedBytes
                )
            } catch {
                verifiedFolders.remove(item.folder.path)
                failedFolders.append(item.folder.name)
                // Continue with the remaining folders/files rather than killing
                // the whole backup. The failed folder will never be offered
                // for deletion.
            }
        }

        for folder in folders {
            let expected = groupedCounts[folder.path] ?? 0
            let done = completedPerFolder[folder.path] ?? 0
            if expected == 0 || done != expected {
                verifiedFolders.remove(folder.path)
            }
        }

        return SeestarBackupSummary(
            verifiedFolderPaths: verifiedFolders,
            filesCopied: completed,
            bytesCopied: copiedBytes,
            failedFolders: Array(Set(failedFolders)).sorted()
        )
    }

    func deleteVerifiedFolders(paths: Set<String>) async throws {
        guard let host else { throw ServiceError.noClient }

        for path in paths.sorted() {
            let smb = try await makeClient(host: host)
            do {
                try await deleteDirectoryRecursively(client: smb, path: path)
                _ = try? await smb.disconnectShare()
                _ = try? await smb.logoff()
            } catch {
                _ = try? await smb.disconnectShare()
                _ = try? await smb.logoff()
                throw error
            }
        }
    }

    func disconnect() async {
        // v0.4.1 uses short-lived SMB sessions and HTTP downloads, so there
        // is no persistent socket to tear down.
    }

    private func makeClient(host: String) async throws -> SMBClient {
        let smb = SMBClient(host: host)
        do {
            try await smb.login(username: nil, password: nil)
            try await smb.connectShare(shareName)
            return smb
        } catch {
            _ = try? await smb.logoff()
            throw error
        }
    }

    private func inventoryForFolderWithRetry(
        _ folder: SeestarFolder,
        host: String
    ) async throws -> [(folder: SeestarFolder, remotePath: String, relativePath: String, size: UInt64)] {
        var lastError: Error?

        for attempt in 1...3 {
            let smb: SMBClient
            do {
                smb = try await makeClient(host: host)
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                throw error
            }

            do {
                var result: [(folder: SeestarFolder, remotePath: String, relativePath: String, size: UInt64)] = []
                try await enumerateFiles(
                    client: smb,
                    rootFolder: folder,
                    currentPath: folder.path,
                    relativeBase: "",
                    into: &result
                )
                _ = try? await smb.disconnectShare()
                _ = try? await smb.logoff()
                return result
            } catch {
                lastError = error
                _ = try? await smb.disconnectShare()
                _ = try? await smb.logoff()

                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 600_000_000)
                }
            }
        }

        throw lastError ?? ServiceError.noClient
    }

    private func enumerateFiles(
        client: SMBClient,
        rootFolder: SeestarFolder,
        currentPath: String,
        relativeBase: String,
        into inventory: inout [(folder: SeestarFolder, remotePath: String, relativePath: String, size: UInt64)]
    ) async throws {
        let entries = try await client.listDirectory(path: currentPath)

        for entry in entries where entry.name != "." && entry.name != ".." {
            let remote = "\(currentPath)/\(entry.name)"
            let relative = relativeBase.isEmpty ? entry.name : "\(relativeBase)/\(entry.name)"

            if entry.isDirectory {
                try await enumerateFiles(
                    client: client,
                    rootFolder: rootFolder,
                    currentPath: remote,
                    relativeBase: relative,
                    into: &inventory
                )
            } else {
                inventory.append((rootFolder, remote, relative, entry.size))
            }
        }
    }

    private func copyHTTPWithRetry(
        host: String,
        remotePath: String,
        remoteSize: UInt64,
        destination: URL
    ) async throws -> (bytes: Int64, sha256: String) {
        var lastError: Error?

        for attempt in 1...3 {
            do {
                let result = try await copyHTTP(
                    host: host,
                    remotePath: remotePath,
                    remoteSize: remoteSize,
                    destination: destination
                )
                return result
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: destination)

                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 750_000_000)
                }
            }
        }

        throw lastError ?? ServiceError.verificationFailed((remotePath as NSString).lastPathComponent)
    }

    private func copyHTTP(
        host: String,
        remotePath: String,
        remoteSize: UInt64,
        destination: URL
    ) async throws -> (bytes: Int64, sha256: String) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.path = "/" + remotePath

        guard let url = components.url else { throw ServiceError.badHTTPURL }

        let downloader = HTTPStreamDownloader(
            destination: destination,
            expectedSize: remoteSize
        )
        let (bytes, sourceHash) = try await downloader.download(from: url)

        let destinationHash = try localHash(destination)
        guard sourceHash == destinationHash else {
            try? FileManager.default.removeItem(at: destination)
            throw ServiceError.verificationFailed((remotePath as NSString).lastPathComponent)
        }

        return (Int64(bytes), destinationHash)
    }

    private func deleteDirectoryRecursively(client: SMBClient, path: String) async throws {
        let entries = try await client.listDirectory(path: path)

        for entry in entries where entry.name != "." && entry.name != ".." {
            let child = "\(path)/\(entry.name)"
            if entry.isDirectory {
                try await deleteDirectoryRecursively(client: client, path: child)
            } else {
                try await client.deleteFile(path: child)
            }
        }

        try await client.deleteDirectory(path: path)
    }

    private func localHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
