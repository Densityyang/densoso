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

struct RecipePriorRecord: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let canonicalDishName: String
    let aliases: [String]
    let category: String
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

struct RecipeIngredientPrior: Codable, Equatable, Sendable {
    let sourceName: String
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
    case malformedCatalog
}

struct RecipePriorCatalog: Sendable {
    static let resourceName = "recipe_priors"
    static let maximumResults = 2
    static let maximumIngredientsPerResult = 16
    static let pinnedSourceID = "anduin-howtocook"
    static let pinnedSourceVersion = "5fb3140c20b2a713296696dc6fdd3b83ccc617a6"

    let source: RecipePriorSource
    private let recipes: [RecipePriorRecord]

    init(data: Data) throws {
        guard let file = try? JSONDecoder().decode(RecipePriorCatalogFile.self, from: data),
              file.schemaVersion == 1,
              file.dataRole == "recipe-prior",
              file.source.dataRole == "recipe-prior",
              file.source.sourceID == Self.pinnedSourceID,
              file.source.sourceVersion == Self.pinnedSourceVersion,
              file.source.verificationStatus == "verified",
              file.source.redistributionAllowed,
              !file.recipes.isEmpty,
              Set(file.recipes.map(\.id)).count == file.recipes.count,
              file.recipes.allSatisfy({
                  $0.sourceID == file.source.sourceID
                      && $0.sourceVersion == file.source.sourceVersion
                      && $0.licenseStatus == "verified"
                      && $0.licenseSPDX == file.source.licenseSPDX
                      && !$0.isNutritionAuthority
                      && !$0.id.isEmpty
                      && !$0.sourceRecordID.isEmpty
                      && Self.isSHA256($0.sourceRecordSHA256)
                      && !$0.ingredients.isEmpty
              }) else {
            throw RecipePriorCatalogError.malformedCatalog
        }
        self.source = file.source
        self.recipes = file.recipes
    }

    static func bundled(bundle: Bundle = .main) throws -> RecipePriorCatalog {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw RecipePriorCatalogError.resourceMissing
        }
        return try RecipePriorCatalog(data: data)
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
