import CoreData
import Foundation
import SwiftData

enum PersistentStoreVersionInspectorError: Error, Equatable {
    case missingModelVersionHashes
}

enum PersistentStoreVersionInspector {
    static func version(at storeURL: URL) -> String? {
        guard let sourceHashes = try? modelVersionHashesFromIsolatedCopy(of: storeURL) else {
            return nil
        }
        if let v2Hashes = referenceHashes(for: DensosoSchemaV2.self),
           sourceHashes == v2Hashes {
            return "2.0.0"
        }
        if let v1Hashes = referenceHashes(for: DensosoSchemaV1.self),
           sourceHashes == v1Hashes {
            return "1.0.0"
        }
        return nil
    }

    static func modelVersionHashes(at storeURL: URL) throws -> [String: Data] {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite,
            at: storeURL,
            options: [NSReadOnlyPersistentStoreOption: true]
        )
        return try modelVersionHashes(from: metadata)
    }

    static func modelVersionHashes(from metadata: [String: Any]) throws -> [String: Data] {
        if let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: Data] {
            guard !hashes.isEmpty else {
                throw PersistentStoreVersionInspectorError.missingModelVersionHashes
            }
            return hashes
        }
        if let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: NSData] {
            guard !hashes.isEmpty else {
                throw PersistentStoreVersionInspectorError.missingModelVersionHashes
            }
            return hashes.mapValues { Data(referencing: $0) }
        }
        throw PersistentStoreVersionInspectorError.missingModelVersionHashes
    }

    private static func modelVersionHashesFromIsolatedCopy(
        of storeURL: URL
    ) throws -> [String: Data] {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "densoso-store-metadata-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sourceURLs = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        guard sourceURLs.contains(where: { $0.path == storeURL.path }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        for sourceURL in sourceURLs {
            try FileManager.default.copyItem(
                at: sourceURL,
                to: directoryURL.appendingPathComponent(sourceURL.lastPathComponent)
            )
        }

        return try modelVersionHashes(
            at: directoryURL.appendingPathComponent(storeURL.lastPathComponent)
        )
    }

    private static func referenceHashes<Version: VersionedSchema>(
        for version: Version.Type
    ) -> [String: Data]? {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "densoso-schema-reference-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        let storeURL = directoryURL.appendingPathComponent("reference.store")
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let schema = Schema(versionedSchema: version)
            let configuration = ModelConfiguration(
                "DensosoSchemaReference",
                schema: schema,
                url: storeURL
            )
            try createReferenceStore(schema: schema, configuration: configuration)
            return try modelVersionHashes(at: storeURL)
        } catch {
            return nil
        }
    }

    private static func createReferenceStore(
        schema: Schema,
        configuration: ModelConfiguration
    ) throws {
        try autoreleasepool {
            let container = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
            _ = container
        }
    }
}
