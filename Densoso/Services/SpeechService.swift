import DensosoDomain
import Foundation
import Observation

/// Main-actor facade used by SwiftUI. Platform audio, local transcription and
/// cloud ASR remain behind injectable boundaries so Gate 4 can prove each stage.
@MainActor
@Observable
final class SpeechService {
    enum Runtime: Equatable {
        case speechAnalyzer(localeIdentifier: String)
        case legacySpeech
        case qwenASR
        case manualEntry
    }

    private let locale: Locale
    private let audioSession: any AudioSessionControlling
    private let frameStreamer: any AudioFrameStreaming
    private let transcriberFactory: any VoiceTranscriberFactory
    private let cloudProvider: (any CloudSpeechProvider)?
    private let governanceRepository: (any ProviderGovernanceRepository)?
    private let usageLedger: ProviderUsageLedger?
    private let providerConfiguration: ProviderConfigurationPreferences?
    private let audioStore: any SpeechAudioStoring
    private let diagnostics: any SpeechDiagnosticsRecording
    private let policy: SpeechCapturePolicy

    private var activeRequestID: UUID?
    private var activeTranscriber: (any VoiceTranscribing)?
    private var activeRoute: SpeechAudioRouteSnapshot?
    private var frameHistory: [SpeechAudioFrame] = []
    private var capturedDurationSeconds = 0.0
    private var audioStarted = false
    private var cloudFallbackAllowed = false
    private var localTranscriptionFailed = false
    private var fallbackInProgress = false
    private var captureGeneration: UInt64 = 0
    private var temporaryAudioFailure: SpeechCaptureFailure?

    private var frameTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var sessionEventTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?

    private(set) var state: SpeechCaptureState = .idle
    private(set) var runtime: Runtime = .legacySpeech
    private(set) var activeBackend: SpeechBackendID?
    private(set) var transcriptSource: VoiceCommandEnvelope.Source = .iPhoneLegacySpeech
    private(set) var durationWarning: String?
    private(set) var isAuthorized = false
    private(set) var error: SpeechCaptureFailure?
    var transcribedText = ""

    var isRecording: Bool { state == .recording }
    var envelopeSource: VoiceCommandEnvelope.Source { transcriptSource }

    init(
        locale: Locale = Locale(identifier: "zh-CN"),
        audioSession: any AudioSessionControlling = AVAudioSessionController(),
        frameStreamer: any AudioFrameStreaming = AVAudioFrameStreamer(),
        transcriberFactory: any VoiceTranscriberFactory = SystemVoiceTranscriberFactory(),
        cloudProvider: (any CloudSpeechProvider)? = nil,
        governanceRepository: (any ProviderGovernanceRepository)? = nil,
        usageLedger: ProviderUsageLedger? = nil,
        providerConfiguration: ProviderConfigurationPreferences? = nil,
        audioStore: any SpeechAudioStoring = ProtectedSpeechAudioStore(),
        diagnostics: any SpeechDiagnosticsRecording = SpeechDiagnosticsStore(),
        policy: SpeechCapturePolicy = .phase4
    ) {
        self.locale = locale
        self.audioSession = audioSession
        self.frameStreamer = frameStreamer
        self.transcriberFactory = transcriberFactory
        self.cloudProvider = cloudProvider
        self.governanceRepository = governanceRepository
        self.usageLedger = usageLedger
        self.providerConfiguration = providerConfiguration
        self.audioStore = audioStore
        self.diagnostics = diagnostics
        self.policy = policy
    }

    func cleanupStaleTemporaryAudio() async {
        await audioStore.cleanupStaleFiles()
    }

    func requestAuthorization() async -> Bool {
        state = .requestingPermission
        let granted = await audioSession.requestRecordPermission()
        isAuthorized = granted
        if !granted {
            let failure = makeFailure(
                kind: .permissionDenied,
                stage: .requestingPermission,
                backend: nil,
                error: nil,
                recoverable: true
            )
            error = failure
            state = .failed(failure)
        } else if state == .requestingPermission {
            state = .idle
        }
        return granted
    }

    /// Capability check only. It never downloads assets or requests legacy
    /// Speech permission; those actions happen after a user taps the microphone.
    func refreshRuntime(locale: Locale = Locale(identifier: "zh-CN")) async {
        if await transcriberFactory.isModernTranscriptionAvailable(locale: locale) {
            runtime = .speechAnalyzer(localeIdentifier: locale.identifier)
        } else {
            runtime = .legacySpeech
        }
    }

    func startRecording() async throws {
        guard !isActiveCapture else { return }
        await resetForNewCapture()
        let requestID = UUID()
        activeRequestID = requestID
        transcribedText = ""
        durationWarning = nil
        error = nil

        state = .requestingPermission
        if !isAuthorized {
            isAuthorized = await audioSession.requestRecordPermission()
        }
        guard isAuthorized else {
            isAuthorized = false
            let failure = makeFailure(
                kind: .permissionDenied,
                stage: .requestingPermission,
                backend: nil,
                error: nil,
                recoverable: true
            )
            await failAndCleanUp(failure, discardAudio: true)
            throw failure
        }
        isAuthorized = true

        state = .configuringSession
        do {
            try audioSession.configureForMeasurement()
            let route = try audioSession.activate()
            guard route.hasUsableInput else {
                throw AudioCapturePlatformError.invalidInputFormat
            }
            activeRoute = route
            await recordDiagnostic(stage: .configuringSession, backend: nil, error: nil)
        } catch {
            let kind: SpeechCaptureFailureKind = (error as? AudioCapturePlatformError) == .invalidInputFormat
                ? .routeUnavailable
                : .sessionConfiguration
            let failure = makeFailure(
                kind: kind,
                stage: .configuringSession,
                backend: nil,
                error: error,
                recoverable: true
            )
            await failAndCleanUp(failure, discardAudio: true)
            throw failure
        }

        cloudFallbackAllowed = await shouldAllowCloudFallback()
        if cloudFallbackAllowed {
            do {
                try await audioStore.begin(requestID: requestID)
            } catch {
                await audioStore.discard()
                cloudFallbackAllowed = false
                temporaryAudioFailure = makeFailure(
                    kind: .temporaryAudio,
                    stage: .preparingBackend,
                    backend: .qwenASR,
                    error: error,
                    recoverable: true
                )
                self.error = temporaryAudioFailure
                await recordDiagnostic(stage: .preparingBackend, backend: .qwenASR, error: error)
            }
        }

        state = .preparingBackend
        await prepareBestLocalTranscriber()
        if activeTranscriber == nil && !cloudFallbackAllowed {
            let failure = temporaryAudioFailure ?? makeFailure(
                kind: .transcriptionUnavailable,
                stage: .preparingBackend,
                backend: nil,
                error: nil,
                recoverable: true
            )
            await failAndCleanUp(failure, discardAudio: true)
            throw failure
        }

        let inputFormat: SpeechAudioFormatSnapshot
        do {
            inputFormat = try frameStreamer.prepare()
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw AudioCapturePlatformError.invalidInputFormat
            }
        } catch {
            let failure = makeFailure(
                kind: .invalidAudioFormat,
                stage: .preparingBackend,
                backend: activeBackend,
                error: error,
                recoverable: true
            )
            await failAndCleanUp(failure, discardAudio: true)
            throw failure
        }

        let frames: AsyncStream<SpeechAudioFrame>
        do {
            frames = try frameStreamer.installTap()
        } catch {
            let failure = makeFailure(
                kind: .tapInstallation,
                stage: .preparingBackend,
                backend: activeBackend,
                error: error,
                recoverable: true
            )
            await failAndCleanUp(failure, discardAudio: true)
            throw failure
        }
        bindFrameStream(frames)
        bindSessionEvents(audioSession.eventStream())
        do {
            try frameStreamer.start()
        } catch {
            let failure = makeFailure(
                kind: .engineStart,
                stage: .preparingBackend,
                backend: activeBackend,
                error: error,
                recoverable: true
            )
            await failAndCleanUp(failure, discardAudio: true)
            throw failure
        }
        audioStarted = true
        state = .recording
        await recordDiagnostic(
            stage: .recording,
            backend: activeBackend,
            error: nil
        )
        startDurationBoundary()
    }

    func stopRecording() async {
        await finalizeCapture(cancelled: false)
    }

    func cancelRecording() async {
        await finalizeCapture(cancelled: true)
    }

    func exportDiagnostics() async throws -> URL {
        try await diagnostics.export()
    }

    private var isActiveCapture: Bool {
        switch state {
        case .requestingPermission, .configuringSession, .preparingBackend, .recording, .finalizing:
            true
        default:
            false
        }
    }

    private func prepareBestLocalTranscriber() async {
        if await transcriberFactory.isModernTranscriptionAvailable(locale: locale) {
            do {
                let transcriber = try await transcriberFactory.makeModernTranscriber(locale: locale)
                activate(transcriber)
                runtime = .speechAnalyzer(localeIdentifier: locale.identifier)
                transcriptSource = .iPhoneSpeechAnalyzer
                return
            } catch {
                await recordDiagnostic(stage: .preparingBackend, backend: .speechAnalyzer, error: error)
            }
        }

        do {
            let transcriber = try await transcriberFactory.makeLegacyTranscriber(locale: locale)
            activate(transcriber)
            runtime = .legacySpeech
            transcriptSource = .iPhoneLegacySpeech
        } catch {
            localTranscriptionFailed = true
            activeTranscriber = nil
            activeBackend = nil
            await recordDiagnostic(
                stage: .preparingBackend,
                backend: .legacySpeechRecognizer,
                error: error
            )
        }
    }

    private func activate(_ transcriber: any VoiceTranscribing) {
        activeTranscriber = transcriber
        activeBackend = transcriber.backendID
        localTranscriptionFailed = false
        bindTranscriberResults(transcriber)
    }

    private func bindTranscriberResults(_ transcriber: any VoiceTranscribing) {
        resultTask?.cancel()
        let backendID = transcriber.backendID
        let results = transcriber.results
        let generation = captureGeneration
        resultTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await update in results {
                    guard !Task.isCancelled,
                          self.captureGeneration == generation else { return }
                    self.transcribedText = update.text
                    if !update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.localTranscriptionFailed = false
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                await self.handleLocalTranscriberFailure(
                    backend: backendID,
                    error: error,
                    generation: generation
                )
            }
        }
    }

    private func handleLocalTranscriberFailure(
        backend: SpeechBackendID,
        error: Error,
        generation: UInt64
    ) async {
        guard captureGeneration == generation else { return }
        localTranscriptionFailed = true
        await recordDiagnostic(stage: .recording, backend: backend, error: error)
        guard state == .recording, !fallbackInProgress else { return }

        guard backend == .speechAnalyzer else {
            activeTranscriber = nil
            activeBackend = cloudFallbackAllowed ? .qwenASR : .manualEntry
            runtime = cloudFallbackAllowed ? .qwenASR : .manualEntry
            return
        }

        fallbackInProgress = true
        defer { fallbackInProgress = false }
        await activeTranscriber?.cancel()
        do {
            let legacy = try await transcriberFactory.makeLegacyTranscriber(locale: locale)
            for frame in frameHistory { legacy.append(frame) }
            activate(legacy)
            runtime = .legacySpeech
            transcriptSource = .iPhoneLegacySpeech
        } catch {
            activeTranscriber = nil
            activeBackend = cloudFallbackAllowed ? .qwenASR : .manualEntry
            runtime = cloudFallbackAllowed ? .qwenASR : .manualEntry
            await recordDiagnostic(
                stage: .recording,
                backend: .legacySpeechRecognizer,
                error: error
            )
        }
    }

    private func bindFrameStream(_ stream: AsyncStream<SpeechAudioFrame>) {
        frameTask?.cancel()
        let generation = captureGeneration
        frameTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await frame in stream {
                guard !Task.isCancelled,
                      self.captureGeneration == generation else { return }
                self.frameHistory.append(frame)
                self.capturedDurationSeconds += frame.durationSeconds
                self.activeTranscriber?.append(frame)
                if self.cloudFallbackAllowed {
                    do {
                        try await self.audioStore.append(frame)
                    } catch {
                        let failure = self.makeFailure(
                            kind: .temporaryAudio,
                            stage: .recording,
                            backend: .qwenASR,
                            error: error,
                            recoverable: true
                        )
                        self.temporaryAudioFailure = failure
                        self.error = failure
                        self.cloudFallbackAllowed = false
                        await self.audioStore.discard()
                        await self.recordDiagnostic(
                            stage: .recording,
                            backend: .qwenASR,
                            error: error
                        )
                    }
                }
            }
        }
    }

    private func bindSessionEvents(_ stream: AsyncStream<SpeechAudioSessionEvent>) {
        sessionEventTask?.cancel()
        let generation = captureGeneration
        sessionEventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in stream {
                guard !Task.isCancelled,
                      self.captureGeneration == generation else { return }
                switch event {
                case .interruptionBegan:
                    Task { @MainActor [weak self] in
                        await self?.abortForSystemEvent(.interrupted, event: event)
                    }
                    return
                case .routeChanged:
                    Task { @MainActor [weak self] in
                        await self?.abortForSystemEvent(.routeChanged, event: event)
                    }
                    return
                case .mediaServicesReset:
                    self.frameStreamer.resetAfterMediaServicesReset()
                    Task { @MainActor [weak self] in
                        await self?.abortForSystemEvent(.mediaServicesReset, event: event)
                    }
                    return
                case .interruptionEnded:
                    break // Never restart recording silently.
                }
            }
        }
    }

    private func startDurationBoundary() {
        durationTask?.cancel()
        let generation = captureGeneration
        durationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(self.policy.warningAfterSeconds))
                guard self.captureGeneration == generation else { return }
                self.durationWarning = "录音将在 5 秒后自动结束。"
                let remaining = max(
                    self.policy.maximumDurationSeconds - self.policy.warningAfterSeconds,
                    0
                )
                try await Task.sleep(for: .seconds(remaining))
                guard self.captureGeneration == generation else { return }
                Task { @MainActor [weak self] in
                    await self?.stopRecording()
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func finalizeCapture(cancelled: Bool) async {
        guard isActiveCapture, state != .finalizing else { return }
        state = .finalizing
        let finalizingBackend = activeBackend
        let oldDurationTask = durationTask
        let oldSessionEventTask = sessionEventTask
        durationTask = nil
        sessionEventTask = nil
        oldDurationTask?.cancel()
        oldSessionEventTask?.cancel()
        await oldDurationTask?.value
        await oldSessionEventTask?.value

        frameStreamer.stop()
        frameStreamer.removeTap()
        let oldFrameTask = frameTask
        frameTask = nil
        await oldFrameTask?.value

        if cancelled {
            await activeTranscriber?.cancel()
        } else {
            do {
                try await activeTranscriber?.finish()
            } catch {
                localTranscriptionFailed = true
                await recordDiagnostic(
                    stage: .finalizing,
                    backend: finalizingBackend,
                    error: error
                )
            }
        }
        let oldResultTask = resultTask
        resultTask = nil
        if cancelled { oldResultTask?.cancel() }
        await oldResultTask?.value
        activeTranscriber = nil
        activeBackend = nil
        try? audioSession.deactivate()

        if cancelled {
            await audioStore.discard()
            let failure = makeFailure(
                kind: .cancelled,
                stage: .finalizing,
                backend: nil,
                error: nil,
                recoverable: true
            )
            error = failure
            state = .failed(failure)
            return
        }

        if frameStreamer.droppedFrameCount > 0 {
            await audioStore.discard()
            let failure = makeFailure(
                kind: .droppedAudioFrames,
                stage: .finalizing,
                backend: finalizingBackend,
                error: nil,
                recoverable: true
            )
            error = failure
            state = .failed(failure)
            await recordDiagnostic(stage: .finalizing, backend: finalizingBackend, error: failure)
            return
        }

        let localText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUsableLocalTranscript(localText), !localTranscriptionFailed {
            await audioStore.discard()
            state = .completed
            await recordDiagnostic(stage: .completed, backend: nil, error: nil)
            return
        }

        if let temporaryAudioFailure {
            await audioStore.discard()
            runtime = .manualEntry
            error = temporaryAudioFailure
            state = .failed(temporaryAudioFailure)
            return
        }

        let audio: SanitizedAudio?
        do {
            audio = try await audioStore.finalize()
        } catch {
            await audioStore.discard()
            runtime = .manualEntry
            let failure = makeFailure(
                kind: .temporaryAudio,
                stage: .finalizing,
                backend: .qwenASR,
                error: error,
                recoverable: true
            )
            self.error = failure
            state = .failed(failure)
            await recordDiagnostic(stage: .finalizing, backend: .qwenASR, error: error)
            return
        }
        let cloudStillAllowed = await shouldAllowCloudFallback()
        guard audioStarted,
              cloudFallbackAllowed,
              cloudStillAllowed,
              let audio,
              audio.durationSeconds >= policy.minimumCloudFallbackSeconds,
              let cloudProvider else {
            await audioStore.discard()
            runtime = .manualEntry
            let failure = makeFailure(
                kind: cloudFallbackAllowed && !cloudStillAllowed
                    ? .cloudConsentRequired
                    : .transcriptionUnavailable,
                stage: .finalizing,
                backend: .manualEntry,
                error: nil,
                recoverable: true
            )
            error = failure
            state = .failed(failure)
            return
        }

        do {
            let cloud = try await cloudProvider.transcribe(audio: audio, locale: locale)
            transcribedText = cloud.text
            transcriptSource = .qwenASR
            runtime = .qwenASR
            if let usageLedger, let requestID = activeRequestID {
                try? await usageLedger.record(
                    ProviderUsage(
                        provider: .qwen,
                        model: cloud.model,
                        capability: .speech,
                        inputTokens: 0,
                        outputTokens: 0,
                        audioSeconds: cloud.billedAudioSeconds,
                        attempt: cloud.attempt
                    ),
                    requestID: requestID
                )
            }
            state = .completed
            await recordDiagnostic(stage: .completed, backend: .qwenASR, error: nil)
        } catch {
            runtime = .manualEntry
            let failure = makeFailure(
                kind: .cloudRejected,
                stage: .finalizing,
                backend: .qwenASR,
                error: error,
                recoverable: true
            )
            self.error = failure
            state = .failed(failure)
            await recordDiagnostic(stage: .finalizing, backend: .qwenASR, error: error)
        }
        await audioStore.discard()
    }

    private func abortForSystemEvent(
        _ kind: SpeechCaptureFailureKind,
        event: SpeechAudioSessionEvent
    ) async {
        guard isActiveCapture, state != .finalizing else { return }
        let failure = makeFailure(
            kind: kind,
            stage: state.stage,
            backend: activeBackend,
            error: nil,
            recoverable: true
        )
        await failAndCleanUp(failure, discardAudio: true)
    }

    private func failAndCleanUp(
        _ failure: SpeechCaptureFailure,
        discardAudio: Bool
    ) async {
        captureGeneration &+= 1
        frameStreamer.stop()
        frameStreamer.removeTap()
        let oldDurationTask = durationTask
        let oldSessionEventTask = sessionEventTask
        let oldFrameTask = frameTask
        let oldResultTask = resultTask
        durationTask = nil
        sessionEventTask = nil
        frameTask = nil
        resultTask = nil
        oldDurationTask?.cancel()
        oldSessionEventTask?.cancel()
        oldFrameTask?.cancel()
        oldResultTask?.cancel()
        await activeTranscriber?.cancel()
        await oldDurationTask?.value
        await oldSessionEventTask?.value
        await oldFrameTask?.value
        await oldResultTask?.value
        activeTranscriber = nil
        activeBackend = nil
        try? audioSession.deactivate()
        if discardAudio { await audioStore.discard() }
        error = failure
        state = .failed(failure)
        await recordDiagnostic(stage: failure.stage, backend: failure.backend, error: failure)
    }

    private func resetForNewCapture() async {
        captureGeneration &+= 1
        frameStreamer.stop()
        frameStreamer.removeTap()
        let oldDurationTask = durationTask
        let oldSessionEventTask = sessionEventTask
        let oldFrameTask = frameTask
        let oldResultTask = resultTask
        durationTask = nil
        sessionEventTask = nil
        frameTask = nil
        resultTask = nil
        oldDurationTask?.cancel()
        oldSessionEventTask?.cancel()
        oldFrameTask?.cancel()
        oldResultTask?.cancel()
        await activeTranscriber?.cancel()
        await oldDurationTask?.value
        await oldSessionEventTask?.value
        await oldFrameTask?.value
        await oldResultTask?.value
        activeTranscriber = nil
        activeBackend = nil
        try? audioSession.deactivate()
        await audioStore.discard()
        activeRequestID = nil
        activeRoute = nil
        frameHistory.removeAll(keepingCapacity: true)
        capturedDurationSeconds = 0
        audioStarted = false
        cloudFallbackAllowed = false
        localTranscriptionFailed = false
        fallbackInProgress = false
        temporaryAudioFailure = nil
        state = .idle
    }

    private func shouldAllowCloudFallback() async -> Bool {
        guard cloudProvider != nil,
              providerConfiguration?.qwenSpeechFallbackEnabled == true,
              let governanceRepository else { return false }
        return (try? await governanceRepository.isConsentGranted(
            provider: .qwen,
            dataClass: .speechAudio
        )) == true
    }

    private func isUsableLocalTranscript(_ text: String) -> Bool {
        text.count >= 2
    }

    private func makeFailure(
        kind: SpeechCaptureFailureKind,
        stage: SpeechCaptureStage,
        backend: SpeechBackendID?,
        error: Error?,
        recoverable: Bool
    ) -> SpeechCaptureFailure {
        let nsError = error.map { $0 as NSError }
        let osStatus = nsError?.domain == NSOSStatusErrorDomain ? nsError?.code : nil
        return SpeechCaptureFailure(
            requestID: activeRequestID ?? UUID(),
            stage: stage,
            kind: kind,
            backend: backend,
            osStatus: osStatus,
            underlyingDomain: nsError?.domain,
            underlyingCode: nsError?.code,
            isRecoverable: recoverable
        )
    }

    private func recordDiagnostic(
        stage: SpeechCaptureStage,
        backend: SpeechBackendID?,
        error: Error?
    ) async {
        let nsError = error.map { $0 as NSError }
        await diagnostics.record(
            SpeechDiagnosticEvent(
                requestID: activeRequestID ?? UUID(),
                timestamp: Date(),
                stage: stage,
                backend: backend,
                failureKind: (error as? SpeechCaptureFailure)?.kind,
                category: "record",
                mode: "measurement",
                options: [],
                inputPortType: activeRoute?.inputPortType,
                sampleRate: activeRoute?.sampleRate,
                channelCount: activeRoute?.channelCount,
                engineRunning: frameStreamer.isRunning,
                osStatus: nsError?.domain == NSOSStatusErrorDomain ? nsError?.code : nil,
                errorDomain: nsError?.domain,
                errorCode: nsError?.code
            )
        )
    }
}
