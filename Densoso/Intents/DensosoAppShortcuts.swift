import AppIntents
import Foundation

/// A small inbox is sufficient for handoff from a system App Intent to the app.
/// The data is always a draft; no HealthKit or SwiftData write occurs here.
enum AppIntentInbox {
    private static let workoutPlanKey = "appIntent.workoutPlanDraft"
    private static let mealTextKey = "appIntent.mealTextDraft"

    static func store(workoutPlan: WorkoutPlanDraft) {
        UserDefaults.standard.set(try? JSONEncoder().encode(workoutPlan), forKey: workoutPlanKey)
    }

    static func consumeWorkoutPlan() -> WorkoutPlanDraft? {
        defer { UserDefaults.standard.removeObject(forKey: workoutPlanKey) }
        guard let data = UserDefaults.standard.data(forKey: workoutPlanKey) else { return nil }
        return try? JSONDecoder().decode(WorkoutPlanDraft.self, from: data)
    }

    static func store(mealText: String) {
        UserDefaults.standard.set(mealText, forKey: mealTextKey)
    }

    static func consumeMealText() -> String? {
        defer { UserDefaults.standard.removeObject(forKey: mealTextKey) }
        return UserDefaults.standard.string(forKey: mealTextKey)
    }
}

struct StartWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "开始训练"
    static let description = IntentDescription("在 densoso 中创建一份可编辑的训练草稿。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppIntentInbox.store(workoutPlan: .squatFiveByFive)
        return .result(dialog: "已打开 densoso。请确认训练草稿后再同步到 Apple Watch。")
    }
}

struct CreateWorkoutPlanIntent: AppIntent {
    static let title: LocalizedStringResource = "创建训练计划"
    static let description = IntentDescription("创建一份可编辑、未同步的训练计划草稿。")
    static let openAppWhenRun = true

    @Parameter(title: "训练名称", default: "训练计划")
    var name: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppIntentInbox.store(workoutPlan: WorkoutPlanDraft(name: name, activity: .strength))
        return .result(dialog: "已创建训练计划草稿。请在 densoso 中确认后再同步。")
    }
}

struct LogMealByVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "语音记餐"
    static let description = IntentDescription("把语音转写作为未保存的餐食草稿交给 densoso。")
    static let openAppWhenRun = true

    @Parameter(title: "餐食内容")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppIntentInbox.store(mealText: text)
        return .result(dialog: "已创建餐食草稿。请在 densoso 中检查并确认。")
    }
}

struct DensosoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWorkoutIntent(),
            phrases: ["在\(.applicationName)开始训练"],
            shortTitle: "开始训练",
            systemImageName: "figure.run"
        )
        AppShortcut(
            intent: CreateWorkoutPlanIntent(),
            phrases: ["在\(.applicationName)创建训练计划"],
            shortTitle: "训练计划",
            systemImageName: "calendar.badge.plus"
        )
        AppShortcut(
            intent: LogMealByVoiceIntent(),
            phrases: ["在\(.applicationName)记录餐食"],
            shortTitle: "语音记餐",
            systemImageName: "mic"
        )
    }
}
