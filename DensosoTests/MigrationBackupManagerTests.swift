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
}
