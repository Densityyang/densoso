import Foundation

public enum ToolEffect: String, Codable, Sendable {
    case readOnly
    case stagesAction
}

public enum ActionType: String, Codable, Sendable {
    case meal
    case weight
    case workoutPlan
    case trainingPlan
    case dailyCheckIn
    case userPreference
}

public enum CanonicalizationError: Error, Equatable, Sendable {
    case nonFinite(field: String)
    case outOfRange(field: String)
}

public enum ActionPayload: Codable, Equatable, Sendable {
    case meal(MealDraft)
    case weight(WeightDraft)
    case workoutPlan(WorkoutPlanDraft)
    case trainingPlan(TrainingPlanDraft)
    case dailyCheckIn(DailyCheckIn)
    case userPreference(UserPreference)

    public var actionType: ActionType {
        switch self {
        case .meal: .meal
        case .weight: .weight
        case .workoutPlan: .workoutPlan
        case .trainingPlan: .trainingPlan
        case .dailyCheckIn: .dailyCheckIn
        case .userPreference: .userPreference
        }
    }

    public var title: String {
        switch self {
        case .meal: "确认餐食记录"
        case .weight: "确认体重记录"
        case .workoutPlan: "确认训练计划"
        case .trainingPlan: "确认多日训练计划"
        case .dailyCheckIn: "确认每日状态"
        case .userPreference: "确认用户偏好"
        }
    }

    public var summary: String {
        switch self {
        case .meal(let draft):
            let dishes = draft.dishes.map(\.name).joined(separator: "、")
            guard let presentation = draft.caloriePresentation else {
                return "\(dishes)，热量暂不可用"
            }
            return "\(dishes)，约 \(presentation.likelyKcal) kcal，可信度\(presentation.confidence.displayName)"
        case .weight(let draft):
            return String(format: "%.1f kg", draft.kilograms)
        case .workoutPlan(let draft):
            return draft.name
        case .trainingPlan(let draft):
            let workoutCount = draft.sessions.filter { !$0.isRestDay }.count
            let restCount = draft.sessions.count - workoutCount
            return "\(draft.name)：\(workoutCount) 次训练、\(restCount) 天休息"
        case .dailyCheckIn(let checkIn):
            let energy = switch checkIn.energy {
            case .low: "精力偏低"
            case .typical: "精力一般"
            case .high: "精力较好"
            }
            let stress = switch checkIn.stress {
            case .low: "压力较低"
            case .typical: "压力一般"
            case .elevated: "压力偏高"
            }
            let sleep = switch checkIn.subjectiveSleep {
            case .poor: "主观睡眠较差"
            case .fair: "主观睡眠一般"
            case .good: "主观睡眠较好"
            }
            let summary = [energy, stress, sleep].joined(separator: "，")
            let note = checkIn.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let note, !note.isEmpty else { return summary }
            return "\(summary)；备注：\(note.prefix(120))"
        case .userPreference(let preference):
            let category = switch preference.category {
            case .food: "饮食偏好"
            case .exercise: "运动偏好"
            case .communication: "沟通偏好"
            }
            return "\(category)：\(preference.statement.prefix(120))"
        }
    }

    public var confidence: Double {
        switch self {
        case .meal(let draft):
            switch draft.caloriePresentation?.confidence {
            case .some(.high): return 0.9
            case .some(.medium): return 0.65
            case .some(.low), .none: return 0.35
            }
        case .weight, .workoutPlan, .trainingPlan, .dailyCheckIn, .userPreference:
            return 1
        }
    }

    public func canonicalData(schemaVersion: Int = 1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            try CanonicalActionEnvelope(schemaVersion: schemaVersion, payload: self)
        )
    }
}

public struct PendingAction: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let idempotencyKey: String
    public let clientRequestID: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let payload: ActionPayload
    public let state: PendingActionState
    public let failureCode: String?

    public init(
        id: UUID,
        idempotencyKey: String,
        clientRequestID: UUID,
        createdAt: Date,
        expiresAt: Date,
        payload: ActionPayload,
        state: PendingActionState,
        failureCode: String? = nil
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.clientRequestID = clientRequestID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.payload = payload
        self.state = state
        self.failureCode = failureCode
    }
}

public enum PendingActionState: String, Codable, CaseIterable, Sendable {
    case pending
    case committing
    case committed
    case rejected
    case expired
    case failed

    public var isTerminal: Bool {
        switch self {
        case .committed, .rejected, .expired, .failed: true
        case .pending, .committing: false
        }
    }
}

public enum HealthSyncState: String, Codable, CaseIterable, Sendable {
    case pending
    case sending
    case succeeded
    case retryable
    case terminal
    case notApplicable
}

public struct CommitReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let actionID: UUID
    public let idempotencyKey: String
    public let actionType: ActionType
    public let localRecordID: UUID
    public let outboxIDs: [UUID]
    public let committedAt: Date
    public let healthSyncState: HealthSyncState

    public init(
        id: UUID,
        actionID: UUID,
        idempotencyKey: String,
        actionType: ActionType,
        localRecordID: UUID,
        outboxIDs: [UUID],
        committedAt: Date,
        healthSyncState: HealthSyncState
    ) {
        self.id = id
        self.actionID = actionID
        self.idempotencyKey = idempotencyKey
        self.actionType = actionType
        self.localRecordID = localRecordID
        self.outboxIDs = outboxIDs
        self.committedAt = committedAt
        self.healthSyncState = healthSyncState
    }
}

private struct CanonicalActionEnvelope: Encodable {
    let schemaVersion: Int
    let actionType: String
    let payload: CanonicalPayload

    init(schemaVersion: Int, payload: ActionPayload) throws {
        self.schemaVersion = schemaVersion
        self.actionType = payload.actionType.rawValue
        self.payload = try CanonicalPayload(payload)
    }
}

private enum CanonicalPayload: Encodable {
    case meal(CanonicalMeal)
    case weight(CanonicalWeight)
    case workoutPlan(CanonicalWorkoutPlan)
    case trainingPlan(CanonicalTrainingPlan)
    case dailyCheckIn(CanonicalDailyCheckIn)
    case userPreference(CanonicalUserPreference)

    init(_ payload: ActionPayload) throws {
        switch payload {
        case .meal(let meal): self = .meal(try CanonicalMeal(meal))
        case .weight(let weight): self = .weight(try CanonicalWeight(weight))
        case .workoutPlan(let plan): self = .workoutPlan(try CanonicalWorkoutPlan(plan))
        case .trainingPlan(let plan): self = .trainingPlan(try CanonicalTrainingPlan(plan))
        case .dailyCheckIn(let checkIn): self = .dailyCheckIn(try CanonicalDailyCheckIn(checkIn))
        case .userPreference(let preference): self = .userPreference(try CanonicalUserPreference(preference))
        }
    }
}

private struct CanonicalUserPreference: Encodable {
    let category: String
    let statement: String
    let source: String

    init(_ preference: UserPreference) throws {
        let statement = preference.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty, statement.count <= 500 else {
            throw CanonicalizationError.outOfRange(field: "userPreference.statement")
        }
        category = preference.category.rawValue
        self.statement = statement
        source = preference.source.rawValue
    }
}

private struct CanonicalDailyCheckIn: Encodable {
    let occurredAtMilliseconds: Int64
    let energy: String
    let stress: String
    let subjectiveSleep: String
    let note: String?

    init(_ checkIn: DailyCheckIn) throws {
        occurredAtMilliseconds = try CanonicalInteger.dateMilliseconds(
            checkIn.occurredAt,
            field: "dailyCheckIn.occurredAt"
        )
        energy = checkIn.energy.rawValue
        stress = checkIn.stress.rawValue
        subjectiveSleep = checkIn.subjectiveSleep.rawValue
        let trimmedNote = checkIn.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmedNote?.count ?? 0) <= 500 else {
            throw CanonicalizationError.outOfRange(field: "dailyCheckIn.note")
        }
        note = trimmedNote.flatMap { $0.isEmpty ? nil : $0 }
    }
}

private struct CanonicalMeal: Encodable {
    let occurredAtMilliseconds: Int64
    let mealType: String
    let dishes: [CanonicalDish]
    let note: String?

    init(_ meal: MealDraft) throws {
        occurredAtMilliseconds = try CanonicalInteger.dateMilliseconds(meal.occurredAt, field: "meal.occurredAt")
        mealType = meal.mealType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        dishes = try meal.dishes.map(CanonicalDish.init)
        note = meal.note?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CanonicalDish: Encodable {
    let name: String
    let cookingMethod: String?
    let portionGrams: CanonicalRange?
    let nutrients: CanonicalNutrients
    let ingredients: [CanonicalIngredient]
    let evidence: [CanonicalEvidence]
    let algorithmVersion: String

    init(_ dish: MealDishDraft) throws {
        name = dish.name.trimmingCharacters(in: .whitespacesAndNewlines)
        cookingMethod = dish.cookingMethod?.lowercased()
        portionGrams = try dish.portionGrams.map { try CanonicalRange($0, field: "dish.portionGrams") }
        nutrients = try CanonicalNutrients(dish.nutrients, field: "dish.nutrients")
        ingredients = try dish.ingredients.map(CanonicalIngredient.init)
        evidence = try dish.evidence.map(CanonicalEvidence.init).sorted { $0.sortKey < $1.sortKey }
        algorithmVersion = dish.algorithmVersion
    }
}

private struct CanonicalIngredient: Encodable {
    let foodID: String?
    let name: String
    let amountGrams: CanonicalRange
    let nutrients: CanonicalNutrients
    let evidence: [CanonicalEvidence]

    init(_ ingredient: MealIngredientDraft) throws {
        foodID = ingredient.foodID
        name = ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines)
        amountGrams = try CanonicalRange(ingredient.amountGrams, field: "ingredient.amountGrams")
        nutrients = try CanonicalNutrients(ingredient.nutrients, field: "ingredient.nutrients")
        evidence = try ingredient.evidence.map(CanonicalEvidence.init).sorted { $0.sortKey < $1.sortKey }
    }
}

private struct CanonicalEvidence: Encodable {
    let grade: String
    let sourceID: String?
    let sourceVersion: String?
    let summary: String
    let confidenceMillionths: Int64?

    var sortKey: String {
        [
            grade,
            sourceID ?? "",
            sourceVersion ?? "",
            summary,
            confidenceMillionths.map { String($0) } ?? "",
        ].joined(separator: "|")
    }

    init(_ evidence: EvidenceSnapshot) throws {
        grade = evidence.grade.rawValue
        sourceID = evidence.sourceID
        sourceVersion = evidence.sourceVersion
        summary = evidence.summary
        confidenceMillionths = try evidence.confidence.map {
            guard (0...1).contains($0) else {
                throw CanonicalizationError.outOfRange(field: "evidence.confidence")
            }
            return try CanonicalInteger.scaled(
                $0,
                by: 1_000_000,
                field: "evidence.confidence"
            )
        }
    }
}

private struct CanonicalNutrients: Encodable {
    let energyKcal: CanonicalRange
    let proteinGrams: CanonicalRange?
    let fatGrams: CanonicalRange?
    let carbohydrateGrams: CanonicalRange?

    init(_ nutrients: NutrientEstimate, field: String) throws {
        energyKcal = try CanonicalRange(nutrients.energyKcal, field: "\(field).energyKcal")
        proteinGrams = try nutrients.proteinGrams.map { try CanonicalRange($0, field: "\(field).proteinGrams") }
        fatGrams = try nutrients.fatGrams.map { try CanonicalRange($0, field: "\(field).fatGrams") }
        carbohydrateGrams = try nutrients.carbohydrateGrams.map {
            try CanonicalRange($0, field: "\(field).carbohydrateGrams")
        }
    }
}

private struct CanonicalRange: Encodable {
    let lowMilliunits: Int64
    let likelyMilliunits: Int64
    let highMilliunits: Int64

    init(_ range: EstimateRange, field: String) throws {
        lowMilliunits = try CanonicalInteger.scaled(range.low, by: 1_000, field: "\(field).low")
        likelyMilliunits = try CanonicalInteger.scaled(range.likely, by: 1_000, field: "\(field).likely")
        highMilliunits = try CanonicalInteger.scaled(range.high, by: 1_000, field: "\(field).high")
    }
}

private struct CanonicalWeight: Encodable {
    let measuredAtMilliseconds: Int64
    let milligrams: Int64
    let source: String

    init(_ weight: WeightDraft) throws {
        measuredAtMilliseconds = try CanonicalInteger.dateMilliseconds(weight.measuredAt, field: "weight.measuredAt")
        guard weight.kilograms >= 0 else {
            throw CanonicalizationError.outOfRange(field: "weight.kilograms")
        }
        milligrams = try CanonicalInteger.scaled(weight.kilograms, by: 1_000_000, field: "weight.kilograms")
        source = weight.source.lowercased()
    }
}

private struct CanonicalWorkoutPlan: Encodable {
    let name: String
    let activity: String
    let location: String
    let goal: CanonicalWorkoutGoal
    let scheduledAtMilliseconds: Int64?
    let strengthSets: [CanonicalStrengthSet]

    init(_ plan: WorkoutPlanDraft) throws {
        name = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
        activity = plan.activity.rawValue
        location = plan.location.rawValue
        goal = try CanonicalWorkoutGoal(plan.goal)
        scheduledAtMilliseconds = try plan.scheduledAt.map {
            try CanonicalInteger.dateMilliseconds($0, field: "workoutPlan.scheduledAt")
        }
        strengthSets = try plan.strengthSets.map(CanonicalStrengthSet.init)
    }
}

private struct CanonicalTrainingPlan: Encodable {
    let name: String
    let sessions: [CanonicalTrainingSession]

    init(_ plan: TrainingPlanDraft) throws {
        guard plan.validationError == nil else {
            throw CanonicalizationError.outOfRange(field: "trainingPlan")
        }
        name = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let keyedSessions = try plan.sessions.map { session -> (CanonicalTrainingSession, Data) in
            let canonical = try CanonicalTrainingSession(session)
            return (canonical, try encoder.encode(canonical))
        }
        sessions = keyedSessions.sorted { lhs, rhs in
            if lhs.0.dateMilliseconds != rhs.0.dateMilliseconds {
                return lhs.0.dateMilliseconds < rhs.0.dateMilliseconds
            }
            return lhs.1.lexicographicallyPrecedes(rhs.1)
        }.map(\.0)
    }
}

private struct CanonicalTrainingSession: Encodable {
    let dateMilliseconds: Int64
    let activity: String?
    let goal: CanonicalWorkoutGoal?
    let location: String?
    let recommendedIntensity: String?
    let reason: String

    init(_ session: TrainingSessionDraft) throws {
        dateMilliseconds = try CanonicalInteger.dateMilliseconds(session.date, field: "trainingPlan.session.date")
        activity = session.activity?.rawValue
        goal = try session.goal.map(CanonicalWorkoutGoal.init)
        location = session.location?.rawValue
        recommendedIntensity = session.recommendedIntensity?.rawValue
        reason = session.reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum CanonicalWorkoutGoal: Encodable {
    case open
    case timeMinutes(Int)
    case distanceMeters(Int64)

    init(_ goal: WorkoutPlanDraft.Goal) throws {
        switch goal {
        case .open: self = .open
        case .timeMinutes(let minutes): self = .timeMinutes(minutes)
        case .distanceMeters(let meters):
            guard (100...100_000).contains(meters) else {
                throw CanonicalizationError.outOfRange(field: "workoutPlan.goal.distanceMeters")
            }
            self = .distanceMeters(try CanonicalInteger.scaled(
                meters,
                by: 1_000,
                field: "workoutPlan.goal.distanceMeters"
            ))
        }
    }
}

private struct CanonicalStrengthSet: Encodable {
    let exerciseID: String?
    let exerciseName: String
    let setCount: Int
    let repetitions: Int
    let loadGrams: Int64?

    init(_ set: WorkoutPlanDraft.StrengthSet) throws {
        exerciseID = set.exerciseID
        exerciseName = set.exerciseName
        setCount = set.setCount
        repetitions = set.repetitions
        loadGrams = try set.loadKilograms.map {
            guard $0 >= 0 else {
                throw CanonicalizationError.outOfRange(field: "workoutPlan.strengthSet.loadKilograms")
            }
            return try CanonicalInteger.scaled(
                $0,
                by: 1_000,
                field: "workoutPlan.strengthSet.loadKilograms"
            )
        }
    }
}

private enum CanonicalInteger {
    static func dateMilliseconds(_ date: Date, field: String) throws -> Int64 {
        try scaled(date.timeIntervalSince1970, by: 1_000, field: field)
    }

    static func scaled(_ value: Double, by scale: Double, field: String) throws -> Int64 {
        guard value.isFinite, scale.isFinite else {
            throw CanonicalizationError.nonFinite(field: field)
        }
        let rounded = (value * scale).rounded()
        guard rounded.isFinite,
              rounded > Double(Int64.min),
              rounded < Double(Int64.max) else {
            throw CanonicalizationError.outOfRange(field: field)
        }
        return Int64(rounded)
    }
}
