import DensosoDomain
import XCTest
@testable import Densoso

@MainActor
final class AgentUIStateMachineTests: XCTestCase {
    func testAgentEventsMoveThroughThinkingToolDraftConfirmationCommitAndFailureStates() {
        let action = PendingAction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000771")!,
            idempotencyKey: "ui-state-fixture",
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000772")!,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_800_086_400),
            payload: .weight(WeightDraft(
                measuredAt: Date(timeIntervalSince1970: 1_800_000_000),
                kilograms: 62.5
            )),
            state: .pending
        )

        var state = AgentUIState.idle
        state = AgentUIStateMachine.transition(
            from: state,
            event: .accepted(requestID: UUID()),
            hasDraftInCurrentTurn: false
        )
        XCTAssertEqual(state, .thinking)

        state = AgentUIStateMachine.transition(
            from: state,
            event: .toolCallStarted(name: "log_weight", index: 1),
            hasDraftInCurrentTurn: false
        )
        XCTAssertEqual(state, .toolExecuting(name: "log_weight"))
        XCTAssertTrue(state.isBusy)
        XCTAssertTrue(state.canCancel)

        state = AgentUIStateMachine.transition(
            from: state,
            event: .pendingAction(action),
            hasDraftInCurrentTurn: true
        )
        XCTAssertEqual(state, .draftReady)

        state = AgentUIStateMachine.transition(
            from: state,
            event: .awaitingConfirmation,
            hasDraftInCurrentTurn: true
        )
        XCTAssertEqual(state, .awaitingConfirmation)

        state = AgentUIStateMachine.transition(
            from: state,
            event: .completed(AgentResponse(text: "请确认。", toolCallsCount: 1, providerRoundsCount: 2)),
            hasDraftInCurrentTurn: true
        )
        XCTAssertEqual(state, .awaitingConfirmation)
        XCTAssertFalse(state.isBusy)

        state = AgentUIStateMachine.transition(
            from: state,
            event: .committing(actionID: action.id),
            hasDraftInCurrentTurn: true
        )
        XCTAssertEqual(state, .committing)
        XCTAssertTrue(state.isBusy)
        XCTAssertFalse(state.canCancel)

        state = AgentUIStateMachine.transition(
            from: state,
            event: .completed(AgentResponse(text: "已保存。", toolCallsCount: 0, providerRoundsCount: 0)),
            hasDraftInCurrentTurn: false
        )
        XCTAssertEqual(state, .completed)

        state = AgentUIStateMachine.transition(
            from: state,
            event: .failed(.providerUnavailableFallback),
            hasDraftInCurrentTurn: false
        )
        XCTAssertEqual(state, .failed)

        let readOnlyCompletion = AgentUIStateMachine.transition(
            from: .thinking,
            event: .completed(AgentResponse(text: "查询完成。", toolCallsCount: 0, providerRoundsCount: 1)),
            hasDraftInCurrentTurn: false
        )
        XCTAssertEqual(readOnlyCompletion, .completed)

        let cancelled = AgentUIStateMachine.transition(
            from: .thinking,
            event: .cancelled(requestID: UUID()),
            hasDraftInCurrentTurn: false
        )
        XCTAssertEqual(cancelled, .idle)

        let cancelledAfterDraft = AgentUIStateMachine.transition(
            from: .thinking,
            event: .cancelled(requestID: UUID()),
            hasDraftInCurrentTurn: true
        )
        XCTAssertEqual(cancelledAfterDraft, .awaitingConfirmation)
        XCTAssertEqual(
            AgentUIStateMachine.transition(
                from: cancelledAfterDraft,
                event: .cancelled(requestID: UUID()),
                hasDraftInCurrentTurn: false
            ),
            .awaitingConfirmation
        )
    }

    func testVoiceUIStateMapsExistingSpeechCaptureStatesAndFailureKinds() {
        XCTAssertEqual(
            AgentUIStateMachine.voiceState(from: .requestingPermission, transcribedText: ""),
            .starting
        )
        XCTAssertEqual(
            AgentUIStateMachine.voiceState(from: .recording, transcribedText: ""),
            .listening
        )
        let partialTranscriptState = AgentUIStateMachine.voiceState(
            from: .recording,
            transcribedText: "午餐吃了米饭"
        )
        XCTAssertEqual(partialTranscriptState, .transcribing)
        XCTAssertEqual(partialTranscriptState.buttonTitle, "停止录音")
        XCTAssertEqual(partialTranscriptState.buttonSystemImage, "stop.fill")
        XCTAssertEqual(
            AgentUIStateMachine.voiceState(from: .finalizing, transcribedText: "午餐吃了米饭"),
            .finalizing
        )
        XCTAssertEqual(
            AgentUIStateMachine.voiceState(from: .completed, transcribedText: "午餐吃了米饭"),
            .submitted
        )
        XCTAssertEqual(
            AgentUIStateMachine.voiceState(
                from: .failed(failure(kind: .permissionDenied)),
                transcribedText: ""
            ),
            .permissionDenied
        )
        XCTAssertEqual(
            AgentUIStateMachine.voiceState(
                from: .failed(failure(kind: .routeUnavailable)),
                transcribedText: ""
            ),
            .microphoneUnavailable
        )
        XCTAssertEqual(
            AgentUIStateMachine.voiceState(
                from: .failed(failure(kind: .transcriptionFailed)),
                transcribedText: ""
            ),
            .speechUnavailable
        )
        XCTAssertEqual(
            AgentUIStateMachine.voiceState(
                from: .failed(failure(kind: .cancelled)),
                transcribedText: ""
            ),
            .cancelled
        )
    }

    private func failure(kind: SpeechCaptureFailureKind) -> SpeechCaptureFailure {
        SpeechCaptureFailure(
            requestID: UUID(),
            stage: .recording,
            kind: kind,
            backend: nil,
            osStatus: nil,
            underlyingDomain: nil,
            underlyingCode: nil,
            isRecoverable: true
        )
    }
}
