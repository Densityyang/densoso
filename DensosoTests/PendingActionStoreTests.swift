import XCTest
@testable import Densoso

@MainActor
final class PendingActionStoreTests: XCTestCase {
    func testSameKeyReturnsOnePendingActionAndCannotCommitTwice() throws {
        let store = PendingActionStore()
        let preparation = PendingActionPreparation(payload: .workout(sampleWorkout), idempotencyKey: "same")

        let first = try store.enqueue(preparation)
        let second = try store.enqueue(preparation)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.actions.count, 1)

        _ = try store.beginConfirmation(id: first.id)
        store.finishConfirmation(id: first.id)
        XCTAssertThrowsError(try store.enqueue(preparation)) { error in
            XCTAssertEqual((error as? PendingActionError)?.errorDescription, PendingActionError.alreadyCommitted.errorDescription)
        }
    }

    func testExpiredActionCannotBeConfirmed() throws {
        var current = Date(timeIntervalSince1970: 1_000)
        let store = PendingActionStore(ttl: 60, now: { current })
        let action = try store.enqueue(PendingActionPreparation(payload: .workout(sampleWorkout), idempotencyKey: "expired"))
        current = current.addingTimeInterval(61)
        XCTAssertThrowsError(try store.beginConfirmation(id: action.id))
    }

    func testDeepSeekRequestsDisableThinking() throws {
        let request = DeepSeekClient.Request(model: "test", maxTokens: 1, system: nil, messages: [], tools: nil, toolChoice: nil, thinking: .disabled)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        let thinking = object?["thinking"] as? [String: String]
        XCTAssertEqual(thinking?["type"], "disabled")
    }

    private var sampleWorkout: WorkoutDraft {
        WorkoutDraft(date: Date(), type: "walking", durationMinutes: 30, intensity: "light", estimatedCalories: 100, notes: nil)
    }
}
