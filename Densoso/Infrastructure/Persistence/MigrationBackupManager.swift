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

enum MigrationRestoreTransactionState: String, Codable, Sendable {
    case prepared
    case staging
    case originalMoved
    case installing
    case validating
    case committed
    case rollingBack
    case recoveryRequired
}

struct MigrationRestoreTransactionManifest: Codable, Sendable {
    let transactionID: UUID
    let sourceStoreURL: URL
    let backupStoreURL: URL
    let stagedDirectory: URL
    let rollbackDirectory: URL
    let expectedFiles: [MigrationBackupManifest.FileEntry]
    let originalFiles: [MigrationBackupManifest.FileEntry]
    let createdAt: Date
    var updatedAt: Date
    var state: MigrationRestoreTransactionState
}

enum MigrationBackupMoveKind {
    case originalToRollback
    case stagedToDestination
    case rollbackToOriginal
}

struct MigrationBackupRestoreFailure: LocalizedError {
    let originalFailure: String
    let rollbackFailure: String
    let transactionDirectory: URL

    var errorDescription: String? {
        "Store restore failed: \(originalFailure). Rollback also failed: \(rollbackFailure). Recovery files were preserved at \(transactionDirectory.path)."
    }
}

enum MigrationBackupError: Error, Equatable {
    case missingFile(String)
    case byteCountMismatch(String)
    case checksumMismatch(String)
    case missingPrimaryStore
    case interruptedRestoreManifestMissing(String)
    case interruptedRestoreRecoveryRequired(String)
    case invalidRestoreTransactionManifest(String)
}

enum MigrationBackupManager {
    typealias MoveFaultInjector = (MigrationBackupMoveKind, URL, URL) throws -> Void

    private static let sidecarSuffixes = ["", "-wal", "-shm"]
    private static let transactionPrefix = ".densoso-restore-"

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

        let sourceURLs = storeFamilyURLs(for: storeURL).filter { fileManager.fileExists(atPath: $0.path) }
        let entries = try copyAndFingerprint(sourceURLs, to: backupDirectory, fileManager: fileManager)
        let backupStoreURL = backupDirectory.appendingPathComponent(storeURL.lastPathComponent)
        let manifest = MigrationBackupManifest(
            createdAt: now,
            sourceStoreURL: storeURL,
            backupStoreURL: backupStoreURL,
            files: entries.sorted { $0.name < $1.name }
        )
        try encode(manifest).write(
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
        fileManager: FileManager = .default,
        willMove: MoveFaultInjector? = nil,
        now: Date = Date()
    ) throws {
        try validateBackupManifestPaths(manifest)
        try validateFileEntries(manifest.files, storeURL: manifest.sourceStoreURL)
        let backupDirectory = manifest.backupStoreURL.deletingLastPathComponent()
        let destinationDirectory = manifest.sourceStoreURL.deletingLastPathComponent()
        try validate(manifest: manifest, directory: backupDirectory, fileManager: fileManager)
        guard manifest.files.contains(where: { $0.name == manifest.sourceStoreURL.lastPathComponent }) else {
            throw MigrationBackupError.missingPrimaryStore
        }

        let transactionID = UUID()
        let transactionDirectory = destinationDirectory
            .appendingPathComponent("\(transactionPrefix)\(transactionID.uuidString.lowercased())", isDirectory: true)
        let stagedDirectory = transactionDirectory.appendingPathComponent("staged", isDirectory: true)
        let rollbackDirectory = transactionDirectory.appendingPathComponent("rollback", isDirectory: true)
        try fileManager.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)

        var transaction = MigrationRestoreTransactionManifest(
            transactionID: transactionID,
            sourceStoreURL: manifest.sourceStoreURL,
            backupStoreURL: manifest.backupStoreURL,
            stagedDirectory: stagedDirectory,
            rollbackDirectory: rollbackDirectory,
            expectedFiles: manifest.files,
            originalFiles: try fingerprintExistingStoreFamily(
                at: manifest.sourceStoreURL,
                fileManager: fileManager
            ),
            createdAt: now,
            updatedAt: now,
            state: .prepared
        )
        try write(transaction, in: transactionDirectory)

        do {
            try update(&transaction, to: .staging, in: transactionDirectory)
            for entry in manifest.files {
                try fileManager.copyItem(
                    at: backupDirectory.appendingPathComponent(entry.name),
                    to: stagedDirectory.appendingPathComponent(entry.name)
                )
            }
            try validate(files: transaction.expectedFiles, directory: stagedDirectory, fileManager: fileManager)

            for original in transaction.originalFiles {
                let source = destinationDirectory.appendingPathComponent(original.name)
                let destination = rollbackDirectory.appendingPathComponent(original.name)
                try willMove?(.originalToRollback, source, destination)
                try fileManager.moveItem(at: source, to: destination)
                try update(&transaction, to: .originalMoved, in: transactionDirectory)
            }

            try update(&transaction, to: .installing, in: transactionDirectory)
            for entry in manifest.files {
                let source = stagedDirectory.appendingPathComponent(entry.name)
                let destination = destinationDirectory.appendingPathComponent(entry.name)
                try willMove?(.stagedToDestination, source, destination)
                try fileManager.moveItem(at: source, to: destination)
                try update(&transaction, to: .installing, in: transactionDirectory)
            }

            try update(&transaction, to: .validating, in: transactionDirectory)
            try validate(files: transaction.expectedFiles, directory: destinationDirectory, fileManager: fileManager)
            try update(&transaction, to: .committed, in: transactionDirectory)
            try fileManager.removeItem(at: transactionDirectory)
        } catch {
            let originalError = error
            do {
                try rollback(transaction: &transaction, directory: transactionDirectory, fileManager: fileManager, willMove: willMove)
                if fileManager.fileExists(atPath: transactionDirectory.path) {
                    try fileManager.removeItem(at: transactionDirectory)
                }
            } catch {
                let rollbackError = error
                transaction.state = .recoveryRequired
                transaction.updatedAt = Date()
                var recoveryFailure: String?
                do { try write(transaction, in: transactionDirectory) }
                catch {
                    recoveryFailure = "recovery manifest update failed: \(error.localizedDescription)"
                }
                throw MigrationBackupRestoreFailure(
                    originalFailure: String(describing: originalError),
                    rollbackFailure: [String(describing: rollbackError), recoveryFailure]
                        .compactMap { $0 }
                        .joined(separator: "; "),
                    transactionDirectory: transactionDirectory
                )
            }
            throw originalError
        }
    }

    /// Runs before ModelContainer creation. An unresolved transaction blocks
    /// bootstrap so a missing primary store can never become a fresh empty store.
    static func recoverInterruptedRestores(
        storeURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let parent = storeURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path) else { return }
        // Restore directories are hidden by design, so retain hidden entries in
        // this scan to detect a process death between file moves.
        let allEntries = try fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey])
        for directory in allEntries where directory.lastPathComponent.hasPrefix(transactionPrefix) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let manifestURL = directory.appendingPathComponent("transaction.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                throw MigrationBackupError.interruptedRestoreManifestMissing(directory.lastPathComponent)
            }
            var transaction = try decodeTransaction(at: manifestURL)
            guard transaction.sourceStoreURL.standardizedFileURL == storeURL.standardizedFileURL else { continue }
            try validateTransaction(
                transaction,
                directory: directory,
                storeURL: storeURL
            )

            if matches(files: transaction.expectedFiles, in: parent, fileManager: fileManager) {
                try update(&transaction, to: .committed, in: directory)
                try fileManager.removeItem(at: directory)
                continue
            }
            if transaction.originalFiles.isEmpty {
                do {
                    try completeRestore(transaction: &transaction, directory: directory, fileManager: fileManager)
                    try fileManager.removeItem(at: directory)
                    continue
                } catch {
                    transaction.state = .recoveryRequired
                    transaction.updatedAt = Date()
                    var detail = error.localizedDescription
                    do { try write(transaction, in: directory) }
                    catch { detail += "; recovery manifest update failed: \(error.localizedDescription)" }
                    throw MigrationBackupError.interruptedRestoreRecoveryRequired(
                        "\(directory.lastPathComponent): \(detail)"
                    )
                }
            }
            let originalIsIntact: Bool
            originalIsIntact = matches(files: transaction.originalFiles, in: parent, fileManager: fileManager)
            if originalIsIntact {
                // The original family never moved (or rollback already finished).
                try fileManager.removeItem(at: directory)
                continue
            }

            do {
                try rollback(transaction: &transaction, directory: directory, fileManager: fileManager, willMove: nil)
                try fileManager.removeItem(at: directory)
            } catch {
                transaction.state = .recoveryRequired
                transaction.updatedAt = Date()
                var detail = error.localizedDescription
                do { try write(transaction, in: directory) }
                catch { detail += "; recovery manifest update failed: \(error.localizedDescription)" }
                throw MigrationBackupError.interruptedRestoreRecoveryRequired(
                    "\(directory.lastPathComponent): \(detail)"
                )
            }
        }
    }

    private static func completeRestore(
        transaction: inout MigrationRestoreTransactionManifest,
        directory: URL,
        fileManager: FileManager
    ) throws {
        let destinationDirectory = transaction.sourceStoreURL.deletingLastPathComponent()
        let backupDirectory = transaction.backupStoreURL.deletingLastPathComponent()
        try validate(files: transaction.expectedFiles, directory: backupDirectory, fileManager: fileManager)
        try update(&transaction, to: .installing, in: directory)
        for entry in transaction.expectedFiles {
            let destination = destinationDirectory.appendingPathComponent(entry.name)
            if matches(file: entry, at: destination, fileManager: fileManager) { continue }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            let staged = transaction.stagedDirectory.appendingPathComponent(entry.name)
            if !matches(file: entry, at: staged, fileManager: fileManager) {
                if fileManager.fileExists(atPath: staged.path) { try fileManager.removeItem(at: staged) }
                try fileManager.copyItem(at: backupDirectory.appendingPathComponent(entry.name), to: staged)
            }
            try fileManager.moveItem(at: staged, to: destination)
            try update(&transaction, to: .installing, in: directory)
        }
        try update(&transaction, to: .validating, in: directory)
        try validate(files: transaction.expectedFiles, directory: destinationDirectory, fileManager: fileManager)
        try update(&transaction, to: .committed, in: directory)
    }

    private static func validateTransaction(
        _ transaction: MigrationRestoreTransactionManifest,
        directory: URL,
        storeURL: URL
    ) throws {
        let parent = storeURL.deletingLastPathComponent().standardizedFileURL
        let transactionDirectory = directory.standardizedFileURL
        let expectedStaged = transactionDirectory.appendingPathComponent("staged", isDirectory: true)
        let expectedRollback = transactionDirectory.appendingPathComponent("rollback", isDirectory: true)
        guard transactionDirectory.deletingLastPathComponent() == parent,
              directory.lastPathComponent == "\(transactionPrefix)\(transaction.transactionID.uuidString.lowercased())",
              transaction.stagedDirectory.standardizedFileURL == expectedStaged.standardizedFileURL,
              transaction.rollbackDirectory.standardizedFileURL == expectedRollback.standardizedFileURL,
              transaction.sourceStoreURL.standardizedFileURL == storeURL.standardizedFileURL else {
            throw MigrationBackupError.invalidRestoreTransactionManifest(directory.lastPathComponent)
        }
        try validateFileEntries(transaction.expectedFiles, storeURL: storeURL)
        try validateFileEntries(transaction.originalFiles, storeURL: storeURL, allowEmpty: true)
        let backupDirectory = transaction.backupStoreURL.deletingLastPathComponent().standardizedFileURL
        let migrationBackupsDirectory = parent.appendingPathComponent("DensosoMigrationBackups", isDirectory: true).standardizedFileURL
        guard backupDirectory.deletingLastPathComponent() == migrationBackupsDirectory,
              transaction.backupStoreURL.lastPathComponent == storeURL.lastPathComponent else {
            throw MigrationBackupError.invalidRestoreTransactionManifest(directory.lastPathComponent)
        }
    }

    private static func validateFileEntries(
        _ entries: [MigrationBackupManifest.FileEntry],
        storeURL: URL,
        allowEmpty: Bool = false
    ) throws {
        let allowedNames = Set(storeFamilyURLs(for: storeURL).map(\.lastPathComponent))
        let names = entries.map(\.name)
        guard allowEmpty || !entries.isEmpty,
              Set(names).count == names.count,
              names.allSatisfy({ allowedNames.contains($0) }),
              entries.allSatisfy({ entry in
                  entry.sha256.count == 64
                      && entry.sha256.allSatisfy(\.isHexDigit)
                      && entry.name == URL(fileURLWithPath: entry.name).lastPathComponent
              }) else {
            throw MigrationBackupError.invalidRestoreTransactionManifest(storeURL.lastPathComponent)
        }
    }

    private static func validateBackupManifestPaths(_ manifest: MigrationBackupManifest) throws {
        let sourceDirectory = manifest.sourceStoreURL.deletingLastPathComponent().standardizedFileURL
        let backupDirectory = manifest.backupStoreURL.deletingLastPathComponent().standardizedFileURL
        let backupsRoot = sourceDirectory.appendingPathComponent("DensosoMigrationBackups", isDirectory: true)
            .standardizedFileURL
        guard !manifest.sourceStoreURL.lastPathComponent.isEmpty,
              manifest.backupStoreURL.lastPathComponent == manifest.sourceStoreURL.lastPathComponent,
              backupDirectory.deletingLastPathComponent() == backupsRoot else {
            throw MigrationBackupError.invalidRestoreTransactionManifest(manifest.sourceStoreURL.lastPathComponent)
        }
    }

    private static func rollback(
        transaction: inout MigrationRestoreTransactionManifest,
        directory: URL,
        fileManager: FileManager,
        willMove: MoveFaultInjector?
    ) throws {
        try update(&transaction, to: .rollingBack, in: directory)
        let destinationDirectory = transaction.sourceStoreURL.deletingLastPathComponent()
        var failures: [String] = []

        let originalByName = Dictionary(uniqueKeysWithValues: transaction.originalFiles.map { ($0.name, $0) })
        let targetNames = Set(transaction.expectedFiles.map(\.name))
            .union(transaction.originalFiles.map(\.name))
        for name in targetNames.sorted() {
            let destination = destinationDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: destination.path) else { continue }
            if let original = originalByName[name], matches(file: original, at: destination, fileManager: fileManager) {
                continue
            }
            do { try fileManager.removeItem(at: destination) }
            catch { failures.append("remove \(name): \(error.localizedDescription)") }
        }

        for original in transaction.originalFiles {
            let destination = destinationDirectory.appendingPathComponent(original.name)
            if matches(file: original, at: destination, fileManager: fileManager) { continue }
            let rollbackURL = transaction.rollbackDirectory.appendingPathComponent(original.name)
            guard fileManager.fileExists(atPath: rollbackURL.path) else {
                failures.append("missing rollback file \(original.name)")
                continue
            }
            do {
                try willMove?(.rollbackToOriginal, rollbackURL, destination)
                try fileManager.moveItem(at: rollbackURL, to: destination)
            } catch {
                failures.append("restore \(original.name): \(error.localizedDescription)")
            }
        }

        for original in transaction.originalFiles where !matches(
            file: original,
            at: destinationDirectory.appendingPathComponent(original.name),
            fileManager: fileManager
        ) {
            failures.append("verification failed for \(original.name)")
        }
        if !failures.isEmpty {
            throw MigrationBackupError.interruptedRestoreRecoveryRequired(failures.joined(separator: "; "))
        }
    }

    private static func update(
        _ manifest: inout MigrationRestoreTransactionManifest,
        to state: MigrationRestoreTransactionState,
        in directory: URL
    ) throws {
        manifest.state = state
        manifest.updatedAt = Date()
        try write(manifest, in: directory)
    }

    private static func write(_ manifest: MigrationRestoreTransactionManifest, in directory: URL) throws {
        try encode(manifest).write(to: directory.appendingPathComponent("transaction.json"), options: .atomic)
    }

    private static func decodeTransaction(at url: URL) throws -> MigrationRestoreTransactionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MigrationRestoreTransactionManifest.self, from: Data(contentsOf: url))
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private static func storeFamilyURLs(for storeURL: URL) -> [URL] {
        sidecarSuffixes.map { suffix in URL(fileURLWithPath: storeURL.path + suffix) }
    }

    private static func fingerprintExistingStoreFamily(
        at storeURL: URL,
        fileManager: FileManager
    ) throws -> [MigrationBackupManifest.FileEntry] {
        try fingerprintFiles(storeFamilyURLs(for: storeURL).filter { fileManager.fileExists(atPath: $0.path) }, fileManager: fileManager)
    }

    private static func copyAndFingerprint(
        _ sourceURLs: [URL],
        to directory: URL,
        fileManager: FileManager
    ) throws -> [MigrationBackupManifest.FileEntry] {
        var result: [MigrationBackupManifest.FileEntry] = []
        for source in sourceURLs {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            try fileManager.copyItem(at: source, to: destination)
            result.append(try fingerprint(file: destination, fileManager: fileManager))
        }
        return result
    }

    private static func fingerprintFiles(
        _ urls: [URL],
        fileManager: FileManager
    ) throws -> [MigrationBackupManifest.FileEntry] {
        try urls.map { try fingerprint(file: $0, fileManager: fileManager) }.sorted { $0.name < $1.name }
    }

    private static func fingerprint(
        file url: URL,
        fileManager: FileManager
    ) throws -> MigrationBackupManifest.FileEntry {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return MigrationBackupManifest.FileEntry(
            name: url.lastPathComponent,
            byteCount: UInt64(data.count),
            sha256: SHA256.hash(data: data).hexString
        )
    }

    private static func matches(
        files: [MigrationBackupManifest.FileEntry],
        in directory: URL,
        fileManager: FileManager
    ) -> Bool {
        files.allSatisfy { entry in
            matches(file: entry, at: directory.appendingPathComponent(entry.name), fileManager: fileManager)
        }
    }

    private static func matches(
        file entry: MigrationBackupManifest.FileEntry,
        at url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return UInt64(data.count) == entry.byteCount && SHA256.hash(data: data).hexString == entry.sha256
    }

    private static func validate(
        manifest: MigrationBackupManifest,
        directory: URL,
        fileManager: FileManager
    ) throws {
        try validate(files: manifest.files, directory: directory, fileManager: fileManager)
    }

    private static func validate(
        files: [MigrationBackupManifest.FileEntry],
        directory: URL,
        fileManager: FileManager
    ) throws {
        for entry in files {
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
