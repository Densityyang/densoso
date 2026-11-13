import CryptoKit
import Foundation

struct RecipePriorCatalogFile: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let dataRole: String
    let source: RecipePriorSource
    let recipes: [RecipePriorRecord]
}

struct RecipePriorSource: Codable, Equatable, Sendable {
    let sourceID: String
    let sourceURL: String
    let sourceVersion: String
    let retrievedAt: String
    let licenseSPDX: String
    let dataRole: String
    let redistributionAllowed: Bool
    let verificationStatus: String
    let licenseURL: String
    let notes: String
}

struct RecipePriorVerifiedFoodIDsManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let foodDataSHA256: String
    let seedFoodDataSHA256: String
    let foodSourceManifestSHA256: String
    let foodIDs: [Int64]
}

struct RecipePriorVerifiedFoodRecordsFile: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let records: [RecipePriorVerifiedFoodRecord]
}

struct RecipePriorVerifiedFoodRecord: Codable, Equatable, Sendable {
    let id: Int64
    let sourceID: String
    let sourceRecordID: String
    let sourceVersion: String
    let sourceDataType: String
    let licenseStatus: String
    let licenseSPDX: String
    let redistributionAllowed: Bool
    let dataRole: String
    let edible: Int
}

struct RecipePriorFoodSourceManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sources: [RecipePriorFoodSource]
}

struct RecipePriorFoodSource: Codable, Equatable, Sendable {
    let sourceID: String
    let sourceVersion: String
    let dataType: String?
    let dataRole: String
    let licenseSPDX: String?
    let licenseURL: String?
    let redistributionAllowed: Bool
    let verificationStatus: String
}

struct RecipePriorRecord: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let canonicalDishName: String
    let aliases: [String]
    let category: String
    let cuisineRegion: String?
    let cookingMethod: String
    let cookingMethodEvidence: String
    let ingredients: [RecipeIngredientPrior]
    let servingsSourceText: String?
    let cookedYieldEvidence: RecipePriorQuantityEvidence
    let householdMeasures: [String]
    let oilRetention: RecipePriorQuantityEvidence
    let sourceID: String
    let sourceRecordID: String
    let sourceVersion: String
    let licenseStatus: String
    let licenseSPDX: String
    let confidenceGrade: String
    let sourceRecordSHA256: String
    let isNutritionAuthority: Bool
}

enum RecipeIngredientFoodMatchStatus: String, Codable, Sendable {
    case exact
    case ambiguous
    case unmapped
}

enum RecipeIngredientMassBasis: String, Codable, Sendable {
    case raw
    case cooked
    case unknown
}

enum RecipeIngredientRole: String, Codable, Sendable {
    case ingredient
    case oil
    case seasoning
}

enum RecipeIngredientMassBasisEvidenceKind: String, Codable, Sendable {
    case explicitSourceCue
    case unknown
}

enum RecipeIngredientEdibleFractionEvidenceKind: String, Codable, Sendable {
    case foodCompositionRecord
    case unknown
}

struct RecipeIngredientSourceProvenance: Codable, Equatable, Sendable {
    let sourceID: String
    let sourceRecordID: String
    let sourceVersion: String
    let sourceText: String
}

struct RecipeIngredientMassBasisEvidence: Codable, Equatable, Sendable {
    let kind: RecipeIngredientMassBasisEvidenceKind
    let sourceText: String?
}

struct RecipeIngredientEdibleFractionEvidence: Codable, Equatable, Sendable {
    let kind: RecipeIngredientEdibleFractionEvidenceKind
    let fraction: Double?
    let foodID: Int64?
    let sourceID: String?
    let sourceRecordID: String?
    let sourceVersion: String?
    let licenseStatus: String?
    let licenseSPDX: String?
    let redistributionAllowed: Bool?
    let reason: String?
}

struct RecipeIngredientPrior: Codable, Equatable, Sendable {
    let sourceName: String
    let foodID: Int64?
    let foodMatchStatus: RecipeIngredientFoodMatchStatus
    let edibleFractionEvidence: RecipeIngredientEdibleFractionEvidence
    let massBasis: RecipeIngredientMassBasis
    let massBasisEvidence: RecipeIngredientMassBasisEvidence
    let role: RecipeIngredientRole
    let roleEvidence: String
    let sourceProvenance: RecipeIngredientSourceProvenance
    let isOptional: Bool
    let isAlternative: Bool
    let quantityEvidence: RecipePriorQuantityEvidence
}

struct RecipePriorQuantityEvidence: Codable, Equatable, Sendable {
    let kind: String
    let sourceText: String?
    let value: Double?
    let upperValue: Double?
    let unit: String?
}

struct RecipePriorMatch: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case exact
        case partial
    }

    let record: RecipePriorRecord
    let kind: Kind
}

enum RecipePriorCatalogError: Error, Equatable {
    case resourceMissing
    case malformedCatalog(String)
}

struct RecipePriorCatalog: Sendable {
    static let resourceName = "recipe_priors"
    static let maximumResults = 2
    static let maximumIngredientsPerResult = 16
    static let currentSchemaVersion = 2
    static let pinnedSourceID = "anduin-howtocook"
    static let pinnedSourceVersion = "5fb3140c20b2a713296696dc6fdd3b83ccc617a6"

    let source: RecipePriorSource
    private let recipes: [RecipePriorRecord]

    init(
        data: Data,
        validFoodIDs: Set<Int64>? = nil,
        verifiedFoodSources: [String: RecipePriorFoodSource]? = nil,
        verifiedFoodRecords: [Int64: RecipePriorVerifiedFoodRecord]? = nil
    ) throws {
        let file: RecipePriorCatalogFile
        do {
            file = try JSONDecoder().decode(RecipePriorCatalogFile.self, from: data)
        } catch {
            throw RecipePriorCatalogError.malformedCatalog("recipe-prior JSON decoding failed: \(error)")
        }
        guard file.schemaVersion == Self.currentSchemaVersion,
              file.dataRole == "recipe-prior",
              file.source.dataRole == "recipe-prior",
              file.source.sourceID == Self.pinnedSourceID,
              file.source.sourceVersion == Self.pinnedSourceVersion,
              file.source.verificationStatus == "verified",
              file.source.redistributionAllowed,
              !file.recipes.isEmpty,
              Set(file.recipes.map(\.id)).count == file.recipes.count else {
            throw RecipePriorCatalogError.malformedCatalog("invalid recipe-prior envelope or source metadata")
        }
        for recipe in file.recipes {
            guard recipe.sourceID == file.source.sourceID,
                  recipe.sourceVersion == file.source.sourceVersion,
                  recipe.licenseStatus == "verified",
                  recipe.licenseSPDX == file.source.licenseSPDX,
                  !recipe.isNutritionAuthority,
                  !recipe.id.isEmpty,
                  !recipe.sourceRecordID.isEmpty,
                  Self.isSHA256(recipe.sourceRecordSHA256),
                  !recipe.ingredients.isEmpty else {
                throw RecipePriorCatalogError.malformedCatalog("invalid recipe record metadata")
            }
            for ingredient in recipe.ingredients {
                guard ingredient.sourceProvenance.sourceID == recipe.sourceID,
                      ingredient.sourceProvenance.sourceRecordID == recipe.sourceRecordID,
                      ingredient.sourceProvenance.sourceVersion == recipe.sourceVersion,
                      !ingredient.sourceProvenance.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RecipePriorCatalogError.malformedCatalog("ingredient source provenance does not match its recipe")
                }
                guard Self.hasValidFoodMapping(ingredient) else {
                    throw RecipePriorCatalogError.malformedCatalog("ingredient food mapping is invalid")
                }
                guard Self.hasValidEdibleFractionEvidence(
                    ingredient,
                    verifiedFoodSources: verifiedFoodSources,
                    verifiedFoodRecords: verifiedFoodRecords
                ) else {
                    throw RecipePriorCatalogError.malformedCatalog("ingredient edible-fraction evidence does not match a verified food row")
                }
                guard Self.hasValidMassBasisEvidence(ingredient) else {
                    throw RecipePriorCatalogError.malformedCatalog("ingredient mass-basis evidence is invalid")
                }
                guard !ingredient.roleEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RecipePriorCatalogError.malformedCatalog("ingredient role evidence is empty")
                }
            }
        }
        if let validFoodIDs {
            let mappedFoodIDs = Set(file.recipes.flatMap { $0.ingredients.compactMap(\.foodID) })
            guard mappedFoodIDs.isSubset(of: validFoodIDs) else {
                throw RecipePriorCatalogError.malformedCatalog("recipe food IDs are outside the verified food manifest")
            }
        }
        self.source = file.source
        self.recipes = file.recipes
    }

    static func bundled(bundle: Bundle = .main) throws -> RecipePriorCatalog {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let foodIDsURL = bundle.url(forResource: "verified_food_ids", withExtension: "json"),
              let foodIDsData = try? Data(contentsOf: foodIDsURL),
              let foodRecordsURL = bundle.url(forResource: "verified_food_records", withExtension: "json"),
              let foodRecordsData = try? Data(contentsOf: foodRecordsURL),
              let foodSourcesURL = bundle.url(forResource: "sources", withExtension: "json"),
              let foodSourcesData = try? Data(contentsOf: foodSourcesURL),
              let verifiedIDs = try? JSONDecoder().decode(RecipePriorVerifiedFoodIDsManifest.self, from: foodIDsData),
              let foodRecords = try? JSONDecoder().decode(RecipePriorVerifiedFoodRecordsFile.self, from: foodRecordsData),
              let foodSourceManifest = try? JSONDecoder().decode(RecipePriorFoodSourceManifest.self, from: foodSourcesData),
              verifiedIDs.schemaVersion == 2,
              Self.isSHA256(verifiedIDs.foodDataSHA256),
              Self.isSHA256(verifiedIDs.seedFoodDataSHA256),
              Self.isSHA256(verifiedIDs.foodSourceManifestSHA256),
              !verifiedIDs.foodIDs.isEmpty,
              verifiedIDs.foodIDs.allSatisfy({ $0 > 0 }),
              verifiedIDs.foodIDs == verifiedIDs.foodIDs.sorted(),
              Set(verifiedIDs.foodIDs).count == verifiedIDs.foodIDs.count,
              foodRecords.schemaVersion == 1,
              !foodRecords.records.isEmpty,
              foodSourceManifest.schemaVersion == 1 else {
            throw RecipePriorCatalogError.resourceMissing
        }
        guard let actualFoodDataSHA256 = canonicalSHA256(foodRecordsData),
              let actualFoodSourceManifestSHA256 = canonicalSHA256(foodSourcesData),
              actualFoodDataSHA256 == verifiedIDs.foodDataSHA256,
              actualFoodSourceManifestSHA256 == verifiedIDs.foodSourceManifestSHA256 else {
            throw RecipePriorCatalogError.malformedCatalog("food-data manifests do not match their pinned checksums")
        }
        var verifiedSources: [String: RecipePriorFoodSource] = [:]
        var seenSourceIDs = Set<String>()
        for source in foodSourceManifest.sources {
            guard !source.sourceID.isEmpty, seenSourceIDs.insert(source.sourceID).inserted else {
                throw RecipePriorCatalogError.malformedCatalog("food-source manifest contains an empty or duplicate source ID")
            }
            guard source.verificationStatus == "verified",
                  source.dataRole == "food-composition",
                  source.redistributionAllowed,
                  source.dataType?.isEmpty == false,
                  source.licenseSPDX?.isEmpty == false,
                  source.licenseURL?.isEmpty == false,
                  !source.sourceVersion.isEmpty else {
                continue
            }
            verifiedSources[source.sourceID] = source
        }
        guard !verifiedSources.isEmpty else {
            throw RecipePriorCatalogError.malformedCatalog("food-source manifest has no verified redistributable food-composition sources")
        }
        var foodRecordByID: [Int64: RecipePriorVerifiedFoodRecord] = [:]
        var seenFoodSourceRecordIDs = Set<String>()
        for record in foodRecords.records {
            let sourceRecordKey = "\(record.sourceID)\u{0}\(record.sourceRecordID)"
            guard record.id > 0,
                  record.edible >= 0,
                  record.edible <= 100,
                  record.licenseStatus == "verified",
                  record.redistributionAllowed,
                  record.dataRole == "food-composition",
                  !record.sourceRecordID.isEmpty,
                  !record.sourceVersion.isEmpty,
                  !record.sourceDataType.isEmpty,
                  let source = verifiedSources[record.sourceID],
                  source.dataRole == record.dataRole,
                  source.dataType == record.sourceDataType,
                  source.sourceVersion == record.sourceVersion,
                  source.licenseSPDX == record.licenseSPDX,
                  foodRecordByID[record.id] == nil,
                  seenFoodSourceRecordIDs.insert(sourceRecordKey).inserted else {
                throw RecipePriorCatalogError.malformedCatalog("verified food record does not match its source manifest")
            }
            foodRecordByID[record.id] = record
        }
        guard verifiedIDs.foodIDs == foodRecords.records.map(\.id),
              Set(foodRecordByID.keys) == Set(verifiedIDs.foodIDs) else {
            throw RecipePriorCatalogError.malformedCatalog("verified food IDs do not match the food-record manifest")
        }
        return try RecipePriorCatalog(
            data: data,
            validFoodIDs: Set(verifiedIDs.foodIDs),
            verifiedFoodSources: verifiedSources,
            verifiedFoodRecords: foodRecordByID
        )
    }

    func matches(_ query: String, limit: Int = Self.maximumResults) -> [RecipePriorMatch] {
        let key = Self.normalized(query)
        guard key.count >= 2 else { return [] }
        let boundedLimit = min(max(limit, 1), Self.maximumResults)
        let matches = recipes.compactMap { recipe -> (RecipePriorMatch, Int)? in
            let canonical = Self.normalized(recipe.canonicalDishName)
            let aliases = recipe.aliases.map(Self.normalized)
            if key == canonical || aliases.contains(key) {
                return (RecipePriorMatch(record: recipe, kind: .exact), 3)
            }
            if canonical.contains(key) || key.contains(canonical)
                || aliases.contains(where: { $0.contains(key) || key.contains($0) }) {
                return (RecipePriorMatch(record: recipe, kind: .partial), 1)
            }
            return nil
        }
        return matches
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.record.canonicalDishName < rhs.0.record.canonicalDishName
            }
            .prefix(boundedLimit)
            .map { $0.0 }
    }

    func record(id: String) -> RecipePriorRecord? {
        recipes.first { $0.id == id }
    }

    /// A model-supplied identifier is usable only when the local pinned row
    /// exists and the dish name is an exact canonical-name or alias match.
    func exactRecord(dishName: String, id: String) -> RecipePriorRecord? {
        guard let record = record(id: id) else { return nil }
        let key = Self.normalized(dishName)
        guard key.count >= 2 else { return nil }
        let canonical = Self.normalized(record.canonicalDishName)
        let aliases = record.aliases.map(Self.normalized)
        guard key == canonical || aliases.contains(key) else { return nil }
        return record
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }
    }

    private static func canonicalSHA256(_ data: Data) -> String? {
        guard let sourceText = String(data: data, encoding: .utf8) else { return nil }
        let canonicalText = sourceText.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return SHA256.hash(data: Data(canonicalText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func hasValidFoodMapping(_ ingredient: RecipeIngredientPrior) -> Bool {
        switch ingredient.foodMatchStatus {
        case .exact:
            return ingredient.foodID.map { $0 > 0 } == true
        case .ambiguous, .unmapped:
            return ingredient.foodID == nil
        }
    }

    private static func hasValidEdibleFractionEvidence(
        _ ingredient: RecipeIngredientPrior,
        verifiedFoodSources: [String: RecipePriorFoodSource]?,
        verifiedFoodRecords: [Int64: RecipePriorVerifiedFoodRecord]?
    ) -> Bool {
        let evidence = ingredient.edibleFractionEvidence
        switch evidence.kind {
        case .foodCompositionRecord:
            guard let fraction = evidence.fraction,
                  fraction.isFinite,
                  (0...1).contains(fraction),
                  evidence.foodID == ingredient.foodID,
                  evidence.sourceID?.isEmpty == false,
                  evidence.sourceRecordID?.isEmpty == false,
                  evidence.sourceVersion?.isEmpty == false,
                  evidence.licenseStatus == "verified",
                  evidence.licenseSPDX?.isEmpty == false,
                  evidence.redistributionAllowed == true,
                  evidence.reason == nil else {
                return false
            }
            guard ingredient.foodMatchStatus == .exact else { return false }
            guard let foodID = ingredient.foodID,
                  let verifiedFoodRecords,
                  let record = verifiedFoodRecords[foodID],
                  record.sourceID == evidence.sourceID,
                  record.sourceRecordID == evidence.sourceRecordID,
                  record.sourceVersion == evidence.sourceVersion,
                  record.licenseStatus == evidence.licenseStatus,
                  record.licenseSPDX == evidence.licenseSPDX,
                  record.redistributionAllowed == evidence.redistributionAllowed,
                  record.dataRole == "food-composition",
                  !record.sourceDataType.isEmpty,
                  abs(fraction - Double(record.edible) / 100.0) <= 1e-12,
                  let verifiedFoodSources else {
                return false
            }
            guard let sourceID = evidence.sourceID,
                  let source = verifiedFoodSources[sourceID] else {
                return false
            }
            return source.verificationStatus == "verified"
                && source.dataRole == "food-composition"
                && source.redistributionAllowed
                && source.dataType == record.sourceDataType
                && source.sourceVersion == evidence.sourceVersion
                && source.licenseSPDX == evidence.licenseSPDX
        case .unknown:
            return ingredient.foodMatchStatus != .exact
                && ingredient.foodID == nil
                && evidence.fraction == nil
                && evidence.foodID == nil
                && evidence.sourceID == nil
                && evidence.sourceRecordID == nil
                && evidence.sourceVersion == nil
                && evidence.licenseStatus == nil
                && evidence.licenseSPDX == nil
                && evidence.redistributionAllowed == nil
                && evidence.reason?.isEmpty == false
        }
    }

    private static func hasValidMassBasisEvidence(_ ingredient: RecipeIngredientPrior) -> Bool {
        switch (ingredient.massBasis, ingredient.massBasisEvidence.kind) {
        case (.raw, .explicitSourceCue), (.cooked, .explicitSourceCue):
            return ingredient.massBasisEvidence.sourceText?.isEmpty == false
        case (.unknown, .unknown):
            return ingredient.massBasisEvidence.sourceText == nil
        default:
            return false
        }
    }

    private static func normalized(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "zh_CN")
        )
        return folded.unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }
}
