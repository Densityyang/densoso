/// Persisted identifiers for deterministic algorithms and generated summaries.
/// Keep these values centralized so cache and projection invalidation can share them.
public enum AlgorithmVersions {
    public static let calorieAccounting = "calorie-accounting-v2"
    public static let dailyMetricsProjection = "daily-metrics-projection-v1"
    public static let mealEstimator = "meal-estimator-v2"
    public static let portionEstimator = "portion-estimator-v2"
    public static let healthIntelligence = "health-intelligence-v2"
    public static let recommendationPolicy = "recommendation-policy-v1"
    public static let dailyLoop = "daily-loop-v1"
}
