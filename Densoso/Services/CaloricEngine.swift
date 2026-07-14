import Foundation

/// 热量计算引擎 —— 全部纯函数，无副作用
enum CaloricEngine {

    // MARK: - BMR

    /// Mifflin-St Jeor 方程
    /// - Parameters:
    ///   - sex: "male" 或 "female"
    ///   - weightKg: 体重 (kg)
    ///   - heightCm: 身高 (cm)
    ///   - age: 年龄 (岁)
    /// - Returns: BMR (kcal/day)
    static func bmr(sex: String, weightKg: Double, heightCm: Double, age: Int) -> Int {
        let base = 10.0 * weightKg + 6.25 * heightCm - 5.0 * Double(age)
        let result = sex == "male" ? base + 5.0 : base - 161.0
        return Int(round(result))
    }

    // MARK: - TDEE

    /// TDEE = BMR × 活动系数
    static func tdee(bmr: Int, activityLevel: String) -> Int {
        let multiplier: Double
        switch activityLevel {
        case "sedentary":  multiplier = 1.2
        case "light":      multiplier = 1.375
        case "moderate":   multiplier = 1.55
        case "active":     multiplier = 1.725
        case "veryActive": multiplier = 1.9
        default:           multiplier = 1.2
        }
        return Int(round(Double(bmr) * multiplier))
    }

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
        let totalDeficitKcal: Int
        let avgDailyDeficitKcal: Double
        let projectedWeightLossKg: Double
        let bestDay: DailyMetrics?
        let worstDay: DailyMetrics?
        let totalMeals: Int
        let totalWorkouts: Int
        let daysWithData: Int
    }

    static func weeklySummary(dailyMetrics: [DailyMetrics]) -> WeeklySummary {
        let totalDeficit = dailyMetrics.map(\.deficitKcal).reduce(0, +)
        let days = max(dailyMetrics.count, 1)
        let avgDaily = Double(totalDeficit) / Double(days)
        let projectedLoss = Double(totalDeficit) / 7700.0
        let best = dailyMetrics.max(by: { $0.deficitKcal < $1.deficitKcal })
        let worst = dailyMetrics.min(by: { $0.deficitKcal < $1.deficitKcal })
        let totalMeals = dailyMetrics.map(\.mealCount).reduce(0, +)
        let totalWorkouts = dailyMetrics.map(\.workoutCount).reduce(0, +)

        return WeeklySummary(
            totalDeficitKcal: totalDeficit,
            avgDailyDeficitKcal: avgDaily,
            projectedWeightLossKg: projectedLoss,
            bestDay: best,
            worstDay: worst,
            totalMeals: totalMeals,
            totalWorkouts: totalWorkouts,
            daysWithData: dailyMetrics.count
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
        userProfile: UserProfile
    ) -> DailyMetrics {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let age = calendar.dateComponents([.year], from: userProfile.dateOfBirth, to: Date()).year ?? 30

        let bmrValue = bmr(
            sex: userProfile.biologicalSex,
            weightKg: userProfile.weightKg,
            heightCm: userProfile.heightCm,
            age: age
        )

        let dayMeals = meals.filter { calendar.isDate($0.date, inSameDayAs: startOfDay) }
        let dayWorkouts = workouts.filter { calendar.isDate($0.date, inSameDayAs: startOfDay) }

        let totalIntake = dayMeals.map(\.totalCaloriesKcal).reduce(0, +)
        let totalProtein = dayMeals.map(\.proteinG).reduce(0, +)
        let totalFat = dayMeals.map(\.fatG).reduce(0, +)
        let totalCarbs = dayMeals.map(\.carbsG).reduce(0, +)

        // v1: 活动消耗 = 用户自报运动消耗之和
        //     如果当天没运动，用 TDEE 的 activity 部分粗略估算
        let activeCal: Int
        if !dayWorkouts.isEmpty {
            activeCal = dayWorkouts.map(\.estimatedCaloriesBurned).reduce(0, +)
        } else {
            // 兜底：TDEE - BMR 作为活动消耗的粗略值
            activeCal = tdee(bmr: bmrValue, activityLevel: userProfile.activityLevel) - bmrValue
        }

        let totalExpenditure = bmrValue + activeCal
        let deficit = dailyDeficit(totalExpenditure: totalExpenditure, totalIntake: totalIntake)

        return DailyMetrics(
            date: startOfDay,
            bmrKcal: bmrValue,
            activeCaloriesKcal: activeCal,
            totalExpenditureKcal: totalExpenditure,
            totalIntakeKcal: totalIntake,
            deficitKcal: deficit,
            proteinG: totalProtein,
            fatG: totalFat,
            carbsG: totalCarbs,
            mealCount: dayMeals.count,
            workoutCount: dayWorkouts.count
        )
    }
}