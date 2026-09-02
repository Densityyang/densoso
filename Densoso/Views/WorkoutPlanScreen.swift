import SwiftUI
import DensosoDomain

/// A confirmation-first editor for WorkoutKit plans. No WorkoutKit call happens
/// while this view is being edited.
struct WorkoutPlanScreen: View {
    @Environment(AppState.self) private var appState
    @State private var name = WorkoutPlanDraft.squatFiveByFive.name
    @State private var activity = WorkoutPlanDraft.Activity.strength
    @State private var location = WorkoutPlanDraft.Location.indoor
    @State private var usesTimeGoal = true
    @State private var durationMinutes = 45
    @State private var shouldSchedule = true
    @State private var scheduledAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var strengthSets = WorkoutPlanDraft.squatFiveByFive.strengthSets
    @State private var isPresentingConfirmation = false
    @State private var resultMessage: String?
    @State private var schedulingService = WorkoutPlanSchedulingService()
    @State private var catalogEntries: [ExerciseCatalog.Entry] = []
    @State private var catalogVersion: String?

    var body: some View {
        NavigationStack {
            Form {
                    Section {
                        OrbitScreenHeader(
                            eyebrow: "Plan on phone, act on wrist",
                            title: "手机负责意图，手表负责训练现场。",
                            subtitle: "这里始终先编辑本地草稿；只有你确认后才连接 WorkoutKit。"
                        )
                        .padding(.vertical, 8)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

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
                                Menu("从离线目录选择") {
                                    ForEach(strengthExercises) { exercise in
                                        Button(exercise.name) {
                                            set.exerciseID = exercise.id
                                            set.exerciseName = exercise.aliases.first ?? exercise.name
                                        }
                                    }
                                }
                                Stepper("\(set.setCount) 组 × \(set.repetitions) 次", value: $set.setCount, in: 1...100)
                                Stepper("每组 \(set.repetitions) 次", value: $set.repetitions, in: 1...1_000)
                            }
                        }
                        .onDelete { strengthSets.remove(atOffsets: $0) }

                        Button("添加动作", systemImage: "plus") {
                            strengthSets.append(.init(exerciseName: "", setCount: 3, repetitions: 10))
                        }
                        if let catalogVersion {
                            Text("动作目录：\(catalogVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("同步到 Apple Watch") {
                        Toggle("安排到指定时间", isOn: $shouldSchedule)
                        if shouldSchedule {
                            DatePicker("开始时间", selection: $scheduledAt, displayedComponents: [.date, .hourAndMinute])
                        }
                        Label(
                            "确认前只编辑本地草稿；确认后才会调用 WorkoutKit。力量组次保留为 Densoso 领域数据。",
                            systemImage: "hand.raised.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if let resultMessage {
                        Section("状态") {
                            Label(resultMessage, systemImage: "info.circle")
                                .font(.caption)
                        }
                    }
            }
            .orbitScrollBackground()
            .navigationTitle("计划")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadExerciseCatalog()
                if let incomingDraft = appState.pendingWorkoutPlan {
                    apply(incomingDraft)
                    appState.pendingWorkoutPlan = nil
                }
            }
            .toolbar {
                Button {
                    isPresentingConfirmation = true
                } label: {
                    Image(systemName: "checkmark")
                }
                .accessibilityLabel("确认训练计划")
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
            resultMessage = "已请求系统安排该训练计划。"
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

    private var strengthExercises: [ExerciseCatalog.Entry] {
        Array(catalogEntries.filter { $0.category == "strength" }.prefix(12))
    }

    private func loadExerciseCatalog() {
        guard catalogEntries.isEmpty else { return }
        do {
            let catalog = try ExerciseCatalog.loadBundled()
            catalogEntries = catalog.entries
            catalogVersion = catalog.catalogVersion
        } catch {
            resultMessage = error.localizedDescription
        }
    }
}
