import SwiftUI
import DensosoDomain

@main
struct DensosoWatchWorkoutApp: App {
    var body: some Scene {
        WindowGroup {
            WatchWorkoutScreen()
        }
    }
}

private struct WatchWorkoutScreen: View {
    @State private var workout = WatchHealthKitWorkoutManager()

    var body: some View {
        VStack(spacing: 10) {
            Text(workout.state.rawValue.capitalized)
                .font(.headline)

            if let heartRate = workout.heartRate {
                Text("\(heartRate, format: .number.precision(.fractionLength(0))) BPM")
                    .font(.title3.monospacedDigit())
            }

            if let activeEnergy = workout.activeEnergy {
                Text("\(activeEnergy, format: .number.precision(.fractionLength(0))) kcal")
                    .font(.footnote.monospacedDigit())
            }

            if let event = primaryEvent {
                Button(event.rawValue.capitalized) {
                    send(event)
                }
                .buttonStyle(.borderedProminent)
            }

            if workout.state == .running {
                Button("Pause") { send(.pause) }
                Button("Log 5 reps") { workout.logStrengthSet() }
            } else if workout.state == .paused {
                Button("Resume") { send(.resume) }
            }

            if workout.isResting {
                VStack(spacing: 4) {
                    Text("Rest \(workout.restSecondsRemaining)s")
                        .font(.title3.monospacedDigit())
                    Button("Skip rest") { workout.cancelRestTimer() }
                        .buttonStyle(.bordered)
                }
            }

            if !workout.completedStrengthSets.isEmpty {
                Text("Sets: \(workout.completedStrengthSets.count)")
                    .font(.footnote.monospacedDigit())
            }

            if workout.state == .prepared || workout.state == .running || workout.state == .paused {
                Button("Discard", role: .destructive) { send(.discard) }
            }

            if workout.isEnding {
                ProgressView("Saving workout")
            }

            if let errorMessage = workout.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding()
    }

    private var primaryEvent: WorkoutSessionEvent? {
        switch workout.state {
        case .idle, .ended, .discarded:
            .prepare
        case .prepared:
            .start
        case .running, .paused:
            .end
        }
    }

    private func send(_ event: WorkoutSessionEvent) {
        Task {
            await workout.send(event)
        }
    }
}
