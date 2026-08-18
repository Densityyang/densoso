import AVFoundation
import Foundation
import Observation
import Speech
import DensosoDomain

@MainActor
private protocol ModernSpeechRecognitionBackend: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async
    func cancel() async
}

/// Uses SpeechAnalyzer on capable devices and retains SFSpeechRecognizer as a fallback.
@MainActor
@Observable
final class SpeechService {
    enum Runtime: Equatable {
        case speechAnalyzer(localeIdentifier: String)
        case legacySpeech
        case manualEntry
    }
    enum Backend: Equatable {
        case speechAnalyzer
        case legacySpeechRecognizer
    }

    private let locale: Locale
    private let legacyRecognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?

    private var modernBackend: (any ModernSpeechRecognitionBackend)?

    var isRecording = false
    var transcribedText = ""
    var isAuthorized = false
    var error: SpeechError?
    private(set) var runtime: Runtime = .legacySpeech
    private(set) var activeBackend: Backend?
    private(set) var transcriptSource: VoiceCommandEnvelope.Source = .iPhoneLegacySpeech

    enum SpeechError: Error, LocalizedError {
        case notAuthorized
        case audioEngineUnavailable
        case recognitionUnavailable
        case localeUnsupported
        case invalidAudioFormat

        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Microphone or speech permission has not been granted."
            case .audioEngineUnavailable: "The audio engine is unavailable."
            case .recognitionUnavailable: "Speech recognition is unavailable on this device."
            case .localeUnsupported: "The selected speech language is not supported on this device."
            case .invalidAudioFormat: "The microphone format cannot be converted for speech recognition."
            }
        }
    }

    init(locale: Locale = Locale(identifier: "zh-CN")) {
        self.locale = locale
        self.legacyRecognizer = SFSpeechRecognizer(locale: locale)
        self.legacyRecognizer?.defaultTaskHint = .dictation
    }

    func requestAuthorization() async -> Bool {
        let microphoneGranted = await Self.requestMicrophonePermission()
        guard microphoneGranted else {
            isAuthorized = false
            return false
        }

        let speechStatus = await Self.requestLegacySpeechAuthorization()
        let legacySpeechGranted = speechStatus == .authorized
        let modernSpeechAvailable = PlatformCapabilities.current.modernSpeechAvailable
        // SpeechAnalyzer itself does not need SFSpeechRecognizer authorization, but the
        // authorization is requested now so a later legacy fallback remains safe.
        isAuthorized = modernSpeechAvailable || legacySpeechGranted
        return isAuthorized
    }

    /// Checks the iOS 26 on-device path without downloading assets or changing
    /// the current transcript. A failure retains the editable legacy/manual path.
    func refreshRuntime(locale: Locale = Locale(identifier: "zh-CN")) async {
        if #available(iOS 26.0, *), SpeechTranscriber.isAvailable,
           let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            runtime = .speechAnalyzer(localeIdentifier: supportedLocale.identifier)
        } else if legacyRecognizer?.isAvailable == true {
            runtime = .legacySpeech
        } else {
            runtime = .manualEntry
        }
    }

    var envelopeSource: VoiceCommandEnvelope.Source {
        transcriptSource
    }

    func startRecording() async throws {
        guard isAuthorized else { throw SpeechError.notAuthorized }
        guard !audioEngine.isRunning else { return }

        await stopRecording()
        transcribedText = ""
        error = nil

        try configureAudioSession()
        if SpeechRoutingPolicy().backend(modernSpeechAvailable: PlatformCapabilities.current.modernSpeechAvailable) == .speechAnalyzer {
            do {
                try await startModernRecognition()
                transcriptSource = .iPhoneSpeechAnalyzer
                return
            } catch {
                // A missing locale asset or an analyzer setup failure must not block legacy dictation.
                await tearDownModernRecognition(finalize: false)
            }
        }
        try startLegacyRecognition()
        transcriptSource = .iPhoneLegacySpeech
    }

    func stopRecording() async {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        if activeBackend == .speechAnalyzer {
            await tearDownModernRecognition(finalize: true)
        } else {
            legacyRequest?.endAudio()
            legacyTask?.cancel()
            legacyRequest = nil
            legacyTask = nil
        }

        activeBackend = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private nonisolated static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private nonisolated static func requestLegacySpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startModernRecognition() async throws {
        guard #available(iOS 26.0, *) else { throw SpeechError.recognitionUnavailable }
        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw SpeechError.audioEngineUnavailable
        }
        let backend = try await SpeechAnalyzerRecognitionBackend.make(
            locale: locale,
            inputFormat: inputFormat,
            onTranscript: { [weak self] text, isFinal in
                self?.acceptModernTranscript(text, isFinal: isFinal)
            },
            onFailure: { [weak self] in
                self?.recordModernFailure()
            }
        )
        modernBackend = backend

        try installAudioTap { [weak backend] buffer in
            Task { @MainActor in
                backend?.append(buffer)
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
        activeBackend = .speechAnalyzer
        isRecording = true
    }

    private func acceptModernTranscript(_ text: String, isFinal: Bool) {
        // The progressive preset may revise volatile text. Finalized text replaces it in the service's visible field.
        transcribedText = text
    }

    private func recordModernFailure() {
        error = .recognitionUnavailable
    }

    private func tearDownModernRecognition(finalize: Bool) async {
        if finalize {
            await modernBackend?.finish()
        } else {
            await modernBackend?.cancel()
        }
        modernBackend = nil
    }

    private func startLegacyRecognition() throws {
        guard let recognizer = legacyRecognizer, recognizer.isAvailable else {
            throw SpeechError.recognitionUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        legacyRequest = request

        try installAudioTap { buffer in request.append(buffer) }
        audioEngine.prepare()
        try audioEngine.start()

        legacyTask = recognizer.recognitionTask(with: request) { [weak self] result, recognitionError in
            Task { @MainActor in
                if let result {
                    self?.transcribedText = result.bestTranscription.formattedString
                }
                if recognitionError != nil {
                    self?.error = .recognitionUnavailable
                }
            }
        }
        activeBackend = .legacySpeechRecognizer
        isRecording = true
    }

    private func installAudioTap(_ handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechError.audioEngineUnavailable
        }
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            handler(buffer)
    }
    }
}

@available(iOS 26.0, *)
@MainActor
private final class SpeechAnalyzerRecognitionBackend: ModernSpeechRecognitionBackend {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat
    private let audioConverter: AVAudioConverter
    private let onTranscript: @MainActor @Sendable (String, Bool) -> Void
    private let onFailure: @MainActor @Sendable () -> Void
    private var resultsTask: Task<Void, Never>?

    private init(
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat,
        audioConverter: AVAudioConverter,
        onTranscript: @escaping @MainActor @Sendable (String, Bool) -> Void,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.inputBuilder = inputBuilder
        self.analyzerFormat = analyzerFormat
        self.audioConverter = audioConverter
        self.onTranscript = onTranscript
        self.onFailure = onFailure
    }

    static func make(
        locale: Locale,
        inputFormat: AVAudioFormat,
        onTranscript: @escaping @MainActor @Sendable (String, Bool) -> Void,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) async throws -> SpeechAnalyzerRecognitionBackend {
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechService.SpeechError.localeUnsupported
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        let installedLocales = await SpeechTranscriber.installedLocales
        if !installedLocales.contains(where: { $0.identifier == supportedLocale.identifier }) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechService.SpeechError.invalidAudioFormat
        }
        guard let audioConverter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw SpeechService.SpeechError.invalidAudioFormat
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputSequence)

        let backend = SpeechAnalyzerRecognitionBackend(
            analyzer: analyzer,
            transcriber: transcriber,
            inputBuilder: inputBuilder,
            analyzerFormat: analyzerFormat,
            audioConverter: audioConverter,
            onTranscript: onTranscript,
            onFailure: onFailure
        )
        backend.startResultsTask()
        return backend
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let ratio = analyzerFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(max(1, Int(Double(buffer.frameLength) * ratio) + 1))
        guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
            onFailure()
            return
        }

        var conversionError: NSError?
        let status = audioConverter.convert(to: converted, error: &conversionError) { _, outputStatus in
            outputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil else {
            onFailure()
            return
        }
        inputBuilder.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async {
        inputBuilder.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
    }

    func cancel() async {
        inputBuilder.finish()
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
        resultsTask = nil
    }

    private func startResultsTask() {
        resultsTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    self?.onTranscript(String(result.text.characters), result.isFinal)
                }
            } catch {
                self?.onFailure()
            }
        }
    }
}
