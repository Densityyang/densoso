import DensosoDomain
import SwiftUI

struct WatchCompanionView: View {
    @State private var connectivity = WatchConnectivityClient()
    @State private var transcript = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                todaySection
                transcriptSection
                pendingActionsSection
                workoutPlansSection
                Text(connectivity.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
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
    private var todaySection: some View {
        if let snapshot = connectivity.todaySnapshot {
            VStack(alignment: .leading, spacing: 6) {
                Text("今天").font(.subheadline.weight(.semibold))
                Text(snapshot.summary)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                if let intake = snapshot.energyIntakeKcal {
                    LabeledContent("摄入", value: "\(intake) kcal")
                        .font(.caption2)
                }
                if let expenditure = snapshot.totalExpenditureKcal {
                    LabeledContent("总消耗", value: "\(expenditure) kcal")
                        .font(.caption2)
                }
                if let deficit = snapshot.deficitKcal {
                    LabeledContent("能量差", value: "\(deficit) kcal")
                        .font(.caption2)
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

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("发送语音草稿").font(.subheadline.weight(.semibold))
            TextField("口述或输入记录", text: $transcript, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityLabel("口述或输入记录")
            Button("发送到 iPhone") {
                connectivity.sendTranscript(transcript)
                transcript = ""
            }
            .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .font(.caption)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var pendingActionsSection: some View {
        if let snapshot = connectivity.todaySnapshot, !snapshot.pendingActions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("待确认草稿").font(.subheadline.weight(.semibold))
                ForEach(snapshot.pendingActions) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(action.title)
                            .font(.caption.weight(.semibold))
                        Text(action.summary)
                            .font(.caption2)
                            .lineLimit(3)
                        HStack {
                            Button("确认") { connectivity.confirm(actionID: action.actionID) }
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

    @ViewBuilder
    private var workoutPlansSection: some View {
        if let snapshot = connectivity.todaySnapshot, !snapshot.workoutPlans.isEmpty {
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
                            .foregroundStyle(plan.lastError == nil ? Color.secondary : OrbitPalette.coral)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
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
}
