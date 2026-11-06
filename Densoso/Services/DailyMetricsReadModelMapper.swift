import DensosoDomain
import Foundation

enum DailyMetricsReadModelMapper {
    private struct NutritionCoverage: Decodable {
        let intake: Bool?
        let allRecordedMealsHaveEvidence: Bool?
        let protein: Bool?
        let proteinComplete: Bool?
        let fat: Bool?
        let fatComplete: Bool?
        let carbs: Bool?
        let carbsComplete: Bool?

        init(
            intake: Bool?,
            allRecordedMealsHaveEvidence: Bool?,
            protein: Bool?,
            proteinComplete: Bool?,
            fat: Bool?,
            fatComplete: Bool?,
            carbs: Bool?,
            carbsComplete: Bool?
        ) {
            self.intake = intake
            self.allRecordedMealsHaveEvidence = allRecordedMealsHaveEvidence
            self.protein = protein
            self.proteinComplete = proteinComplete
            self.fat = fat
            self.fatComplete = fatComplete
            self.carbs = carbs
            self.carbsComplete = carbsComplete
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
        let nutritionRecordStatus = metric.requiresRecompute
            ? NutritionDayRecordStatus.unknown
            : nutritionDayRecordStatus(from: metric.dataCoverageJSON)
        let lastMealRecordedAt = coverageObject(from: metric.dataCoverageJSON)?["nutritionLastMealRecordedAt"] as? NSNumber
        let lastMealDate = lastMealRecordedAt.flatMap { timestamp in
            timestamp.doubleValue.isFinite ? Date(timeIntervalSince1970: timestamp.doubleValue) : nil
        }
        let explicitlyConfirmedEmptyDay = nutritionRecordStatus == .complete && metric.mealCount == 0
        let intakeAvailability = nutritionEstimateAvailability(
            hasEstimate: nutrition.intake == true,
            allMealsHaveEstimate: nutrition.allRecordedMealsHaveEvidence,
            recordStatus: nutritionRecordStatus,
            requiresRecompute: metric.requiresRecompute,
            explicitlyConfirmedEmptyDay: explicitlyConfirmedEmptyDay
        )
        let intake = DailyMetricsUsabilityPolicy.value(
            intakeRange,
            availability: intakeAvailability,
            hasEvidence: hasCurrentProjectionEvidence
                && ((metric.mealCount > 0 && nutrition.intake == true) || explicitlyConfirmedEmptyDay),
            sourceReferences: references
        )
        let calculatedDeficit = DailyMetricsUsabilityPolicy.deficit(expenditure: expenditure, intake: intake)
        let deficit = nutritionRecordStatus == .complete
            && (intake.availability == .observed || intake.availability == .estimated)
            ? calculatedDeficit
            : MetricValue<SignedEstimateRange>(
                value: nil,
                availability: metric.requiresRecompute ? .pendingRecompute : .unavailable
            )
        let proteinAvailability = nutritionEstimateAvailability(
            hasEstimate: nutrition.protein == true,
            allMealsHaveEstimate: nutrition.proteinComplete,
            recordStatus: nutritionRecordStatus,
            requiresRecompute: metric.requiresRecompute,
            explicitlyConfirmedEmptyDay: explicitlyConfirmedEmptyDay
        )
        let fatAvailability = nutritionEstimateAvailability(
            hasEstimate: nutrition.fat == true,
            allMealsHaveEstimate: nutrition.fatComplete,
            recordStatus: nutritionRecordStatus,
            requiresRecompute: metric.requiresRecompute,
            explicitlyConfirmedEmptyDay: explicitlyConfirmedEmptyDay
        )
        let carbsAvailability = nutritionEstimateAvailability(
            hasEstimate: nutrition.carbs == true,
            allMealsHaveEstimate: nutrition.carbsComplete,
            recordStatus: nutritionRecordStatus,
            requiresRecompute: metric.requiresRecompute,
            explicitlyConfirmedEmptyDay: explicitlyConfirmedEmptyDay
        )

        let protein = DailyMetricsUsabilityPolicy.value(
            finiteNonNegative(metric.proteinG),
            availability: proteinAvailability,
            hasEvidence: hasCurrentProjectionEvidence && (nutrition.protein == true || explicitlyConfirmedEmptyDay),
            sourceReferences: references
        )
        let fat = DailyMetricsUsabilityPolicy.value(
            finiteNonNegative(metric.fatG),
            availability: fatAvailability,
            hasEvidence: hasCurrentProjectionEvidence && (nutrition.fat == true || explicitlyConfirmedEmptyDay),
            sourceReferences: references
        )
        let carbs = DailyMetricsUsabilityPolicy.value(
            finiteNonNegative(metric.carbsG),
            availability: carbsAvailability,
            hasEvidence: hasCurrentProjectionEvidence && (nutrition.carbs == true || explicitlyConfirmedEmptyDay),
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
            workoutCount: metric.workoutCount,
            nutritionRecordStatus: nutritionRecordStatus,
            lastMealRecordedAt: lastMealDate,
            allRecordedMealsHaveEvidence: metric.requiresRecompute
                ? nil
                : nutrition.allRecordedMealsHaveEvidence
        )
    }

    private static func nutritionEstimateAvailability(
        hasEstimate: Bool,
        allMealsHaveEstimate: Bool?,
        recordStatus: NutritionDayRecordStatus,
        requiresRecompute: Bool,
        explicitlyConfirmedEmptyDay: Bool
    ) -> MetricAvailability {
        if requiresRecompute { return .pendingRecompute }
        if explicitlyConfirmedEmptyDay { return .estimated }
        guard hasEstimate else { return .unavailable }
        return recordStatus == .complete && allMealsHaveEstimate == true ? .estimated : .partial
    }

    static func nutritionDayRecordStatus(from json: String) -> NutritionDayRecordStatus {
        guard let object = coverageObject(from: json),
              let rawValue = object["nutritionRecordStatus"] as? String,
              let status = NutritionDayRecordStatus(rawValue: rawValue) else {
            return .unknown
        }
        guard status == .complete else { return status }
        guard let mealFingerprint = object["nutritionMealFingerprint"] as? String,
              !mealFingerprint.isEmpty,
              object["nutritionCompletionMealFingerprint"] as? String == mealFingerprint else {
            return .unknown
        }
        return .complete
    }

    /// Persists an explicit user decision beside the derived coverage fields.
    /// A complete state is accepted only when it can be bound to the current meal set.
    @discardableResult
    static func setNutritionDayRecordStatus(
        _ status: NutritionDayRecordStatus,
        for metric: DailyMetrics
    ) -> Bool {
        guard !metric.requiresRecompute,
              metric.projectionVersion == AlgorithmVersions.dailyMetricsProjection,
              !metric.sourceFingerprint.isEmpty else { return false }
        guard var object = coverageObject(from: metric.dataCoverageJSON) else { return false }
        if status == .complete {
            guard let fingerprint = object["nutritionMealFingerprint"] as? String,
                  !fingerprint.isEmpty else { return false }
            object["nutritionCompletionMealFingerprint"] = fingerprint
        } else {
            object.removeValue(forKey: "nutritionCompletionMealFingerprint")
        }
        object["nutritionRecordStatus"] = status.rawValue
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else {
            return false
        }
        metric.dataCoverageJSON = encoded
        return true
    }

    static func hasNutritionMealFingerprint(for metric: DailyMetrics) -> Bool {
        guard !metric.requiresRecompute,
              metric.projectionVersion == AlgorithmVersions.dailyMetricsProjection,
              !metric.sourceFingerprint.isEmpty,
              let object = coverageObject(from: metric.dataCoverageJSON),
              let fingerprint = object["nutritionMealFingerprint"] as? String else {
            return false
        }
        return !fingerprint.isEmpty
    }

    /// Carries an explicit completion across a projection only while the meal set
    /// still matches the meal fingerprint that was confirmed by the user.
    static func preservingNutritionRecordStatus(
        projectedJSON: String,
        existingJSON: String
    ) -> String {
        guard var projected = coverageObject(from: projectedJSON) else { return projectedJSON }
        let existing = coverageObject(from: existingJSON) ?? [:]
        let existingStatus = (existing["nutritionRecordStatus"] as? String)
            .flatMap(NutritionDayRecordStatus.init(rawValue:)) ?? .unknown
        let completionFingerprint = existing["nutritionCompletionMealFingerprint"] as? String
        let projectedFingerprint = projected["nutritionMealFingerprint"] as? String
        if existingStatus == .complete,
           let completionFingerprint,
           !completionFingerprint.isEmpty,
           completionFingerprint == projectedFingerprint {
            projected["nutritionRecordStatus"] = NutritionDayRecordStatus.complete.rawValue
            projected["nutritionCompletionMealFingerprint"] = completionFingerprint
        } else {
            projected.removeValue(forKey: "nutritionCompletionMealFingerprint")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: projected, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else {
            return projectedJSON
        }
        return encoded
    }

    private static func decodeNutritionCoverage(_ json: String) -> NutritionCoverage {
        guard let data = json.data(using: .utf8),
              let coverage = try? JSONDecoder().decode(NutritionCoverage.self, from: data) else {
            return NutritionCoverage(
                intake: false,
                allRecordedMealsHaveEvidence: nil,
                protein: false,
                proteinComplete: nil,
                fat: false,
                fatComplete: nil,
                carbs: false,
                carbsComplete: nil
            )
        }
        return coverage
    }

    private static func coverageObject(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
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
