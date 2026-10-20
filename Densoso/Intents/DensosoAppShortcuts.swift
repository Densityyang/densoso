import AppIntents
import Foundation
import DensosoDomain

enum DensosoAppIntentDestination: String, CaseIterable, Equatable, Sendable {
    case todayStatus
    case todayGuidance
    case openToday
    case startRecording
}

/// A small inbox is sufficient for handoff from a system App Intent to the app.
/// The data is always a draft; no HealthKit or SwiftData write occurs here.
enum AppIntentInbox {
    private static let workoutPlanKey = "appIntent.workoutPlanDraft"
    private static let queuedWorkoutPlansKey = "appIntent.queuedWorkoutPlanDrafts"
    private static let mealTextKey = "appIntent.mealTextDraft"
    private static let destinationKey = "appIntent.destination"
    private static let maximumQueuedWorkoutPlans = 16

    static func store(workoutPlan: WorkoutPlanDraft, defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(workoutPlan), forKey: workoutPlanKey)
    }

    static func consumeWorkoutPlan(defaults: UserDefaults = .standard) -> WorkoutPlanDraft? {
        defer { defaults.removeObject(forKey: workoutPlanKey) }
        guard let data = defaults.data(forKey: workoutPlanKey) else { return nil }
        return try? JSONDecoder().decode(WorkoutPlanDraft.self, from: data)
    }

    static func store(mealText: String, defaults: UserDefaults = .standard) {
        defaults.set(mealText, forKey: mealTextKey)
    }

    static func consumeMealText(defaults: UserDefaults = .standard) -> String? {
        defer { defaults.removeObject(forKey: mealTextKey) }
        return defaults.string(forKey: mealTextKey)
    }

    static func clearWorkoutPlan(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: workoutPlanKey)
    }

    static func enqueueWorkoutPlan(_ draft: WorkoutPlanDraft, defaults: UserDefaults = .standard) -> Bool {
        let queued = queuedWorkoutPlans(defaults: defaults)
        guard queued.count < maximumQueuedWorkoutPlans,
              let data = try? JSONEncoder().encode(queued + [draft]) else { return false }
        defaults.set(data, forKey: queuedWorkoutPlansKey)
        return true
    }

    static func nextQueuedWorkoutPlan(defaults: UserDefaults = .standard) -> WorkoutPlanDraft? {
        queuedWorkoutPlans(defaults: defaults).first
    }

    static func acknowledgeQueuedWorkoutPlan(
        _ draft: WorkoutPlanDraft,
        defaults: UserDefaults = .standard
    ) {
        var queued = queuedWorkoutPlans(defaults: defaults)
        guard queued.first == draft else { return }
        queued.removeFirst()
        guard !queued.isEmpty else {
            defaults.removeObject(forKey: queuedWorkoutPlansKey)
            return
        }
        guard let data = try? JSONEncoder().encode(queued) else { return }
        defaults.set(data, forKey: queuedWorkoutPlansKey)
    }

    static func clearQueuedWorkoutPlans(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: queuedWorkoutPlansKey)
    }

    static func clearMealText(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: mealTextKey)
    }

    static func mergedMealText(existing: String, incoming: String) -> String {
        guard !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return incoming
        }
        return existing + "\n\n" + incoming
    }

    static func store(destination: DensosoAppIntentDestination, defaults: UserDefaults = .standard) {
        defaults.set(destination.rawValue, forKey: destinationKey)
    }

    static func consumeDestination(defaults: UserDefaults = .standard) -> DensosoAppIntentDestination? {
        defer { defaults.removeObject(forKey: destinationKey) }
        guard let rawValue = defaults.string(forKey: destinationKey) else { return nil }
        return DensosoAppIntentDestination(rawValue: rawValue)
    }

    static func clearDestination(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: destinationKey)
    }

    @MainActor
    static func deliver(destination: DensosoAppIntentDestination) {
        AppState.shared.pendingSystemIntent = destination
    }

    @MainActor
    static func deliver(workoutPlan: WorkoutPlanDraft, defaults: UserDefaults = .standard) {
        store(workoutPlan: workoutPlan, defaults: defaults)
        AppState.shared.pendingWorkoutPlan = workoutPlan
    }

    @MainActor
    static func deliver(mealText: String, defaults: UserDefaults = .standard) {
        store(mealText: mealText, defaults: defaults)
        AppState.shared.pendingMealText = mealText
    }

    @MainActor
    static func receivePendingDrafts(
        receiveWorkoutPlan: Bool = true,
        defaults: UserDefaults = .standard
    ) {
        if receiveWorkoutPlan,
           AppState.shared.pendingWorkoutPlan == nil,
           let workoutPlan = consumeWorkoutPlan(defaults: defaults) {
            AppState.shared.pendingWorkoutPlan = workoutPlan
        }
        if let mealText = consumeMealText(defaults: defaults) {
            AppState.shared.pendingMealText = mealText
        }
    }

    private static func queuedWorkoutPlans(defaults: UserDefaults) -> [WorkoutPlanDraft] {
        guard let data = defaults.data(forKey: queuedWorkoutPlansKey) else { return [] }
        return (try? JSONDecoder().decode([WorkoutPlanDraft].self, from: data)) ?? []
    }
}

struct ViewTodayStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "查看今天状态"
    static let description = IntentDescription("打开 densoso Today snapshot 查看已有的今日状态摘要。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppIntentInbox.store(destination: .todayStatus)
        await AppIntentInbox.deliver(destination: .todayStatus)
        return .result(dialog: "已打开 densoso Today 概览。")
    }
}

struct ViewTodayGuidanceIntent: AppIntent {
    static let title: LocalizedStringResource = "查看今日建议"
    static let description = IntentDescription("打开 densoso Today snapshot 查看现有的明日建议。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppIntentInbox.store(destination: .todayGuidance)
        await AppIntentInbox.deliver(destination: .todayGuidance)
        return .result(dialog: "已打开 densoso Today 概览。")
    }
}

struct OpenDensosoIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 densoso"
    static let description = IntentDescription("打开 densoso 的 Today 页面。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppIntentInbox.store(destination: .openToday)
        await AppIntentInbox.deliver(destination: .openToday)
        return .result(dialog: "已打开 densoso。")
    }
}

struct StartRecordIntent: AppIntent {
    static let title: LocalizedStringResource = "开始记录"
    static let description = IntentDescription("打开 densoso 并聚焦可编辑的文字输入框，不会自动录音或保存。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppIntentInbox.store(destination: .startRecording)
        await AppIntentInbox.deliver(destination: .startRecording)
        return .result(dialog: "已打开输入框。检查并编辑内容后，再由你决定是否发送。")
    }
}

struct StartWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "开始训练"
    static let description = IntentDescription("在 densoso 中创建一份可编辑的训练草稿。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AppIntentInbox.deliver(workoutPlan: .defaultDraft)
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
        let draft = WorkoutPlanDraft(name: name, activity: .walking, goal: .timeMinutes(30))
        await AppIntentInbox.deliver(workoutPlan: draft)
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
        await AppIntentInbox.deliver(mealText: text)
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
        AppShortcut(
            intent: ViewTodayStatusIntent(),
            phrases: ["在\(.applicationName)查看今天状态"],
            shortTitle: "今天状态",
            systemImageName: "heart.text.square"
        )
        AppShortcut(
            intent: ViewTodayGuidanceIntent(),
            phrases: ["在\(.applicationName)查看今日建议"],
            shortTitle: "今日建议",
            systemImageName: "arrow.up.right"
        )
        AppShortcut(
            intent: OpenDensosoIntent(),
            phrases: ["打开\(.applicationName)"],
            shortTitle: "打开 densoso",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: StartRecordIntent(),
            phrases: ["在\(.applicationName)开始记录"],
            shortTitle: "开始记录",
            systemImageName: "square.and.pencil"
        )
    }
}
