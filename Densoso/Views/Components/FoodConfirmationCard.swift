import SwiftUI

/// 食物热量估算确认卡片
struct FoodConfirmationCard: View {
    let summary: String
    let confidence: Double
    let onConfirm: () -> Void
    let onAdjust: (Double) -> Void

    @State private var selectedFactor = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("热量确认")
                    .font(.headline)
                Spacer()
                confidenceBadge
            }

            Text(summary)
                .font(.subheadline)
                .lineLimit(5)

            HStack(spacing: 8) {
                adjustmentButton(label: "-20%", factor: 0.8)
                adjustmentButton(label: "正常", factor: 1.0)
                adjustmentButton(label: "+20%", factor: 1.2)
                adjustmentButton(label: "+50%", factor: 1.5)
            }

            Button("确认记录") {
                onAdjust(selectedFactor)
                onConfirm()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
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
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func adjustmentButton(label: String, factor: Double) -> some View {
        Button {
            selectedFactor = factor
        } label: {
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selectedFactor == factor ? Color.blue : Color.gray.opacity(0.2))
                .foregroundStyle(selectedFactor == factor ? .white : .primary)
                .clipShape(Capsule())
        }
    }
}

/// 所有健康数据写入共用的显式确认边界。
struct PendingActionConfirmationCard: View {
    let action: PendingAction
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(action.payload.title).font(.headline)
                Spacer()
                Text("确认前不会保存")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }
            Text(action.payload.summary).font(.subheadline)
            if case .meal = action.payload {
                Text("估算可信度：\(Int(action.payload.confidence * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("拒绝", role: .cancel, action: onReject)
                    .buttonStyle(.bordered)
                Button("确认并保存", action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
