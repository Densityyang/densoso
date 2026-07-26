import Foundation

/// Experiments that are eligible only on a future platform. Keeping this list
/// local means a remote configuration can never turn on a capability that the
/// installed app has not explicitly opted into.
public enum MultimodalExperiment: String, CaseIterable, Codable, Sendable {
    case foundationModelVision
    case systemBarcodeAndOCR
    case healthWorkoutZones
}

public struct LocalMultimodalExperimentFlags: Codable, Equatable, Sendable {
    private let enabled: Set<MultimodalExperiment>

    public init(enabled: Set<MultimodalExperiment> = []) {
        self.enabled = enabled
    }

    /// The stable iOS/watchOS 26 path remains the default. The caller supplies
    /// the OS major version so this policy remains deterministic in tests.
    public func permits(_ experiment: MultimodalExperiment, osMajorVersion: Int) -> Bool {
        osMajorVersion >= 27 && enabled.contains(experiment)
    }
}

/// All fields required to compare an experimental path with the frozen PR-I
/// evaluation set. This intentionally stores identifiers and measurements,
/// never the raw photo, prompt, or model payload.
public struct MultimodalEvaluationMetadata: Codable, Equatable, Sendable {
    public let experiment: MultimodalExperiment
    public let promptVersion: String
    public let outputSchemaVersion: String
    public let modelIdentifier: String
    public let deviceModel: String
    public let osVersion: String

    public init(
        experiment: MultimodalExperiment,
        promptVersion: String,
        outputSchemaVersion: String,
        modelIdentifier: String,
        deviceModel: String,
        osVersion: String
    ) {
        self.experiment = experiment
        self.promptVersion = promptVersion
        self.outputSchemaVersion = outputSchemaVersion
        self.modelIdentifier = modelIdentifier
        self.deviceModel = deviceModel
        self.osVersion = osVersion
    }
}

public struct MultimodalExperimentMetrics: Codable, Equatable, Sendable {
    public let identityTopKAccuracy: Double
    public let portionIntervalCoverage: Double
    public let p95LatencyMilliseconds: Double
    public let peakMemoryMegabytes: Double
    public let energyMilliwattHours: Double
    public let rawPhotoRetentionCount: Int

    public init(
        identityTopKAccuracy: Double,
        portionIntervalCoverage: Double,
        p95LatencyMilliseconds: Double,
        peakMemoryMegabytes: Double,
        energyMilliwattHours: Double,
        rawPhotoRetentionCount: Int
    ) {
        self.identityTopKAccuracy = identityTopKAccuracy
        self.portionIntervalCoverage = portionIntervalCoverage
        self.p95LatencyMilliseconds = p95LatencyMilliseconds
        self.peakMemoryMegabytes = peakMemoryMegabytes
        self.energyMilliwattHours = energyMilliwattHours
        self.rawPhotoRetentionCount = rawPhotoRetentionCount
    }
}

/// A promotion gate for a research path. It is deliberately conjunctive: no
/// performance gain can compensate for retained photos or a worse safety bound.
public struct MultimodalExperimentPromotionGate: Sendable {
    public let minimumTopKAccuracy: Double
    public let minimumIntervalCoverage: Double
    public let maximumP95LatencyMilliseconds: Double
    public let maximumPeakMemoryMegabytes: Double
    public let maximumEnergyMilliwattHours: Double

    public init(
        minimumTopKAccuracy: Double,
        minimumIntervalCoverage: Double,
        maximumP95LatencyMilliseconds: Double,
        maximumPeakMemoryMegabytes: Double,
        maximumEnergyMilliwattHours: Double
    ) {
        self.minimumTopKAccuracy = minimumTopKAccuracy
        self.minimumIntervalCoverage = minimumIntervalCoverage
        self.maximumP95LatencyMilliseconds = maximumP95LatencyMilliseconds
        self.maximumPeakMemoryMegabytes = maximumPeakMemoryMegabytes
        self.maximumEnergyMilliwattHours = maximumEnergyMilliwattHours
    }

    public func permitsPromotion(of metrics: MultimodalExperimentMetrics) -> Bool {
        metrics.identityTopKAccuracy >= minimumTopKAccuracy &&
            metrics.portionIntervalCoverage >= minimumIntervalCoverage &&
            metrics.p95LatencyMilliseconds <= maximumP95LatencyMilliseconds &&
            metrics.peakMemoryMegabytes <= maximumPeakMemoryMegabytes &&
            metrics.energyMilliwattHours <= maximumEnergyMilliwattHours &&
            metrics.rawPhotoRetentionCount == 0
    }
}

/// Adapter contract for a future system-model implementation. It may emit only
/// sanitized evidence; meal resolution, confirmation, estimation, persistence,
/// and HealthKit projection remain outside this contract.
public protocol ExperimentalMealEvidenceProducer: Sendable {
    func produceEvidence() async throws -> [MealEvidence]
}

@available(iOS 27.0, *)
public enum iOS27MultimodalExperimentBoundary {
    /// This marker makes the platform availability explicit without coupling
    /// the release build to an unreleased Foundation Models API surface.
    public static let requiresLocalFlag = true
}
