import SwiftUI
import DensosoDomain

struct MealCalorieSummaryPresentation: Equatable {
    let likelyText: String
    let confidence: CalorieConfidence
    let confidenceText: String
    let detailsTitle: String
    let rangeDetailsText: String

    init(energyRange: EstimateRange) {
        let presentation = CaloriePresentationPolicy().presentation(for: energyRange)
        likelyText = "约 \(presentation.likelyKcal) kcal"
        confidence = presentation.confidence
        confidenceText = "估算可信度：\(presentation.confidence.displayName)"
        detailsTitle = "估算区间详情"
        rangeDetailsText = "热量范围：\(Int(energyRange.low.rounded()))–\(Int(energyRange.high.rounded())) kcal"
    }
}

/// Presents persisted meal energy without treating V2's default zero as a
/// measured or estimated value. Positive legacy point estimates remain visible
/// as historical estimates; zero requires non-legacy, resolved evidence.
struct MealRecordEnergyPresentation: Equatable {
    let label: String
    let isAvailable: Bool

    init(totalCaloriesKcal: Int, evidenceData: Data?) {
        guard totalCaloriesKcal >= 0 else {
            label = "热量不可用"
            isAvailable = false
            return
        }
        guard totalCaloriesKcal == 0 else {
            label = "\(totalCaloriesKcal) kcal"
            isAvailable = true
            return
        }

        let evidence = evidenceData.flatMap {
            try? JSONDecoder().decode([EvidenceSnapshot].self, from: $0)
        } ?? []
        let hasCurrentZeroEvidence = MealEnergyAvailabilityPolicy.supportsExplicitZero(evidence)
        label = hasCurrentZeroEvidence ? "0 kcal" : "热量不可用"
        isAvailable = hasCurrentZeroEvidence
    }
}

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

            if let calorieSummary {
                Text(calorieSummary.likelyText)
                    .font(.title3.weight(.semibold))
                Text(calorieSummary.confidenceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("基于当前份量调整后的估算范围")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(calorieSummary.rangeDetailsText)
                            .font(.subheadline)
                    }
                } label: {
                    Text(calorieSummary.detailsTitle)
                        .font(.subheadline)
                }
                .accessibilityIdentifier("food-calorie-estimate-details")
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
        let confidence = calorieSummary?.confidence ?? .low
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

    private var calorieSummary: MealCalorieSummaryPresentation? {
        adjustedEnergyRange.map { MealCalorieSummaryPresentation(energyRange: $0) }
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
                    let presentation = MealCalorieSummaryPresentation(energyRange: energyRange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(presentation.likelyText)
                            .font(.title3.weight(.semibold))
                        Text(presentation.confidenceText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pending-meal-calorie-summary")
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
                                        if let correction = MealPortionPriorCorrection.correction(from: evidence) {
                                            Text("确认后保存个人份量先验：\(correction.unitCount.formatted(.number.precision(.fractionLength(0...2)))) \(MealPortionPriorPresentation.unitLabel(correction.unit)) ≈ \(Int(correction.totalGrams.rounded()))g")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        } else if let usage = MealPortionPriorUsage.usage(from: evidence) {
                                            Text("估算采用个人份量先验：\(usage.count.formatted(.number.precision(.fractionLength(0...2)))) \(MealPortionPriorPresentation.unitLabel(usage.unit))（每单位 \(Int(usage.p10Grams.rounded()))–\(Int(usage.p90Grams.rounded()))g，中值 \(Int(usage.p50Grams.rounded()))g）")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        } else if let usage = PersonalMealDishPriorUsage.usage(from: evidence) {
                                            let dishName = Self.safePriorName(usage.dishName)
                                            let ingredientName = Self.safePriorName(usage.ingredientName)
                                            let provenance = usage.isUserManaged
                                                ? "用户管理的模板"
                                                : "来自 \(usage.observationCount) 次已确认餐食"
                                            Text("估算采用个人菜品先验：\(dishName) · \(ingredientName) \(Int(usage.lowGrams.rounded()))–\(Int(usage.highGrams.rounded()))g（likely \(Int(usage.likelyGrams.rounded()))g；\(provenance)）")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        } else if evidence.sourceID == MealPortionPriorCorrection.evidenceSourceID
                                            || evidence.sourceID == MealPortionPriorUsage.evidenceSourceID {
                                            Text("无法验证的份量先验")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        } else if evidence.sourceID == PersonalMealDishPriorUsage.evidenceSourceID {
                                            Text("无法验证的菜品份量先验")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("\(evidence.grade.rawValue)：\(evidence.summary)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                    .accessibilityIdentifier("pending-meal-estimate-details")
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

    private static func safePriorName(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "未知名称" }
        return String(normalized.prefix(80))
    }
}

/// Shows an already-confirmed meal in Today and lets the user explicitly
/// correct its likely energy. The parent persists edits through
/// `HealthRepository.update(_:)`, keeping projection and HealthKit outbox work
/// in the existing repository transaction.
struct TodayConfirmedMealCard: View {
    let meal: MealRecord
    let isSaving: Bool
    let errorMessage: String?
    let onSaveCorrection: (Double) -> Void

    @State private var correctedLikelyText: String

    init(
        meal: MealRecord,
        isSaving: Bool,
        errorMessage: String?,
        onSaveCorrection: @escaping (Double) -> Void
    ) {
        self.meal = meal
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.onSaveCorrection = onSaveCorrection
        _correctedLikelyText = State(initialValue: Self.kcalText(meal.energyLikelyKcal))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(mealTypeLabel)
                    .font(.headline)
                Spacer()
                Text(meal.date, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(meal.dishes.map(\.dishName).joined(separator: "、"))
                .font(.subheadline)
                .lineLimit(2)

            if let presentation {
                HStack(spacing: 8) {
                    Text(presentation.likelyText)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text(presentation.confidenceText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("today-confirmed-meal-calories")
            } else {
                Text("热量估算暂不可用")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(MealRecordAuditPresentation.summary(
                evidenceData: meal.evidenceData,
                algorithmVersion: meal.algorithmVersion
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            if let sourceVersions = MealRecordAuditPresentation.sourceVersionSummary(
                evidenceData: meal.evidenceData
            ) {
                Text(sourceVersions)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .accessibilityIdentifier("today-confirmed-meal-source-versions")
            }

            if let correctionSummary {
                Label(correctionSummary, systemImage: "pencil.line")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("today-meal-correction-evidence")
            }

            if energyRange != nil {
                Divider()

                Text("仅更正这餐的 likely kcal")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 10) {
                    TextField("更正后的 kcal", text: $correctedLikelyText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("today-meal-corrected-kcal-input")
                    Button("保存修正") {
                        guard let value = parsedCorrectedLikely else { return }
                        onSaveCorrection(value)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || !canSaveCorrection)
                    .accessibilityIdentifier("today-meal-save-correction")
                }
                if canSaveCorrection,
                   let parsedCorrectedLikely,
                   let factor = try? ConfirmedMealCalorieCorrection.correctionFactor(
                        currentLikelyKcal: meal.energyLikelyKcal,
                        correctedLikelyKcal: parsedCorrectedLikely
                   ) {
                    Text("复核热量：\(Self.kcalText(meal.energyLikelyKcal)) → \(Self.kcalText(parsedCorrectedLikely)) kcal（热量范围 ×\(factor.formatted(.number.precision(.fractionLength(2))))）；蛋白质、脂肪、碳水和食材份量保持原记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("today-meal-correction-preview")
                }
                Text("保存后只更新热量估算范围。蛋白质、脂肪、碳水、菜品和食材份量保持原记录；更正前后的热量与时间会追加为证据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("旧记录的热量来源无法确认，不能以默认 0 kcal 作为修正基准。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isSaving {
                Label("正在保存并更新今日汇总", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(OrbitPalette.coral)
                    .accessibilityIdentifier("today-meal-correction-error")
            }
        }
        .orbitCard()
        .onChange(of: meal.energyLikelyKcal) { _, newValue in
            correctedLikelyText = Self.kcalText(newValue)
        }
        .accessibilityIdentifier("today-confirmed-meal-card")
    }

    private var mealTypeLabel: String {
        switch meal.mealType {
        case "breakfast": "早餐"
        case "lunch": "午餐"
        case "dinner": "晚餐"
        case "snack": "加餐"
        default: "餐食"
        }
    }

    private var energyRange: EstimateRange? {
        guard MealRecordEnergyPresentation(
            totalCaloriesKcal: meal.totalCaloriesKcal,
            evidenceData: meal.evidenceData
        ).isAvailable else { return nil }
        return try? EstimateRange(
            low: meal.energyLowKcal,
            likely: meal.energyLikelyKcal,
            high: meal.energyHighKcal
        )
    }

    private var presentation: MealCalorieSummaryPresentation? {
        energyRange.map { MealCalorieSummaryPresentation(energyRange: $0) }
    }

    private var correctionSummary: String? {
        guard let data = meal.evidenceData,
              let evidence = try? JSONDecoder().decode([EvidenceSnapshot].self, from: data),
              let correction = evidence.last(where: { $0.sourceID == "user-meal-calorie-correction" }) else {
            return nil
        }
        return correction.summary
    }

    private var parsedCorrectedLikely: Double? {
        guard let value = Double(correctedLikelyText.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite else { return nil }
        return value
    }

    private var canSaveCorrection: Bool {
        guard let parsedCorrectedLikely,
              let energyRange else { return false }
        return (try? ConfirmedMealCalorieCorrection.correctionFactor(
            currentLikelyKcal: energyRange.likely,
            correctedLikelyKcal: parsedCorrectedLikely
        )) != nil
    }

    private static func kcalText(_ value: Double) -> String {
        String(format: "%.0f", value)
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
