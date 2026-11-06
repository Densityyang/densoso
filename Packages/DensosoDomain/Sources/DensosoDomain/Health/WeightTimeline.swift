import Foundation

public enum WeightSource: String, Codable, CaseIterable, Sendable {
    case healthKit
    case manual
    case densoso
    case imported
}

public enum EffectiveWeightSource: String, Codable, Sendable {
    case healthKit
    case manual
    case densoso
    case imported
    case profileInitial
}

public struct WeightObservation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let measuredAt: Date
    public let kilograms: Double
    public let source: WeightSource
    public let confidence: Double
    public let healthKitSyncIdentifier: String?

    public init(
        id: UUID = UUID(),
        measuredAt: Date,
        kilograms: Double,
        source: WeightSource,
        confidence: Double,
        healthKitSyncIdentifier: String? = nil
    ) {
        self.id = id
        self.measuredAt = measuredAt
        self.kilograms = kilograms
        self.source = source
        self.confidence = confidence
        self.healthKitSyncIdentifier = healthKitSyncIdentifier
    }

    public var isValid: Bool {
        measuredAt.timeIntervalSince1970.isFinite
            && kilograms.isFinite && kilograms > 0
            && confidence.isFinite && (0...1).contains(confidence)
    }
}

public struct EffectiveWeight: Codable, Equatable, Sendable {
    public let measuredAt: Date
    public let kilograms: Double
    public let source: EffectiveWeightSource
    public let confidence: Double?

    public init(
        measuredAt: Date,
        kilograms: Double,
        source: EffectiveWeightSource,
        confidence: Double?
    ) {
        self.measuredAt = measuredAt
        self.kilograms = kilograms
        self.source = source
        self.confidence = confidence
    }
}

/// Resolves a historical weight without borrowing measurements from the future.
public struct WeightTimeline: Sendable {
    public static let defaultMinimumConfidence = 0.5

    private let observations: [WeightObservation]

    public init(observations: [WeightObservation]) {
        self.observations = observations
    }

    public func effectiveWeight(
        at date: Date,
        profileWeightKg: Double? = nil,
        profileEffectiveFrom: Date? = nil,
        minimumConfidence: Double = defaultMinimumConfidence
    ) -> EffectiveWeight? {
        guard minimumConfidence.isFinite, (0...1).contains(minimumConfidence) else { return nil }

        if let observation = observations
            .filter({
                $0.isValid && $0.measuredAt <= date && $0.confidence >= minimumConfidence
            })
            .sorted(by: Self.precedes)
            .last {
            return EffectiveWeight(
                measuredAt: observation.measuredAt,
                kilograms: observation.kilograms,
                source: effectiveSource(for: observation.source),
                confidence: observation.confidence
            )
        }

        guard let profileWeightKg,
              profileWeightKg.isFinite,
              profileWeightKg > 0,
              let profileEffectiveFrom,
              profileEffectiveFrom <= date
        else {
            return nil
        }

        return EffectiveWeight(
            measuredAt: profileEffectiveFrom,
            kilograms: profileWeightKg,
            source: .profileInitial,
            confidence: nil
        )
    }

    private static func precedes(_ lhs: WeightObservation, _ rhs: WeightObservation) -> Bool {
        if lhs.measuredAt != rhs.measuredAt {
            return lhs.measuredAt < rhs.measuredAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func effectiveSource(for source: WeightSource) -> EffectiveWeightSource {
        switch source {
        case .healthKit: .healthKit
        case .manual: .manual
        case .densoso: .densoso
        case .imported: .imported
        }
    }
}
