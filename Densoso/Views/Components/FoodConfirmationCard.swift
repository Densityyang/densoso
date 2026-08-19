import SwiftUI
import DensosoDomain

/// 食物热量估算确认卡片
struct FoodConfirmationCard: View {
    let summary: String
    let confidence: Double
    let onConfirm: () -> Void
    let onAdjust: (Double) -> Void

    @State private var selectedFactor = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("热量确认")
                    .font(.headline)
                Spacer()
                confidenceBadge
            }

            Text(summary)
                .font(.subheadline)
                .lineLimit(5)

            Picker("估算调整", selection: $selectedFactor) {
                Text("-20%").tag(0.8)
                Text("正常").tag(1.0)
                Text("+20%").tag(1.2)
                Text("+50%").tag(1.5)
            }
            .pickerStyle(.segmented)

            Button("确认记录") {
                onAdjust(selectedFactor)
                onConfirm()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        .orbitCard(emphasized: true)
    }

    private var confidenceBadge: some View {
        let text: String
        let color: Color
        switch confidence {
        case ..<0.5: text = "低"; color = .red
        case 0.5..<0.8: text = "中"; color = .orange
        default: text = "高"; color = .green
        }
        return Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

/// 所有健康数据写入共用的显式确认边界。
struct PendingActionConfirmationCard: View {
    let action: PendingAction
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(action.payload.title).font(.headline)
                Spacer()
                OrbitStatusBadge(text: "确认前不会保存", tone: .gold)
            }
            Text(action.payload.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if case .meal = action.payload {
                Label(
                    "估算可信度：\(Int(action.payload.confidence * 100))%",
                    systemImage: "checkmark.seal"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
                Button("拒绝", role: .cancel, action: onReject)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("确认并保存", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
        .orbitCard(emphasized: true)
    }
}

#Preview {
    FoodConfirmationCard(
        summary: "红烧肉一小碗 ≈ 690 kcal\n五花肉 120g + 冰糖 10g + 油 10g",
        confidence: 0.65,
        onConfirm: {},
        onAdjust: { _ in }
    )
}
