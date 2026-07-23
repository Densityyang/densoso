import Foundation

public enum PackagedFoodProviderError: Error, Equatable, Sendable {
    case rateLimited
    case offlineWithoutCache
}

/// Actor-isolated cache and request gate for a concrete provider. Cached
/// results remain available when offline; misses never fabricate a product.
public actor CachedPackagedFoodProvider: PackagedFoodProvider {
    private let upstream: any PackagedFoodProvider
    private let minimumInterval: TimeInterval
    private var cached: [String: PackagedFoodMatch] = [:]
    private var lastRequestAt: Date?
    private var isOnline: Bool

    public init(upstream: any PackagedFoodProvider, minimumInterval: TimeInterval = 1, isOnline: Bool = true) {
        self.upstream = upstream
        self.minimumInterval = max(0, minimumInterval)
        self.isOnline = isOnline
    }

    public func setOnline(_ isOnline: Bool) { self.isOnline = isOnline }

    public func lookup(barcode: String) async throws -> PackagedFoodMatch? {
        if let cached = cached[barcode] { return cached }
        guard isOnline else { throw PackagedFoodProviderError.offlineWithoutCache }
        if let lastRequestAt, Date().timeIntervalSince(lastRequestAt) < minimumInterval {
            throw PackagedFoodProviderError.rateLimited
        }
        lastRequestAt = Date()
        let result = try await upstream.lookup(barcode: barcode)
        if let result { cached[barcode] = result }
        return result
    }
}
