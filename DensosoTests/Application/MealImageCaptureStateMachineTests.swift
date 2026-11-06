import XCTest
@testable import Densoso

@MainActor
final class MealImageCaptureStateMachineTests: XCTestCase {
    func testOpenPhotoRequiresConsentBeforeUploadAndMovesThroughVisionResolution() {
        var state = MealImageCaptureState.idle
        state = MealImageCaptureStateMachine.transition(from: state, event: .selected)
        XCTAssertEqual(state, .selected)
        state = MealImageCaptureStateMachine.transition(from: state, event: .sanitizing)
        XCTAssertEqual(state, .sanitizing)
        state = MealImageCaptureStateMachine.transition(from: state, event: .localScanning)
        XCTAssertEqual(state, .localScanning)
        state = MealImageCaptureStateMachine.transition(from: state, event: .deepseekRequired)
        XCTAssertEqual(state, .deepseekRequired)
        state = MealImageCaptureStateMachine.transition(from: state, event: .consentPrompt)
        XCTAssertEqual(state, .consent)

        XCTAssertFalse(state.canSend(preparedRequestExists: true, consentGranted: false))
        state = MealImageCaptureStateMachine.transition(from: state, event: .consentGranted)
        XCTAssertTrue(state.canSend(preparedRequestExists: true, consentGranted: true))

        XCTAssertEqual(
            MealImageCaptureStateMachine.transition(
                from: state,
                event: .uploadStarted,
                preparedRequestExists: true,
                consentGranted: false
            ),
            .consent
        )
        state = MealImageCaptureStateMachine.transition(
            from: state,
            event: .uploadStarted,
            preparedRequestExists: true,
            consentGranted: true
        )
        XCTAssertEqual(state, .uploading)
        state = MealImageCaptureStateMachine.transition(from: state, event: .visionStarted)
        XCTAssertEqual(state, .vision)
        state = MealImageCaptureStateMachine.transition(from: state, event: .resolved)
        XCTAssertEqual(state, .resolved)
        XCTAssertFalse(state.canSend(preparedRequestExists: true, consentGranted: true))
    }

    func testLocalResolutionAndCancellationNeverBecomeUploadable() {
        let localResolved = MealImageCaptureStateMachine.transition(
            from: .localScanning,
            event: .localResolved
        )
        XCTAssertEqual(localResolved, .localResolved)
        XCTAssertFalse(localResolved.canSend(preparedRequestExists: true, consentGranted: true))
        let stagedLocally = MealImageCaptureStateMachine.transition(
            from: localResolved,
            event: .resolved
        )
        XCTAssertEqual(stagedLocally, .resolved)
        XCTAssertFalse(stagedLocally.canSend(preparedRequestExists: true, consentGranted: true))

        let cancelled = MealImageCaptureStateMachine.transition(
            from: .consent,
            event: .cancelled
        )
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertFalse(cancelled.canSend(preparedRequestExists: false, consentGranted: true))
    }
}
