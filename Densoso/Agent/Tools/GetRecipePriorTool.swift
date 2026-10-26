import Foundation

@MainActor
struct GetRecipePriorTool: AgentTool {
    static let maximumDishNameLength = 80

    private let catalogOverride: RecipePriorCatalog?

    init(catalog: RecipePriorCatalog? = nil) {
        self.catalogOverride = catalog
    }

    var definition: ToolSchema {
        .strictObject(
            name: "get_recipe_prior",
            description: "只读查询本地许可清晰的菜谱先验，返回原始菜谱中的候选食材和份量表述；不返回营养值，也不代表本餐实际食用的份量。只在菜名与规范菜名明确匹配时用于分解参考。",
            properties: [
                "dishName": .string(
                    minimumLength: 2,
                    maximumLength: Self.maximumDishNameLength,
                    description: "识别出的规范菜名。仅在菜名明确时查询，不要用整句或整张图片描述。"
                ),
                "limit": .integer(
                    minimum: 1,
                    maximum: RecipePriorCatalog.maximumResults,
                    description: "最多返回几条候选，默认 1。"
                ),
            ],
            required: ["dishName"]
        )
    }

    func execute(
        argumentsJSON: String,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawDishName = arguments["dishName"] as? String else {
            return encode(Output(status: "invalidArguments", results: []))
        }
        let dishName = String(
            rawDishName.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Self.maximumDishNameLength)
        )
        guard dishName.count >= 2 else {
            return encode(Output(status: "invalidQuery", results: []))
        }
        let catalog: RecipePriorCatalog
        do {
            catalog = try catalogOverride ?? RecipePriorCatalog.bundled()
        } catch {
            return encode(Output(status: "unavailable", results: []))
        }
        let rawLimit = arguments["limit"] as? Int ?? 1
        let limit = min(max(rawLimit, 1), RecipePriorCatalog.maximumResults)
        return response(dishName: dishName, limit: limit, catalog: catalog)
    }

    func response(
        dishName: String,
        limit: Int = 1,
        catalog: RecipePriorCatalog
    ) -> String {
        let matches = catalog.matches(dishName, limit: limit)
        guard !matches.isEmpty else {
            return encode(Output(status: "notFound", results: []))
        }
        return encode(Output(
            status: "available",
            results: matches.map { match in
                Result(
                    id: match.record.id,
                    matchType: match.kind.rawValue,
                    canonicalDishName: match.record.canonicalDishName,
                    category: match.record.category,
                    cookingMethod: match.record.cookingMethod,
                    cookingMethodEvidence: match.record.cookingMethodEvidence,
                    ingredients: Array(match.record.ingredients.prefix(RecipePriorCatalog.maximumIngredientsPerResult)),
                    servingsSourceText: match.record.servingsSourceText,
                    cookedYieldEvidence: match.record.cookedYieldEvidence,
                    householdMeasures: match.record.householdMeasures,
                    oilRetention: match.record.oilRetention,
                    sourceID: match.record.sourceID,
                    sourceRecordID: match.record.sourceRecordID,
                    sourceVersion: match.record.sourceVersion,
                    sourceRecordSHA256: match.record.sourceRecordSHA256,
                    licenseStatus: match.record.licenseStatus,
                    licenseSPDX: match.record.licenseSPDX,
                    confidenceGrade: match.record.confidenceGrade,
                    isNutritionAuthority: match.record.isNutritionAuthority
                )
            }
        ))
    }

    private func encode(_ output: Output) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(output),
              let result = String(data: data, encoding: .utf8) else {
            return #"{"status":"unavailable","dataRole":"recipe-prior","nutritionAuthority":false,"results":[]}"#
        }
        return result
    }

    private struct Output: Encodable {
        let status: String
        let dataRole = "recipe-prior"
        let nutritionAuthority = false
        let results: [Result]
    }

    private struct Result: Encodable {
        let id: String
        let matchType: String
        let canonicalDishName: String
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
        let sourceRecordSHA256: String
        let licenseStatus: String
        let licenseSPDX: String
        let confidenceGrade: String
        let isNutritionAuthority: Bool
    }
}
