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
        self.syncIdentifier = syncIdentifier
        self.syncVersion = syncVersion
    }
}

public enum HealthReadState: String, Codable, Equatable, Sendable {
    case available
    /// HealthKit deliberately does not reveal whether an empty read is caused by denied access.
    case dataUnavailableOrReadScopeUnknown
    case healthDataUnavailable
}

public enum HealthStoreClientError: LocalizedError, Equatable, Sendable {
    case unavailable
    case authorizationDenied
    case authorizationNotDetermined
    case healthDataRestricted
    case dataStoreLocked
    case unsupportedMetric(HealthMetricID)
    case invalidAnchor
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "此设备无法使用 Apple Health。"
        case .authorizationDenied:
            "Apple Health 未允许写入此数据类型。"
        case .authorizationNotDetermined:
            "该 HealthKit 写入类型尚未完成授权请求。"
        case .healthDataRestricted:
            "当前设备策略限制了 HealthKit。"
        case .dataStoreLocked:
            "设备锁定时 HealthKit 数据暂不可读取。"
        case .unsupportedMetric(let metric):
            "当前系统不提供 HealthKit 数据类型：\(metric.rawValue)。"
        case .invalidAnchor:
            "HealthKit 同步游标无法读取。"
        case .queryFailed(let detail):
            "HealthKit 操作失败：\(detail)"
        }
    }
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
    func workoutChanges(after anchor: Data?) async throws -> HealthChangePage<WorkoutSnapshot>
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
