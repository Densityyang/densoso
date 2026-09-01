import Foundation

struct QueryFoodTool: AgentTool {
    var definition: ToolSchema { .strictObject(
        name: "query_food",
        description: "查询本地食材库，按食材名模糊搜索，返回匹配食材的热量/营养数据。",
        properties: [
            "query": .string(minimumLength: 1, maximumLength: 80, description: "食材搜索词，如猪五花肉"),
            "limit": .integer(minimum: 1, maximum: 10, description: "返回条数上限，默认5"),
        ],
        required: ["query"]
    )}

    func execute(argumentsJSON: String, context: AgentSession, clientRequestID: UUID) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return #"{"error": "参数解析失败"}"#
        }

        let query = json["query"] as? String ?? ""
        let limit = min(max(json["limit"] as? Int ?? 5, 1), 10)

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
