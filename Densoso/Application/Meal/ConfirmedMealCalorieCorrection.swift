import DensosoDomain
import Foundation

enum ConfirmedMealCalorieCorrectionError: Error, Equatable {
    case invalidCorrectedValue
    case correctionOutOfRange
    case unchangedValue
}

/// A user-entered correction to a meal's energy estimate. It deliberately
/// leaves protein, fat, carbohydrate and ingredient quantities to the caller.
struct ConfirmedMealCalorieCorrection: Equatable {
    static let evidenceSourceID = "user-meal-calorie-correction"
    static let evidenceSourceVersion = "user-meal-calorie-correction-v1"

    let originalEnergy: EstimateRange
    let correctedEnergy: EstimateRange
    let factor: Double
    let timestamp: String
    let evidence: EvidenceSnapshot

    init(
        originalEnergy: EstimateRange,
        correctedLikelyKcal: Double,
        occurredAt: Date
    ) throws {
        let factor = try Self.correctionFactor(
            currentLikelyKcal: originalEnergy.likely,
            correctedLikelyKcal: correctedLikelyKcal
        )
        let correctedEnergy = try originalEnergy.scaled(by: factor)
        let timestamp = ISO8601DateFormatter().string(from: occurredAt)
        let evidence = EvidenceSnapshot(
            grade: .userReported,
            sourceID: Self.evidenceSourceID,
            sourceVersion: Self.evidenceSourceVersion,
            summary: "用户于 \(timestamp) 将 likely 热量从 \(Self.kcal(originalEnergy.likely)) kcal 更正为 \(Self.kcal(correctedEnergy.likely)) kcal；热量范围 \(Self.rangeSummary(originalEnergy)) → \(Self.rangeSummary(correctedEnergy))。本次只更正热量；蛋白质、脂肪和碳水估算未调整，因为用户未更正这些字段；菜品和食材份量保持原记录。",
            confidence: 1
        )

        self.originalEnergy = originalEnergy
        self.correctedEnergy = correctedEnergy
        self.factor = factor
        self.timestamp = timestamp
        self.evidence = evidence
    }

    static func correctionFactor(
        currentLikelyKcal: Double,
        correctedLikelyKcal: Double
    ) throws -> Double {
        guard currentLikelyKcal.isFinite,
              currentLikelyKcal > 0,
              correctedLikelyKcal.isFinite,
              correctedLikelyKcal > 0,
              correctedLikelyKcal <= 100_000 else {
            throw ConfirmedMealCalorieCorrectionError.invalidCorrectedValue
        }
        guard abs(correctedLikelyKcal - currentLikelyKcal) >= 0.5 else {
            throw ConfirmedMealCalorieCorrectionError.unchangedValue
        }
        let factor = correctedLikelyKcal / currentLikelyKcal
        guard factor.isFinite, (0.1...10).contains(factor) else {
            throw ConfirmedMealCalorieCorrectionError.correctionOutOfRange
        }
        return factor
    }

    private static func rangeSummary(_ range: EstimateRange) -> String {
        "\(kcal(range.low))–\(kcal(range.high))（likely \(kcal(range.likely))） kcal"
    }

    private static func kcal(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}
