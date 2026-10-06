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
}

final class SeestarSMBService: @unchecked Sendable {
    enum ServiceError: LocalizedError {
        case badHost
        case noClient
        case noEMMCShare
        case noMyWorks
        case verificationFailed(String)

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
            }
        }
    }

    private var client: SMBClient?
    private let shareName = "EMMC Images"
    private let myWorksPath = "MyWorks"

    func connect(host: String) async throws -> (folders: [SeestarFolder], storage: SeestarStorageInfo?) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ServiceError.badHost }

        let smb = SMBClient(host: clean)

        do {
            // Anonymous/null-session login. SMBClient 0.3.1 specifically
            // disables signing for anonymous sessions, which matches Seestar.
            try await smb.login(username: nil, password: nil)
            try await smb.connectShare(shareName)
        } catch {
            _ = try? await smb.logoff()
            throw error
        }

        let root = try await smb.listDirectory(path: myWorksPath)
        let folders = root
            .filter { $0.isDirectory && !$0.name.hasPrefix(".") }
            .map { SeestarFolder(name: $0.name, path: "\(myWorksPath)/\($0.name)") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if folders.isEmpty {
            let exists = (try? await smb.existDirectory(path: myWorksPath)) ?? false
            if !exists {
                _ = try? await smb.disconnectShare()
                _ = try? await smb.logoff()
                throw ServiceError.noMyWorks
            }
        }

        self.client = smb

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
        guard let client else { throw ServiceError.noClient }

        var inventory: [(folder: SeestarFolder, remotePath: String, relativePath: String, size: UInt64)] = []

        for folder in folders {
            try await enumerateFiles(
                client: client,
                rootFolder: folder,
                currentPath: folder.path,
                relativeBase: "",
                into: &inventory
            )
        }

        let totalFiles = inventory.count
        var completed = 0
        var copiedBytes: Int64 = 0
        var verifiedFolders = Set(folders.map(\.path))

        for item in inventory {
            progress(
                "Copying \(item.folder.name) • \((item.relativePath as NSString).lastPathComponent)",
                completed,
                totalFiles,
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
                let result = try await copyAndVerify(
                    client: client,
                    remotePath: item.remotePath,
                    remoteSize: item.size,
                    destination: destination
                )
                copiedBytes += result.bytes
                completed += 1
                progress(
                    "Verified \((item.relativePath as NSString).lastPathComponent)",
                    completed,
                    totalFiles,
                    copiedBytes
                )
            } catch {
                verifiedFolders.remove(item.folder.path)
                throw error
            }
        }

        return SeestarBackupSummary(
            verifiedFolderPaths: verifiedFolders,
            filesCopied: completed,
            bytesCopied: copiedBytes
        )
    }

    func deleteVerifiedFolders(paths: Set<String>) async throws {
        guard let client else { throw ServiceError.noClient }

        for path in paths.sorted() {
            try await deleteDirectoryRecursively(client: client, path: path)
        }
    }

    func disconnect() async {
        guard let client else { return }
        _ = try? await client.disconnectShare()
        _ = try? await client.logoff()
        self.client = nil
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

    private func copyAndVerify(
        client: SMBClient,
        remotePath: String,
        remoteSize: UInt64,
        destination: URL
    ) async throws -> (bytes: Int64, sha256: String) {
        let fm = FileManager.default

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        fm.createFile(atPath: destination.path, contents: nil)

        guard let handle = FileHandle(forWritingAtPath: destination.path) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let reader = client.fileReader(path: remotePath)
        var sourceHasher = SHA256()
        var offset: UInt64 = 0

        do {
            while offset < remoteSize {
                let remaining = remoteSize - offset
                let chunkSize = UInt32(min(remaining, UInt64(1024 * 1024)))
                let chunk = try await reader.read(offset: offset, length: chunkSize)
                if chunk.isEmpty { break }

                try handle.write(contentsOf: chunk)
                sourceHasher.update(data: chunk)
                offset += UInt64(chunk.count)
            }

            try handle.close()
            try await reader.close()
        } catch {
            try? handle.close()
            try? await reader.close()
            try? fm.removeItem(at: destination)
            throw error
        }

        guard offset == remoteSize else {
            try? fm.removeItem(at: destination)
            throw ServiceError.verificationFailed((remotePath as NSString).lastPathComponent)
        }

        let sourceHash = sourceHasher.finalize().map { String(format: "%02x", $0) }.joined()
        let destinationHash = try localHash(destination)

        let attrs = try fm.attributesOfItem(atPath: destination.path)
        let localSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        guard sourceHash == destinationHash, localSize == remoteSize else {
            try? fm.removeItem(at: destination)
            throw ServiceError.verificationFailed((remotePath as NSString).lastPathComponent)
        }

        return (Int64(localSize), destinationHash)
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
