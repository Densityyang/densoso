import XCTest
@testable import Densoso

@MainActor
final class SpeechCaptureStateMachineTests: XCTestCase {
    func testSuccessfulCaptureUsesOneTapAndSupportsRepeatedStartStop() async throws {
        let harness = try await SpeechHarness()
        let authorized = await harness.service.requestAuthorization()
        XCTAssertTrue(authorized)

        try await harness.service.startRecording()
        try await harness.service.startRecording()
        XCTAssertEqual(harness.streamer.installCalls, 1)
        XCTAssertEqual(harness.streamer.startCalls, 1)
        XCTAssertTrue(harness.service.isRecording)

        harness.streamer.emit(Gate04Fixtures.frame())
        harness.factory.modern.emit(text: "午饭吃了米饭", isFinal: true)
        await drainTasks()
        await harness.service.stopRecording()
        await harness.service.stopRecording()

        XCTAssertEqual(harness.service.state, .completed)
        XCTAssertEqual(harness.service.transcribedText, "午饭吃了米饭")
        XCTAssertEqual(harness.streamer.removeTapCalls, 1)
        XCTAssertFalse(harness.streamer.isTapInstalled)
        let cloudCalls = await harness.cloud.callCount()
        XCTAssertEqual(cloudCalls, 0)
    }

    func testConcurrentStopFinalizesOnlyOnce() async throws {
        let harness = try await SpeechHarness()
        _ = await harness.service.requestAuthorization()
        try await harness.service.startRecording()
        harness.factory.modern.emit(text: "完成文本", isFinal: true)
        await drainTasks()

        let first = Task { @MainActor in await harness.service.stopRecording() }
        let second = Task { @MainActor in await harness.service.stopRecording() }
        await first.value
        await second.value

        XCTAssertEqual(harness.factory.modern.finishCalls, 1)
        XCTAssertEqual(harness.service.state, .completed)
    }

    func testEveryStartFailureStageStopsBeforeCloudASR() async throws {
        let permission = try await SpeechHarness(cloudEnabled: true, audioConsent: true)
        permission.session.permissionGranted = false
        await assertStartFailure(permission, expected: .permissionDenied)

        let configuration = try await SpeechHarness(cloudEnabled: true, audioConsent: true)
        configuration.session.configureError = Gate04TestError.configuredFailure
        await assertStartFailure(configuration, expected: .sessionConfiguration)

        let route = try await SpeechHarness(cloudEnabled: true, audioConsent: true)
        route.session.route = SpeechAudioRouteSnapshot(inputPortType: nil, sampleRate: 0, channelCount: 0)
        await assertStartFailure(route, expected: .routeUnavailable)

        let format = try await SpeechHarness(cloudEnabled: true, audioConsent: true)
        format.streamer.prepareError = Gate04TestError.configuredFailure
        await assertStartFailure(format, expected: .invalidAudioFormat)

        let tap = try await SpeechHarness(cloudEnabled: true, audioConsent: true)
        tap.streamer.installError = Gate04TestError.configuredFailure
        await assertStartFailure(tap, expected: .tapInstallation)

        let engine = try await SpeechHarness(cloudEnabled: true, audioConsent: true)
        engine.streamer.startError = Gate04TestError.configuredFailure
        await assertStartFailure(engine, expected: .engineStart)
    }

    func testModernRuntimeFailureFallsBackToLegacyAndReplaysCapturedFrames() async throws {
        let harness = try await SpeechHarness()
        _ = await harness.service.requestAuthorization()
        try await harness.service.startRecording()
        let frame = Gate04Fixtures.frame()
        harness.streamer.emit(frame)
        await drainTasks()

        harness.factory.modern.fail()
        await drainTasks(iterations: 20)

        XCTAssertEqual(harness.factory.legacyMakeCalls, 1)
        XCTAssertEqual(harness.factory.legacy.appendedFrames, [frame])
        XCTAssertEqual(harness.service.runtime, .legacySpeech)
        await harness.service.cancelRecording()
    }

    func testLocalFailureWithCapturedAudioUsesQwenOnceAndDeletesTemporaryAudio() async throws {
        let harness = try await SpeechHarness(cloudEnabled: true, audioConsent: true)
        harness.factory.modernAvailable = false
        _ = await harness.service.requestAuthorization()
        try await harness.service.startRecording()
        harness.streamer.emit(Gate04Fixtures.frame())
        await drainTasks()
        harness.factory.legacy.fail()
        await drainTasks(iterations: 20)

        await harness.service.stopRecording()

        let cloudCalls = await harness.cloud.callCount()
        XCTAssertEqual(cloudCalls, 1)
        XCTAssertEqual(harness.service.transcribedText, "云端转写结果")
        XCTAssertEqual(harness.service.envelopeSource, .qwenASR)
        XCTAssertEqual(harness.service.state, .completed)
        let discardCalls = await harness.store.discardCalls
        let usageCount = await harness.governance.usageCount()
        XCTAssertGreaterThanOrEqual(discardCalls, 1)
        XCTAssertEqual(usageCount, 1)
    }

    func testNoCapturedAudioNeverCallsQwenASR() async throws {
        let harness = try await SpeechHarness(cloudEnabled: true, audioConsent: true)
        harness.factory.modernAvailable = false
        _ = await harness.service.requestAuthorization()
        try await harness.service.startRecording()
        harness.factory.legacy.fail()
        await drainTasks(iterations: 20)

        await harness.service.stopRecording()

        let cloudCalls = await harness.cloud.callCount()
        XCTAssertEqual(cloudCalls, 0)
        guard case .failed(let failure) = harness.service.state else {
            return XCTFail("Expected manual fallback failure")
        }
        XCTAssertEqual(failure.kind, .transcriptionUnavailable)
    }

    func testCloudFallbackRequiresIndependentAudioConsent() async throws {
        let harness = try await SpeechHarness(cloudEnabled: true, audioConsent: false)
        harness.factory.modernAvailable = false
        harness.factory.legacyError = Gate04TestError.configuredFailure
        _ = await harness.service.requestAuthorization()

        do {
            try await harness.service.startRecording()
            XCTFail("Expected no transcription route")
        } catch let failure as SpeechCaptureFailure {
            XCTAssertEqual(failure.kind, .transcriptionUnavailable)
        }
        let beginCalls = await harness.store.beginCalls
        let cloudCalls = await harness.cloud.callCount()
        XCTAssertEqual(beginCalls, 0)
        XCTAssertEqual(cloudCalls, 0)
    }

    func testRevokingAudioConsentBeforeFinalizePreventsUpload() async throws {
        let harness = try await SpeechHarness(cloudEnabled: true, audioConsent: true)
        harness.factory.modernAvailable = false
        _ = await harness.service.requestAuthorization()
        try await harness.service.startRecording()
        harness.streamer.emit(Gate04Fixtures.frame())
        await drainTasks()
        harness.factory.legacy.fail()
        await drainTasks(iterations: 20)
        try await harness.governance.setConsent(
            provider: .qwen,
            dataClass: .speechAudio,
            granted: false,
            policyVersion: "revoked"
        )

        await harness.service.stopRecording()

        let cloudCalls = await harness.cloud.callCount()
        XCTAssertEqual(cloudCalls, 0)
        guard case .failed(let failure) = harness.service.state else {
            return XCTFail("Expected consent failure")
        }
        XCTAssertEqual(failure.kind, .cloudConsentRequired)
    }

    func testFailureCleanupWaitsForOldTasksBeforeNextCapture() async throws {
        let harness = try await SpeechHarness()
        _ = await harness.service.requestAuthorization()
        try await harness.service.startRecording()
        harness.streamer.emit(Gate04Fixtures.frame(frameCount: 800))
        await drainTasks()
        await harness.service.cancelRecording()

        harness.factory.modern = ScriptedVoiceTranscriber(backendID: .speechAnalyzer)
        harness.factory.legacy = ScriptedVoiceTranscriber(backendID: .legacySpeechRecognizer)
        try await harness.service.startRecording()
        let currentFrame = Gate04Fixtures.frame(frameCount: 1_600)
        harness.streamer.emit(currentFrame)
        await drainTasks()
        harness.factory.modern.fail()
        await drainTasks(iterations: 20)

        XCTAssertEqual(harness.factory.legacy.appendedFrames, [currentFrame])
        await harness.service.cancelRecording()
    }

    func testDroppedFrameFailsClosedWithoutCloudUpload() async throws {
        let harness = try await SpeechHarness(cloudEnabled: true, audioConsent: true)
        _ = await harness.service.requestAuthorization()
        try await harness.service.startRecording()
        harness.streamer.droppedFrameCount = 1
        harness.streamer.emit(Gate04Fixtures.frame())
        harness.factory.modern.emit(text: "本地完整文本", isFinal: true)
        await drainTasks()

        await harness.service.stopRecording()

        let cloudCalls = await harness.cloud.callCount()
        XCTAssertEqual(cloudCalls, 0)
        guard case .failed(let failure) = harness.service.state else {
            return XCTFail("Expected dropped-frame failure")
        }
        XCTAssertEqual(failure.kind, .droppedAudioFrames)
    }

    func testTemporaryAudioFinalizeFailureIsTypedAndCleaned() async throws {
        let harness = try await SpeechHarness(cloudEnabled: true, audioConsent: true)
        harness.factory.modernAvailable = false
        await harness.store.fail(at: .finalize)
        _ = await harness.service.requestAuthorization()
        try await harness.service.startRecording()
        harness.streamer.emit(Gate04Fixtures.frame())
        await drainTasks()
        harness.factory.legacy.fail()
        await drainTasks(iterations: 20)

        await harness.service.stopRecording()

        let cloudCalls = await harness.cloud.callCount()
        let discardCalls = await harness.store.discardCalls
        XCTAssertEqual(cloudCalls, 0)
        XCTAssertGreaterThanOrEqual(discardCalls, 1)
        guard case .failed(let failure) = harness.service.state else {
            return XCTFail("Expected temporary-audio failure")
        }
        XCTAssertEqual(failure.kind, .temporaryAudio)
    }

    func testTemporaryAudioBeginFailureWinsWhenNoLocalBackendExists() async throws {
        let harness = try await SpeechHarness(cloudEnabled: true, audioConsent: true)
        harness.factory.modernAvailable = false
        harness.factory.legacyError = Gate04TestError.configuredFailure
        await harness.store.fail(at: .begin)
        _ = await harness.service.requestAuthorization()

        do {
            try await harness.service.startRecording()
            XCTFail("Expected typed temporary-audio failure")
        } catch let failure as SpeechCaptureFailure {
            XCTAssertEqual(failure.kind, .temporaryAudio)
        }
        let cloudCalls = await harness.cloud.callCount()
        let discardCalls = await harness.store.discardCalls
        XCTAssertEqual(cloudCalls, 0)
        XCTAssertGreaterThanOrEqual(discardCalls, 1)
    }

    func testInterruptionRouteChangeAndMediaResetStopWithoutSilentRestart() async throws {
        try await assertSystemEvent(
            .interruptionBegan,
            expected: .interrupted,
            expectedResetCalls: 0
        )
        try await assertSystemEvent(
            .routeChanged(
                reason: 1,
                route: SpeechAudioRouteSnapshot(
                    inputPortType: "headsetMic",
                    sampleRate: 48_000,
                    channelCount: 1
                )
            ),
            expected: .routeChanged,
            expectedResetCalls: 0
        )
        try await assertSystemEvent(
            .mediaServicesReset,
            expected: .mediaServicesReset,
            expectedResetCalls: 1
        )
    }

    func testSystemEventNeverUploadsCapturedAudio() async throws {
        let harness = try await SpeechHarness(cloudEnabled: true, audioConsent: true)
        _ = await harness.service.requestAuthorization()
        try await harness.service.startRecording()
        harness.streamer.emit(Gate04Fixtures.frame())
        await drainTasks()
        harness.session.emit(.interruptionBegan)
        await drainTasks(iterations: 20)

        let cloudCalls = await harness.cloud.callCount()
        XCTAssertEqual(cloudCalls, 0)
    }

    func testCancelDeletesTemporaryAudioAndDoesNotCallCloud() async throws {
        let harness = try await SpeechHarness(cloudEnabled: true, audioConsent: true)
        _ = await harness.service.requestAuthorization()
        try await harness.service.startRecording()
        harness.streamer.emit(Gate04Fixtures.frame())
        await drainTasks()

        await harness.service.cancelRecording()

        let cloudCalls = await harness.cloud.callCount()
        let discardCalls = await harness.store.discardCalls
        XCTAssertEqual(cloudCalls, 0)
        XCTAssertGreaterThanOrEqual(discardCalls, 1)
        guard case .failed(let failure) = harness.service.state else {
            return XCTFail("Expected typed cancellation")
        }
        XCTAssertEqual(failure.kind, .cancelled)
    }

    func testDurationBoundaryWarnsAndStopsAtMaximum() async throws {
        let harness = try await SpeechHarness(
            policy: SpeechCapturePolicy(
                warningAfterSeconds: 0.01,
                maximumDurationSeconds: 0.02,
                minimumCloudFallbackSeconds: 0.1
            )
        )
        _ = await harness.service.requestAuthorization()
        try await harness.service.startRecording()

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertFalse(harness.service.isRecording)
        XCTAssertNotNil(harness.service.durationWarning)
        XCTAssertGreaterThanOrEqual(harness.streamer.stopCalls, 1)
    }

    private func assertStartFailure(
        _ harness: SpeechHarness,
        expected: SpeechCaptureFailureKind
    ) async {
        do {
            try await harness.service.startRecording()
            XCTFail("Expected \(expected)")
        } catch let failure as SpeechCaptureFailure {
            XCTAssertEqual(failure.kind, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(harness.streamer.isRunning)
        XCTAssertFalse(harness.streamer.isTapInstalled)
        let cloudCalls = await harness.cloud.callCount()
        XCTAssertEqual(cloudCalls, 0)
    }

    private func assertSystemEvent(
        _ event: SpeechAudioSessionEvent,
        expected: SpeechCaptureFailureKind,
        expectedResetCalls: Int
    ) async throws {
        let harness = try await SpeechHarness()
        _ = await harness.service.requestAuthorization()
        try await harness.service.startRecording()
        harness.session.emit(event)
        await drainTasks(iterations: 20)

        guard case .failed(let failure) = harness.service.state else {
            return XCTFail("Expected failed state")
        }
        XCTAssertEqual(failure.kind, expected)
        XCTAssertFalse(harness.service.isRecording)
        XCTAssertEqual(harness.streamer.resetCalls, expectedResetCalls)
        XCTAssertEqual(harness.streamer.startCalls, 1)
    }
}

@MainActor
private struct SpeechHarness {
    let session = FakeAudioSessionController()
    let streamer = FakeAudioFrameStreamer()
    let factory = FakeVoiceTranscriberFactory()
    let cloud = FakeCloudSpeechProvider()
    let store = InMemorySpeechAudioStore()
    let diagnostics = RecordingSpeechDiagnostics()
    let governance: InMemoryProviderGovernanceRepository
    let configuration: ProviderConfigurationPreferences
    let service: SpeechService

    init(
        cloudEnabled: Bool = false,
        audioConsent: Bool = false,
        policy: SpeechCapturePolicy = .phase4
    ) async throws {
        let governance = InMemoryProviderGovernanceRepository()
        if audioConsent {
            try await governance.setConsent(
                provider: .qwen,
                dataClass: .speechAudio,
                granted: true,
                policyVersion: "fixture"
            )
        }
        let configuration = ProviderConfigurationPreferences()
        configuration.qwenSpeechFallbackEnabled = cloudEnabled
        self.governance = governance
        self.configuration = configuration
        self.service = SpeechService(
            audioSession: session,
            frameStreamer: streamer,
            transcriberFactory: factory,
            cloudProvider: cloud,
            governanceRepository: governance,
            usageLedger: ProviderUsageLedger(repository: governance),
            providerConfiguration: configuration,
            audioStore: store,
            diagnostics: diagnostics,
            policy: policy
        )
    }
}

@MainActor
private func drainTasks(iterations: Int = 8) async {
    for _ in 0..<iterations { await Task.yield() }
}
