import DensosoDomain
import Foundation

struct CreateWorkoutPlanTool: ConfirmationRequiredTool {
    var definition: ToolSchema {
        .strictObject(
            name: "create_workout_plan",
            description: "准备训练计划草稿；不会创建已完成 Workout，也不会在确认前调用 WorkoutKit。",
            effect: .stagesAction,
            properties: [
                "name": .string(minimumLength: 1, maximumLength: 120),
                "activity": .string(
                    allowedValues: WorkoutPlanDraft.Activity.supportedCases.map(\.rawValue)
                ),
                "location": .string(
                    allowedValues: WorkoutPlanDraft.Location.allCases.map(\.rawValue)
                ),
                "durationMinutes": .anyOf([.integer(minimum: 1, maximum: 720), .null]),
                "distanceMeters": .anyOf([.number(minimum: 100, maximum: 100_000), .null]),
                "scheduledAt": .string(format: "date-time"),
            ],
            required: [
                "name", "activity", "location", "durationMinutes", "distanceMeters", "scheduledAt",
            ]
        )
    }

    func prepare(argumentsJSON: String, context: AgentSession) async throws -> ActionPayload {
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(Arguments.self, from: data),
              let activity = WorkoutPlanDraft.Activity(rawValue: arguments.activity),
              let location = WorkoutPlanDraft.Location(rawValue: arguments.location),
              !(arguments.durationMinutes != nil && arguments.distanceMeters != nil),
              !arguments.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DraftError.invalidWorkoutPlan
        }
        guard let scheduledAt = Self.parseISO8601Date(arguments.scheduledAt) else {
            throw DraftError.invalidWorkoutPlan
        }
        let goal: WorkoutPlanDraft.Goal
        if let duration = arguments.durationMinutes {
            goal = .timeMinutes(duration)
        } else if let distance = arguments.distanceMeters {
            goal = .distanceMeters(distance)
        } else {
            goal = .open
        }
        let draft = WorkoutPlanDraft(
            name: arguments.name,
            activity: activity,
            location: location,
            goal: goal,
            scheduledAt: scheduledAt
        )
        do {
            try WorkoutPlanCompiler().validate(draft, asOf: context.currentToolTimeAnchor)
        } catch {
            throw DraftError.invalidWorkoutPlan
        }
        return .workoutPlan(draft)
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private struct Arguments: Decodable {
        let name: String
        let activity: String
        let location: String
        let durationMinutes: Int?
        let distanceMeters: Double?
        let scheduledAt: String
    }
}
