import Foundation

/// A typical ingredient amount learned from repeated, explicitly confirmed meals.
public struct PersonalMealDishIngredientPrior: Codable, Equatable, Identifiable, Sendable {
    public let foodID: String?
    public let name: String
    public let lowGrams: Double
    public let likelyGrams: Double
    public let highGrams: Double
    public let preparation: FoodPreparation?
    public let massBasis: FoodMassBasis?
    public let sourceID: String?
    public let sourceRecordID: String?
    public let sourceVersion: String?
    public let licenseStatus: String?

    public var id: String {
        let identity = foodID.map { "id:\($0.lowercased())" } ?? "name:\(FoodResolver.normalize(name))"
        return "\(identity)|prep:\(preparation?.rawValue ?? "unknown")|basis:\(massBasis?.rawValue ?? "unknown")"
    }

    public init?(
        foodID: String?,
        name: String,
        lowGrams: Double,
        likelyGrams: Double,
        highGrams: Double,
        preparation: FoodPreparation? = nil,
        massBasis: FoodMassBasis? = nil,
        sourceID: String? = nil,
        sourceRecordID: String? = nil,
        sourceVersion: String? = nil,
        licenseStatus: String? = nil
    ) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, FoodResolver.normalize(normalizedName).count > 0,
              normalizedName.count <= 120,
              lowGrams.isFinite, likelyGrams.isFinite, highGrams.isFinite,
              lowGrams >= 0.1, lowGrams <= likelyGrams,
              likelyGrams <= highGrams, highGrams <= 5_000 else {
            return nil
        }
        let normalizedSourceID = sourceID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let normalizedRecordID = sourceRecordID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let normalizedSourceVersion = sourceVersion?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let normalizedLicenseStatus = licenseStatus?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let normalizedFoodID = foodID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard normalizedFoodID.map({ $0.count <= 128 }) ?? true,
              normalizedSourceID.map({ $0.count <= 160 }) ?? true,
              normalizedRecordID.map({ $0.count <= 256 }) ?? true,
              normalizedSourceVersion.map({ $0.count <= 128 }) ?? true,
              normalizedLicenseStatus.map({ $0.count <= 64 }) ?? true,
              massBasis == nil || (
            normalizedLicenseStatus == "verified"
                && normalizedSourceID != nil
                && normalizedRecordID != nil
                && normalizedSourceVersion != nil
        ) else {
            return nil
        }
        self.foodID = normalizedFoodID
        self.name = normalizedName
        self.lowGrams = lowGrams
        self.likelyGrams = likelyGrams
        self.highGrams = highGrams
        self.preparation = preparation
        self.massBasis = massBasis
        self.sourceID = normalizedSourceID
        self.sourceRecordID = normalizedRecordID
        self.sourceVersion = normalizedSourceVersion
        self.licenseStatus = normalizedLicenseStatus
    }
}

public struct PersonalMealDishPrior: Codable, Equatable, Identifiable, Sendable {
    public static let currentVersion = "personal-meal-dish-prior-v1"
    public static let minimumObservationsForAutomaticUse = 2

    public let id: UUID
    public let priorKey: String
    public let dishKey: String
    public let dishName: String
    public let cookingMethod: String?
    public let ingredients: [PersonalMealDishIngredientPrior]
    public let observationCount: Int
    public let isUserManaged: Bool
    public let sourceActionKey: String?
    public let createdAt: Date
    public let updatedAt: Date

    public var isAvailableForAutomaticUse: Bool {
        isUserManaged || observationCount >= Self.minimumObservationsForAutomaticUse
    }

    public init?(
        id: UUID,
        priorKey: String,
        dishKey: String,
        dishName: String,
        cookingMethod: String?,
        ingredients: [PersonalMealDishIngredientPrior],
        observationCount: Int,
        isUserManaged: Bool,
        sourceActionKey: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        let normalizedName = dishName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 120,
              !priorKey.isEmpty, priorKey.count <= 4_096,
              !dishKey.isEmpty, dishKey.count <= 240,
              cookingMethod.map({ $0.count <= 40 }) ?? true,
              sourceActionKey.map({ $0.count <= 512 }) ?? true,
              (1...20).contains(ingredients.count),
              (0...1_000_000).contains(observationCount),
              isUserManaged || observationCount > 0,
              Set(ingredients.map(\.id)).count == ingredients.count else {
            return nil
        }
        self.id = id
        self.priorKey = priorKey
        self.dishKey = dishKey
        self.dishName = normalizedName
        self.cookingMethod = cookingMethod?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.ingredients = ingredients
        self.observationCount = observationCount
        self.isUserManaged = isUserManaged
        self.sourceActionKey = sourceActionKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func ingredient(foodID: String?, name: String) -> PersonalMealDishIngredientPrior? {
        if let foodID = foodID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
           let exactIDMatch = ingredients.first(where: { $0.foodID?.caseInsensitiveCompare(foodID) == .orderedSame }) {
            return exactIDMatch
        }
        let normalizedName = FoodResolver.normalize(name)
        guard !normalizedName.isEmpty else { return nil }
        return ingredients.first { FoodResolver.normalize($0.name) == normalizedName }
    }
}

/// Auditable evidence that one ingredient amount came from a personal dish prior.
public struct PersonalMealDishPriorUsage: Codable, Equatable, Sendable {
    public static let evidenceSourceID = "personal-meal-dish-prior-used"

    public let priorKey: String
    public let dishName: String
    public let ingredientName: String
    public let lowGrams: Double
    public let likelyGrams: Double
    public let highGrams: Double
    public let observationCount: Int
    public let isUserManaged: Bool
    public let version: String
    public let preparation: FoodPreparation?
    public let massBasis: FoodMassBasis?
    public let sourceID: String?
    public let sourceRecordID: String?
    public let sourceVersion: String?
    public let licenseStatus: String?

    public init?(prior: PersonalMealDishPrior, ingredient: PersonalMealDishIngredientPrior) {
        guard prior.isAvailableForAutomaticUse,
              prior.ingredients.contains(ingredient),
              !prior.priorKey.isEmpty,
              !Self.version(for: prior).isEmpty else {
            return nil
        }
        self.priorKey = prior.priorKey
        self.dishName = prior.dishName
        self.ingredientName = ingredient.name
        self.lowGrams = ingredient.lowGrams
        self.likelyGrams = ingredient.likelyGrams
        self.highGrams = ingredient.highGrams
        self.observationCount = prior.observationCount
        self.isUserManaged = prior.isUserManaged
        self.version = Self.version(for: prior)
        self.preparation = ingredient.preparation
        self.massBasis = ingredient.massBasis
        self.sourceID = ingredient.sourceID
        self.sourceRecordID = ingredient.sourceRecordID
        self.sourceVersion = ingredient.sourceVersion
        self.licenseStatus = ingredient.licenseStatus
    }

    public var evidenceSnapshot: EvidenceSnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let summary = (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return EvidenceSnapshot(
            grade: .weak,
            sourceID: Self.evidenceSourceID,
            sourceVersion: version,
            summary: summary,
            confidence: 0.4
        )
    }

    public static func usage(from evidence: EvidenceSnapshot) -> PersonalMealDishPriorUsage? {
        guard evidence.grade == .weak,
              evidence.sourceID == evidenceSourceID,
              let data = evidence.summary.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PersonalMealDishPriorUsage.self, from: data),
              decoded.version == evidence.sourceVersion,
              !decoded.priorKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              decoded.priorKey.count <= 1_000,
              !decoded.dishName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              decoded.dishName.count <= 120,
              !decoded.ingredientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              decoded.ingredientName.count <= 120,
              decoded.version.count <= 128,
              decoded.sourceID.map({ $0.count <= 160 }) ?? true,
              decoded.sourceRecordID.map({ $0.count <= 256 }) ?? true,
              decoded.sourceVersion.map({ $0.count <= 128 }) ?? true,
              decoded.licenseStatus.map({ $0.count <= 64 }) ?? true,
              (decoded.isUserManaged || decoded.observationCount >= PersonalMealDishPrior.minimumObservationsForAutomaticUse),
              (0...1_000_000).contains(decoded.observationCount),
              decoded.lowGrams.isFinite, decoded.likelyGrams.isFinite, decoded.highGrams.isFinite,
              decoded.lowGrams >= 0.1,
              decoded.lowGrams <= decoded.likelyGrams,
              decoded.likelyGrams <= decoded.highGrams,
              decoded.highGrams <= 5_000,
              decoded.massBasis == nil || (
                decoded.licenseStatus == "verified"
                    && decoded.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    && decoded.sourceRecordID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    && decoded.sourceVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    && decoded.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines) != "not-provided"
                    && decoded.sourceRecordID?.trimmingCharacters(in: .whitespacesAndNewlines) != "not-provided"
                    && decoded.sourceVersion?.trimmingCharacters(in: .whitespacesAndNewlines) != "not-provided"
              ) else {
            return nil
        }
        return decoded
    }

    private static func version(for prior: PersonalMealDishPrior) -> String {
        "\(PersonalMealDishPrior.currentVersion):\(prior.isUserManaged ? "userManaged" : "confirmed-\(prior.observationCount)")"
    }
}

public enum PersonalMealDishPriorTemplateOptIn {
    public static let evidenceSourceID = "personal-meal-dish-prior-template-opt-in"
    public static let evidenceVersion = "personal-meal-dish-prior-opt-in-v1"

    public static func evidenceSnapshot(dishName: String) -> EvidenceSnapshot? {
        let normalizedName = dishName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 120 else { return nil }
        return EvidenceSnapshot(
            grade: .userReported,
            sourceID: evidenceSourceID,
            sourceVersion: evidenceVersion,
            summary: normalizedName,
            confidence: 1
        )
    }

    public static func isOptedIn(in evidence: [EvidenceSnapshot], dishName: String) -> Bool {
        let normalizedName = FoodResolver.normalize(dishName)
        guard !normalizedName.isEmpty else { return false }
        return evidence.contains {
            $0.grade == .userReported
                && $0.sourceID == evidenceSourceID
                && $0.sourceVersion == evidenceVersion
                && FoodResolver.normalize($0.summary) == normalizedName
        }
    }
}

/// A marker attached only after the user-text parser found grams for this
/// ingredient. Tool-supplied exact grams alone are not user-reported evidence.
public enum PersonalMealDishPriorUserPortionEvidence {
    public static let evidenceSourceID = "personal-meal-dish-prior-user-portion"
    public static let evidenceVersion = "personal-meal-dish-prior-user-portion-v1"

    public static func evidenceSnapshot(grams: Double) -> EvidenceSnapshot? {
        guard grams.isFinite, (0.1...5_000).contains(grams) else { return nil }
        return EvidenceSnapshot(
            grade: .userReported,
            sourceID: evidenceSourceID,
            sourceVersion: evidenceVersion,
            summary: "user-reported-grams=\(grams)",
            confidence: 1
        )
    }

    public static func isExplicit(in evidence: [EvidenceSnapshot]) -> Bool {
        evidence.contains { snapshot in
            guard snapshot.grade == .userReported,
                  snapshot.sourceID == evidenceSourceID,
                  snapshot.sourceVersion == evidenceVersion,
                  snapshot.summary.hasPrefix("user-reported-grams=") else {
                return false
            }
            let value = snapshot.summary.dropFirst("user-reported-grams=".count)
            guard let grams = Double(String(value)), grams.isFinite else { return false }
            return (0.1...5_000).contains(grams)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
