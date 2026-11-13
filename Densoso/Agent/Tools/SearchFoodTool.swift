import DensosoDomain
import Foundation

@MainActor
struct SearchFoodTool: AgentTool {
    static let maximumQueryLength = 80
    static let maximumCandidates = 3

    var definition: ToolSchema {
        .strictObject(
            name: "search_food",
            description: "只读搜索本地食物候选，按名称别名、生熟、质量基准、类别和已确认历史排序。结果最多三项，始终需要用户确认。",
            properties: [
                "query": .string(
                    minimumLength: 1,
                    maximumLength: Self.maximumQueryLength,
                    description: "本地食物搜索词，不要填食物 ID 或条码作为名称。"
                ),
                "preparation": .string(
                    allowedValues: FoodPreparation.allCases.map(\.rawValue),
                    description: "请求食物状态；不确定时省略。"
                ),
                "massBasis": .string(
                    allowedValues: FoodMassBasis.allCases.map(\.rawValue),
                    description: "重量基准；不确定时省略。"
                ),
                "categoryHint": .string(
                    minimumLength: 1,
                    maximumLength: 80,
                    description: "可选类别线索。"
                ),
            ],
            required: ["query"]
        )
    }

    func execute(
        argumentsJSON: String,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawQuery = arguments["query"] as? String else {
            return try response(
                query: "",
                resolution: FoodResolutionV2(candidates: [], autoPreselectID: nil),
                status: "invalidArguments"
            )
        }
        let query = String(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumQueryLength))
        guard !query.isEmpty else {
            return try response(
                query: query,
                resolution: FoodResolutionV2(candidates: [], autoPreselectID: nil),
                status: "invalidQuery"
            )
        }
        guard let database = context.foodDatabase else {
            return try response(
                query: query,
                resolution: FoodResolutionV2(candidates: [], autoPreselectID: nil),
                status: "unavailable"
            )
        }

        let preparation = (arguments["preparation"] as? String)
            .flatMap { FoodPreparation(rawValue: $0) } ?? .unknown
        let massBasis = (arguments["massBasis"] as? String)
            .flatMap { FoodMassBasis(rawValue: $0) }
        let categoryHint = (arguments["categoryHint"] as? String)
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let history = await context.confirmedFoodIDs(matching: query)
        let resolution = resolve(
            query: query,
            preparation: preparation,
            massBasis: massBasis,
            categoryHint: categoryHint,
            confirmedFoodHistoryIDs: history,
            catalog: try database.catalogEntries()
        )
        return try response(query: query, resolution: resolution)
    }

    func resolve(
        query: String,
        preparation: FoodPreparation = .unknown,
        massBasis: FoodMassBasis? = nil,
        categoryHint: String? = nil,
        confirmedFoodHistoryIDs: Set<String> = [],
        catalog: [FoodCatalogEntry]
    ) -> FoodResolutionV2 {
        FoodResolverV2(catalog: catalog).resolve(
            FoodResolutionV2Query(
                label: String(query.prefix(Self.maximumQueryLength)),
                preparation: preparation,
                massBasis: massBasis,
                categoryHint: categoryHint.map { String($0.prefix(80)) },
                sourceQuality: 1,
                confirmedHistoryFoodIDs: confirmedFoodHistoryIDs
            )
        )
    }

    func response(
        query: String,
        resolution: FoodResolutionV2,
        status: String? = nil
    ) throws -> String {
        let output = SearchFoodToolOutput(
            query: String(query.prefix(Self.maximumQueryLength)),
            status: status ?? (resolution.candidates.isEmpty ? "notFound" : "available"),
            count: resolution.candidates.count,
            requiresConfirmation: resolution.requiresConfirmation,
            autoPreselectCandidate: resolution.autoPreselect.map {
                String($0.entry.name.prefix(100))
            },
            candidates: resolution.candidates.prefix(Self.maximumCandidates).map { candidate in
                SearchFoodCandidateOutput(
                    name: String(candidate.entry.name.prefix(100)),
                    aliases: candidate.entry.aliases.prefix(3).map { String($0.prefix(80)) },
                    preparation: candidate.entry.preparation.rawValue,
                    category: String(candidate.entry.category.prefix(80)),
                    edibleFraction: candidate.entry.edibleFraction,
                    energyKcalPer100Grams: Self.finiteNonnegative(
                        candidate.entry.nutrients.energyKcalPer100Grams
                    ),
                    proteinGramsPer100Grams: Self.finiteNonnegative(candidate.entry.nutrients.proteinGramsPer100Grams),
                    fatGramsPer100Grams: Self.finiteNonnegative(candidate.entry.nutrients.fatGramsPer100Grams),
                    carbohydrateGramsPer100Grams: Self.finiteNonnegative(candidate.entry.nutrients.carbohydrateGramsPer100Grams),
                    score: SearchFoodScoreOutput(candidate.score),
                    evidence: candidate.evidence.prefix(4).map {
                        SearchFoodEvidenceOutput(
                            grade: $0.grade.rawValue,
                            summary: String($0.summary.prefix(120)),
                            confidence: Self.finiteUnit($0.confidence)
                        )
                    },
                    isAutoPreselected: candidate.id == resolution.autoPreselectID
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(output), as: UTF8.self)
    }

    private static func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func finiteUnit(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }
}

private struct SearchFoodToolOutput: Encodable {
    let query: String
    let status: String
    let count: Int
    let requiresConfirmation: Bool
    let autoPreselectCandidate: String?
    let candidates: [SearchFoodCandidateOutput]
}

private struct SearchFoodCandidateOutput: Encodable {
    let name: String
    let aliases: [String]
    let preparation: String
    let category: String
    let edibleFraction: Double
    let energyKcalPer100Grams: Double?
    let proteinGramsPer100Grams: Double?
    let fatGramsPer100Grams: Double?
    let carbohydrateGramsPer100Grams: Double?
    let score: SearchFoodScoreOutput
    let evidence: [SearchFoodEvidenceOutput]
    let isAutoPreselected: Bool
}

private struct SearchFoodScoreOutput: Encodable {
    let lexical: Double
    let alias: Double
    let preparation: Double
    let massBasis: Double
    let category: Double
    let history: Double
    let evidence: Double
    let finalScore: Double

    init(_ score: FoodResolutionScore) {
        lexical = score.lexical
        alias = score.alias
        preparation = score.preparation
        massBasis = score.massBasis
        category = score.category
        history = score.history
        evidence = score.evidence
        finalScore = score.finalScore
    }
}

private struct SearchFoodEvidenceOutput: Encodable {
    let grade: String
    let summary: String
    let confidence: Double?
}
