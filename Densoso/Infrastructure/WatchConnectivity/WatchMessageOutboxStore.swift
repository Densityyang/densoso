import DensosoDomain
import Foundation

enum WatchMessageOutboxStoreError: Error {
    case applicationSupportUnavailable
    case persistedPayloadTooLarge
    case pendingMessageLimitExceeded
}

@MainActor
final class WatchMessageOutboxStore {
    static let legacyStorageKey = "watch.message.outbox.v1"
    static let storageFileName = "watch-message-outbox-v1.json"
    static let maximumPersistedBytes = 5_242_880

    private let defaults: UserDefaults
    private let fileManager: FileManager
    let storageURL: URL

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) throws {
        self.defaults = defaults
        self.fileManager = fileManager
        guard let directoryURL = directoryURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Densoso", isDirectory: true)
                .appendingPathComponent("WatchConnectivity", isDirectory: true) else {
            throw WatchMessageOutboxStoreError.applicationSupportUnavailable
        }
        storageURL = directoryURL.appendingPathComponent(Self.storageFileName, isDirectory: false)
    }

    func load() throws -> WatchMessageOutbox {
        if fileManager.fileExists(atPath: storageURL.path) {
            return try decodePersistedData(Data(contentsOf: storageURL))
        }

        guard let legacyData = defaults.data(forKey: Self.legacyStorageKey) else {
            return WatchMessageOutbox()
        }
        let outbox = try decodePersistedData(legacyData)
        try save(outbox)
        defaults.removeObject(forKey: Self.legacyStorageKey)
        return outbox
    }

    func save(_ outbox: WatchMessageOutbox) throws {
        guard outbox.pending.count <= WatchMessageOutbox.maximumPendingMessageCount else {
            throw WatchMessageOutboxStoreError.pendingMessageLimitExceeded
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(outbox)
        guard data.count <= Self.maximumPersistedBytes else {
            throw WatchMessageOutboxStoreError.persistedPayloadTooLarge
        }
        try fileManager.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: storageURL, options: .atomic)
    }

    private func decodePersistedData(_ data: Data) throws -> WatchMessageOutbox {
        guard data.count <= Self.maximumPersistedBytes else {
            throw WatchMessageOutboxStoreError.persistedPayloadTooLarge
        }
        return try JSONDecoder().decode(WatchMessageOutbox.self, from: data)
    }
}
