import Foundation

public enum FoodPreparation: String, Codable, CaseIterable, Sendable {
    case raw
    case cooked
    case unknown
}

public enum FoodMassBasis: String, Codable, CaseIterable, Sendable {
    case asPurchased
    case edibleRaw
    case cooked
}

public struct FoodNutrientProfile: Codable, Equatable, Sendable {
    public let energyKcalPer100Grams: Double
    public let proteinGramsPer100Grams: Double?
    public let fatGramsPer100Grams: Double?
    public let carbohydrateGramsPer100Grams: Double?

    public init(
        energyKcalPer100Grams: Double,
        proteinGramsPer100Grams: Double? = nil,
        fatGramsPer100Grams: Double? = nil,
        carbohydrateGramsPer100Grams: Double? = nil
    ) {
        self.energyKcalPer100Grams = energyKcalPer100Grams
        self.proteinGramsPer100Grams = proteinGramsPer100Grams
        self.fatGramsPer100Grams = fatGramsPer100Grams
        self.carbohydrateGramsPer100Grams = carbohydrateGramsPer100Grams
    }
}

public struct FoodCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let localFoodID: String?
    public let name: String
    public let aliases: [String]
    public let preparation: FoodPreparation
    public let category: String
    public let edibleFraction: Double
    public let nutrients: FoodNutrientProfile
    public let isCookedComposite: Bool
    public let sourceVersion: String

    public init(
        id: String,
        localFoodID: String? = nil,
        name: String,
        aliases: [String] = [],
        preparation: FoodPreparation,
        category: String,
        edibleFraction: Double = 1,
        nutrients: FoodNutrientProfile,
        isCookedComposite: Bool = false,
        sourceVersion: String
    ) {
        self.id = id
        self.localFoodID = localFoodID
        self.name = name
        self.aliases = aliases
        self.preparation = preparation
        self.category = category
        self.edibleFraction = min(max(edibleFraction, 0), 1)
        self.nutrients = nutrients
        self.isCookedComposite = isCookedComposite
        self.sourceVersion = sourceVersion
    }
}

public struct MealVisionObservation: Codable, Equatable, Sendable {
    public struct Usage: Codable, Equatable, Sendable {
        public let inputTokens: Int
        public let outputTokens: Int
        public let attempt: Int
        public let imageCount: Int
        public let requestID: UUID?
        public let latencyMilliseconds: Int?

        public init(
            inputTokens: Int,
            outputTokens: Int,
            attempt: Int,
            imageCount: Int = 1,
            requestID: UUID? = nil,
            latencyMilliseconds: Int? = nil
        ) {
            self.inputTokens = max(inputTokens, 0)
            self.outputTokens = max(outputTokens, 0)
            self.attempt = max(attempt, 1)
            self.imageCount = max(imageCount, 0)
            self.requestID = requestID
            self.latencyMilliseconds = latencyMilliseconds.map { max($0, 0) }
        }

        private enum CodingKeys: String, CodingKey {
            case inputTokens
            case outputTokens
            case attempt
            case imageCount
            case requestID
            case latencyMilliseconds
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                inputTokens: try values.decode(Int.self, forKey: .inputTokens),
                outputTokens: try values.decode(Int.self, forKey: .outputTokens),
                attempt: try values.decode(Int.self, forKey: .attempt),
                imageCount: try values.decodeIfPresent(Int.self, forKey: .imageCount) ?? 1,
                requestID: try values.decodeIfPresent(UUID.self, forKey: .requestID),
                latencyMilliseconds: try values.decodeIfPresent(Int.self, forKey: .latencyMilliseconds)
            )
        }
    }

    public let labels: [String]
    public let preparationHints: [FoodPreparation]
    public let cookingMethod: String?
    public let containerHint: String?
    public let portionHint: String?
    public let isOccluded: Bool
    public let modelVersion: String
    public let usage: Usage?

    public init(
        labels: [String],
        preparationHints: [FoodPreparation] = [],
        cookingMethod: String? = nil,
        containerHint: String? = nil,
        portionHint: String? = nil,
        isOccluded: Bool,
        modelVersion: String,
        usage: Usage? = nil
    ) {
        self.labels = Array(labels.prefix(8))
        self.preparationHints = Array(preparationHints.prefix(8))
        self.cookingMethod = cookingMethod
        self.containerHint = containerHint
        self.portionHint = portionHint
        self.isOccluded = isOccluded
        self.modelVersion = modelVersion
        self.usage = usage
    }
}

public protocol MealVisionProviding: Sendable {
    func analyze(imageJPEG: Data, locale: Locale) async throws -> MealVisionObservation
    func analyze(
        imageJPEG: Data,
        locale: Locale,
        serializationGate: @escaping @Sendable (@Sendable () throws -> Data) async throws -> Data
    ) async throws -> MealVisionObservation
}
