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
                    allowedValues: WorkoutPlanDraft.Activity.allCases.map(\.rawValue)
                ),
                "location": .string(
                    allowedValues: WorkoutPlanDraft.Location.allCases.map(\.rawValue)
                ),
                "durationMinutes": .anyOf([.integer(minimum: 1, maximum: 720), .null]),
                "scheduledAt": .anyOf([.string(format: "date-time"), .null]),
                "strengthSets": .array(
                    items: .object(
                        properties: [
                            "exerciseID": .anyOf([.string(maximumLength: 120), .null]),
                            "exerciseName": .string(minimumLength: 1, maximumLength: 120),
                            "setCount": .integer(minimum: 1, maximum: 100),
                            "repetitions": .integer(minimum: 1, maximum: 1_000),
                            "loadKilograms": .anyOf([.number(minimum: 0, maximum: 1_000), .null]),
                        ],
                        required: [
                            "exerciseID", "exerciseName", "setCount", "repetitions", "loadKilograms",
                        ],
                        additionalProperties: false
                    ),
                    minimumItems: 0,
                    maximumItems: 30
                ),
            ],
            required: [
                "name", "activity", "location", "durationMinutes", "scheduledAt", "strengthSets",
            ]
        )
    }

    func prepare(argumentsJSON: String, context: AgentSession) async throws -> ActionPayload {
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(Arguments.self, from: data),
              let activity = WorkoutPlanDraft.Activity(rawValue: arguments.activity),
              let location = WorkoutPlanDraft.Location(rawValue: arguments.location),
              !arguments.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DraftError.invalidWorkoutPlan
        }
        let scheduledAt: Date?
        if let raw = arguments.scheduledAt {
            guard let parsed = ISO8601DateFormatter().date(from: raw) else {
                throw DraftError.invalidWorkoutPlan
            }
            scheduledAt = parsed
        } else {
            scheduledAt = nil
        }
        let goal: WorkoutPlanDraft.Goal = arguments.durationMinutes.map {
            .timeMinutes($0)
        } ?? .open
        let strengthSets = arguments.strengthSets.map {
            WorkoutPlanDraft.StrengthSet(
                exerciseID: $0.exerciseID,
                exerciseName: $0.exerciseName,
                setCount: $0.setCount,
                repetitions: $0.repetitions,
                loadKilograms: $0.loadKilograms
            )
        }
        return .workoutPlan(
            WorkoutPlanDraft(
                name: arguments.name,
                activity: activity,
                location: location,
                goal: goal,
                scheduledAt: scheduledAt,
                strengthSets: strengthSets
            )
        )
    }

    private struct Arguments: Decodable {
        let name: String
        let activity: String
        let location: String
        let durationMinutes: Int?
        let scheduledAt: String?
        let strengthSets: [StrengthSet]

        struct StrengthSet: Decodable {
            let exerciseID: String?
            let exerciseName: String
            let setCount: Int
            let repetitions: Int
            let loadKilograms: Double?
        }
    }
}
