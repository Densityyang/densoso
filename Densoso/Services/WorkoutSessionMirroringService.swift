import HealthKit
import Observation

/// Installs the iPhone-side handler before the UI appears so watch reconnects are not missed.
@MainActor
@Observable
final class WorkoutSessionMirroringService {
    private let healthStore = HKHealthStore()

    private(set) var activeMirroredSessionStartDate: Date?
    private(set) var reconnectCount = 0

    init() {
        healthStore.workoutSessionMirroringStartHandler = { [weak self] mirroredSession in
            Task { @MainActor [weak self] in
                self?.accept(mirroredSession)
            }
        }
    }

    private func accept(_ session: HKWorkoutSession) {
        activeMirroredSessionStartDate = session.startDate
        reconnectCount += 1
    }
}
