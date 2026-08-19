import Foundation

public enum ToolEffect: String, Codable, Sendable {
    case readOnly
    case stagesAction
}

public enum ActionType: String, Codable, Sendable {
    case meal
    case weight
    case workoutPlan
}

public enum CanonicalizationError: Error, Equatable, Sendable {
    case nonFinite(field: String)
    case outOfRange(field: String)
}

public enum ActionPayload: Codable, Equatable, Sendable {
    case meal(MealDraft)
    case weight(WeightDraft)
    case workoutPlan(WorkoutPlanDraft)

    public var actionType: ActionType {
        switch self {
        case .meal: .meal
        case .weight: .weight
        case .workoutPlan: .workoutPlan
        }
    }

    public var title: String {
        switch self {
        case .meal: "确认餐食记录"
        case .weight: "确认体重记录"
        case .workoutPlan: "确认训练计划"
        }
    }

    public var summary: String {
        switch self {
        case .meal(let draft):
            let likely = draft.totalNutrients?.energyKcal.likely ?? 0
            let likelyText = likely.isFinite ? String(format: "%.0f", likely) : "unavailable"
            return "\(draft.dishes.map(\.name).joined(separator: "、"))，约 \(likelyText) kcal"
        case .weight(let draft):
            return String(format: "%.1f kg", draft.kilograms)
        case .workoutPlan(let draft):
            return draft.name
        }
    }

    public var confidence: Double {
        switch self {
        case .meal(let draft):
            return draft.dishes
                .flatMap(\.evidence)
                .compactMap(\.confidence)
                .min() ?? 0
        case .weight, .workoutPlan:
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

    init(_ payload: ActionPayload) throws {
        switch payload {
        case .meal(let meal): self = .meal(try CanonicalMeal(meal))
        case .weight(let weight): self = .weight(try CanonicalWeight(weight))
        case .workoutPlan(let plan): self = .workoutPlan(try CanonicalWorkoutPlan(plan))
        }
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
        goal = CanonicalWorkoutGoal(plan.goal)
        scheduledAtMilliseconds = try plan.scheduledAt.map {
            try CanonicalInteger.dateMilliseconds($0, field: "workoutPlan.scheduledAt")
        }
        strengthSets = try plan.strengthSets.map(CanonicalStrengthSet.init)
    }
}

private enum CanonicalWorkoutGoal: Encodable {
    case open
    case timeMinutes(Int)

    init(_ goal: WorkoutPlanDraft.Goal) {
        switch goal {
        case .open: self = .open
        case .timeMinutes(let minutes): self = .timeMinutes(minutes)
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
