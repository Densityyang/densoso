import DensosoDomain
import SwiftUI

private enum WorkoutPlanGoalKind: String, CaseIterable, Identifiable {
    case open = "开放目标"
    case time = "时长"
    case distance = "距离"

    var id: Self { self }
}

/// Plans remain local, editable drafts until ConfirmationCoordinator commits them.
struct WorkoutPlanScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(Dependencies.self) private var dependencies

    @State private var name = WorkoutPlanDraft.defaultDraft.name
    @State private var activity = WorkoutPlanDraft.defaultDraft.activity
    @State private var location = WorkoutPlanDraft.Location.outdoor
    @State private var goalKind = WorkoutPlanGoalKind.time
    @State private var durationMinutes = 30
    @State private var distanceMeters = 1_000.0
    @State private var scheduledAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var isPresentingConfirmation = false
    @State private var isScheduling = false
    @State private var resultMessage: String?
    @State private var confirmedPlans: [ConfirmedWorkoutPlanEntry] = []
    @State private var confirmedTrainingPlans: [ConfirmedTrainingPlanEntry] = []
    @State private var confirmedPlansReadError: String?
    @State private var confirmedPlansNextOffset: Int?
    @State private var confirmedTrainingPlansNextOffset: Int?
    @State private var isLoadingMoreConfirmedPlans = false
    @State private var shouldRetryLoadingMoreConfirmedPlans = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OrbitScreenHeader(
                        eyebrow: "Plan first, schedule after confirmation",
                        title: "训练计划由你确认后交给 WorkoutKit。",
                        subtitle: "Densoso 不记录自建 Workout Session；Workout App 与 HealthKit 是训练事实源。"
                    )
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section("计划草稿") {
                    TextField("计划名称", text: $name)
                    Picker("活动", selection: $activity) {
                        ForEach(WorkoutPlanDraft.Activity.supportedCases, id: \.self) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    Picker("地点", selection: $location) {
                        ForEach(WorkoutPlanDraft.Location.allCases, id: \.self) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                }

                Section("单一目标") {
                    Picker("目标类型", selection: $goalKind) {
                        ForEach(WorkoutPlanGoalKind.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch goalKind {
                    case .open:
                        Text("开始训练后由 Apple Workout 决定记录细节。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .time:
                        Stepper("\(durationMinutes) 分钟", value: $durationMinutes, in: 1...720, step: 5)
                    case .distance:
                        Stepper(
                            "\(Int(distanceMeters.rounded())) 米",
                            value: $distanceMeters,
                            in: 100...100_000,
                            step: 100
                        )
                    }
                }

                Section("安排时间") {
                    DatePicker("开始时间", selection: $scheduledAt, displayedComponents: [.date, .hourAndMinute])
                    Label(
                        "只有确认本机计划后才会请求 WorkoutKit 授权并安排到 Apple Watch。",
                        systemImage: "hand.raised.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("已确认的计划") {
                    if let confirmedPlansReadError {
                        Label(confirmedPlansReadError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(OrbitPalette.coral)
                        Button("重试") {
                            if shouldRetryLoadingMoreConfirmedPlans {
                                loadMoreConfirmedPlans()
                            } else {
                                refreshConfirmedPlans()
                            }
                        }
                    }
                    if confirmedPlansReadError == nil
                        && confirmedPlans.isEmpty
                        && confirmedTrainingPlans.isEmpty {
                        Text("确认后的计划会显示在这里。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(confirmedPlans, id: \.actionID) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.draft.name).font(.subheadline.weight(.semibold))
                            Text(entry.draft.scheduledAt ?? Date(), format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Label(queueStatus(entry), systemImage: entry.state == .scheduled ? "checkmark.circle.fill" : "clock")
                                .font(.caption)
                                .foregroundStyle(entry.state == .scheduled ? OrbitPalette.green : OrbitPalette.gold)
                            if let lastError = entry.lastError {
                                Text(lastError)
                                    .font(.caption2)
                                    .foregroundStyle(OrbitPalette.coral)
                            }
                            if entry.state == .queued || entry.state == .retryable {
                                Button("继续同步到 WorkoutKit") {
                                    Task { await schedule(actionID: entry.actionID) }
                                }
                                .disabled(isScheduling)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(confirmedTrainingPlans, id: \.actionID) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.draft.name).font(.subheadline.weight(.semibold))
                            Text(trainingPlanSummary(entry.draft))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(entry.draft.sessions) { session in
                                Text(confirmedSessionSummary(session))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Label(
                                queueStatus(entry),
                                systemImage: entry.state == .scheduled ? "checkmark.circle.fill" : "clock"
                            )
                            .font(.caption)
                            .foregroundStyle(entry.state == .scheduled ? OrbitPalette.green : OrbitPalette.gold)
                            if let lastError = entry.lastError {
                                Text(lastError)
                                    .font(.caption2)
                                    .foregroundStyle(OrbitPalette.coral)
                            }
                            if entry.state == .queued || entry.state == .retryable {
                                Button("继续同步训练日到 WorkoutKit") {
                                    Task { await schedule(actionID: entry.actionID) }
                                }
                                .disabled(isScheduling)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if confirmedPlansReadError == nil,
                       confirmedPlansNextOffset != nil || confirmedTrainingPlansNextOffset != nil {
                        Button(isLoadingMoreConfirmedPlans ? "正在加载…" : "加载更多已确认计划") {
                            loadMoreConfirmedPlans()
                        }
                        .disabled(isLoadingMoreConfirmedPlans)
                    }
                }

                if let resultMessage {
                    Section("状态") {
                        Text(resultMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .orbitScrollBackground()
            .navigationTitle("训练计划")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if let incomingDraft = appState.pendingWorkoutPlan {
                    apply(incomingDraft)
                    appState.pendingWorkoutPlan = nil
                }
                refreshConfirmedPlans()
            }
            .toolbar {
                Button {
                    isPresentingConfirmation = true
                } label: {
                    Image(systemName: "checkmark")
                }
                .disabled(isScheduling)
                .accessibilityLabel("确认训练计划")
            }
            .confirmationDialog("确认此训练计划？", isPresented: $isPresentingConfirmation) {
                Button("确认并安排") { Task { await confirmAndSchedule() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("确认前不会调用 WorkoutKit；确认后会先在本机留下可重试的计划记录。")
            }
        }
    }

    private var draft: WorkoutPlanDraft {
        let goal: WorkoutPlanDraft.Goal
        switch goalKind {
        case .open: goal = .open
        case .time: goal = .timeMinutes(durationMinutes)
        case .distance: goal = .distanceMeters(distanceMeters)
        }
        return WorkoutPlanDraft(
            name: name,
            activity: activity,
            location: location,
            goal: goal,
            scheduledAt: scheduledAt
        )
    }

    private func confirmAndSchedule() async {
        guard !isScheduling else { return }
        isScheduling = true
        defer { isScheduling = false }
        do {
            try WorkoutPlanCompiler().validate(draft)
            let action = try await dependencies.confirmationCoordinator.stage(
                payload: .workoutPlan(draft),
                clientRequestID: UUID()
            )
            _ = try await dependencies.confirmationCoordinator.confirm(id: action.id)
            try? await dependencies.agentSession.reloadPendingActions()
            refreshConfirmedPlans()
            do {
                try await dependencies.workoutPlanSchedulingService.scheduleConfirmedPlan(actionID: action.id)
                resultMessage = "计划已确认，并已交给 WorkoutKit 安排。"
            } catch {
                resultMessage = "计划已在本机确认；系统安排待处理，可在下方重试：\(error.localizedDescription)"
            }
            dependencies.watchConnectivityCoordinator.refreshApplicationContext()
            refreshConfirmedPlans()
        } catch {
            resultMessage = error.localizedDescription
        }
    }

    private func schedule(actionID: UUID) async {
        guard !isScheduling else { return }
        isScheduling = true
        defer { isScheduling = false }
        do {
            try await dependencies.workoutPlanSchedulingService.scheduleConfirmedPlan(actionID: actionID)
            resultMessage = "WorkoutKit 计划状态已更新。"
        } catch {
            resultMessage = error.localizedDescription
        }
        dependencies.watchConnectivityCoordinator.refreshApplicationContext()
        refreshConfirmedPlans()
    }

    private func refreshConfirmedPlans() {
        shouldRetryLoadingMoreConfirmedPlans = false
        do {
            let plans = try dependencies.workoutPlanSchedulingService.confirmedPlansPage(offset: 0)
            let trainingPlans = try dependencies.workoutPlanSchedulingService.confirmedTrainingPlansPage(offset: 0)
            confirmedPlans = uniqueWorkoutPlans(plans.entries)
            confirmedTrainingPlans = uniqueTrainingPlans(trainingPlans.entries)
            confirmedPlansNextOffset = plans.nextOffset
            confirmedTrainingPlansNextOffset = trainingPlans.nextOffset
            confirmedPlansReadError = nil
        } catch {
            confirmedPlans = []
            confirmedTrainingPlans = []
            confirmedPlansNextOffset = nil
            confirmedTrainingPlansNextOffset = nil
            confirmedPlansReadError = "读取已确认的计划失败：\(error.localizedDescription)"
        }
    }

    private func loadMoreConfirmedPlans() {
        guard !isLoadingMoreConfirmedPlans,
              confirmedPlansNextOffset != nil || confirmedTrainingPlansNextOffset != nil else { return }
        isLoadingMoreConfirmedPlans = true
        defer { isLoadingMoreConfirmedPlans = false }

        do {
            let plans: ConfirmedPlanPage<ConfirmedWorkoutPlanEntry>
            if let confirmedPlansNextOffset {
                plans = try dependencies.workoutPlanSchedulingService.confirmedPlansPage(
                    offset: confirmedPlansNextOffset
                )
            } else {
                plans = ConfirmedPlanPage(entries: [], nextOffset: nil)
            }
            let trainingPlans: ConfirmedPlanPage<ConfirmedTrainingPlanEntry>
            if let confirmedTrainingPlansNextOffset {
                trainingPlans = try dependencies.workoutPlanSchedulingService.confirmedTrainingPlansPage(
                    offset: confirmedTrainingPlansNextOffset
                )
            } else {
                trainingPlans = ConfirmedPlanPage(entries: [], nextOffset: nil)
            }
            confirmedPlans = uniqueWorkoutPlans(confirmedPlans + plans.entries)
            confirmedTrainingPlans = uniqueTrainingPlans(confirmedTrainingPlans + trainingPlans.entries)
            confirmedPlansNextOffset = plans.nextOffset
            confirmedTrainingPlansNextOffset = trainingPlans.nextOffset
            confirmedPlansReadError = nil
            shouldRetryLoadingMoreConfirmedPlans = false
        } catch {
            confirmedPlansReadError = "读取更多已确认的计划失败：\(error.localizedDescription)"
            shouldRetryLoadingMoreConfirmedPlans = true
        }
    }

    private func uniqueWorkoutPlans(_ entries: [ConfirmedWorkoutPlanEntry]) -> [ConfirmedWorkoutPlanEntry] {
        var seenActionIDs = Set<UUID>()
        return entries.filter { seenActionIDs.insert($0.actionID).inserted }
    }

    private func uniqueTrainingPlans(_ entries: [ConfirmedTrainingPlanEntry]) -> [ConfirmedTrainingPlanEntry] {
        var seenActionIDs = Set<UUID>()
        return entries.filter { seenActionIDs.insert($0.actionID).inserted }
    }

    private func trainingPlanSummary(_ plan: TrainingPlanDraft) -> String {
        let workoutCount = plan.sessions.filter { !$0.isRestDay }.count
        let restCount = plan.sessions.count - workoutCount
        let dates = plan.sessions.map(\.date)
        guard let first = dates.min(), let last = dates.max() else {
            return "\(workoutCount) 次训练 · \(restCount) 天休息"
        }
        let range: String
        if Calendar.current.isDate(first, inSameDayAs: last) {
            range = first.formatted(date: .abbreviated, time: .omitted)
        } else {
            range = "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
        }
        return "\(range) · \(workoutCount) 次训练 · \(restCount) 天休息"
    }

    private func confirmedSessionSummary(_ session: TrainingSessionDraft) -> String {
        let date = session.date.formatted(date: .abbreviated, time: .shortened)
        guard let activity = session.activity,
              let goal = session.goal,
              let location = session.location,
              let intensity = session.recommendedIntensity else {
            return "\(date) · 休息 · \(session.reason)"
        }
        return "\(date) · \(activity.displayName) · \(goal.displayName) · \(location.displayName) · \(intensity.displayName) · \(session.reason)"
    }

    private func apply(_ incomingDraft: WorkoutPlanDraft) {
        name = incomingDraft.name
        activity = incomingDraft.activity.isWorkoutKitSupported ? incomingDraft.activity : .walking
        location = incomingDraft.location
        scheduledAt = incomingDraft.scheduledAt ?? scheduledAt
        switch incomingDraft.goal {
        case .open:
            goalKind = .open
        case .timeMinutes(let minutes):
            goalKind = .time
            durationMinutes = min(max(minutes, 1), 720)
        case .distanceMeters(let meters):
            goalKind = .distance
            distanceMeters = min(max(meters, 100), 100_000)
        }
    }

    private func queueStatus(_ entry: ConfirmedWorkoutPlanEntry) -> String {
        switch entry.state {
        case .queued: "已本机确认，等待同步"
        case .retryable: "安排未完成，可重试"
        case .scheduled: "已安排"
        case .terminal: "此计划无法安排，请重新创建"
        }
    }

    private func queueStatus(_ entry: ConfirmedTrainingPlanEntry) -> String {
        switch entry.state {
        case .queued: "已本机确认，等待同步"
        case .retryable: "部分安排未完成，可重试"
        case .scheduled: "训练计划已安排"
        case .terminal: "此训练计划无法安排，请重新创建"
        }
    }
}
