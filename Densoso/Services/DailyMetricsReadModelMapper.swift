import DensosoDomain
import Foundation

enum DailyMetricsReadModelMapper {
    private struct NutritionCoverage: Decodable {
        let intake: Bool?
        let protein: Bool?
        let fat: Bool?
        let carbs: Bool?

        init(intake: Bool?, protein: Bool?, fat: Bool?, carbs: Bool?) {
            self.intake = intake
            self.protein = protein
            self.fat = fat
            self.carbs = carbs
        }
    }

    static func make(_ metric: DailyMetrics) -> DailyMetricsReadResult {
        let quality = EnergyQuality(rawValue: metric.energyQuality) ?? .legacy
        let hasCurrentProjectionEvidence =
            metric.projectionVersion == AlgorithmVersions.dailyMetricsProjection
                && !metric.sourceFingerprint.isEmpty
        let references = hasCurrentProjectionEvidence ? [metric.sourceFingerprint] : []
        let energyAvailability = DailyMetricsUsabilityPolicy.energyAvailability(
            quality: quality,
            requiresRecompute: metric.requiresRecompute,
            hasCurrentProjectionEvidence: hasCurrentProjectionEvidence
        )
        let expenditureRange = try? EstimateRange(
            low: metric.expenditureEnergyLowKcal,
            likely: metric.expenditureEnergyLikelyKcal,
            high: metric.expenditureEnergyHighKcal
        )
        let intakeRange = try? EstimateRange(
            low: metric.intakeEnergyLowKcal,
            likely: metric.intakeEnergyLikelyKcal,
            high: metric.intakeEnergyHighKcal
        )
        let expenditure = DailyMetricsUsabilityPolicy.value(
            expenditureRange,
            availability: energyAvailability,
            hasEvidence: hasCurrentProjectionEvidence,
            sourceReferences: references
        )
        let nutrition = decodeNutritionCoverage(metric.dataCoverageJSON)
        let intake = DailyMetricsUsabilityPolicy.value(
            intakeRange,
            availability: metric.requiresRecompute ? .pendingRecompute : .estimated,
            hasEvidence: hasCurrentProjectionEvidence && metric.mealCount > 0 && nutrition.intake == true,
            sourceReferences: references
        )
        let deficit = DailyMetricsUsabilityPolicy.deficit(expenditure: expenditure, intake: intake)

        let protein = DailyMetricsUsabilityPolicy.value(
            finiteNonNegative(metric.proteinG),
            availability: .estimated,
            hasEvidence: hasCurrentProjectionEvidence && nutrition.protein == true,
            sourceReferences: references
        )
        let fat = DailyMetricsUsabilityPolicy.value(
            finiteNonNegative(metric.fatG),
            availability: .estimated,
            hasEvidence: hasCurrentProjectionEvidence && nutrition.fat == true,
            sourceReferences: references
        )
        let carbs = DailyMetricsUsabilityPolicy.value(
            finiteNonNegative(metric.carbsG),
            availability: .estimated,
            hasEvidence: hasCurrentProjectionEvidence && nutrition.carbs == true,
            sourceReferences: references
        )

        return DailyMetricsReadResult(
            date: metric.date,
            intake: intake,
            expenditure: expenditure,
            deficit: deficit,
            proteinG: protein,
            fatG: fat,
            carbsG: carbs,
            energyQuality: quality,
            requiresRecompute: metric.requiresRecompute,
            coverage: DailyMetricCoverage(
                intake: coverage(intake),
                expenditure: coverage(expenditure),
                deficit: coverage(deficit),
                proteinG: coverage(protein),
                fatG: coverage(fat),
                carbsG: coverage(carbs)
            ),
            projectionVersion: metric.projectionVersion,
            sourceFingerprint: metric.sourceFingerprint,
            mealCount: metric.mealCount,
            workoutCount: metric.workoutCount
        )
    }

    private static func decodeNutritionCoverage(_ json: String) -> NutritionCoverage {
        guard let data = json.data(using: .utf8),
              let coverage = try? JSONDecoder().decode(NutritionCoverage.self, from: data) else {
            return NutritionCoverage(intake: false, protein: false, fat: false, carbs: false)
        }
        return coverage
    }

    private static func finiteNonNegative(_ value: Double) -> Double? {
        value.isFinite && value >= 0 ? value : nil
    }

    private static func coverage<Value: Codable & Equatable & Sendable>(
        _ value: MetricValue<Value>
    ) -> MetricCoverage {
        MetricCoverage(availability: [value.availability], expectedDays: 1)
    }
}
