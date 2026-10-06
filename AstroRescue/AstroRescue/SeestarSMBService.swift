import Foundation
import CryptoKit
import AMSMB2

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
                return "Connected to the Seestar, but the EMMC Images share was not found."
            case .noMyWorks:
                return "Connected to the Seestar, but MyWorks was not found."
            case .verificationFailed(let name):
                return "Verification failed for \(name). The USB copy was removed and the Seestar original was kept."
            }
        }
    }

    private var client: SMB2Manager?
    private var shareName: String?
    private var myWorksPath = "/MyWorks"

    func connect(
        host: String,
        username: String = "",
        password: String = ""
    ) async throws -> (folders: [SeestarFolder], storage: SeestarStorageInfo?) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let url = URL(string: "smb://\(clean)") else {
            throw ServiceError.badHost
        }

        struct Login {
            let user: String
            let password: String
        }

        var logins: [Login] = []
        let enteredUser = username.trimmingCharacters(in: .whitespacesAndNewlines)

        if !enteredUser.isEmpty {
            logins.append(Login(user: enteredUser, password: password))
        }

        // Official Seestar desktop instructions use Guest access.
        logins.append(Login(user: "guest", password: ""))

        // Older Seestar/Samba builds have also accepted this maintenance login.
        // Keep it as a fallback only; the user's actual device credentials are preferred.
        logins.append(Login(user: "zwo", password: "admin"))

        var lastError: Error?

        for login in logins {
            let credential = URLCredential(
                user: login.user,
                password: login.password,
                persistence: .forSession
            )

            guard let manager = SMB2Manager(url: url, credential: credential) else {
                continue
            }

            do {
                let shares = try await manager.listShares()
                guard let share = shares.first(where: {
                    $0.name.lowercased().contains("emmc")
                })?.name ?? shares.first(where: {
                    $0.name.lowercased().contains("image")
                })?.name else {
                    throw ServiceError.noEMMCShare
                }

                try await manager.connectShare(name: share)

                self.client = manager
                self.shareName = share

                let root = try await manager.contentsOfDirectory(atPath: "/")
                if let myWorks = root.first(where: {
                    (($0[.nameKey] as? String) ?? "").caseInsensitiveCompare("MyWorks") == .orderedSame
                }) {
                    myWorksPath = (myWorks[.pathKey] as? String) ?? "/MyWorks"
                } else {
                    let fallback = try? await manager.contentsOfDirectory(atPath: "/MyWorks")
                    guard fallback != nil else { throw ServiceError.noMyWorks }
                    myWorksPath = "/MyWorks"
                }

                let top = try await manager.contentsOfDirectory(atPath: myWorksPath)
                let folders: [SeestarFolder] = top.compactMap { entry in
                    let type = entry[.fileResourceTypeKey] as? URLFileResourceType
                    guard type == .directory,
                          let name = entry[.nameKey] as? String,
                          !name.hasPrefix(".") else { return nil }

                    let path = (entry[.pathKey] as? String)
                        ?? "\(myWorksPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(name)"

                    return SeestarFolder(name: name, path: normalizeRemotePath(path))
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                var storage: SeestarStorageInfo?
                if let attrs = try? await manager.attributesOfFileSystem(forPath: "/") {
                    let total = number(attrs[.systemSize])
                    let free = number(attrs[.systemFreeSize])
                    if total > 0 {
                        storage = SeestarStorageInfo(free: free, total: total)
                    }
                }

                return (folders, storage)
            } catch {
                lastError = error
                try? await manager.disconnectShare(gracefully: false)
            }
        }

        throw lastError ?? ServiceError.noClient
    }

    func backup(
        folders: [SeestarFolder],
        to usbRoot: URL,
        progress: @escaping @Sendable (_ status: String, _ completedFiles: Int, _ totalFiles: Int, _ bytesCopied: Int64) -> Void
    ) async throws -> SeestarBackupSummary {
        guard let client else { throw ServiceError.noClient }

        var inventory: [(folder: SeestarFolder, remotePath: String, relativePath: String)] = []

        for folder in folders {
            let entries = try await client.contentsOfDirectory(atPath: folder.path, recursive: true)
            for entry in entries {
                let type = entry[.fileResourceTypeKey] as? URLFileResourceType
                guard type != .directory else { continue }

                guard let name = entry[.nameKey] as? String else { continue }
                let remote = normalizeRemotePath((entry[.pathKey] as? String) ?? "\(folder.path)/\(name)")
                let relative = relativePath(remotePath: remote, under: folder.path, fallbackName: name)
                inventory.append((folder, remote, relative))
            }
        }

        let totalFiles = inventory.count
        var completed = 0
        var copiedBytes: Int64 = 0
        var folderFailures: [String: Bool] = [:]

        for item in inventory {
            progress("Copying \(item.folder.name) • \((item.relativePath as NSString).lastPathComponent)", completed, totalFiles, copiedBytes)

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
                    destination: destination
                )
                copiedBytes += result.bytes
                completed += 1
                progress("Verified \((item.relativePath as NSString).lastPathComponent)", completed, totalFiles, copiedBytes)
            } catch {
                folderFailures[item.folder.path] = true
                throw error
            }
        }

        let verifiedFolders = Set(
            folders
                .filter { folderFailures[$0.path] != true }
                .map(\.path)
        )

        return SeestarBackupSummary(
            verifiedFolderPaths: verifiedFolders,
            filesCopied: completed,
            bytesCopied: copiedBytes
        )
    }

    func deleteVerifiedFolders(paths: Set<String>) async throws {
        guard let client else { throw ServiceError.noClient }
        for path in paths.sorted() {
            try await client.removeDirectory(atPath: path, recursive: true)
        }
    }

    func disconnect() async {
        try? await client?.disconnectShare(gracefully: true)
        client = nil
        shareName = nil
    }

    private func copyAndVerify(
        client: SMB2Manager,
        remotePath: String,
        destination: URL
    ) async throws -> (bytes: Int64, sha256: String) {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let handle = try FileHandle(forWritingTo: destination)
        var sourceHasher = SHA256()
        var bytes: Int64 = 0

        do {
            let stream: AsyncThrowingStream<Data, any Error> = client.contents(
                atPath: remotePath,
                range: Optional<Range<UInt64>>.none
            )

            for try await chunk in stream {
                try handle.write(contentsOf: chunk)
                sourceHasher.update(data: chunk)
                bytes += Int64(chunk.count)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        let sourceHash = sourceHasher.finalize().map { String(format: "%02x", $0) }.joined()
        let destinationHash = try localHash(destination)

        guard sourceHash == destinationHash else {
            try? FileManager.default.removeItem(at: destination)
            throw ServiceError.verificationFailed((remotePath as NSString).lastPathComponent)
        }

        return (bytes, destinationHash)
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

    private func relativePath(remotePath: String, under folderPath: String, fallbackName: String) -> String {
        let remote = normalizeRemotePath(remotePath)
        let base = normalizeRemotePath(folderPath)
        let prefix = base.hasSuffix("/") ? base : base + "/"

        if remote.hasPrefix(prefix) {
            let result = String(remote.dropFirst(prefix.count))
            if !result.isEmpty { return result }
        }
        return fallbackName
    }

    private func normalizeRemotePath(_ path: String) -> String {
        let replaced = path.replacingOccurrences(of: "\\", with: "/")
        return replaced.hasPrefix("/") ? replaced : "/" + replaced
    }

    private func number(_ value: Any?) -> Int64 {
        if let n = value as? NSNumber { return n.int64Value }
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        return 0
    }
}
