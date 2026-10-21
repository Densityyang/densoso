import DensosoDomain
import SwiftUI

struct WatchCompanionView: View {
    @State private var connectivity = WatchConnectivityClient()
    @State private var transcript = ""
    private let calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    todaySection(asOf: timeline.date)
                    tomorrowGuidanceSection(asOf: timeline.date)
                    transcriptSection
                    pendingActionsSection(asOf: timeline.date)
                    workoutPlansSection(asOf: timeline.date)
                    Text(connectivity.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .task {
            connectivity.activate()
            connectivity.requestTodaySnapshot()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("densoso")
                .font(.headline)
            Text("Watch 伴侣")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func todaySection(asOf date: Date) -> some View {
        if let snapshot = connectivity.todaySnapshot {
            let isCurrent = snapshot.isCurrentLocalDay(asOf: date, calendar: calendar)
            VStack(alignment: .leading, spacing: 6) {
                if isCurrent {
                    Text("今天").font(.subheadline.weight(.semibold))
                    Text(snapshot.summary)
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !snapshot.domains.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("今日状态")
                                .font(.caption.weight(.semibold))
                            ForEach(HealthDomain.allCases, id: \.self) { domain in
                                if let result = snapshot.domains.first(where: { $0.domain == domain }) {
                                    HStack {
                                        Text(domainName(domain))
                                        Spacer(minLength: 6)
                                        Text(domainStatusName(result.status))
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.caption2)
                                }
                            }
                        }
                    }
                    if let recovery = snapshot.recoverySummary {
                        LabeledContent("恢复", value: recoveryStatusName(recovery.status))
                            .font(.caption2)
                        LabeledContent("建议动作", value: recommendedActionName(recovery.recommendedAction))
                            .font(.caption2)
                    }
                } else {
                    Text("最近同步")
                        .font(.subheadline.weight(.semibold))
                    Text(syncDateLabel(snapshot.generatedAt))
                        .font(.caption2)
                    Text("此摘要已跨越本地日期，不代表今天的健康状态或日程。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("刷新") { connectivity.requestTodaySnapshot() }
                    .font(.caption2)
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        } else {
            ContentUnavailableView("等待 iPhone 摘要", systemImage: "iphone")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private func tomorrowGuidanceSection(asOf date: Date) -> some View {
        if let guidance = currentSnapshot(asOf: date)?.tomorrowGuidance {
            VStack(alignment: .leading, spacing: 6) {
                Text("明日建议")
                    .font(.subheadline.weight(.semibold))
                Text(guidance.conditionalNote)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("推荐动作", value: recommendedActionName(guidance.recommendedAction))
                    .font(.caption2)
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("发送语音草稿").font(.subheadline.weight(.semibold))
            TextField("口述或输入记录", text: transcriptBinding, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityLabel("口述或输入记录")
            Button("发送到 iPhone") {
                let pendingCount = connectivity.pendingMessageCount
                connectivity.sendTranscript(transcript)
                // Keep the draft if the durable Watch outbox rejected it (for
                // example, validation failed); only clear after enqueue succeeds.
                if connectivity.pendingMessageCount > pendingCount {
                    transcript = ""
                }
            }
            .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .font(.caption)
            Text("\(transcript.count)/\(WatchMessageCodec.maximumTranscriptLength)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var transcriptBinding: Binding<String> {
        Binding(
            get: { transcript },
            set: { transcript = String($0.prefix(WatchMessageCodec.maximumTranscriptLength)) }
        )
    }

    @ViewBuilder
    private func pendingActionsSection(asOf now: Date) -> some View {
        if let snapshot = connectivity.todaySnapshot {
            let validActions = snapshot.activePendingActions(asOf: now)
            if !validActions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("待确认草稿").font(.subheadline.weight(.semibold))
                    ForEach(validActions) { action in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(action.title)
                                .font(.caption.weight(.semibold))
                            Text(action.summary)
                                .font(.caption2)
                                .lineLimit(3)
                            HStack {
                                if action.requiresPhoneReview == true {
                                    Text("请在 iPhone 查看完整安排后确认")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Button("确认") { connectivity.confirm(actionID: action.actionID) }
                                }
                                Button("拒绝", role: .destructive) { connectivity.reject(actionID: action.actionID) }
                            }
                            .font(.caption2)
                        }
                        .padding(7)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
                    }
                    Text("确认和拒绝由 iPhone 的本地事务幂等处理。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func workoutPlansSection(asOf date: Date) -> some View {
        if let snapshot = currentSnapshot(asOf: date), !snapshot.workoutPlans.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("WorkoutKit 计划").font(.subheadline.weight(.semibold))
                ForEach(snapshot.workoutPlans) { plan in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.title).font(.caption.weight(.semibold))
                        if let scheduledAt = plan.scheduledAt {
                            Text(scheduledAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption2)
                        }
                        Text(plan.lastError ?? planState(plan.state))
                            .font(.caption2)
                            .foregroundStyle(plan.lastError == nil ? Color.secondary : Color.red)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func currentSnapshot(asOf date: Date) -> WatchTodaySnapshot? {
        guard let snapshot = connectivity.todaySnapshot,
              snapshot.isCurrentLocalDay(asOf: date, calendar: calendar) else { return nil }
        return snapshot
    }

    private func syncDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func planState(_ state: String) -> String {
        switch state {
        case "scheduled": "已安排"
        case "queued": "等待同步"
        case "retryable": "可在 iPhone 重试"
        case "terminal": "需要重新创建"
        default: "状态未知"
        }
    }

    private func recommendedActionName(_ action: RecommendationAction) -> String {
        switch action {
        case .continueAsPlanned: "按计划进行"
        case .reduceIntensity: "降低训练强度"
        case .rest: "优先休息"
        case .collectData: "继续收集信息"
        }
    }

    private func recoveryStatusName(_ status: RecoveryStatus) -> String {
        switch status {
        case .insufficientEvidence: "证据不足"
        case .withinTypicalRange: "常见范围"
        case .attention: "需要关注"
        }
    }

    private func domainName(_ domain: HealthDomain) -> String {
        switch domain {
        case .nutrition: "营养"
        case .sleep: "睡眠"
        case .activity: "活动"
        case .body: "身体"
        }
    }

    private func domainStatusName(_ status: HealthDomainStatus) -> String {
        switch status {
        case .noData: "暂无数据"
        case .learning: "学习中"
        case .withinTypicalRange: "常见范围"
        case .changed: "有所变化"
        case .attention: "需要关注"
        }
    }
}
