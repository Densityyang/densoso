import DensosoDomain
import SwiftUI

struct DailyLoopSnapshotCard: View {
    let snapshot: DailyLoopSnapshot?
    let errorMessage: String?
    let isLoading: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isLoading {
                ProgressView("正在读取今日概览…")
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
                    .accessibilityIdentifier("daily-loop-snapshot-loading")
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Label("今日概览读取失败", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(OrbitPalette.coral)
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("重试", action: onRetry)
                        .buttonStyle(.bordered)
                }
                .accessibilityIdentifier("daily-loop-snapshot-error")
            } else if snapshot?.refreshState == .error {
                VStack(alignment: .leading, spacing: 10) {
                    Label("今日概览刷新失败", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(OrbitPalette.coral)
                    Text("本地健康摘要暂时无法读取。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("重试", action: onRetry)
                        .buttonStyle(.bordered)
                }
                .accessibilityIdentifier("daily-loop-snapshot-error")
            } else if let snapshot {
                HStack(alignment: .firstTextBaseline) {
                    Label("今日节奏", systemImage: "sun.max.fill")
                        .font(.headline)
                    Spacer()
                    OrbitStatusBadge(text: phaseName(snapshot.phase), tone: .blue)
                        .accessibilityIdentifier("daily-loop-phase")
                }

                if snapshot.refreshState == .stale || snapshot.refreshState == .refreshRequired {
                    HStack(spacing: 8) {
                        Label(
                            snapshot.refreshState == .stale ? "健康摘要需要更新" : "今日摘要待刷新",
                            systemImage: "arrow.clockwise"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("刷新", action: onRetry)
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                    }
                    .accessibilityIdentifier("daily-loop-refresh-state")
                }

                VStack(alignment: .leading, spacing: 5) {
                    if let todayState = snapshot.todayState {
                        Text(todayState.headline)
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("daily-loop-state")
                        if let detail = todayState.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("今日状态暂不可用")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("daily-loop-state")
                    }

                    if let todaySummary = snapshot.todaySummary {
                        Text(todaySummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("daily-loop-summary")
                    } else {
                        Text("今日总结暂不可用")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("daily-loop-summary")
                    }
                }

                coverageSection(snapshot.coverage)

                Divider()

                guidanceSection(snapshot.tomorrowGuidance)
                pendingActionsSection(snapshot.pendingActions)
                workoutPlansSection(snapshot.workoutPlans)
            } else {
                ContentUnavailableView(
                    "今日概览暂不可用",
                    systemImage: "sun.max",
                    description: Text("现有摘要和计划信息暂时无法读取。")
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .orbitCard(emphasized: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("daily-loop-snapshot")
    }

    @ViewBuilder
    private func coverageSection(_ coverage: DailyLoopMetricCoverage) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3)
        let items: [(String, MetricAvailability)] = [
            ("摄入", coverage.intake),
            ("消耗", coverage.expenditure),
            ("缺口", coverage.deficit),
            ("蛋白", coverage.proteinG),
            ("脂肪", coverage.fatG),
            ("碳水", coverage.carbsG),
        ]
        VStack(alignment: .leading, spacing: 6) {
            Text("数据覆盖")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { item in
                    HStack(spacing: 4) {
                        Text(item.element.0)
                            .foregroundStyle(.secondary)
                        Text(availabilityName(item.element.1))
                            .fontWeight(.medium)
                    }
                    .font(.caption2)
                    .lineLimit(1)
                }
            }
        }
        .accessibilityIdentifier("daily-loop-data-coverage")
    }

    private func availabilityName(_ availability: MetricAvailability) -> String {
        switch availability {
        case .observed: "实测"
        case .estimated: "估算"
        case .partial: "部分"
        case .unavailable: "暂缺"
        case .pendingRecompute: "待重算"
        }
    }

    @ViewBuilder
    private func guidanceSection(_ guidance: NextDayGuidance?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("明日建议", systemImage: "arrow.up.right")
                .font(.subheadline.weight(.semibold))
            if let guidance {
                HStack(spacing: 8) {
                    Text(expectedStateName(guidance.expectedState))
                        .font(.footnote.weight(.medium))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(actionName(guidance.recommendedAction))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(guidance.conditionalNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("明日建议暂不可用")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("daily-loop-guidance")
    }

    @ViewBuilder
    private func pendingActionsSection(_ actions: [WatchPendingActionSummary]) -> some View {
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label("待确认", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
                ForEach(actions) { action in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                            .font(.footnote.weight(.medium))
                        Text(action.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                Text("在下方确认卡片中检查或拒绝草稿。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityIdentifier("daily-loop-pending-actions")
        }
    }

    @ViewBuilder
    private func workoutPlansSection(_ plans: [WatchWorkoutPlanSummary]) -> some View {
        if !plans.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label("训练计划", systemImage: "figure.run")
                    .font(.subheadline.weight(.semibold))
                ForEach(plans) { plan in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.title)
                                .font(.footnote.weight(.medium))
                            if let scheduledAt = plan.scheduledAt {
                                Text(scheduledAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(planStateName(plan.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("daily-loop-workout-plans")
        }
    }

    private func phaseName(_ phase: DailyLoopPhase) -> String {
        switch phase {
        case .morning: "早晨"
        case .daytime: "白天"
        case .evening: "晚上"
        }
    }

    private func expectedStateName(_ state: NextDayState) -> String {
        switch state {
        case .favorable: "恢复条件较好"
        case .neutral: "保持观察"
        case .caution: "建议谨慎安排"
        case .unknown: "现有证据不足"
        }
    }

    private func actionName(_ action: RecommendationAction) -> String {
        switch action {
        case .continueAsPlanned: "可按计划进行"
        case .reduceIntensity: "考虑降低强度"
        case .rest: "优先休息"
        case .collectData: "继续收集信息"
        }
    }

    private func planStateName(_ state: String) -> String {
        switch state {
        case "queued": "等待安排"
        case "retryable": "待重试"
        case "scheduled": "已安排"
        default: state
        }
    }
}
