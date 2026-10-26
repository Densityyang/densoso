import Foundation

/// Stable, HealthKit-independent identifiers used at the application boundary.
public enum HealthMetricID: String, Codable, CaseIterable, Hashable, Sendable {
    case workout
    case workoutEffort
    case stepCount
    case activeEnergy
    case restingEnergy
    case exerciseMinutes
    case sleepAnalysis
    case heartRate
    case restingHeartRate
    case heartRateVariabilitySDNN
    case respiratoryRate
    case bodyMass
    case height
    case bodyFatPercentage
    case wristTemperature
    case dietaryEnergy
    case dietaryProtein
    case dietaryFat
    case dietaryCarbohydrates
}

public struct HealthAuthorizationScope: Codable, Equatable, Sendable {
    public let read: Set<HealthMetricID>
    public let write: Set<HealthMetricID>

    public init(read: Set<HealthMetricID>, write: Set<HealthMetricID>) {
        self.read = read
        self.write = write
    }

    public static let application = HealthAuthorizationScope(
        read: [
            .workout, .workoutEffort, .stepCount, .activeEnergy, .restingEnergy,
            .exerciseMinutes, .sleepAnalysis, .heartRate, .restingHeartRate,
            .heartRateVariabilitySDNN, .respiratoryRate, .bodyMass, .height,
            .bodyFatPercentage, .wristTemperature,
        ],
        write: [.dietaryEnergy, .dietaryProtein, .dietaryFat, .dietaryCarbohydrates, .bodyMass]
    )
}

public struct HealthAggregateRequest: Codable, Equatable, Sendable {
    public let metric: HealthMetricID
    public let startDate: Date
    public let endDate: Date
    public let timezoneIdentifier: String

    public init(metric: HealthMetricID, startDate: Date, endDate: Date, timezoneIdentifier: String) {
        self.metric = metric
        self.startDate = startDate
        self.endDate = endDate
        self.timezoneIdentifier = timezoneIdentifier
    }
}

public struct HealthAggregateBucket: Codable, Equatable, Sendable {
    public let startDate: Date
    public let endDate: Date
    public let value: Double?
    public let readState: HealthReadState

    public init(startDate: Date, endDate: Date, value: Double?, readState: HealthReadState? = nil) {
        self.startDate = startDate
        self.endDate = endDate
        let normalized = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.value = normalized
        self.readState = readState ?? (normalized == nil ? .dataUnavailableOrReadScopeUnknown : .available)
    }
}

public struct HealthSampleRequest: Codable, Equatable, Sendable {
    public let metric: HealthMetricID
    public let startDate: Date
    public let endDate: Date
    public let anchorData: Data?
    public let limit: Int

    public init(metric: HealthMetricID, startDate: Date, endDate: Date, anchorData: Data? = nil, limit: Int = 500) {
        self.metric = metric
        self.startDate = startDate
        self.endDate = endDate
        self.anchorData = anchorData
        self.limit = max(1, limit)
    }
}

/// A normalized local representation; quantity values use the metric's canonical unit.
public struct HealthSampleSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let metric: HealthMetricID
    public let startDate: Date
    public let endDate: Date
    public let value: Double?
    public let categoryValue: String?
    public let sourceBundleIdentifier: String?
    public let deviceName: String?
    public let deviceModel: String?
    public let syncIdentifier: String?
    public let syncVersion: Int?

    public init(
        id: UUID,
        metric: HealthMetricID,
        startDate: Date,
        endDate: Date,
        value: Double? = nil,
        categoryValue: String? = nil,
        sourceBundleIdentifier: String? = nil,
        deviceName: String? = nil,
        deviceModel: String? = nil,
        syncIdentifier: String? = nil,
        syncVersion: Int? = nil
    ) {
        self.id = id
        self.metric = metric
        self.startDate = startDate
        self.endDate = endDate
        self.value = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.categoryValue = categoryValue
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.syncIdentifier = syncIdentifier
        self.syncVersion = syncVersion
    }

    /// Chooses a deterministic representative when the same HealthKit UUID appears more than once.
    /// An explicit higher sync version wins; otherwise a stable field order breaks ties.
    public static func preferredForDeduplication(_ candidate: Self, over current: Self) -> Bool {
        switch (candidate.syncVersion, current.syncVersion) {
        case let (.some(candidateVersion), .some(currentVersion)) where candidateVersion != currentVersion:
            return candidateVersion > currentVersion
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return stableDeduplicationOrder(candidate, current)
        }
    }

    /// Provides stable ordering for deduplicated samples and equal-version candidates.
    public static func stableDeduplicationOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
        if lhs.id != rhs.id { return lhs.id.uuidString < rhs.id.uuidString }
        if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
        if lhs.metric != rhs.metric { return lhs.metric.rawValue < rhs.metric.rawValue }
        if lhs.value != rhs.value { return optionalDeduplicationOrder(lhs.value, rhs.value) }
        if lhs.categoryValue != rhs.categoryValue {
            return optionalDeduplicationOrder(lhs.categoryValue, rhs.categoryValue)
        }
        if lhs.sourceBundleIdentifier != rhs.sourceBundleIdentifier {
            return optionalDeduplicationOrder(lhs.sourceBundleIdentifier, rhs.sourceBundleIdentifier)
        }
        if lhs.deviceName != rhs.deviceName {
            return optionalDeduplicationOrder(lhs.deviceName, rhs.deviceName)
        }
        if lhs.deviceModel != rhs.deviceModel {
            return optionalDeduplicationOrder(lhs.deviceModel, rhs.deviceModel)
        }
        if lhs.syncIdentifier != rhs.syncIdentifier {
            return optionalDeduplicationOrder(lhs.syncIdentifier, rhs.syncIdentifier)
        }
        return optionalDeduplicationOrder(lhs.syncVersion, rhs.syncVersion)
    }

    /// Deduplicates a page or transient aggregation input by HealthKit UUID.
    public static func deduplicated(_ samples: [Self]) -> [Self] {
        var samplesByID: [UUID: Self] = [:]
        for sample in samples {
            if let current = samplesByID[sample.id] {
                if preferredForDeduplication(sample, over: current) {
                    samplesByID[sample.id] = sample
                }
            } else {
                samplesByID[sample.id] = sample
            }
        }
        return samplesByID.values.sorted(by: stableDeduplicationOrder)
    }

    private static func optionalDeduplicationOrder<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> Bool {
        guard lhs != rhs else { return false }
        guard let lhs else { return false }
        guard let rhs else { return true }
        return lhs < rhs
    }
}

public enum HealthReadState: String, Codable, Equatable, Sendable {
    case available
    /// HealthKit deliberately does not reveal whether an empty read is caused by denied access.
    case dataUnavailableOrReadScopeUnknown
    case healthDataUnavailable
}

public enum HealthStoreClientError: Equatable, Sendable, SharedErrorDescribing {
    case unavailable
    case authorizationBoundaryUnavailable
    case authorizationDenied
    case authorizationNotDetermined
    case healthDataRestricted
    case dataStoreLocked
    case unsupportedMetric(HealthMetricID)
    case invalidAnchor
    case queryFailed(String)

    public var sharedErrorDescriptor: SharedErrorDescriptor {
        switch self {
        case .authorizationDenied:
            SharedErrorDescriptor(
                code: .healthKitUnauthorized,
                userMessage: "暂时没能更新今天的状态。",
                subsystem: .healthKit,
                reason: .healthKitAuthorizationDenied
            )
        case .authorizationNotDetermined:
            SharedErrorDescriptor(
                code: .healthKitUnauthorized,
                userMessage: "暂时没能更新今天的状态。",
                subsystem: .healthKit,
                reason: .healthKitAuthorizationUndetermined
            )
        case .unavailable:
            SharedErrorDescriptor(
                code: .healthKitUnavailable,
                userMessage: "暂时没能更新今天的状态。",
                subsystem: .healthKit,
                reason: .healthKitUnavailable
            )
        case .authorizationBoundaryUnavailable:
            SharedErrorDescriptor(
                code: .healthKitUnavailable,
                userMessage: "暂时无法确认健康数据的可访问历史范围；相关数据会按未知处理。",
                subsystem: .healthKit,
                reason: .healthKitAuthorizationBoundaryUnavailable
            )
        case .healthDataRestricted:
            SharedErrorDescriptor(
                code: .healthKitUnavailable,
                userMessage: "暂时没能更新今天的状态。",
                subsystem: .healthKit,
                reason: .healthDataRestricted
            )
        case .dataStoreLocked:
            SharedErrorDescriptor(
                code: .healthKitUnavailable,
                userMessage: "暂时没能更新今天的状态。",
                subsystem: .healthKit,
                reason: .healthDataLocked
            )
        case .unsupportedMetric:
            SharedErrorDescriptor(
                code: .healthKitUnavailable,
                userMessage: "暂时没能更新今天的状态。",
                subsystem: .healthKit,
                reason: .unsupportedHealthMetric
            )
        case .invalidAnchor:
            SharedErrorDescriptor(
                code: .healthKitUnavailable,
                userMessage: "暂时没能更新今天的状态。",
                subsystem: .healthKit,
                reason: .invalidHealthKitAnchor
            )
        case .queryFailed:
            SharedErrorDescriptor(
                code: .healthKitUnavailable,
                userMessage: "暂时没能更新今天的状态。",
                subsystem: .healthKit,
                reason: .healthKitQueryFailed
            )
        }
    }

    public var errorDescription: String? { sharedErrorDescriptor.userMessage }
}

public struct HealthSamplePage: Codable, Equatable, Sendable {
    public let samples: [HealthSampleSnapshot]
    public let deletedSampleIDs: [UUID]
    public let nextAnchorData: Data?
    public let hasMore: Bool
    public let readState: HealthReadState

    public init(
        samples: [HealthSampleSnapshot],
        deletedSampleIDs: [UUID] = [],
        nextAnchorData: Data?,
        hasMore: Bool = false,
        readState: HealthReadState
    ) {
        self.samples = samples
        self.deletedSampleIDs = deletedSampleIDs
        self.nextAnchorData = nextAnchorData
        self.hasMore = hasMore
        self.readState = readState
    }
}

/// A complete transient read for one projection day. It is consumed to rebuild
/// the local daily summary and is never persisted as a raw sample collection.
public struct HealthSampleDaySnapshot: Codable, Equatable, Sendable {
    public let dayStart: Date
    public let samples: [HealthSampleSnapshot]
    public let readState: HealthReadState

    public init(dayStart: Date, samples: [HealthSampleSnapshot], readState: HealthReadState) {
        self.dayStart = dayStart
        self.samples = samples
        self.readState = readState
    }
}

public struct HealthChangePage<Value: Codable & Sendable>: Codable, Sendable {
    public let added: [Value]
    public let deletedObjectIDs: [UUID]
    public let nextAnchorData: Data?
    public let hasMore: Bool
    public let readState: HealthReadState

    public init(
        added: [Value],
        deletedObjectIDs: [UUID],
        nextAnchorData: Data?,
        hasMore: Bool = false,
        readState: HealthReadState = .available
    ) {
        self.added = added
        self.deletedObjectIDs = deletedObjectIDs
        self.nextAnchorData = nextAnchorData
        self.hasMore = hasMore
        self.readState = readState
    }
}

public struct HealthNutritionWrite: Codable, Equatable, Sendable {
    public let energyKilocalories: Double
    public let proteinGrams: Double?
    public let fatGrams: Double?
    public let carbohydrateGrams: Double?

    public init(energyKilocalories: Double, proteinGrams: Double?, fatGrams: Double?, carbohydrateGrams: Double?) {
        self.energyKilocalories = energyKilocalories
        self.proteinGrams = proteinGrams
        self.fatGrams = fatGrams
        self.carbohydrateGrams = carbohydrateGrams
    }
}

public enum HealthWritePayload: Codable, Equatable, Sendable {
    case nutrition(HealthNutritionWrite)
    case confirmedWeight(kilograms: Double)
}

public struct HealthWriteCommand: Codable, Equatable, Sendable {
    public let recordID: UUID
    public let occurredAt: Date
    public let syncIdentifier: String
    public let syncVersion: Int
    public let payload: HealthWritePayload

    public init(recordID: UUID, occurredAt: Date, syncIdentifier: String, syncVersion: Int, payload: HealthWritePayload) {
        self.recordID = recordID
        self.occurredAt = occurredAt
        self.syncIdentifier = syncIdentifier
        self.syncVersion = max(1, syncVersion)
        self.payload = payload
    }
}

public struct HealthWriteReceipt: Codable, Equatable, Sendable {
    public let recordID: UUID
    public let syncIdentifier: String
    public let syncVersion: Int
    public let metrics: [HealthMetricID]
    public let sampleIDs: [UUID]

    public init(recordID: UUID, syncIdentifier: String, syncVersion: Int, metrics: [HealthMetricID], sampleIDs: [UUID]) {
        self.recordID = recordID
        self.syncIdentifier = syncIdentifier
        self.syncVersion = syncVersion
        self.metrics = metrics
        self.sampleIDs = sampleIDs
    }
}

public protocol HealthStoreClient: Sendable {
    func isAvailable() async -> Bool
    func requestAuthorization(_ scope: HealthAuthorizationScope) async throws
    func aggregate(_ request: HealthAggregateRequest) async throws -> [HealthAggregateBucket]
    func samples(_ request: HealthSampleRequest) async throws -> HealthSamplePage
    func workoutChanges(from startDate: Date, after anchor: Data?) async throws -> HealthChangePage<WorkoutSnapshot>
    func save(_ command: HealthWriteCommand) async throws -> HealthWriteReceipt
    func deleteOwnSample(receipt: HealthWriteReceipt) async throws
    func enableBackgroundDelivery(for streams: Set<HealthMetricID>) async throws
}

/// Observer updates are wakeups only. Callers must drain the relevant anchored stream before completion.
public protocol HealthObserverClient: Sendable {
    typealias Completion = @Sendable () -> Void
    typealias UpdateHandler = @Sendable (HealthMetricID, @escaping Completion) -> Void

    func startObserving(_ streams: Set<HealthMetricID>, onUpdate: @escaping UpdateHandler) async throws
}
