import Foundation

private enum MetricValueLimits {
    static let sourceReferences = 8
    static let aggregateSourceReferences = 2
}

public enum MetricAvailability: String, Codable, CaseIterable, Sendable {
    case observed
    case estimated
    case partial
    case unavailable
    case pendingRecompute
}

public enum EnergyQuality: String, Codable, CaseIterable, Sendable {
    case observed
    case estimated
    case unavailable
    case legacy
}

public struct MetricValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let value: Value?
    public let availability: MetricAvailability
    public let sourceReferences: [String]
    public let sourceReferencesTruncated: Bool

    public init(
        value: Value?,
        availability: MetricAvailability,
        sourceReferences: [String] = [],
        sourceReferencesTruncated: Bool = false
    ) {
        self.value = value
        self.availability = availability
        let uniqueReferences = Array(Set(sourceReferences)).sorted()
        self.sourceReferences = Array(uniqueReferences.prefix(MetricValueLimits.sourceReferences))
        self.sourceReferencesTruncated = sourceReferencesTruncated
            || uniqueReferences.count > MetricValueLimits.sourceReferences
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case availability
        case sourceReferences
        case sourceReferencesTruncated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let value {
            try container.encode(value, forKey: .value)
        } else {
            try container.encodeNil(forKey: .value)
        }
        try container.encode(availability, forKey: .availability)
        try container.encode(sourceReferences, forKey: .sourceReferences)
        try container.encode(sourceReferencesTruncated, forKey: .sourceReferencesTruncated)
    }
}

public struct SignedEstimateRange: Codable, Equatable, Sendable {
    public let low: Double
    public let likely: Double
    public let high: Double

    public init(low: Double, likely: Double, high: Double) throws {
        guard low.isFinite, likely.isFinite, high.isFinite else {
            throw EstimateRangeError.nonFinite
        }
        guard low <= likely, likely <= high else {
            throw EstimateRangeError.unordered
        }
        self.low = low
        self.likely = likely
        self.high = high
    }

    public static func subtract(_ lhs: EstimateRange, _ rhs: EstimateRange) -> SignedEstimateRange? {
        try? SignedEstimateRange(
            low: lhs.low - rhs.high,
            likely: lhs.likely - rhs.likely,
            high: lhs.high - rhs.low
        )
    }

    public static func sum(_ values: [SignedEstimateRange]) -> SignedEstimateRange? {
        guard !values.isEmpty else { return nil }
        return try? SignedEstimateRange(
            low: values.reduce(0) { $0 + $1.low },
            likely: values.reduce(0) { $0 + $1.likely },
            high: values.reduce(0) { $0 + $1.high }
        )
    }

    public func divided(by divisor: Int) -> SignedEstimateRange? {
        guard divisor > 0 else { return nil }
        let count = Double(divisor)
        return try? SignedEstimateRange(low: low / count, likely: likely / count, high: high / count)
    }

    private enum CodingKeys: String, CodingKey {
        case low
        case likely
        case high
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                low: container.decode(Double.self, forKey: .low),
                likely: container.decode(Double.self, forKey: .likely),
                high: container.decode(Double.self, forKey: .high)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .low,
                in: container,
                debugDescription: "Signed energy values must be finite and ordered."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(low, forKey: .low)
        try container.encode(likely, forKey: .likely)
        try container.encode(high, forKey: .high)
    }
}

public struct MetricCoverage: Codable, Equatable, Sendable {
    public let expectedDays: Int
    public let observedDays: Int
    public let estimatedDays: Int
    public let partialDays: Int
    public let unavailableDays: Int
    public let pendingRecomputeDays: Int
    public let missingDays: Int
    public let availableDays: Int
    public let coverageFraction: Double?

    public init(availability: [MetricAvailability], expectedDays: Int) {
        let expected = max(expectedDays, 0)
        self.expectedDays = expected
        observedDays = availability.filter { $0 == .observed }.count
        estimatedDays = availability.filter { $0 == .estimated }.count
        partialDays = availability.filter { $0 == .partial }.count
        unavailableDays = availability.filter { $0 == .unavailable }.count
        pendingRecomputeDays = availability.filter { $0 == .pendingRecompute }.count
        missingDays = max(expected - availability.count, 0)
        let available = observedDays + estimatedDays + partialDays
        availableDays = available
        coverageFraction = expected > 0 ? min(Double(available) / Double(expected), 1) : nil
    }

    public var fraction: Double? { coverageFraction }
}

public struct DailyMetricCoverage: Codable, Equatable, Sendable {
    public let intake: MetricCoverage
    public let expenditure: MetricCoverage
    public let deficit: MetricCoverage
    public let proteinG: MetricCoverage
    public let fatG: MetricCoverage
    public let carbsG: MetricCoverage

    public init(
        intake: MetricCoverage,
        expenditure: MetricCoverage,
        deficit: MetricCoverage,
        proteinG: MetricCoverage,
        fatG: MetricCoverage,
        carbsG: MetricCoverage
    ) {
        self.intake = intake
        self.expenditure = expenditure
        self.deficit = deficit
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
    }
}

public struct DailyMetricsReadResult: Codable, Equatable, Sendable {
    public let date: Date
    public let intake: MetricValue<EstimateRange>
    public let expenditure: MetricValue<EstimateRange>
    public let deficit: MetricValue<SignedEstimateRange>
    public let proteinG: MetricValue<Double>
    public let fatG: MetricValue<Double>
    public let carbsG: MetricValue<Double>
    public let energyQuality: EnergyQuality
    public let requiresRecompute: Bool
    public let coverage: DailyMetricCoverage
    public let projectionVersion: String
    public let sourceFingerprint: String
    public let mealCount: Int
    public let workoutCount: Int

    public init(
        date: Date,
        intake: MetricValue<EstimateRange>,
        expenditure: MetricValue<EstimateRange>,
        deficit: MetricValue<SignedEstimateRange>,
        proteinG: MetricValue<Double>,
        fatG: MetricValue<Double>,
        carbsG: MetricValue<Double>,
        energyQuality: EnergyQuality,
        requiresRecompute: Bool,
        coverage: DailyMetricCoverage,
        projectionVersion: String,
        sourceFingerprint: String,
        mealCount: Int,
        workoutCount: Int
    ) {
        self.date = date
        self.intake = intake
        self.expenditure = expenditure
        self.deficit = deficit
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
        self.energyQuality = energyQuality
        self.requiresRecompute = requiresRecompute
        self.coverage = coverage
        self.projectionVersion = projectionVersion
        self.sourceFingerprint = sourceFingerprint
        self.mealCount = max(mealCount, 0)
        self.workoutCount = max(workoutCount, 0)
    }
}

public struct MetricAggregate<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let total: MetricValue<Value>
    public let coverage: MetricCoverage

    public init(total: MetricValue<Value>, coverage: MetricCoverage) {
        self.total = total
        self.coverage = coverage
    }
}

public enum DailyMetricsUsabilityPolicy {
    public static func energyAvailability(
        quality: EnergyQuality,
        requiresRecompute: Bool,
        hasCurrentProjectionEvidence: Bool
    ) -> MetricAvailability {
        if requiresRecompute { return .pendingRecompute }
        guard hasCurrentProjectionEvidence else { return .unavailable }
        switch quality {
        case .observed: return .observed
        case .estimated: return .estimated
        case .unavailable, .legacy: return .unavailable
        }
    }

    public static func value<Value: Codable & Equatable & Sendable>(
        _ value: Value?,
        availability: MetricAvailability,
        hasEvidence: Bool,
        sourceReferences: [String] = []
    ) -> MetricValue<Value> {
        guard let value, hasEvidence else {
            return MetricValue(value: nil, availability: availability == .pendingRecompute ? .pendingRecompute : .unavailable)
        }
        guard availability == .observed || availability == .estimated || availability == .partial else {
            return MetricValue(value: nil, availability: availability)
        }
        return MetricValue(value: value, availability: availability, sourceReferences: sourceReferences)
    }

    public static func deficit(
        expenditure: MetricValue<EstimateRange>,
        intake: MetricValue<EstimateRange>
    ) -> MetricValue<SignedEstimateRange> {
        guard let expenditureValue = expenditure.value,
              let intakeValue = intake.value,
              let range = SignedEstimateRange.subtract(expenditureValue, intakeValue) else {
            let availability: MetricAvailability =
                expenditure.availability == .pendingRecompute || intake.availability == .pendingRecompute
                ? .pendingRecompute
                : .unavailable
            return MetricValue(value: nil, availability: availability)
        }
        let availability = combinedAvailability(expenditure.availability, intake.availability)
        return MetricValue(
            value: range,
            availability: availability,
            sourceReferences: expenditure.sourceReferences + intake.sourceReferences,
            sourceReferencesTruncated: expenditure.sourceReferencesTruncated || intake.sourceReferencesTruncated
        )
    }

    public static func aggregateRanges(
        _ metrics: [MetricValue<EstimateRange>],
        expectedDays: Int
    ) -> MetricAggregate<EstimateRange> {
        let valid = metrics.filter { isUsable($0.availability) && $0.value != nil }
        let coverage = MetricCoverage(
            availability: metrics.map { normalizedAvailability($0, hasValidValue: $0.value != nil) },
            expectedDays: expectedDays
        )
        guard let total = try? EstimateRange.sum(valid.compactMap(\.value)), !valid.isEmpty else {
            return MetricAggregate(
                total: MetricValue(value: nil, availability: emptyAggregateAvailability(metrics)),
                coverage: coverage
            )
        }
        return MetricAggregate(
            total: MetricValue(
                value: total,
                availability: aggregateAvailability(metrics, coverage: coverage),
                sourceReferences: aggregateSourceReferences(valid),
                sourceReferencesTruncated: aggregateSourcesTruncated(valid)
            ),
            coverage: coverage
        )
    }

    public static func aggregateSignedRanges(
        _ metrics: [MetricValue<SignedEstimateRange>],
        expectedDays: Int
    ) -> MetricAggregate<SignedEstimateRange> {
        let valid = metrics.filter { isUsable($0.availability) && $0.value != nil }
        let coverage = MetricCoverage(
            availability: metrics.map { normalizedAvailability($0, hasValidValue: $0.value != nil) },
            expectedDays: expectedDays
        )
        guard let total = SignedEstimateRange.sum(valid.compactMap(\.value)) else {
            return MetricAggregate(
                total: MetricValue(value: nil, availability: emptyAggregateAvailability(metrics)),
                coverage: coverage
            )
        }
        return MetricAggregate(
            total: MetricValue(
                value: total,
                availability: aggregateAvailability(metrics, coverage: coverage),
                sourceReferences: aggregateSourceReferences(valid),
                sourceReferencesTruncated: aggregateSourcesTruncated(valid)
            ),
            coverage: coverage
        )
    }

    public static func aggregateNumbers(
        _ metrics: [MetricValue<Double>],
        expectedDays: Int,
        average: Bool = false
    ) -> MetricAggregate<Double> {
        let valid = metrics.filter {
            isUsable($0.availability) && $0.value.map { $0.isFinite && $0 >= 0 } == true
        }
        let coverage = MetricCoverage(
            availability: metrics.map {
                normalizedAvailability($0, hasValidValue: $0.value.map { $0.isFinite && $0 >= 0 } == true)
            },
            expectedDays: expectedDays
        )
        guard !valid.isEmpty else {
            return MetricAggregate(
                total: MetricValue(value: nil, availability: emptyAggregateAvailability(metrics)),
                coverage: coverage
            )
        }
        let sum = valid.compactMap(\.value).reduce(0, +)
        let result = average ? sum / Double(valid.count) : sum
        guard result.isFinite else {
            return MetricAggregate(total: MetricValue(value: nil, availability: .unavailable), coverage: coverage)
        }
        return MetricAggregate(
            total: MetricValue(
                value: result,
                availability: aggregateAvailability(metrics, coverage: coverage),
                sourceReferences: aggregateSourceReferences(valid),
                sourceReferencesTruncated: aggregateSourcesTruncated(valid)
            ),
            coverage: coverage
        )
    }

    private static func isUsable(_ availability: MetricAvailability) -> Bool {
        availability == .observed || availability == .estimated || availability == .partial
    }

    private static func normalizedAvailability<Value: Codable & Equatable & Sendable>(
        _ metric: MetricValue<Value>,
        hasValidValue: Bool
    ) -> MetricAvailability {
        if metric.availability == .pendingRecompute { return .pendingRecompute }
        guard isUsable(metric.availability), hasValidValue else { return .unavailable }
        return metric.availability
    }

    private static func combinedAvailability(
        _ lhs: MetricAvailability,
        _ rhs: MetricAvailability
    ) -> MetricAvailability {
        if lhs == .partial || rhs == .partial { return .partial }
        if lhs == .estimated || rhs == .estimated { return .estimated }
        if lhs == .observed && rhs == .observed { return .observed }
        return .unavailable
    }

    private static func aggregateAvailability<Value: Codable & Equatable & Sendable>(
        _ metrics: [MetricValue<Value>],
        coverage: MetricCoverage
    ) -> MetricAvailability {
        if coverage.availableDays < coverage.expectedDays { return .partial }
        if metrics.contains(where: { $0.availability == .partial }) { return .partial }
        if metrics.contains(where: { $0.availability == .estimated }) { return .estimated }
        return .observed
    }

    private static func emptyAggregateAvailability<Value: Codable & Equatable & Sendable>(
        _ metrics: [MetricValue<Value>]
    ) -> MetricAvailability {
        metrics.contains(where: { $0.availability == .pendingRecompute }) ? .pendingRecompute : .unavailable
    }

    private static func aggregateSourceReferences<Value: Codable & Equatable & Sendable>(
        _ metrics: [MetricValue<Value>]
    ) -> [String] {
        let references = Array(Set(metrics.flatMap(\.sourceReferences))).sorted()
        return Array(references.prefix(MetricValueLimits.aggregateSourceReferences))
    }

    private static func aggregateSourcesTruncated<Value: Codable & Equatable & Sendable>(
        _ metrics: [MetricValue<Value>]
    ) -> Bool {
        let references = Set(metrics.flatMap(\.sourceReferences))
        return references.count > MetricValueLimits.aggregateSourceReferences
            || metrics.contains(where: \.sourceReferencesTruncated)
    }
}
