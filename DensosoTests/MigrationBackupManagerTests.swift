import CryptoKit
import XCTest
@testable import Densoso

final class MigrationBackupManagerTests: XCTestCase {
    func testCorruptSidecarIsRejectedBeforeAnySourceFileChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso-backup-sidecars-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("default.store")
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        let sourceData = [
            storeURL: Data("store".utf8),
            walURL: Data("wal".utf8),
            shmURL: Data("shm".utf8),
        ]
        for (url, data) in sourceData { try data.write(to: url) }
        let manifest = try XCTUnwrap(
            MigrationBackupManager.createBackupIfPresent(storeURL: storeURL)
        )
        XCTAssertEqual(Set(manifest.files.map(\.name)), Set(sourceData.keys.map(\.lastPathComponent)))

        let backupWAL = manifest.backupStoreURL.deletingLastPathComponent()
            .appendingPathComponent(walURL.lastPathComponent)
        try Data("corrupt-wal".utf8).write(to: backupWAL, options: .atomic)

        XCTAssertThrowsError(try MigrationBackupManager.restore(manifest: manifest))
        for (url, expected) in sourceData {
            XCTAssertEqual(try Data(contentsOf: url), expected)
        }
    }

    func testInterruptedRestoreStartupRecoveryRestoresMovedOriginalStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso-interrupted-restore-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("default.store")
        let originalData = Data("verified-original-store".utf8)
        let replacementData = Data("verified-replacement-store".utf8)
        let transactionID = UUID()
        try originalData.write(to: storeURL)
        let transactionDirectory = directory.appendingPathComponent(
            ".densoso-restore-\(transactionID.uuidString.lowercased())",
            isDirectory: true
        )
        let rollbackDirectory = transactionDirectory.appendingPathComponent("rollback", isDirectory: true)
        let stagedDirectory = transactionDirectory.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        let backupDirectory = directory.appendingPathComponent("DensosoMigrationBackups/manual", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backupStoreURL = backupDirectory.appendingPathComponent(storeURL.lastPathComponent)
        try replacementData.write(to: backupStoreURL)
        try replacementData.write(to: stagedDirectory.appendingPathComponent(storeURL.lastPathComponent))

        let transaction = MigrationRestoreTransactionManifest(
            transactionID: transactionID,
            sourceStoreURL: storeURL,
            backupStoreURL: backupStoreURL,
            stagedDirectory: stagedDirectory,
            rollbackDirectory: rollbackDirectory,
            expectedFiles: [fileEntry(name: storeURL.lastPathComponent, data: replacementData)],
            originalFiles: [fileEntry(name: storeURL.lastPathComponent, data: originalData)],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            state: .originalMoved
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(transaction).write(to: transactionDirectory.appendingPathComponent("transaction.json"))
        try FileManager.default.moveItem(
            at: storeURL,
            to: rollbackDirectory.appendingPathComponent(storeURL.lastPathComponent)
        )

        let bootstrap = PersistenceBootstrap.make(storeURL: storeURL)

        if case .diagnosticOnly = bootstrap.state {
            // Synthetic bytes are not a valid SQLite store, but startup must
            // restore them before container creation and then remain read-only.
        } else {
            XCTFail("An interrupted restore must be recovered before opening the store")
        }
        XCTAssertEqual(try Data(contentsOf: storeURL), originalData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transactionDirectory.path))
    }

    func testInterruptedRestoreWithoutOriginalFinishesFromVerifiedBackupBeforeStoreOpen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso-interrupted-restore-empty-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("default.store")
        let replacementData = Data("verified-replacement-store".utf8)
        let transactionID = UUID()
        let transactionDirectory = directory.appendingPathComponent(
            ".densoso-restore-\(transactionID.uuidString.lowercased())",
            isDirectory: true
        )
        let rollbackDirectory = transactionDirectory.appendingPathComponent("rollback", isDirectory: true)
        let stagedDirectory = transactionDirectory.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        let backupDirectory = directory.appendingPathComponent("DensosoMigrationBackups/manual", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backupStoreURL = backupDirectory.appendingPathComponent(storeURL.lastPathComponent)
        try replacementData.write(to: backupStoreURL)

        let transaction = MigrationRestoreTransactionManifest(
            transactionID: transactionID,
            sourceStoreURL: storeURL,
            backupStoreURL: backupStoreURL,
            stagedDirectory: stagedDirectory,
            rollbackDirectory: rollbackDirectory,
            expectedFiles: [fileEntry(name: storeURL.lastPathComponent, data: replacementData)],
            originalFiles: [],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            state: .installing
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(transaction).write(to: transactionDirectory.appendingPathComponent("transaction.json"))

        let bootstrap = PersistenceBootstrap.make(storeURL: storeURL)
        if case .diagnosticOnly = bootstrap.state {
            // Synthetic bytes remain invalid SQLite, but recovery must install the
            // verified replacement before SwiftData attempts to open it.
        } else {
            XCTFail("The synthetic replacement should keep bootstrap in diagnostics")
        }
        XCTAssertEqual(try Data(contentsOf: storeURL), replacementData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transactionDirectory.path))
    }

    func testRollbackMoveFailurePreservesOriginalCopyAndTransactionDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso-rollback-failure-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("default.store")
        let originalFiles = [
            storeURL: Data("original-store".utf8),
            URL(fileURLWithPath: storeURL.path + "-wal"): Data("original-wal".utf8),
            URL(fileURLWithPath: storeURL.path + "-shm"): Data("original-shm".utf8),
        ]
        for (url, data) in originalFiles { try data.write(to: url) }
        let backup = try XCTUnwrap(MigrationBackupManager.createBackupIfPresent(storeURL: storeURL))
        // Make the live store differ from its verified backup so restore has
        // to replace and then roll back the primary store as well as sidecars.
        var expectedOriginalFiles = originalFiles
        let currentStoreData = Data("current-store".utf8)
        expectedOriginalFiles[storeURL] = currentStoreData
        try currentStoreData.write(to: storeURL)
        var installMoveCount = 0
        var rollbackMoveNames: [String] = []

        XCTAssertThrowsError(try MigrationBackupManager.restore(
            manifest: backup,
            willMove: { kind, _, destinationURL in
                switch kind {
                case .stagedToDestination:
                    installMoveCount += 1
                    if installMoveCount == 2 { throw InjectedMoveFailure.install }
                case .rollbackToOriginal:
                    rollbackMoveNames.append(destinationURL.lastPathComponent)
                    // Inject the failure for a specific member of the SQLite
                    // family; a call-count based fault changes meaning if the
                    // file enumeration order changes.
                    if destinationURL.lastPathComponent == storeURL.lastPathComponent + "-shm" {
                        throw InjectedMoveFailure.rollback
                    }
                case .originalToRollback:
                    break
                }
            }
        )) { error in
            guard let failure = error as? MigrationBackupRestoreFailure else {
                return XCTFail("Both the restore and rollback failures must be reported")
            }
            XCTAssertTrue(failure.originalFailure.contains("install"))
            XCTAssertTrue(failure.rollbackFailure.contains("rollback"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: failure.transactionDirectory.path))
            let rollbackFiles = try? FileManager.default.contentsOfDirectory(
                at: failure.transactionDirectory.appendingPathComponent("rollback", isDirectory: true),
                includingPropertiesForKeys: nil
            )
            XCTAssertTrue(rollbackFiles?.contains { $0.lastPathComponent == storeURL.lastPathComponent + "-shm" } == true)
        }
        XCTAssertEqual(installMoveCount, 2)
        XCTAssertEqual(rollbackMoveNames.count, 3)
        XCTAssertEqual(
            Set(rollbackMoveNames),
            Set([storeURL.lastPathComponent, storeURL.lastPathComponent + "-shm", storeURL.lastPathComponent + "-wal"])
        )

        try MigrationBackupManager.recoverInterruptedRestores(storeURL: storeURL)
        for (url, expected) in expectedOriginalFiles {
            XCTAssertEqual(try Data(contentsOf: url), expected)
        }
    }

    private func fileEntry(name: String, data: Data) -> MigrationBackupManifest.FileEntry {
        MigrationBackupManifest.FileEntry(
            name: name,
            byteCount: UInt64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }
}

private enum InjectedMoveFailure: Error, LocalizedError, CustomStringConvertible {
    case install
    case rollback

    var description: String {
        switch self {
        case .install: "injected install failure"
        case .rollback: "injected rollback failure"
        }
    }

    var errorDescription: String? { description }
}
