import SwiftUI
import DensosoDomain

/// 食物热量估算确认卡片
struct FoodConfirmationCard: View {
    let summary: String
    let energyRange: EstimateRange?
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

            if let presentation = caloriePresentation,
               let adjustedEnergyRange {
                Text("约 \(presentation.likelyKcal) kcal")
                    .font(.title3.weight(.semibold))
                DisclosureGroup {
                    Text("基于当前份量调整后的估算范围")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } label: {
                    Text("区间详情：\(rangeText(adjustedEnergyRange, unit: "kcal"))")
                        .font(.subheadline)
                }
            } else {
                Text("热量暂不可用")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

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
        let confidence = caloriePresentation?.confidence ?? .low
        let color: Color
        switch confidence {
        case .low: color = .red
        case .medium: color = .orange
        case .high: color = .green
        }
        return Text(confidence.displayName)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var adjustedEnergyRange: EstimateRange? {
        guard let energyRange else { return nil }
        return try? energyRange.scaled(by: selectedFactor)
    }

    private var caloriePresentation: CaloriePresentation? {
        guard let adjustedEnergyRange else { return nil }
        return CaloriePresentationPolicy().presentation(for: adjustedEnergyRange)
    }

    private func rangeText(_ range: EstimateRange, unit: String) -> String {
        "\(Int(range.low.rounded()))–\(Int(range.high.rounded())) \(unit)"
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
            if case .meal(let meal) = action.payload {
                if let consumedFraction = meal.consumedFractionEvidence {
                    Text("按你本轮明确报告的约 \(Int((consumedFraction.fraction * 100).rounded()))% 摄入比例计算")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if let energyRange = meal.totalNutrients?.energyKcal {
                    let presentation = CaloriePresentationPolicy().presentation(for: energyRange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("约 \(presentation.likelyKcal) kcal")
                            .font(.title3.weight(.semibold))
                        Text("估算可信度：\(presentation.confidence.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("区间详情：\(rangeText(energyRange, unit: "kcal"))")
                            .font(.subheadline)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    DisclosureGroup("营养素与估算详情") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("热量区间：\(rangeText(meal.totalNutrients?.energyKcal, unit: "kcal"))")
                            Text("蛋白质：\(rangeText(meal.totalNutrients?.proteinGrams, unit: "g")) · 脂肪：\(rangeText(meal.totalNutrients?.fatGrams, unit: "g")) · 碳水：\(rangeText(meal.totalNutrients?.carbohydrateGrams, unit: "g"))")
                            ForEach(meal.dishes) { dish in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(dish.name).font(.subheadline.weight(.semibold))
                                    if let portion = dish.portionGrams {
                                        let portionLabel = meal.consumedFractionEvidence == nil
                                            ? "份量估计"
                                            : "摄入份量估计"
                                        Text("\(portionLabel)：\(rangeText(portion, unit: "g"))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    ForEach(dish.evidence.indices, id: \.self) { index in
                                        let evidence = dish.evidence[index]
                                        Text("\(evidence.grade.rawValue)：\(evidence.summary)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                }
            }
            if case .trainingPlan(let plan) = action.payload {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.sessions) { session in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.date, format: .dateTime.weekday(.wide).month().day().hour().minute())
                                .font(.caption.weight(.semibold))
                            if session.isRestDay {
                                Text("休息日 · \(session.reason)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let activity = session.activity,
                                      let goal = session.goal,
                                      let location = session.location,
                                      let intensity = session.recommendedIntensity {
                                Text("\(activity.displayName) · \(goal.displayName) · \(location.displayName) · \(intensity.displayName)")
                                    .font(.caption)
                                Text(session.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 2)
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

    private func rangeText(_ range: EstimateRange?, unit: String) -> String {
        guard let range else { return "未估算" }
        return "\(Int(range.likely.rounded()))\(unit)（\(Int(range.low.rounded()))–\(Int(range.high.rounded()))\(unit)）"
    }
}

#Preview {
    FoodConfirmationCard(
        summary: "红烧肉一小碗 ≈ 690 kcal\n五花肉 120g + 冰糖 10g + 油 10g",
        energyRange: try! EstimateRange(low: 580, likely: 690, high: 840),
        onConfirm: {},
        onAdjust: { _ in }
    )
}
