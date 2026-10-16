import DensosoDomain
import Foundation

struct StageDailyCheckInTool: ConfirmationRequiredTool {
    var definition: ToolSchema {
        .strictObject(
            name: "stage_daily_checkin",
            description: "根据用户明确自述准备每日状态待确认草稿，只允许记录用户说出的精力、压力和主观睡眠；不得依据 HealthKit 或其他生理指标推断。此工具不会保存，必须由用户确认。",
            effect: .stagesAction,
            properties: [
                "energy": .string(allowedValues: UserReportedEnergy.allCases.map(\.rawValue)),
                "stress": .string(allowedValues: UserReportedStress.allCases.map(\.rawValue)),
                "subjectiveSleep": .string(allowedValues: SubjectiveSleepQuality.allCases.map(\.rawValue)),
                "occurredAt": .anyOf(
                    [.string(format: "date-time"), .null],
                    description: "自述对应时间的 ISO8601；null 或省略表示现在"
                ),
                "note": .anyOf(
                    [.string(maximumLength: 500), .null],
                    description: "可选的用户自述备注，最多 500 个字符"
                ),
            ],
            required: ["energy", "stress", "subjectiveSleep"]
        )
    }

    func prepare(argumentsJSON: String, context: AgentSession) async throws -> ActionPayload {
        .dailyCheckIn(try draft(argumentsJSON: argumentsJSON, asOf: Date()))
    }

    /// Parses a self-report into a domain fact; it does not persist the fact.
    func draft(argumentsJSON: String, asOf date: Date) throws -> DailyCheckIn {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let energyRaw = json["energy"] as? String,
              let energy = UserReportedEnergy(rawValue: energyRaw),
              let stressRaw = json["stress"] as? String,
              let stress = UserReportedStress(rawValue: stressRaw),
              let sleepRaw = json["subjectiveSleep"] as? String,
              let subjectiveSleep = SubjectiveSleepQuality(rawValue: sleepRaw) else {
            throw DraftError.invalidDailyCheckIn
        }

        let occurredAt: Date
        if let rawDate = json["occurredAt"] as? String {
            guard let parsedDate = Self.parseDate(rawDate) else { throw DraftError.invalidDailyCheckIn }
            occurredAt = parsedDate
        } else if json["occurredAt"] == nil || json["occurredAt"] is NSNull {
            occurredAt = date
        } else {
            throw DraftError.invalidDailyCheckIn
        }

        let note: String?
        if let rawNote = json["note"] as? String {
            let trimmed = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= 500 else { throw DraftError.invalidDailyCheckIn }
            note = trimmed.isEmpty ? nil : trimmed
        } else if json["note"] == nil || json["note"] is NSNull {
            note = nil
        } else {
            throw DraftError.invalidDailyCheckIn
        }

        return DailyCheckIn(
            occurredAt: occurredAt,
            energy: energy,
            stress: stress,
            subjectiveSleep: subjectiveSleep,
            note: note
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
