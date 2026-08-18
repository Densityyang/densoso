import Foundation

public enum PackagedFoodProviderError: Error, Equatable, Sendable {
    case rateLimited
    case offlineWithoutCache
}

/// Actor-isolated cache and request gate for a concrete provider. Cached
/// results remain available when offline; misses never fabricate a product.
public actor CachedPackagedFoodProvider: PackagedFoodProvider {
    private struct CacheEntry: Sendable {
        let match: PackagedFoodMatch
        let cachedAt: Date
    }

    private let upstream: any PackagedFoodProvider
    private let minimumInterval: TimeInterval
    private let cacheLifetime: TimeInterval
    private var cached: [String: CacheEntry] = [:]
    private var lastRequestAt: Date?
    private var isOnline: Bool

    public init(
        upstream: any PackagedFoodProvider,
        minimumInterval: TimeInterval = 1,
        cacheLifetime: TimeInterval = 24 * 60 * 60,
        isOnline: Bool = true
    ) {
        self.upstream = upstream
        self.minimumInterval = max(0, minimumInterval)
        self.cacheLifetime = max(0, cacheLifetime)
        self.isOnline = isOnline
    }

    public func setOnline(_ isOnline: Bool) { self.isOnline = isOnline }

    public func lookup(barcode: String) async throws -> PackagedFoodMatch? {
        let entry = cached[barcode]
        if let entry, Date().timeIntervalSince(entry.cachedAt) <= cacheLifetime { return entry.match }
        guard isOnline else {
            // A stale, explicitly labelled provider value is safer than an
            // invented result and enables the offline/manual confirmation path.
            if let entry { return entry.match }
            throw PackagedFoodProviderError.offlineWithoutCache
        }
        if let lastRequestAt, Date().timeIntervalSince(lastRequestAt) < minimumInterval {
            throw PackagedFoodProviderError.rateLimited
        }
        lastRequestAt = Date()
        let result = try await upstream.lookup(barcode: barcode)
        if let result { cached[barcode] = CacheEntry(match: result, cachedAt: Date()) }
        return result
    }
}
