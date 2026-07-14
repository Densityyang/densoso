import Foundation

struct QueryFoodTool: AgentTool {
    var definition: DeepSeekClient.ToolDef { .make(
        name: "query_food",
        description: "查询本地食材库，按食材名模糊搜索，返回匹配食材的热量/营养数据。",
        properties: [
            ("query", "string", "食材搜索词，如'猪五花肉'", true),
            ("limit", "integer", "返回条数上限，默认5", false),
        ]
    )}

    func execute(argumentsJSON: String, context: AgentSession, modelContext: ModelContext) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return #"{"error": "参数解析失败"}"#
        }

        let query = json["query"] as? String ?? ""
        let limit = json["limit"] as? Int ?? 5

        guard let db = context.foodDatabase else {
            return #"{"error": "食材库未初始化", "results": []}"#
        }

        let results = try db.search(query: query, limit: limit)
        let items = results.map { item -> [String: Any] in
            [
                "id": item.id,
                "name": item.name,
                "alias": item.alias ?? "",
                "category": item.category,
                "energyKcal": item.energyKcal,
                "proteinG": item.proteinG,
                "fatG": item.fatG,
                "carbohydrateG": item.carbohydrateG,
                "edible": item.edible,
            ]
        }

        let resp: [String: Any] = ["query": query, "results": items, "count": items.count]
        let respData = try JSONSerialization.data(withJSONObject: resp)
        return String(data: respData, encoding: .utf8) ?? "{}"
    }
}