import CryptoKit
import Foundation

struct MigrationBackupManifest: Codable, Equatable, Sendable {
    struct FileEntry: Codable, Equatable, Sendable {
        let name: String
        let byteCount: UInt64
        let sha256: String
    }

    let createdAt: Date
    let sourceStoreURL: URL
    let backupStoreURL: URL
    let files: [FileEntry]
}

enum MigrationBackupError: Error, Equatable {
    case missingFile(String)
    case byteCountMismatch(String)
    case checksumMismatch(String)
    case missingPrimaryStore
}

enum MigrationBackupManager {
    static func createBackupIfPresent(
        storeURL: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> MigrationBackupManifest? {
        guard fileManager.fileExists(atPath: storeURL.path) else { return nil }

        let backupDirectory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("DensosoMigrationBackups", isDirectory: true)
            .appendingPathComponent("\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let sourceURLs = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ].filter { fileManager.fileExists(atPath: $0.path) }

        var entries: [MigrationBackupManifest.FileEntry] = []
        for sourceURL in sourceURLs {
            let destinationURL = backupDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            let data = try Data(contentsOf: destinationURL, options: .mappedIfSafe)
            entries.append(
                .init(
                    name: destinationURL.lastPathComponent,
                    byteCount: UInt64(data.count),
                    sha256: SHA256.hash(data: data).hexString
                )
            )
        }

        let backupStoreURL = backupDirectory.appendingPathComponent(storeURL.lastPathComponent)
        let manifest = MigrationBackupManifest(
            createdAt: now,
            sourceStoreURL: storeURL,
            backupStoreURL: backupStoreURL,
            files: entries.sorted { $0.name < $1.name }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: backupDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        return manifest
    }

    static func fingerprint(
        manifest: MigrationBackupManifest,
        fileManager: FileManager = .default
    ) throws -> [String: String] {
        let directory = manifest.backupStoreURL.deletingLastPathComponent()
        return try Dictionary(uniqueKeysWithValues: manifest.files.map { entry in
            let url = directory.appendingPathComponent(entry.name)
            guard fileManager.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return (entry.name, SHA256.hash(data: data).hexString)
        })
    }

    static func restore(
        manifest: MigrationBackupManifest,
        fileManager: FileManager = .default
    ) throws {
        let backupDirectory = manifest.backupStoreURL.deletingLastPathComponent()
        let destinationDirectory = manifest.sourceStoreURL.deletingLastPathComponent()
        try validate(manifest: manifest, directory: backupDirectory, fileManager: fileManager)
        guard manifest.files.contains(where: { $0.name == manifest.sourceStoreURL.lastPathComponent }) else {
            throw MigrationBackupError.missingPrimaryStore
        }

        let transactionDirectory = destinationDirectory
            .appendingPathComponent(".densoso-restore-\(UUID().uuidString.lowercased())", isDirectory: true)
        let stagedDirectory = transactionDirectory.appendingPathComponent("staged", isDirectory: true)
        let rollbackDirectory = transactionDirectory.appendingPathComponent("rollback", isDirectory: true)
        try fileManager.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)

        for entry in manifest.files {
            try fileManager.copyItem(
                at: backupDirectory.appendingPathComponent(entry.name),
                to: stagedDirectory.appendingPathComponent(entry.name)
            )
        }
        try validate(manifest: manifest, directory: stagedDirectory, fileManager: fileManager)

        let knownDestinationURLs = [
            manifest.sourceStoreURL,
            URL(fileURLWithPath: manifest.sourceStoreURL.path + "-wal"),
            URL(fileURLWithPath: manifest.sourceStoreURL.path + "-shm"),
        ]

        do {
            for destinationURL in knownDestinationURLs where fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.moveItem(
                    at: destinationURL,
                    to: rollbackDirectory.appendingPathComponent(destinationURL.lastPathComponent)
                )
            }
            for entry in manifest.files {
                try fileManager.moveItem(
                    at: stagedDirectory.appendingPathComponent(entry.name),
                    to: destinationDirectory.appendingPathComponent(entry.name)
                )
            }
            try validate(manifest: manifest, directory: destinationDirectory, fileManager: fileManager)
            try fileManager.removeItem(at: transactionDirectory)
        } catch {
            for entry in manifest.files {
                let partiallyRestored = destinationDirectory.appendingPathComponent(entry.name)
                if fileManager.fileExists(atPath: partiallyRestored.path) {
                    try? fileManager.removeItem(at: partiallyRestored)
                }
            }
            if let rollbackFiles = try? fileManager.contentsOfDirectory(
                at: rollbackDirectory,
                includingPropertiesForKeys: nil
            ) {
                for rollbackURL in rollbackFiles {
                    try? fileManager.moveItem(
                        at: rollbackURL,
                        to: destinationDirectory.appendingPathComponent(rollbackURL.lastPathComponent)
                    )
                }
            }
            try? fileManager.removeItem(at: transactionDirectory)
            throw error
        }
    }

    private static func validate(
        manifest: MigrationBackupManifest,
        directory: URL,
        fileManager: FileManager
    ) throws {
        for entry in manifest.files {
            let url = directory.appendingPathComponent(entry.name)
            guard fileManager.fileExists(atPath: url.path) else {
                throw MigrationBackupError.missingFile(entry.name)
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard UInt64(data.count) == entry.byteCount else {
                throw MigrationBackupError.byteCountMismatch(entry.name)
            }
            guard SHA256.hash(data: data).hexString == entry.sha256 else {
                throw MigrationBackupError.checksumMismatch(entry.name)
            }
        }
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
