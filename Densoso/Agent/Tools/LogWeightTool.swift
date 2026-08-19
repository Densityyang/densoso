import DensosoDomain
import Foundation

struct LogWeightTool: ConfirmationRequiredTool {
    var definition: DeepSeekClient.ToolDef {
        .make(
            name: "log_weight",
            description: "准备一条体重草稿，不会保存数据，必须等待用户确认。",
            properties: [
                ("kilograms", "number", "体重千克数，20 到 500", true),
                ("measuredAt", "string", "测量时间 ISO8601，缺省为当前", false),
            ]
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
