import SwiftUI

/// A confirmation-first editor for WorkoutKit plans. No WorkoutKit call happens
/// while this view is being edited.
struct WorkoutPlanScreen: View {
    @Environment(AppState.self) private var appState
    @State private var name = WorkoutPlanDraft.squatFiveByFive.name
    @State private var activity = WorkoutPlanDraft.Activity.strength
    @State private var location = WorkoutPlanDraft.Location.indoor
    @State private var usesTimeGoal = true
    @State private var durationMinutes = 45
    @State private var shouldSchedule = false
    @State private var scheduledAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var strengthSets = WorkoutPlanDraft.squatFiveByFive.strengthSets
    @State private var isPresentingConfirmation = false
    @State private var resultMessage: String?
    @State private var schedulingService = WorkoutPlanSchedulingService()

    var body: some View {
        NavigationStack {
            Form {
                Section("训练草稿") {
                    TextField("计划名称", text: $name)
                    Picker("训练类型", selection: $activity) {
                        ForEach(WorkoutPlanDraft.Activity.allCases, id: \.self) { activity in
                            Text(activity.displayName).tag(activity)
                        }
                    }
                    Picker("地点", selection: $location) {
                        ForEach(WorkoutPlanDraft.Location.allCases, id: \.self) { location in
                            Text(location.displayName).tag(location)
                        }
                    }
                }

                Section("目标") {
                    Toggle("设定时长", isOn: $usesTimeGoal)
                    if usesTimeGoal {
                        Stepper("\(durationMinutes) 分钟", value: $durationMinutes, in: 1...720, step: 5)
                    }
                }

                Section("力量组次（应用内数据）") {
                    ForEach($strengthSets) { $set in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("动作", text: $set.exerciseName)
                            Stepper("\(set.setCount) 组 × \(set.repetitions) 次", value: $set.setCount, in: 1...100)
                            Stepper("每组 \(set.repetitions) 次", value: $set.repetitions, in: 1...1_000)
                        }
                    }
                    .onDelete { strengthSets.remove(atOffsets: $0) }

                    Button("添加动作") {
                        strengthSets.append(.init(exerciseName: "", setCount: 3, repetitions: 10))
                    }
                }

                Section("同步到 Apple Watch") {
                    Toggle("安排到指定时间", isOn: $shouldSchedule)
                    if shouldSchedule {
                        DatePicker("开始时间", selection: $scheduledAt, displayedComponents: [.date, .hourAndMinute])
                    }
                    Text("确认前只编辑本地草稿；确认后才会调用 Apple WorkoutKit 并请求系统授权。组次和重量仍保留为应用领域数据，不写入 HealthKit 的 workout 明细。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let resultMessage {
                    Section("状态") {
                        Text(resultMessage)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("训练计划")
            .onAppear {
                if let incomingDraft = appState.pendingWorkoutPlan {
                    apply(incomingDraft)
                    appState.pendingWorkoutPlan = nil
                }
            }
            .toolbar {
                Button("确认") { isPresentingConfirmation = true }
            }
            .confirmationDialog("确认同步训练计划？", isPresented: $isPresentingConfirmation) {
                Button("确认并继续", role: .none) {
                    Task { await confirm() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("系统仅会在确认后打开或安排 Apple Watch Workout 计划。")
            }
        }
    }

    private var draft: WorkoutPlanDraft {
        WorkoutPlanDraft(
            name: name,
            activity: activity,
            location: location,
            goal: usesTimeGoal ? .timeMinutes(durationMinutes) : .open,
            scheduledAt: shouldSchedule ? scheduledAt : nil,
            strengthSets: strengthSets
        )
    }

    private func confirm() async {
        do {
            try await schedulingService.previewOrSchedule(draft)
            resultMessage = shouldSchedule ? "已请求系统安排该训练计划。" : "已请求在 Apple Watch Workout App 中打开该计划。"
        } catch {
            resultMessage = error.localizedDescription
        }
    }

    private func apply(_ draft: WorkoutPlanDraft) {
        name = draft.name
        activity = draft.activity
        location = draft.location
        if case .timeMinutes(let minutes) = draft.goal {
            usesTimeGoal = true
            durationMinutes = minutes
        } else {
            usesTimeGoal = false
        }
        shouldSchedule = draft.scheduledAt != nil
        scheduledAt = draft.scheduledAt ?? scheduledAt
        strengthSets = draft.strengthSets
    }
}
