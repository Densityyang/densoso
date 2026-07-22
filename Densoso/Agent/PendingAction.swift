import CryptoKit
import Foundation
import SwiftData

enum ToolEffect: String {
    case readOnly
    case requiresConfirmation
}

struct MealDishDraft {
    let dishName: String
    let cookingMethod: String
    let ingredients: [IngredientEstimate]
    let caloriesKcal: Int
    let proteinG: Double
    let fatG: Double
    let carbsG: Double
    let confidence: Double
}

struct MealDraft {
    let date: Date
    let mealType: String
    let dishes: [MealDishDraft]

    var totalCaloriesKcal: Int { dishes.map(\.caloriesKcal).reduce(0, +) }
    var totalProteinG: Double { dishes.map(\.proteinG).reduce(0, +) }
    var totalFatG: Double { dishes.map(\.fatG).reduce(0, +) }
    var totalCarbsG: Double { dishes.map(\.carbsG).reduce(0, +) }
    var confidence: String { dishes.allSatisfy { $0.confidence >= 0.8 } ? "high" : "medium" }
    var summary: String { dishes.map { "\($0.dishName): \($0.caloriesKcal) kcal" }.joined(separator: "; ") }
}

struct WorkoutDraft {
    let date: Date
    let type: String
    let durationMinutes: Int
    let intensity: String
    let estimatedCalories: Int
    let notes: String?

    var summary: String { "\(type) \(durationMinutes) 分钟，约 \(estimatedCalories) kcal" }
}

enum PendingActionPayload {
    case meal(MealDraft)
    case workout(WorkoutDraft)

    var title: String { switch self { case .meal: "确认餐食记录"; case .workout: "确认运动记录" } }
    var summary: String { switch self { case .meal(let draft): draft.summary; case .workout(let draft): draft.summary } }
    var confidence: Double { switch self { case .meal(let draft): draft.dishes.map(\.confidence).min() ?? 0; case .workout: 1 } }
}

struct PendingActionPreparation {
    let payload: PendingActionPayload
    let idempotencyKey: String
}

struct PendingAction: Identifiable {
    enum State: Equatable { case pending, confirming }

    let id: UUID
    let idempotencyKey: String
    let createdAt: Date
    let expiresAt: Date
    let payload: PendingActionPayload
    var state: State
}

enum PendingActionError: LocalizedError {
    case notFound
    case expired
    case alreadyCommitted
    case alreadyConfirming

    var errorDescription: String? {
        switch self {
        case .notFound: "待确认操作不存在"
        case .expired: "待确认操作已过期，请重新记录"
        case .alreadyCommitted: "该操作已经确认过，未重复写入"
        case .alreadyConfirming: "该操作正在确认中"
        }
    }
}

@MainActor
final class PendingActionStore {
    private let now: () -> Date
    private let ttl: TimeInterval
    private(set) var actions: [PendingAction] = []
    private var committedKeys: Set<String> = []

    init(ttl: TimeInterval = 15 * 60, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    func enqueue(_ preparation: PendingActionPreparation) throws -> PendingAction {
        purgeExpired()
        if committedKeys.contains(preparation.idempotencyKey) { throw PendingActionError.alreadyCommitted }
        if let existing = actions.first(where: { $0.idempotencyKey == preparation.idempotencyKey }) { return existing }

        let createdAt = now()
        let action = PendingAction(id: UUID(), idempotencyKey: preparation.idempotencyKey, createdAt: createdAt,
                                   expiresAt: createdAt.addingTimeInterval(ttl), payload: preparation.payload, state: .pending)
        actions.append(action)
        return action
    }

    func beginConfirmation(id: UUID) throws -> PendingAction {
        purgeExpired()
        guard let index = actions.firstIndex(where: { $0.id == id }) else { throw PendingActionError.notFound }
        guard actions[index].expiresAt > now() else { throw PendingActionError.expired }
        guard actions[index].state == .pending else { throw PendingActionError.alreadyConfirming }
        actions[index].state = .confirming
        return actions[index]
    }

    func finishConfirmation(id: UUID) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        committedKeys.insert(actions[index].idempotencyKey)
        actions.remove(at: index)
    }

    func restorePending(id: UUID) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[index].state = .pending
    }

    func reject(id: UUID) { actions.removeAll { $0.id == id } }

    func purgeExpired() { actions.removeAll { $0.expiresAt <= now() } }

    static func idempotencyKey(for argumentsJSON: String, toolName: String) -> String {
        let digest = SHA256.hash(data: Data("\(toolName):\(argumentsJSON)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
enum PendingActionCommitter {
    static func commit(_ payload: PendingActionPayload, modelContext: ModelContext) throws -> String {
        switch payload {
        case .meal(let draft):
            let meal = MealRecord(date: draft.date, mealType: draft.mealType, totalCaloriesKcal: draft.totalCaloriesKcal,
                                  proteinG: draft.totalProteinG, fatG: draft.totalFatG, carbsG: draft.totalCarbsG,
                                  confidence: "userConfirmed")
            meal.dishes = draft.dishes.map {
                let dish = DishEntry(dishName: $0.dishName, cookingMethod: $0.cookingMethod, estimatedCaloriesKcal: $0.caloriesKcal,
                                     estimatedProteinG: $0.proteinG, estimatedFatG: $0.fatG, estimatedCarbsG: $0.carbsG,
                                     confidenceScore: $0.confidence, userCorrectionFactor: 1)
                dish.setIngredients($0.ingredients)
                return dish
            }
            modelContext.insert(meal)
            try modelContext.save()
            try recomputeMetrics(on: draft.date, modelContext: modelContext)
            return "已确认并保存餐食：\(draft.summary)"
        case .workout(let draft):
            modelContext.insert(WorkoutRecord(date: draft.date, type: draft.type, durationMinutes: draft.durationMinutes,
                                               estimatedCaloriesBurned: draft.estimatedCalories, intensity: draft.intensity, notes: draft.notes))
            try modelContext.save()
            try recomputeMetrics(on: draft.date, modelContext: modelContext)
            return "已确认并保存运动：\(draft.summary)"
        }
    }

    private static func recomputeMetrics(on date: Date, modelContext: ModelContext) throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let profile = try modelContext.fetch(FetchDescriptor<UserProfile>()).first ?? UserProfile()
        let mealPredicate = #Predicate<MealRecord> { $0.date >= day && $0.date < nextDay }
        let workoutPredicate = #Predicate<WorkoutRecord> { $0.date >= day && $0.date < nextDay }
        let meals = try modelContext.fetch(FetchDescriptor<MealRecord>(predicate: mealPredicate))
        let workouts = try modelContext.fetch(FetchDescriptor<WorkoutRecord>(predicate: workoutPredicate))
        let metrics = CaloricEngine.computeDailyMetrics(date: day, meals: meals, workouts: workouts, userProfile: profile)
        let metricPredicate = #Predicate<DailyMetrics> { $0.date == day }
        try modelContext.fetch(FetchDescriptor<DailyMetrics>(predicate: metricPredicate)).forEach { modelContext.delete($0) }
        modelContext.insert(metrics)
        try modelContext.save()
    }
}
