import DensosoDomain
import Foundation

struct CreateTrainingPlanTool: ConfirmationRequiredTool {
    private static let restValue = "rest"

    var definition: ToolSchema {
        .strictObject(
            name: "create_training_plan",
            description: "准备未来几天的简单训练计划，包含训练日或休息日；只创建待确认草稿，不会创建已完成 Workout。",
            effect: .stagesAction,
            properties: [
                "name": .string(minimumLength: 1, maximumLength: 100),
                "sessions": .array(
                    items: .object(
                        properties: [
                            "date": .string(format: "date-time"),
                            "activity": .string(
                                allowedValues: WorkoutPlanDraft.Activity.supportedCases.map(\.rawValue)
                                    + [Self.restValue]
                            ),
                            "goalType": .anyOf([
                                .string(allowedValues: ["time", "distance"]),
                                .null,
                            ]),
                            "durationMinutes": .anyOf([.integer(minimum: 1, maximum: 720), .null]),
                            "distanceMeters": .anyOf([.number(minimum: 100, maximum: 100_000), .null]),
                            "location": .anyOf([
                                .string(allowedValues: WorkoutPlanDraft.Location.allCases.map(\.rawValue)),
                                .null,
                            ]),
                            "recommendedIntensity": .anyOf([
                                .string(allowedValues: TrainingSessionDraft.Intensity.allCases.map(\.rawValue)),
                                .null,
                            ]),
                            "reason": .string(minimumLength: 1, maximumLength: 240),
                        ],
                        required: [
                            "date", "activity", "goalType", "durationMinutes", "distanceMeters",
                            "location", "recommendedIntensity", "reason",
                        ],
                        additionalProperties: false
                    ),
                    minimumItems: 1,
                    maximumItems: TrainingPlanDraft.maximumSessionCount
                ),
            ],
            required: ["name", "sessions"]
        )
    }

    func prepare(argumentsJSON: String, context: AgentSession) async throws -> ActionPayload {
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(Arguments.self, from: data) else {
            throw ProviderError.schemaViolation(path: "trainingPlan")
        }
        let sessions = try arguments.sessions.map(makeSession)
        let draft = TrainingPlanDraft(name: arguments.name, sessions: sessions)
        guard draft.validationError == nil else {
            throw ProviderError.schemaViolation(path: "trainingPlan")
        }
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        guard let latestDate = calendar.date(byAdding: .day, value: 31, to: today),
              sessions.allSatisfy({
                  $0.date >= today
                      && $0.date < latestDate
                      && ($0.isRestDay || $0.date > now)
              }) else {
            throw ProviderError.schemaViolation(path: "trainingPlan.sessions.date")
        }
        return .trainingPlan(draft)
    }

    private func makeSession(_ arguments: SessionArguments) throws -> TrainingSessionDraft {
        guard let date = ISO8601DateFormatter().date(from: arguments.date) else {
            throw ProviderError.schemaViolation(path: "trainingPlan.sessions.date")
        }

        let session: TrainingSessionDraft
        if arguments.activity == Self.restValue {
            guard arguments.goalType == nil,
                  arguments.durationMinutes == nil,
                  arguments.distanceMeters == nil,
                  arguments.location == nil,
                  arguments.recommendedIntensity == nil else {
                throw ProviderError.schemaViolation(path: "trainingPlan.sessions.rest")
            }
            session = TrainingSessionDraft(
                date: date,
                activity: nil,
                reason: arguments.reason
            )
        } else {
            guard let activity = WorkoutPlanDraft.Activity(rawValue: arguments.activity),
                  let location = arguments.location.flatMap({ WorkoutPlanDraft.Location(rawValue: $0) }),
                  let intensity = arguments.recommendedIntensity.flatMap({ TrainingSessionDraft.Intensity(rawValue: $0) }),
                  let goalType = arguments.goalType else {
                throw ProviderError.schemaViolation(path: "trainingPlan.sessions")
            }
            let goal: WorkoutPlanDraft.Goal
            switch goalType {
            case "time":
                guard let minutes = arguments.durationMinutes, arguments.distanceMeters == nil else {
                    throw ProviderError.schemaViolation(path: "trainingPlan.sessions.durationMinutes")
                }
                goal = .timeMinutes(minutes)
            case "distance":
                guard let meters = arguments.distanceMeters, arguments.durationMinutes == nil else {
                    throw ProviderError.schemaViolation(path: "trainingPlan.sessions.distanceMeters")
                }
                goal = .distanceMeters(meters)
            default:
                throw ProviderError.schemaViolation(path: "trainingPlan.sessions.goalType")
            }
            session = TrainingSessionDraft(
                date: date,
                activity: activity,
                goal: goal,
                location: location,
                recommendedIntensity: intensity,
                reason: arguments.reason
            )
        }
        guard session.validationError == nil else {
            throw ProviderError.schemaViolation(path: "trainingPlan.sessions")
        }
        return session
    }

    private struct Arguments: Decodable {
        let name: String
        let sessions: [SessionArguments]
    }

    private struct SessionArguments: Decodable {
        let date: String
        let activity: String
        let goalType: String?
        let durationMinutes: Int?
        let distanceMeters: Double?
        let location: String?
        let recommendedIntensity: String?
        let reason: String
    }
}
