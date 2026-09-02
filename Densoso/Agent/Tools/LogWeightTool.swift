import DensosoDomain
import Foundation

struct LogWeightTool: ConfirmationRequiredTool {
    var definition: ToolSchema {
        .strictObject(
            name: "log_weight",
            description: "准备一条体重草稿，不会保存数据，必须等待用户确认。",
            effect: .stagesAction,
            properties: [
                "kilograms": .number(minimum: 20, maximum: 500, description: "体重千克数"),
                "measuredAt": .anyOf(
                    [.string(format: "date-time"), .null],
                    description: "测量时间 ISO8601，null 表示当前"
                ),
            ],
            required: ["kilograms", "measuredAt"]
        )
    }

    func prepare(argumentsJSON: String, context: AgentSession) async throws -> ActionPayload {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kilograms = json["kilograms"] as? Double,
              kilograms.isFinite,
              (20...500).contains(kilograms) else {
            throw DraftError.invalidWeight
        }
        let measuredAt: Date
        if let rawDate = json["measuredAt"] as? String {
            guard let parsed = ISO8601DateFormatter().date(from: rawDate) else {
                throw DraftError.invalidWeight
            }
            measuredAt = parsed
        } else {
            measuredAt = Date()
        }
        return .weight(
            WeightDraft(measuredAt: measuredAt, kilograms: kilograms)
        )
    }
}
