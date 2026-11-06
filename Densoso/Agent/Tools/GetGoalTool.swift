import DensosoDomain
import Foundation

typealias GoalProfileProvider = @Sendable (Date) async throws -> GoalProfile?

@MainActor
struct GetGoalTool: AgentTool {
    private let calendar: Calendar
    private let goalProvider: GoalProfileProvider

    init(
        calendar: Calendar = .current,
        goalProvider: @escaping GoalProfileProvider = { _ in nil }
    ) {
        self.calendar = calendar
        self.goalProvider = goalProvider
    }

    var definition: ToolSchema {
        .strictObject(
            name: "get_goal",
            description: "只读查看当前已生效的健康目标。未设置目标时明确返回 unavailable；不会推测或补默认值。",
            properties: [:],
            required: []
        )
    }

    func execute(
        argumentsJSON: String,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String {
        try await response(asOf: Date())
    }

    func response(asOf date: Date) async throws -> String {
        let profile = try await goalProvider(date)
        return try response(asOf: date, profile: profile)
    }

    func response(asOf date: Date, profile: GoalProfile?) throws -> String {
        let targetWeight = profile?.targetWeightKilograms.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let dailyDeficit = profile?.dailyDeficitKcal.flatMap { $0 >= 0 ? $0 : nil }
        let dailyProtein = profile?.dailyProteinGrams.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let isAvailable = targetWeight != nil || dailyDeficit != nil || dailyProtein != nil

        let output = GoalToolOutput(
            status: isAvailable ? "available" : "unavailable",
            asOf: localDateString(date),
            goal: isAvailable
                ? GoalToolTarget(
                    effectiveFrom: profile.map { localDateString($0.effectiveFrom) },
                    targetWeightKilograms: targetWeight,
                    dailyDeficitKcal: dailyDeficit,
                    dailyProteinGrams: dailyProtein
                )
                : nil,
            message: isAvailable ? "目标来自本地当前生效设置。" : "尚未设置当前生效的健康目标。"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(output), as: UTF8.self)
    }

    private func localDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct GoalToolOutput: Encodable {
    let status: String
    let asOf: String
    let goal: GoalToolTarget?
    let message: String
}

private struct GoalToolTarget: Encodable {
    let effectiveFrom: String?
    let targetWeightKilograms: Double?
    let dailyDeficitKcal: Int?
    let dailyProteinGrams: Double?
}
