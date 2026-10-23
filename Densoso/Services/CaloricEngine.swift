import Foundation
import CryptoKit
import DensosoDomain

/// 热量计算引擎 —— 全部纯函数，无副作用
enum CaloricEngine {

    // MARK: - 运动消耗估算

    /// MET 值查表
    static func met(for workoutType: String) -> Double {
        switch workoutType {
        case "running":  return 8.0
        case "walking":  return 4.3
        case "cycling":  return 6.0
        case "swimming": return 6.0
        case "strength": return 5.0
        case "hiit":     return 10.0
        case "yoga":     return 2.5
        default:         return 4.0
        }
    }

    /// 运动消耗 = MET × 体重(kg) × 时长(h)
    static func workoutCalories(type: String, durationMinutes: Int, weightKg: Double) -> Int {
        let hours = Double(durationMinutes) / 60.0
        return Int(round(met(for: type) * weightKg * hours))
    }

    // MARK: - 缺口

    /// 当日热量缺口（正数=减脂，负=盈余）
    static func dailyDeficit(totalExpenditure: Int, totalIntake: Int) -> Int {
        totalExpenditure - totalIntake
    }

    // MARK: - 周汇总

    struct WeeklySummary {
        let totalDeficitKcal: Int?
        let avgDailyDeficitKcal: Double?
        let projectedWeightLossKg: Double?
        let bestDay: DailyMetrics?
        let worstDay: DailyMetrics?
        let totalMeals: Int
        let totalWorkouts: Int
        let daysWithData: Int
    }

    static func weeklySummary(dailyMetrics: [DailyMetrics]) -> WeeklySummary {
        let readResults = dailyMetrics.map(DailyMetricsReadModelMapper.make)
        let aggregate = DailyMetricsUsabilityPolicy.aggregateSignedRanges(
            readResults.map(\.deficit),
            expectedDays: readResults.count
        )
        let totalDeficit = aggregate.total.value?.likely
        let validRows = zip(dailyMetrics, readResults).filter { $0.1.deficit.value != nil }
        let avgDaily = totalDeficit.flatMap { value in
            aggregate.coverage.availableDays > 0 ? value / Double(aggregate.coverage.availableDays) : nil
        }
        let projectedLoss = totalDeficit.map { $0 / 7_700 }
        let totalMeals = dailyMetrics.map(\.mealCount).reduce(0, +)
        let totalWorkouts = dailyMetrics.map(\.workoutCount).reduce(0, +)

        return WeeklySummary(
            totalDeficitKcal: totalDeficit.flatMap(boundedRoundedInteger),
            avgDailyDeficitKcal: avgDaily,
            projectedWeightLossKg: projectedLoss,
            bestDay: validRows.max {
                ($0.1.deficit.value?.likely ?? -Double.infinity) < ($1.1.deficit.value?.likely ?? -Double.infinity)
            }?.0,
            worstDay: validRows.min {
                ($0.1.deficit.value?.likely ?? Double.infinity) < ($1.1.deficit.value?.likely ?? Double.infinity)
            }?.0,
            totalMeals: totalMeals,
            totalWorkouts: totalWorkouts,
            daysWithData: aggregate.coverage.availableDays
        )
    }

    // MARK: - 目标预测

    /// 按当前日均缺口预估达到目标体重所需天数
    /// - Returns: nil 表示无法预测（目标不低于当前体重，或缺口为负）
    static func projectDaysToTarget(
        currentWeightKg: Double,
        targetWeightKg: Double,
        avgDailyDeficit: Double
    ) -> Int? {
        let deltaKg = targetWeightKg - currentWeightKg
        guard deltaKg < 0 else { return nil }
        guard avgDailyDeficit > 0 else { return nil }
        let totalDeficitNeeded = abs(deltaKg) * 7700.0
        return Int(ceil(totalDeficitNeeded / avgDailyDeficit))
    }

    // MARK: - 每日结算

    /// 根据某天的所有餐和运动，计算 DailyMetrics
    static func computeDailyMetrics(
        date: Date,
        meals: [MealRecord],
        workouts: [WorkoutRecord],
        effectiveProfile: EffectiveProfile?,
        effectiveWeight: EffectiveWeight?,
        healthKitActiveEnergyKcal: Double? = nil,
        healthKitRestingEnergyKcal: Double? = nil,
        healthKitSteps: Double? = nil,
        healthKitExerciseMinutes: Double? = nil,
        fingerprintContext: DailyMetricsProjectionFingerprintContext = .init()
    ) -> DailyMetrics {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)

        let dayMeals = meals.filter { calendar.isDate($0.date, inSameDayAs: startOfDay) }
        let dayWorkouts = workouts.filter { calendar.isDate($0.date, inSameDayAs: startOfDay) }

        let evidenceBackedMeals = dayMeals.filter(hasCurrentMealEvidence)
        let intakeRanges = evidenceBackedMeals.compactMap { meal in
            try? EstimateRange(
                low: meal.energyLowKcal,
                likely: meal.energyLikelyKcal,
                high: meal.energyHighKcal
            )
        }
        let intakeComplete = !dayMeals.isEmpty
            && evidenceBackedMeals.count == dayMeals.count
            && intakeRanges.count == dayMeals.count
            && intakeRanges.allSatisfy { $0.likely > 0 }
        // DailyMetrics still has required scalar/range columns for compatibility.
        // Keep their sentinel at zero when any meal lacks usable evidence; the
        // coverage bit is the canonical signal consumed by read models.
        let intake = intakeComplete
            ? ((try? EstimateRange.sum(intakeRanges)) ?? (try! EstimateRange.point(0)))
            : (try! EstimateRange.point(0))
        // Compatibility scalar fields are only populated from complete nutrient
        // evidence. A legacy zero mirror can mean unknown, not a measured zero.
        let proteinRanges = evidenceBackedMeals.compactMap { nutrientRange(
            low: $0.proteinLowG, likely: $0.proteinLikelyG, high: $0.proteinHighG
        ) }
        let fatRanges = evidenceBackedMeals.compactMap { nutrientRange(
            low: $0.fatLowG, likely: $0.fatLikelyG, high: $0.fatHighG
        ) }
        let carbRanges = evidenceBackedMeals.compactMap { nutrientRange(
            low: $0.carbsLowG, likely: $0.carbsLikelyG, high: $0.carbsHighG
        ) }
        let proteinComplete = !dayMeals.isEmpty
            && evidenceBackedMeals.count == dayMeals.count
            && proteinRanges.count == dayMeals.count
        let fatComplete = !dayMeals.isEmpty
            && evidenceBackedMeals.count == dayMeals.count
            && fatRanges.count == dayMeals.count
        let carbsComplete = !dayMeals.isEmpty
            && evidenceBackedMeals.count == dayMeals.count
            && carbRanges.count == dayMeals.count
        let totalProtein = proteinComplete ? proteinRanges.reduce(0) { $0 + $1.likely } : 0
        let totalFat = fatComplete ? fatRanges.reduce(0) { $0 + $1.likely } : 0
        let totalCarbs = carbsComplete ? carbRanges.reduce(0) { $0 + $1.likely } : 0

        let energyAccounting = EnergyAccounting.calculate(
            observedBasalEnergyKcal: healthKitRestingEnergyKcal,
            observedActiveEnergyKcal: healthKitActiveEnergyKcal,
            profile: effectiveProfile,
            effectiveWeightKg: effectiveWeight?.kilograms
        )
        let expenditure = energyAccounting.expenditure
        let basal = energyAccounting.basalComponent?.likely
        let active = energyAccounting.activeComponent?.likely
        let energyQuality: String
        switch expenditure?.source {
        case .some(.observed): energyQuality = "observed"
        case .some(.estimated): energyQuality = "estimated"
        case .none: energyQuality = "unavailable"
        }

        let balanceLow = expenditure.map { $0.low - intake.high } ?? 0
        let balanceLikely = expenditure.map { $0.likely - intake.likely } ?? 0
        let balanceHigh = expenditure.map { $0.high - intake.low } ?? 0
        let coverageJSON = makeCoverageJSON(
            intakePresent: intakeComplete,
            profileAvailable: effectiveProfile != nil,
            weightAvailable: effectiveWeight != nil,
            basalObserved: validEnergy(healthKitRestingEnergyKcal) != nil,
            activeObserved: validEnergy(healthKitActiveEnergyKcal) != nil,
            basalEstimated: energyAccounting.basalComponent?.source == .estimated,
            activeEstimated: energyAccounting.activeComponent?.source == .estimated,
            stepsObserved: validEnergy(healthKitSteps) != nil,
            exerciseObserved: validEnergy(healthKitExerciseMinutes) != nil,
            proteinPresent: proteinComplete,
            fatPresent: fatComplete,
            carbsPresent: carbsComplete
        )
        let fingerprint = projectionFingerprint(
            day: startOfDay,
            meals: dayMeals,
            workouts: dayWorkouts,
            profile: effectiveProfile,
            weight: effectiveWeight,
            activeEnergy: healthKitActiveEnergyKcal,
            basalEnergy: healthKitRestingEnergyKcal,
            steps: healthKitSteps,
            exerciseMinutes: healthKitExerciseMinutes,
            context: fingerprintContext
        )

        return DailyMetrics(
            date: startOfDay,
            bmrKcal: roundedInteger(basal ?? 0),
            activeCaloriesKcal: roundedInteger(active ?? 0),
            totalExpenditureKcal: roundedInteger(expenditure?.likely ?? 0),
            totalIntakeKcal: roundedInteger(intake.likely),
            deficitKcal: roundedInteger(balanceLikely),
            proteinG: totalProtein,
            fatG: totalFat,
            carbsG: totalCarbs,
            mealCount: dayMeals.count,
            workoutCount: dayWorkouts.count,
            intakeEnergyLowKcal: intake.low,
            intakeEnergyLikelyKcal: intake.likely,
            intakeEnergyHighKcal: intake.high,
            expenditureEnergyLowKcal: expenditure?.low ?? 0,
            expenditureEnergyLikelyKcal: expenditure?.likely ?? 0,
            expenditureEnergyHighKcal: expenditure?.high ?? 0,
            energyBalanceLowKcal: balanceLow,
            energyBalanceLikelyKcal: balanceLikely,
            energyBalanceHighKcal: balanceHigh,
            activeEnergyKcal: validEnergy(healthKitActiveEnergyKcal),
            basalEnergyKcal: validEnergy(healthKitRestingEnergyKcal),
            steps: validEnergy(healthKitSteps),
            exerciseMinutes: validEnergy(healthKitExerciseMinutes),
            weightKg: effectiveWeight?.kilograms,
            energyQuality: energyQuality,
            dataCoverageJSON: coverageJSON,
            projectionVersion: fingerprintContext.algorithmVersion,
            sourceFingerprint: fingerprint,
            requiresRecompute: false
        )
    }

    static func projectionFingerprint(
        day: Date,
        meals: [MealRecord],
        workouts: [WorkoutRecord],
        profile: EffectiveProfile?,
        weight: EffectiveWeight?,
        activeEnergy: Double? = nil,
        basalEnergy: Double? = nil,
        steps: Double? = nil,
        exerciseMinutes: Double? = nil,
        context: DailyMetricsProjectionFingerprintContext = .init()
    ) -> String {
        sourceFingerprint(
            day: day,
            meals: meals,
            workouts: workouts,
            profile: profile,
            weight: weight,
            activeEnergy: activeEnergy,
            basalEnergy: basalEnergy,
            steps: steps,
            exerciseMinutes: exerciseMinutes,
            context: context
        )
    }

    private static func validEnergy(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    private static func nutrientRange(
        low: Double?,
        likely: Double?,
        high: Double?
    ) -> EstimateRange? {
        guard let low, let likely, let high else { return nil }
        return try? EstimateRange(low: low, likely: likely, high: high)
    }

    private static func hasCurrentMealEvidence(_ meal: MealRecord) -> Bool {
        guard let evidenceData = meal.evidenceData,
              let evidence = try? JSONDecoder().decode([EvidenceSnapshot].self, from: evidenceData),
              !evidence.isEmpty else {
            return false
        }
        return !evidence.contains { $0.grade == .legacyPointEstimate }
    }

    private static func roundedInteger(_ value: Double) -> Int {
        guard value.isFinite, value < Double(Int.max), value > Double(Int.min) else { return 0 }
        return Int(value.rounded())
    }

    private static func boundedRoundedInteger(_ value: Double) -> Int? {
        guard value.isFinite, value < Double(Int.max), value > Double(Int.min) else { return nil }
        return Int(value.rounded())
    }

    private static func makeCoverageJSON(
        intakePresent: Bool,
        profileAvailable: Bool,
        weightAvailable: Bool,
        basalObserved: Bool,
        activeObserved: Bool,
        basalEstimated: Bool,
        activeEstimated: Bool,
        stepsObserved: Bool,
        exerciseObserved: Bool,
        proteinPresent: Bool,
        fatPresent: Bool,
        carbsPresent: Bool
    ) -> String {
        let values = [
            "intake": intakePresent,
            "profile": profileAvailable,
            "weight": weightAvailable,
            "basalEnergy": basalObserved,
            "activeEnergy": activeObserved,
            "basalEnergyEstimated": basalEstimated,
            "activeEnergyEstimated": activeEstimated,
            "steps": stepsObserved,
            "exerciseMinutes": exerciseObserved,
            "protein": proteinPresent,
            "fat": fatPresent,
            "carbs": carbsPresent,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return value
    }

    private static func sourceFingerprint(
        day: Date,
        meals: [MealRecord],
        workouts: [WorkoutRecord],
        profile: EffectiveProfile?,
        weight: EffectiveWeight?,
        activeEnergy: Double?,
        basalEnergy: Double?,
        steps: Double?,
        exerciseMinutes: Double?,
        context: DailyMetricsProjectionFingerprintContext
    ) -> String {
        let mealKeys = meals.map { meal in
            let evidenceDigest = meal.evidenceData.map { digestData($0) } ?? "none"
            return "meal:\(meal.id.uuidString.lowercased()):calories:\(meal.totalCaloriesKcal):energy:\(meal.energyLowKcal):\(meal.energyLikelyKcal):\(meal.energyHighKcal):protein:\(meal.proteinLowG ?? -1):\(meal.proteinLikelyG ?? -1):\(meal.proteinHighG ?? -1):legacy-protein:\(meal.proteinG):fat:\(meal.fatLowG ?? -1):\(meal.fatLikelyG ?? -1):\(meal.fatHighG ?? -1):legacy-fat:\(meal.fatG):carbs:\(meal.carbsLowG ?? -1):\(meal.carbsLikelyG ?? -1):\(meal.carbsHighG ?? -1):legacy-carbs:\(meal.carbsG):evidence:\(evidenceDigest)"
        }.sorted()
        let workoutKeys = workouts.map {
            "workout:\($0.id.uuidString.lowercased()):date:\($0.date.timeIntervalSince1970):type:\($0.type):duration:\($0.durationMinutes):estimated:\($0.estimatedCaloriesBurned):intensity:\($0.intensity):origin:\($0.workoutOrigin):energy-source:\($0.energySource ?? "none")"
        }.sorted()
        let material = ([
            "day:\(day.timeIntervalSince1970)",
            "profile:\(profile?.sourceRevisionID.uuidString.lowercased() ?? "none")",
            "profile-date:\(profile?.dateOfBirth.timeIntervalSince1970 ?? -1)",
            "profile-sex:\(profile?.biologicalSex.rawValue ?? "none")",
            "profile-height:\(profile?.heightCm ?? -1)",
            "profile-activity:\(profile?.activityLevel.rawValue ?? "none")",
            "weight:\(weight?.measuredAt.timeIntervalSince1970 ?? -1):\(weight?.kilograms ?? -1):\(weight?.source.rawValue ?? "none")",
            "active:\(activeEnergy ?? -1)",
            "basal:\(basalEnergy ?? -1)",
            "steps:\(steps ?? -1)",
            "exercise:\(exerciseMinutes ?? -1)",
        ] + mealKeys + workoutKeys + context.canonicalComponents).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func digestData(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
