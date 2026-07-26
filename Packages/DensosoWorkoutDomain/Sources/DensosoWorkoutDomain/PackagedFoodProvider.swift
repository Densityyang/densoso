import Foundation

/// Provider-neutral result for a scanned packaged food. Networking adapters
/// live outside this package; callers must still convert this into a draft and
/// obtain explicit confirmation before persistence.
public struct PackagedFoodMatch: Codable, Equatable, Sendable {
    public let barcode: String
    public let displayName: String
    public let servingGrams: Double?
    public let caloriesPer100Grams: Double?
    public let providerID: String
    public let attribution: String?

    public init(
        barcode: String,
        displayName: String,
        servingGrams: Double? = nil,
        caloriesPer100Grams: Double? = nil,
        providerID: String,
        attribution: String? = nil
    ) {
        self.barcode = barcode
        self.displayName = displayName
        self.servingGrams = servingGrams
        self.caloriesPer100Grams = caloriesPer100Grams
        self.providerID = providerID
        self.attribution = attribution
    }
}

public protocol PackagedFoodProvider: Sendable {
    func lookup(barcode: String) async throws -> PackagedFoodMatch?
}

public enum PackagedFoodLookupError: Error, Equatable, Sendable {
    case invalidBarcode
}

public struct PackagedFoodLookupCoordinator: Sendable {
    private let provider: any PackagedFoodProvider

    public init(provider: any PackagedFoodProvider) {
        self.provider = provider
    }

    public func lookup(barcode: String) async throws -> PackagedFoodMatch? {
        let normalized = barcode.filter(\.isNumber)
        guard (8...14).contains(normalized.count) else { throw PackagedFoodLookupError.invalidBarcode }
        return try await provider.lookup(barcode: normalized)
    }
}
