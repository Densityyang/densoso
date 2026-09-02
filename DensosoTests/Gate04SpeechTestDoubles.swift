import Foundation
@testable import Densoso

enum Gate04TestError: Error, Equatable {
    case configuredFailure
}

@MainActor
final class FakeAudioSessionController: AudioSessionControlling {
    var permissionGranted = true
    var configureError: Error?
    var activationError: Error?
    var route = SpeechAudioRouteSnapshot(
        inputPortType: "builtInMic",
        sampleRate: 48_000,
        channelCount: 1
    )
    private var eventContinuation: AsyncStream<SpeechAudioSessionEvent>.Continuation?

    private(set) var permissionRequests = 0
    private(set) var configureCalls = 0
    private(set) var activateCalls = 0
    private(set) var deactivateCalls = 0

    func requestRecordPermission() async -> Bool {
        permissionRequests += 1
        return permissionGranted
    }

    func configureForMeasurement() throws {
        configureCalls += 1
        if let configureError { throw configureError }
    }

    func activate() throws -> SpeechAudioRouteSnapshot {
        activateCalls += 1
        if let activationError { throw activationError }
        return route
    }

    func deactivate() throws {
        deactivateCalls += 1
    }

    func eventStream() -> AsyncStream<SpeechAudioSessionEvent> {
        let (stream, continuation) = AsyncStream<SpeechAudioSessionEvent>.makeStream()
        eventContinuation = continuation
        return stream
    }

    func emit(_ event: SpeechAudioSessionEvent) {
        eventContinuation?.yield(event)
    }
}

@MainActor
final class FakeAudioFrameStreamer: AudioFrameStreaming {
    var prepareError: Error?
    var installError: Error?
    var startError: Error?
    var format = SpeechAudioFormatSnapshot(sampleRate: 48_000, channelCount: 1)
    private var frameContinuation: AsyncStream<SpeechAudioFrame>.Continuation?

    private(set) var isRunning = false
    private(set) var isTapInstalled = false
    private(set) var prepareCalls = 0
    private(set) var installCalls = 0
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var removeTapCalls = 0
    private(set) var resetCalls = 0
    var droppedFrameCount = 0

    func prepare() throws -> SpeechAudioFormatSnapshot {
        prepareCalls += 1
        if let prepareError { throw prepareError }
        return format
    }

    func installTap() throws -> AsyncStream<SpeechAudioFrame> {
        installCalls += 1
        if let installError { throw installError }
        guard !isTapInstalled else { throw AudioCapturePlatformError.tapAlreadyInstalled }
        isTapInstalled = true
        let (stream, continuation) = AsyncStream<SpeechAudioFrame>.makeStream()
        frameContinuation = continuation
        return stream
    }

    func start() throws {
        startCalls += 1
        if let startError { throw startError }
        isRunning = true
    }

    func stop() {
        stopCalls += 1
        isRunning = false
    }

    func removeTap() {
        guard isTapInstalled else { return }
        removeTapCalls += 1
        isTapInstalled = false
        frameContinuation?.finish()
        frameContinuation = nil
    }

    func resetAfterMediaServicesReset() {
        resetCalls += 1
        isRunning = false
        isTapInstalled = false
        frameContinuation?.finish()
        frameContinuation = nil
    }

    func emit(_ frame: SpeechAudioFrame) {
        frameContinuation?.yield(frame)
    }
}

@MainActor
final class ScriptedVoiceTranscriber: VoiceTranscribing {
    let backendID: SpeechBackendID
    let results: AsyncThrowingStream<SpeechTranscriptUpdate, Error>
    private let continuation: AsyncThrowingStream<SpeechTranscriptUpdate, Error>.Continuation

    private(set) var appendedFrames: [SpeechAudioFrame] = []
    private(set) var finishCalls = 0
    private(set) var cancelCalls = 0

    init(backendID: SpeechBackendID) {
        self.backendID = backendID
        let (stream, continuation) = AsyncThrowingStream<SpeechTranscriptUpdate, Error>.makeStream()
        results = stream
        self.continuation = continuation
    }

    func append(_ frame: SpeechAudioFrame) {
        appendedFrames.append(frame)
    }

    func finish() async throws {
        finishCalls += 1
        continuation.finish()
    }

    func cancel() async {
        cancelCalls += 1
        continuation.finish(throwing: CancellationError())
    }

    func emit(text: String, isFinal: Bool = false) {
        continuation.yield(SpeechTranscriptUpdate(text: text, isFinal: isFinal))
        if isFinal { continuation.finish() }
    }

    func fail(_ error: Error = Gate04TestError.configuredFailure) {
        continuation.finish(throwing: error)
    }
}

@MainActor
final class FakeVoiceTranscriberFactory: VoiceTranscriberFactory {
    var modernAvailable = true
    var modernError: Error?
    var legacyError: Error?
    var modern = ScriptedVoiceTranscriber(backendID: .speechAnalyzer)
    var legacy = ScriptedVoiceTranscriber(backendID: .legacySpeechRecognizer)

    private(set) var modernAvailabilityChecks = 0
    private(set) var modernMakeCalls = 0
    private(set) var legacyMakeCalls = 0

    func isModernTranscriptionAvailable(locale: Locale) async -> Bool {
        modernAvailabilityChecks += 1
        return modernAvailable
    }

    func makeModernTranscriber(locale: Locale) async throws -> any VoiceTranscribing {
        modernMakeCalls += 1
        if let modernError { throw modernError }
        return modern
    }

    func makeLegacyTranscriber(locale: Locale) async throws -> any VoiceTranscribing {
        legacyMakeCalls += 1
        if let legacyError { throw legacyError }
        return legacy
    }
}

actor FakeCloudSpeechProvider: CloudSpeechProvider {
    var result = CloudTranscript(
        text: "云端转写结果",
        model: QwenASRProvider.model,
        billedAudioSeconds: 1,
        attempt: 1
    )
    var error: Error?
    private var capturedAudio: [SanitizedAudio] = []

    func transcribe(audio: SanitizedAudio, locale: Locale) throws -> CloudTranscript {
        capturedAudio.append(audio)
        if let error { throw error }
        return result
    }

    func callCount() -> Int { capturedAudio.count }
}

actor InMemorySpeechAudioStore: SpeechAudioStoring {
    enum FailureStage: Equatable, Sendable {
        case begin, append, finalize
    }

    private(set) var cleanupCalls = 0
    private(set) var beginCalls = 0
    private(set) var discardCalls = 0
    private var frames: [SpeechAudioFrame] = []
    private var failureStage: FailureStage?

    func cleanupStaleFiles() { cleanupCalls += 1 }

    func begin(requestID: UUID) throws {
        if failureStage == .begin { throw Gate04TestError.configuredFailure }
        beginCalls += 1
        frames.removeAll()
    }

    func append(_ frame: SpeechAudioFrame) throws {
        if failureStage == .append { throw Gate04TestError.configuredFailure }
        frames.append(frame)
    }

    func finalize() throws -> SanitizedAudio? {
        if failureStage == .finalize { throw Gate04TestError.configuredFailure }
        guard !frames.isEmpty else { return nil }
        return SanitizedAudio(
            data: Data("RIFF-fixture".utf8),
            mimeType: "audio/wav",
            durationSeconds: frames.reduce(0) { $0 + $1.durationSeconds },
            sampleRate: SpeechAudioFrame.canonicalSampleRate,
            channelCount: SpeechAudioFrame.canonicalChannelCount
        )
    }

    func discard() {
        discardCalls += 1
        frames.removeAll()
    }

    func storedFrameCount() -> Int { frames.count }
    func fail(at stage: FailureStage?) { failureStage = stage }
}

actor RecordingSpeechDiagnostics: SpeechDiagnosticsRecording {
    private var events: [SpeechDiagnosticEvent] = []

    func record(_ event: SpeechDiagnosticEvent) { events.append(event) }

    func export() throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gate04-diagnostics.json")
    }

    func recordedEvents() -> [SpeechDiagnosticEvent] { events }
}

enum Gate04Fixtures {
    static func frame(frameCount: Int = 1_600) -> SpeechAudioFrame {
        SpeechAudioFrame(
            pcm16LittleEndian: Data(repeating: 0, count: frameCount * MemoryLayout<Int16>.size),
            frameCount: frameCount,
            presentationTimeSeconds: 0
        )
    }
}
