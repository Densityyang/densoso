import SwiftUI
import DensosoWorkoutDomain

@main
struct DensosoWatchWorkoutApp: App {
    var body: some Scene {
        WindowGroup {
            WatchWorkoutScreen()
        }
    }
}

private struct WatchWorkoutScreen: View {
    @State private var coordinator = WatchWorkoutCoordinator()
    @State private var state: WorkoutSessionState = .idle
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            Text(state.rawValue.capitalized)
                .font(.headline)

            if let event = primaryEvent {
                Button(event.rawValue.capitalized) {
                    send(event)
                }
                .buttonStyle(.borderedProminent)
            }

            if state == .running {
                Button("Pause") { send(.pause) }
            } else if state == .paused {
                Button("Resume") { send(.resume) }
            }

            if state == .prepared || state == .running || state == .paused {
                Button("Discard", role: .destructive) { send(.discard) }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding()
    }

    private var primaryEvent: WorkoutSessionEvent? {
        switch state {
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
            do {
                let snapshot = try await coordinator.send(event)
                state = snapshot.state
                errorMessage = nil
            } catch {
                errorMessage = "Unable to \(event.rawValue)."
            }
        }
    }
}
