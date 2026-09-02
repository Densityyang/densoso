import AVFoundation
import Foundation
import Speech

@MainActor
final class SystemVoiceTranscriberFactory: VoiceTranscriberFactory {
    func isModernTranscriptionAvailable(locale: Locale) async -> Bool {
        guard #available(iOS 26.0, *), SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
    }

    func makeModernTranscriber(locale: Locale) async throws -> any VoiceTranscribing {
        guard #available(iOS 26.0, *) else {
            throw SpeechTranscriberFactoryError.modernUnavailable
        }
        return try await SpeechAnalyzerVoiceTranscriber.make(locale: locale)
    }

    func makeLegacyTranscriber(locale: Locale) async throws -> any VoiceTranscribing {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard authorization == .authorized else {
            throw SpeechTranscriberFactoryError.legacyNotAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechTranscriberFactoryError.legacyUnavailable
        }
        recognizer.defaultTaskHint = .dictation
        return LegacyVoiceTranscriber(recognizer: recognizer)
    }
}

enum SpeechTranscriberFactoryError: Error, LocalizedError, Equatable {
    case modernUnavailable
    case legacyNotAuthorized
    case legacyUnavailable
    case legacyFinalizationTimedOut
    case invalidFrame
    case inputDropped

    var errorDescription: String? {
        switch self {
        case .modernUnavailable: "SpeechAnalyzer is unavailable for this locale."
        case .legacyNotAuthorized: "Legacy speech recognition is not authorized."
        case .legacyUnavailable: "Legacy speech recognition is unavailable."
        case .legacyFinalizationTimedOut: "Legacy speech recognition did not finalize in time."
        case .invalidFrame: "The captured PCM frame is invalid."
        case .inputDropped: "SpeechAnalyzer input buffering dropped an audio frame."
        }
    }
}

@MainActor
private final class LegacyVoiceTranscriber: VoiceTranscribing {
    let backendID: SpeechBackendID = .legacySpeechRecognizer
    let results: AsyncThrowingStream<SpeechTranscriptUpdate, Error>

    private let resultContinuation: AsyncThrowingStream<SpeechTranscriptUpdate, Error>.Continuation
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let completionSignal: AsyncStream<Void>
    private let completionContinuation: AsyncStream<Void>.Continuation
    private var task: SFSpeechRecognitionTask?
    private var terminalError: Error?

    init(recognizer: SFSpeechRecognizer) {
        let (stream, continuation) = AsyncThrowingStream<SpeechTranscriptUpdate, Error>.makeStream()
        results = stream
        resultContinuation = continuation
        let (completionSignal, completionContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.completionSignal = completionSignal
        self.completionContinuation = completionContinuation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        task = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.resultContinuation.yield(
                        SpeechTranscriptUpdate(
                            text: result.bestTranscription.formattedString,
                            isFinal: result.isFinal
                        )
                    )
                    if result.isFinal {
                        self.resultContinuation.finish()
                        self.completionContinuation.yield(())
                        self.completionContinuation.finish()
                    }
                }
                if let error {
                    self.terminalError = error
                    self.resultContinuation.finish(throwing: error)
                    self.completionContinuation.yield(())
                    self.completionContinuation.finish()
                }
            }
        }
    }

    func append(_ frame: SpeechAudioFrame) {
        guard let buffer = SpeechPCMBufferFactory.buffer(from: frame) else {
            resultContinuation.finish(throwing: SpeechTranscriberFactoryError.invalidFrame)
            return
        }
        request.append(buffer)
    }

    func finish() async throws {
        request.endAudio()
        task?.finish()
        let completionSignal = self.completionSignal
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = completionSignal.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard completed else {
            let error = SpeechTranscriberFactoryError.legacyFinalizationTimedOut
            task?.cancel()
            task = nil
            resultContinuation.finish(throwing: error)
            completionContinuation.finish()
            throw error
        }
        if let terminalError { throw terminalError }
        resultContinuation.finish()
        task = nil
    }

    func cancel() async {
        request.endAudio()
        task?.cancel()
        task = nil
        completionContinuation.finish()
        resultContinuation.finish(throwing: CancellationError())
    }
}

@available(iOS 26.0, *)
@MainActor
private final class SpeechAnalyzerVoiceTranscriber: VoiceTranscribing {
    let backendID: SpeechBackendID = .speechAnalyzer
    let results: AsyncThrowingStream<SpeechTranscriptUpdate, Error>

    private let resultContinuation: AsyncThrowingStream<SpeechTranscriptUpdate, Error>.Continuation
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let converter: AnalyzerInputConverter
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var terminalError: Error?

    private init(
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        converter: AnalyzerInputConverter,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.converter = converter
        self.inputContinuation = inputContinuation
        let (results, resultContinuation) = AsyncThrowingStream<SpeechTranscriptUpdate, Error>.makeStream()
        self.results = results
        self.resultContinuation = resultContinuation
        startResultsTask()
    }

    static func make(locale: Locale) async throws -> SpeechAnalyzerVoiceTranscriber {
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechTranscriberFactoryError.modernUnavailable
        }
        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .progressiveTranscription
        )
        let installedLocales = await SpeechTranscriber.installedLocales
        if !installedLocales.contains(where: { $0.identifier == supportedLocale.identifier }),
           let installation = try await AssetInventory.assetInstallationRequest(
               supporting: [transcriber]
           ) {
            try await installation.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let converter = try await AnalyzerInputConverter.converter(
            compatibleWith: [transcriber]
        )
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        try await analyzer.start(inputSequence: inputSequence)
        return SpeechAnalyzerVoiceTranscriber(
            analyzer: analyzer,
            transcriber: transcriber,
            converter: converter,
            inputContinuation: inputContinuation
        )
    }

    func append(_ frame: SpeechAudioFrame) {
        guard let buffer = SpeechPCMBufferFactory.buffer(from: frame) else {
            resultContinuation.finish(throwing: SpeechTranscriberFactoryError.invalidFrame)
            return
        }
        do {
            for input in try converter.convert(
                buffer,
                at: SpeechPCMBufferFactory.audioTime(for: frame)
            ) {
                try yieldInput(input)
            }
        } catch {
            terminalError = error
            resultContinuation.finish(throwing: error)
        }
    }

    func finish() async throws {
        do {
            for input in try converter.flush() { try yieldInput(input) }
            inputContinuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await resultsTask?.value
            resultsTask = nil
            if let terminalError { throw terminalError }
        } catch {
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            resultsTask?.cancel()
            await resultsTask?.value
            resultsTask = nil
            resultContinuation.finish(throwing: error)
            throw error
        }
    }

    func cancel() async {
        inputContinuation.finish()
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
        await resultsTask?.value
        resultsTask = nil
        resultContinuation.finish(throwing: CancellationError())
    }

    private func startResultsTask() {
        resultsTask = Task { @MainActor [weak self, transcriber] in
            var finalized = ""
            var volatile = ""
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    self?.resultContinuation.yield(
                        SpeechTranscriptUpdate(
                            text: finalized + volatile,
                            isFinal: result.isFinal
                        )
                    )
                }
                self?.resultContinuation.finish()
            } catch is CancellationError {
                self?.resultContinuation.finish(throwing: CancellationError())
            } catch {
                self?.terminalError = error
                self?.resultContinuation.finish(throwing: error)
            }
        }
    }

    private func yieldInput(_ input: AnalyzerInput) throws {
        switch inputContinuation.yield(input) {
        case .enqueued:
            return
        case .dropped, .terminated:
            throw SpeechTranscriberFactoryError.inputDropped
        @unknown default:
            throw SpeechTranscriberFactoryError.inputDropped
        }
    }
}

private enum SpeechPCMBufferFactory {
    static func buffer(from frame: SpeechAudioFrame) -> AVAudioPCMBuffer? {
        guard frame.frameCount > 0,
              frame.pcm16LittleEndian.count >= frame.frameCount * MemoryLayout<Int16>.size,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: SpeechAudioFrame.canonicalSampleRate,
                  channels: AVAudioChannelCount(SpeechAudioFrame.canonicalChannelCount),
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frame.frameCount)
              ),
              let destination = buffer.int16ChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frame.frameCount)
        frame.pcm16LittleEndian.withUnsafeBytes { source in
            guard let baseAddress = source.baseAddress else { return }
            memcpy(
                destination,
                baseAddress,
                frame.frameCount * MemoryLayout<Int16>.size
            )
        }
        return buffer
    }

    static func audioTime(for frame: SpeechAudioFrame) -> AVAudioTime? {
        guard let seconds = frame.presentationTimeSeconds,
              seconds.isFinite,
              seconds >= 0 else { return nil }
        return AVAudioTime(
            sampleTime: AVAudioFramePosition(seconds * SpeechAudioFrame.canonicalSampleRate),
            atRate: SpeechAudioFrame.canonicalSampleRate
        )
    }
}
