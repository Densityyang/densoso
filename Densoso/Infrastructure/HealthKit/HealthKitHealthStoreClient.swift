@preconcurrency import HealthKit
import Foundation
import DensosoDomain

/// The only HealthKit adapter used by the application. HealthKit types do not cross this boundary.
final class HealthKitHealthStoreClient: HealthStoreClient, HealthObserverClient, @unchecked Sendable {
    private let store: HKHealthStore
    private let observerLock = NSLock()
    private var observerKeys: Set<String> = []
    private var observerQueries: [String: HKObserverQuery] = [:]

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    func isAvailable() async -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization(_ scope: HealthAuthorizationScope) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthStoreClientError.unavailable }
        let shareTypes = try Set(scope.write.map(sampleType(for:)))
        let readTypes: Set<HKObjectType> = try Set(scope.read.map { try sampleType(for: $0) as HKObjectType })
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
        } catch {
            throw Self.mapHealthKitError(error)
        }
    }

    func aggregate(_ request: HealthAggregateRequest) async throws -> [HealthAggregateBucket] {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthStoreClientError.unavailable }
        guard let type = quantityType(for: request.metric), let unit = Self.unit(for: request.metric),
              let option = statisticsOption(for: request.metric) else {
            throw HealthStoreClientError.unsupportedMetric(request.metric)
        }

        var configuredCalendar = Calendar(identifier: .gregorian)
        configuredCalendar.timeZone = TimeZone(identifier: request.timezoneIdentifier) ?? .current
        let calendar = configuredCalendar
        let anchor = calendar.startOfDay(for: request.startDate)
        var interval = DateComponents()
        interval.day = 1
        let predicate = HKQuery.predicateForSamples(withStart: request.startDate, end: request.endDate, options: [])

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: option,
                anchorDate: anchor,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: Self.mapHealthKitError(error))
                    return
                }
                guard let collection else {
                    continuation.resume(returning: [])
                    return
                }
                let buckets = LockedArray<HealthAggregateBucket>()
                collection.enumerateStatistics(from: request.startDate, to: request.endDate) { statistics, _ in
                    let end = calendar.date(byAdding: .day, value: 1, to: statistics.startDate) ?? statistics.endDate
                    let value = statistics.sumQuantity()?.doubleValue(for: unit)
                    buckets.append(HealthAggregateBucket(
                        startDate: statistics.startDate,
                        endDate: end,
                        value: value,
                        readState: value == nil ? .dataUnavailableOrReadScopeUnknown : .available
                    ))
                }
                continuation.resume(returning: buckets.value)
            }
            store.execute(query)
        }
    }

    func samples(_ request: HealthSampleRequest) async throws -> HealthSamplePage {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthStoreClientError.unavailable }
        guard request.metric != .workout, let type = sampleTypeIfAvailable(for: request.metric) else {
            throw HealthStoreClientError.unsupportedMetric(request.metric)
        }
        let anchor = try decodeAnchor(request.anchorData)
        let predicate = HKQuery.predicateForSamples(withStart: request.startDate, end: request.endDate, options: [])
        let page: HealthSamplePage = try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: predicate,
                anchor: anchor,
                limit: request.limit
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    continuation.resume(throwing: Self.mapHealthKitError(error))
                    return
                }
                guard let newAnchor, let anchorData = try? Self.encodeAnchor(newAnchor) else {
                    continuation.resume(throwing: HealthStoreClientError.invalidAnchor)
                    return
                }
                let rawSamples = samples ?? []
                let mapped = rawSamples.compactMap { Self.snapshot(from: $0, metric: request.metric) }
                let deleted = (deletedObjects ?? []).map(\.uuid)
                continuation.resume(returning: HealthSamplePage(
                    samples: mapped,
                    deletedSampleIDs: deleted,
                    nextAnchorData: anchorData,
                    hasMore: rawSamples.count + deleted.count >= request.limit,
                    readState: mapped.isEmpty && deleted.isEmpty
                        ? .dataUnavailableOrReadScopeUnknown
                        : .available
                ))
            }
            store.execute(query)
        }
        return page
    }

    func workoutChanges(after anchorData: Data?) async throws -> HealthChangePage<WorkoutSnapshot> {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthStoreClientError.unavailable }
        let anchor = try decodeAnchor(anchorData)
        let limit = 500
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(),
                predicate: nil,
                anchor: anchor,
                limit: limit
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    continuation.resume(throwing: Self.mapHealthKitError(error))
                    return
                }
                guard let newAnchor, let encoded = try? Self.encodeAnchor(newAnchor) else {
                    continuation.resume(throwing: HealthStoreClientError.invalidAnchor)
                    return
                }
                let added = (samples ?? [])
                    .compactMap { $0 as? HKWorkout }
                    .compactMap(Self.workoutSnapshot(from:))
                let deletedIDs = (deletedObjects ?? []).map(\.uuid)
                continuation.resume(returning: HealthChangePage(
                    added: added,
                    deletedObjectIDs: deletedIDs,
                    nextAnchorData: encoded,
                    hasMore: (samples?.count ?? 0) + deletedIDs.count >= limit,
                    readState: added.isEmpty && deletedIDs.isEmpty
                        ? .dataUnavailableOrReadScopeUnknown
                        : .available
                ))
            }
            store.execute(query)
        }
    }

    func save(_ command: HealthWriteCommand) async throws -> HealthWriteReceipt {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthStoreClientError.unavailable }
        let values: [(HealthMetricID, Double)]
        switch command.payload {
        case .nutrition(let nutrition):
            var result: [(HealthMetricID, Double)] = [(.dietaryEnergy, nutrition.energyKilocalories)]
            if let protein = nutrition.proteinGrams { result.append((.dietaryProtein, protein)) }
            if let fat = nutrition.fatGrams { result.append((.dietaryFat, fat)) }
            if let carbohydrates = nutrition.carbohydrateGrams { result.append((.dietaryCarbohydrates, carbohydrates)) }
            values = result
        case .confirmedWeight(let kilograms):
            values = [(.bodyMass, kilograms)]
        }

        let samples = try values.map { metric, value -> HKQuantitySample in
            guard value.isFinite, value >= 0,
                  let type = quantityType(for: metric), let unit = Self.unit(for: metric) else {
                throw HealthStoreClientError.unsupportedMetric(metric)
            }
            let quantity = HKQuantity(unit: unit, doubleValue: value)
            let identifier = Self.syncIdentifier(command.syncIdentifier, metric: metric)
            let metadata: [String: Any] = [
                HKMetadataKeySyncIdentifier: identifier,
                HKMetadataKeySyncVersion: NSNumber(value: command.syncVersion),
            ]
            return HKQuantitySample(
                type: type,
                quantity: quantity,
                start: command.occurredAt,
                end: command.occurredAt,
                metadata: metadata
            )
        }
        do {
            try await store.save(samples)
        } catch {
            throw Self.mapHealthKitError(error)
        }
        return HealthWriteReceipt(
            recordID: command.recordID,
            syncIdentifier: command.syncIdentifier,
            syncVersion: command.syncVersion,
            metrics: values.map(\.0),
            sampleIDs: samples.map(\.uuid)
        )
    }

    func deleteOwnSample(receipt: HealthWriteReceipt) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthStoreClientError.unavailable }
        for metric in receipt.metrics {
            guard let type = sampleTypeIfAvailable(for: metric) else { continue }
            let identifier = Self.syncIdentifier(receipt.syncIdentifier, metric: metric)
            let predicate = HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeySyncIdentifier,
                operatorType: .equalTo,
                value: identifier
            )
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.deleteObjects(of: type, predicate: predicate) { success, _, error in
                    if let error {
                        continuation.resume(throwing: Self.mapHealthKitError(error))
                    } else if success {
                        // A zero count is already converged and is safe to retry.
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: HealthStoreClientError.queryFailed("删除本应用同步样本失败"))
                    }
                }
            }
        }
    }

    func enableBackgroundDelivery(for streams: Set<HealthMetricID>) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthStoreClientError.unavailable }
        for metric in streams {
            guard let type = sampleTypeIfAvailable(for: metric) else { continue }
            let frequency: HKUpdateFrequency = .hourly
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.enableBackgroundDelivery(for: type, frequency: frequency) { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: HealthStoreClientError.queryFailed("启用后台健康数据投递失败"))
                    }
                }
            }
        }
    }

    func startObserving(
        _ streams: Set<HealthMetricID>,
        onUpdate: @escaping HealthObserverClient.UpdateHandler
    ) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthStoreClientError.unavailable }
        for metric in streams.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let type = sampleTypeIfAvailable(for: metric) else { continue }
            let key = metric.rawValue
            guard registerObserverKey(key) else { continue }
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else {
                    completion()
                    return
                }
                onUpdate(metric) {
                    completion()
                }
            }
            registerObserver(query, key: key)
            store.execute(query)
        }
    }

    private func registerObserverKey(_ key: String) -> Bool {
        observerLock.lock()
        defer { observerLock.unlock() }
        guard !observerKeys.contains(key) else { return false }
        observerKeys.insert(key)
        return true
    }

    private func registerObserver(_ query: HKObserverQuery, key: String) {
        observerLock.lock()
        defer { observerLock.unlock() }
        observerQueries[key] = query
    }

    private func decodeAnchor(_ data: Data?) throws -> HKQueryAnchor? {
        guard let data else { return nil }
        guard let anchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) else {
            throw HealthStoreClientError.invalidAnchor
        }
        return anchor
    }

    private static func encodeAnchor(_ anchor: HKQueryAnchor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    private func sampleType(for metric: HealthMetricID) throws -> HKSampleType {
        guard let type = sampleTypeIfAvailable(for: metric) else { throw HealthStoreClientError.unsupportedMetric(metric) }
        return type
    }

    private func sampleTypeIfAvailable(for metric: HealthMetricID) -> HKSampleType? {
        if metric == .workout { return HKObjectType.workoutType() }
        if metric == .sleepAnalysis {
            return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        }
        guard let identifier = quantityIdentifier(for: metric) else { return nil }
        return HKObjectType.quantityType(forIdentifier: identifier)
    }

    private func quantityType(for metric: HealthMetricID) -> HKQuantityType? {
        guard let identifier = quantityIdentifier(for: metric) else { return nil }
        return HKObjectType.quantityType(forIdentifier: identifier)
    }

    private func quantityIdentifier(for metric: HealthMetricID) -> HKQuantityTypeIdentifier? {
        switch metric {
        case .stepCount: .stepCount
        case .activeEnergy: .activeEnergyBurned
        case .restingEnergy: .basalEnergyBurned
        case .exerciseMinutes: .appleExerciseTime
        case .heartRate: .heartRate
        case .restingHeartRate: .restingHeartRate
        case .heartRateVariabilitySDNN: .heartRateVariabilitySDNN
        case .respiratoryRate: .respiratoryRate
        case .bodyMass: .bodyMass
        case .height: .height
        case .bodyFatPercentage: .bodyFatPercentage
        case .wristTemperature: .appleSleepingWristTemperature
        case .dietaryEnergy: .dietaryEnergyConsumed
        case .dietaryProtein: .dietaryProtein
        case .dietaryFat: .dietaryFatTotal
        case .dietaryCarbohydrates: .dietaryCarbohydrates
        case .workoutEffort: .workoutEffortScore
        case .workout, .sleepAnalysis: nil
        }
    }

    private func statisticsOption(for metric: HealthMetricID) -> HKStatisticsOptions? {
        switch metric {
        case .activeEnergy, .restingEnergy, .stepCount, .exerciseMinutes,
             .dietaryEnergy, .dietaryProtein, .dietaryFat, .dietaryCarbohydrates:
            .cumulativeSum
        default:
            nil
        }
    }

    private static func snapshot(from sample: HKSample, metric: HealthMetricID) -> HealthSampleSnapshot? {
        let value: Double?
        let categoryValue: String?
        if let quantitySample = sample as? HKQuantitySample {
            guard let unit = Self.unit(for: metric) else { return nil }
            let rawValue = quantitySample.quantity.doubleValue(for: unit)
            value = metric == .bodyFatPercentage ? rawValue * 100 : rawValue
            categoryValue = nil
        } else if let categorySample = sample as? HKCategorySample {
            value = nil
            categoryValue = sleepCategoryName(categorySample.value)
        } else {
            return nil
        }
        return HealthSampleSnapshot(
            id: sample.uuid,
            metric: metric,
            startDate: sample.startDate,
            endDate: sample.endDate,
            value: value,
            categoryValue: categoryValue,
            sourceBundleIdentifier: sample.sourceRevision.source.bundleIdentifier,
            deviceName: sample.device?.name,
            deviceModel: sample.device?.model,
            syncIdentifier: sample.metadata?[HKMetadataKeySyncIdentifier] as? String,
            syncVersion: (sample.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue
        )
    }

    private static func sleepCategoryName(_ value: Int) -> String {
        if value == HKCategoryValueSleepAnalysis.inBed.rawValue { return \"inBed\" }
        if value == HKCategoryValueSleepAnalysis.awake.rawValue { return \"awake\" }
        if value == HKCategoryValueSleepAnalysis.asleepCore.rawValue { return \"asleepCore\" }
        if value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue { return \"asleepDeep\" }
        if value == HKCategoryValueSleepAnalysis.asleepREM.rawValue { return \"asleepREM\" }
        if value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue { return \"asleepUnspecified\" }
        if value == HKCategoryValueSleepAnalysis.asleep.rawValue { return \"asleepUnspecified\" }
        return \"unknown\"
    }

    private static func workoutSnapshot(from workout: HKWorkout) -> WorkoutSnapshot? {
        let measuredEnergy = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
        let sourceRevision = workout.sourceRevision
        let sourceBundleIdentifier = sourceRevision.source.bundleIdentifier
        let logicalSessionID = (workout.metadata?["com.densoso.logicalWorkoutSessionID"] as? String)
            .flatMap(UUID.init(uuidString:))
        let origin: WorkoutOrigin = sourceBundleIdentifier == "com.densoso.densoso" ? .watchHealthKit : .externalHealthKit
        let dataQuality: WorkoutDataQuality = measuredEnergy == nil ? .partial : .complete
        return try? WorkoutSnapshot(
            healthKitUUID: workout.uuid,
            logicalSessionID: logicalSessionID,
            startedAt: workout.startDate,
            duration: workout.duration,
            activityType: String(workout.workoutActivityType.rawValue),
            energyInput: .init(measuredKilocalories: measuredEnergy),
            origin: origin,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceVersion: sourceRevision.version,
            sourceRevision: sourceRevision.productType,
            deviceName: workout.device?.name,
            deviceModel: workout.device?.model,
            dataQuality: dataQuality,
            routeStatus: .unavailable
        )
    }

    private static func unit(for metric: HealthMetricID) -> HKUnit? {
        switch metric {
        case .activeEnergy, .restingEnergy, .dietaryEnergy: .kilocalorie()
        case .stepCount, .workoutEffort: .count()
        case .exerciseMinutes: .minute()
        case .heartRate, .restingHeartRate, .respiratoryRate: .count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN: .secondUnit(with: .milli)
        case .bodyMass: .gramUnit(with: .kilo)
        case .height: .meterUnit(with: .centi)
        case .bodyFatPercentage: .percent()
        case .wristTemperature: .degreeCelsius()
        case .dietaryProtein, .dietaryFat, .dietaryCarbohydrates: .gram()
        case .workout, .sleepAnalysis: nil
        }
    }

    private static func syncIdentifier(_ base: String, metric: HealthMetricID) -> String {
        "\(base).\(metric.rawValue)"
    }

    private static func mapHealthKitError(_ error: Error) -> Error {
        guard let healthError = error as? HKError else { return error }
        return switch healthError.code {
        case .errorAuthorizationDenied:
            HealthStoreClientError.authorizationDenied
        case .errorAuthorizationNotDetermined:
            HealthStoreClientError.authorizationNotDetermined
        case .errorHealthDataRestricted:
            HealthStoreClientError.healthDataRestricted
        case .errorDatabaseInaccessible:
            HealthStoreClientError.dataStoreLocked
        case .errorHealthDataUnavailable:
            HealthStoreClientError.unavailable
        default:
            error
        }
    }
}

private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }

    var value: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
