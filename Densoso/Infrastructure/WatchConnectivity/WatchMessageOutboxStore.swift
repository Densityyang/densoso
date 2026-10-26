import DensosoDomain
import Foundation

@MainActor
final class WatchMessageOutboxStore {
    static let storageKey = "watch.message.outbox.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> WatchMessageOutbox {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return WatchMessageOutbox()
        }
        return try JSONDecoder().decode(WatchMessageOutbox.self, from: data)
    }

    func save(_ outbox: WatchMessageOutbox) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(outbox), forKey: Self.storageKey)
    }
}
