import Foundation
import HealthKit
import Observation
import WatchKit
import DensosoDomain

@MainActor
@Observable
final class WatchHealthKitWorkoutManager: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    private let healthStore = HKHealthStore()
    private let coordinator = WatchWorkoutCoordinator()

    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var isFinalizing = false
    private var restTimer = RestTimer()
    private var restTimerTask: Task<Void, Never>?

    private(set) var state: WorkoutSessionState = .idle
    private(set) var heartRate: Double?
    private(set) var activeEnergy: Double?
    private(set) var savedWorkoutID: UUID?
    private(set) var errorMessage: String?
    private(set) var completedStrengthSets: [StrengthSetLog] = []
    private(set) var restSecondsRemaining = 0
    private(set) var isResting = false

    var isEnding: Bool { isFinalizing }

    func send(_ event: WorkoutSessionEvent) async {
        do {
            switch event {
            case .prepare:
                try await prepare()
            case .start:
                try await start()
            case .pause:
                try await pause()
            case .resume:
                try await resume()
            case .end:
                try stop()
            case .discard:
                try await discard()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepare() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw WatchWorkoutError.healthDataUnavailable
        }

        let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
        let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!
        let healthTypes: Set<HKSampleType> = [HKObjectType.workoutType(), energyType, heartRateType]
        try await healthStore.requestAuthorization(toShare: healthTypes, read: healthTypes)

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .indoor

        let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        let dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
        dataSource.enableCollection(for: energyType, predicate: nil)
        dataSource.enableCollection(for: heartRateType, predicate: nil)
        builder.dataSource = dataSource
        session.delegate = self
        builder.delegate = self

        self.session = session
        self.builder = builder
        savedWorkoutID = nil
        heartRate = nil
        activeEnergy = nil
        try await updateState(for: .prepare)
    }

    private func start() async throws {
        guard let session, let builder else { throw WatchWorkoutError.sessionNotPrepared }

        do {
            try await session.startMirroringToCompanionDevice()
        } catch {
            // A disconnected companion must not prevent the user from recording locally on Watch.
            errorMessage = "Phone mirroring is unavailable; recording continues on Watch."
        }

        let startDate = Date()
        session.startActivity(with: startDate)
        try await builder.beginCollection(at: startDate)
        let logicalSession = await coordinator.snapshot().logicalSession
        try? await builder.addMetadata(["com.densoso.logicalWorkoutSessionID": logicalSession.id.uuidString])
        try await updateState(for: .start)
    }

    private func pause() async throws {
        guard let session else { throw WatchWorkoutError.sessionNotPrepared }
        session.pause()
        try await updateState(for: .pause)
    }

    private func resume() async throws {
        guard let session else { throw WatchWorkoutError.sessionNotPrepared }
        session.resume()
        try await updateState(for: .resume)
    }

    private func stop() throws {
        guard let session else { throw WatchWorkoutError.sessionNotPrepared }
        guard !isFinalizing else { return }
        isFinalizing = true
        session.stopActivity(with: Date())
    }

    private func discard() async throws {
        guard let session, let builder else { throw WatchWorkoutError.sessionNotPrepared }
        builder.discardWorkout()
        session.end()
        try await updateState(for: .discard)
        clearSession()
    }

    /// Captures an app-owned strength set without attempting to encode custom
    /// repetitions into HealthKit's workout schema. The final summary is linked
    /// to the saved HKWorkout UUID in `finishWorkout`.
    func logStrengthSet(
        exerciseID: String = "free-exercise-db:Barbell_Squat",
        exerciseName: String = "Barbell Squat",
        repetitions: Int = 5,
        loadKilograms: Double? = nil,
        restDuration: TimeInterval = 90
    ) {
        guard state == .running || state == .paused else {
            errorMessage = "Start the workout before logging a strength set."
            return
        }
        completedStrengthSets.append(
            StrengthSetLog(
                exerciseID: exerciseID,
                exerciseName: exerciseName,
                repetitions: repetitions,
                loadKilograms: loadKilograms
            )
        )
        WKInterfaceDevice.current().play(.click)
        startRestTimer(duration: restDuration)
    }

    func cancelRestTimer() {
        restTimerTask?.cancel()
        restTimerTask = nil
        restTimer.cancel()
        restSecondsRemaining = 0
        isResting = false
    }

    private func startRestTimer(duration: TimeInterval) {
        cancelRestTimer()
        restTimer.start(duration: duration)
        isResting = true
        restSecondsRemaining = restTimer.secondsRemaining()
        WKInterfaceDevice.current().play(.start)
        restTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if self.restTimer.refresh() {
                    self.restSecondsRemaining = 0
                    self.isResting = false
                    self.restTimerTask = nil
                    WKInterfaceDevice.current().play(.notification)
                    return
                }
                self.restSecondsRemaining = self.restTimer.secondsRemaining()
            }
        }
    }

    private func finishWorkout(at date: Date) async {
        guard let session, let builder else { return }
        defer {
            session.end()
            clearSession()
        }

        do {
            try await builder.endCollection(at: date)
            savedWorkoutID = try await builder.finishWorkout()?.uuid
            try await updateState(for: .end)
            if let savedWorkoutID {
                let logicalSessionID = await coordinator.snapshot().logicalSession.id
                WatchStrengthWorkoutStore.save(
                    StrengthWorkoutSummary(
                        healthKitUUID: savedWorkoutID,
                        logicalSessionID: logicalSessionID,
                        catalogVersion: ExerciseCatalogVersion.current,
                        completedSets: completedStrengthSets
                    )
                )
            }
        } catch {
            errorMessage = "Unable to save this workout: \(error.localizedDescription)"
        }
    }

    private func clearSession() {
        cancelRestTimer()
        session = nil
        builder = nil
        isFinalizing = false
    }

    private func updateState(for event: WorkoutSessionEvent) async throws {
        state = try await coordinator.send(event).state
    }

    private func refreshStatistics() {
        guard let builder else { return }

        if let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
           let quantity = builder.statistics(for: heartRateType)?.mostRecentQuantity() {
            heartRate = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        }

        if let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
           let quantity = builder.statistics(for: energyType)?.sumQuantity() {
            activeEnergy = quantity.doubleValue(for: .kilocalorie())
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        guard toState == .stopped else { return }
        Task { @MainActor [weak self] in
            await self?.finishWorkout(at: date)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.errorMessage = "Workout session failed: \(error.localizedDescription)"
            self?.clearSession()
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        Task { @MainActor [weak self] in
            self?.refreshStatistics()
        }
    }
}

private enum WatchStrengthWorkoutStore {
    private static let storageKey = "watch.strengthWorkoutSummaries"

    static func save(_ summary: StrengthWorkoutSummary, defaults: UserDefaults = .standard) {
        var summaries = (try? JSONDecoder().decode(
            [StrengthWorkoutSummary].self,
            from: defaults.data(forKey: storageKey) ?? Data()
        )) ?? []
        summaries.removeAll { $0.healthKitUUID == summary.healthKitUUID }
        summaries.append(summary)
        defaults.set(try? JSONEncoder().encode(summaries), forKey: storageKey)
    }
}

private enum WatchWorkoutError: LocalizedError {
    case healthDataUnavailable
    case sessionNotPrepared

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            "Health data is unavailable on this device."
        case .sessionNotPrepared:
            "Prepare a workout before controlling it."
        }
    }
}
