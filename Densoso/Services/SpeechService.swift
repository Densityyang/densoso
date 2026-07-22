import AVFoundation
import Foundation
import Observation
import Speech

/// Uses SpeechAnalyzer on capable devices and retains SFSpeechRecognizer as a fallback.
@MainActor
@Observable
final class SpeechService {
    enum Backend: Equatable {
        case speechAnalyzer
        case legacySpeechRecognizer
    }

    private let locale: Locale
    private let legacyRecognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerInputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?
    private var modernResultsTask: Task<Void, Never>?

    var isRecording = false
    var transcribedText = ""
    var isAuthorized = false
    var error: SpeechError?
    private(set) var activeBackend: Backend?

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
        let microphoneGranted = await requestMicrophonePermission()
        guard microphoneGranted else {
            isAuthorized = false
            return false
        }

        if SpeechRoutingPolicy().backend(modernSpeechAvailable: PlatformCapabilities.current.modernSpeechAvailable) == .speechAnalyzer {
            isAuthorized = true
            return true
        }

        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        isAuthorized = speechGranted
        return speechGranted
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
                return
            } catch {
                // A missing locale asset or an analyzer setup failure must not block legacy dictation.
                await tearDownModernRecognition(finalize: false)
            }
        }
        try startLegacyRecognition()
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

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
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
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechError.localeUnsupported
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        let installedLocales = await SpeechTranscriber.installedLocales
        if !installedLocales.contains(where: { $0.identifier == supportedLocale.identifier }) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechError.invalidAudioFormat
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputSequence)

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = format
        self.analyzerInputBuilder = inputBuilder
        self.audioConverter = try makeConverter(outputFormat: format)
        self.modernResultsTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    let text = String(result.text.characters)
                    await self?.acceptModernTranscript(text, isFinal: result.isFinal)
                }
            } catch {
                await self?.recordModernFailure()
            }
        }

        installAudioTap { [weak self] buffer in
            Task { @MainActor [weak self] in
                self?.appendModernAudio(buffer)
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
        activeBackend = .speechAnalyzer
        isRecording = true
    }

    private func makeConverter(outputFormat: AVAudioFormat) throws -> AVAudioConverter {
        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SpeechError.invalidAudioFormat
        }
        return converter
    }

    private func appendModernAudio(_ buffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter, let format = analyzerFormat, let inputBuilder = analyzerInputBuilder else { return }
        let ratio = format.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(max(1, Int(Double(buffer.frameLength) * ratio) + 1))
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            error = .invalidAudioFormat
            return
        }

        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outputStatus in
            outputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil else {
            error = .invalidAudioFormat
            return
        }
        inputBuilder.yield(AnalyzerInput(buffer: converted))
    }

    private func acceptModernTranscript(_ text: String, isFinal: Bool) {
        // The progressive preset may revise volatile text. Finalized text replaces it in the service's visible field.
        transcribedText = text
    }

    private func recordModernFailure() {
        error = .recognitionUnavailable
    }

    private func tearDownModernRecognition(finalize: Bool) async {
        analyzerInputBuilder?.finish()
        if finalize {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        } else {
            await analyzer?.cancelAndFinishNow()
        }
        modernResultsTask?.cancel()
        modernResultsTask = nil
        analyzerInputBuilder = nil
        analyzerFormat = nil
        audioConverter = nil
        analyzer = nil
        transcriber = nil
    }

    private func startLegacyRecognition() throws {
        guard let recognizer = legacyRecognizer, recognizer.isAvailable else {
            throw SpeechError.recognitionUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        legacyRequest = request

        installAudioTap { buffer in request.append(buffer) }
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

    private func installAudioTap(_ handler: @escaping (AVAudioPCMBuffer) -> Void) {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            handler(buffer)
        }
    }
}
