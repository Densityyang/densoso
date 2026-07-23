import Foundation
import AVFoundation
import Speech

/// 语音识别服务 —— Apple Speech framework，on-device zh-CN
@MainActor
@Observable
final class SpeechService {
    enum Runtime: Equatable {
        case speechAnalyzer(localeIdentifier: String)
        case legacySpeech
        case manualEntry
    }
    private let speechRecognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    var isRecording = false
    var transcribedText = ""
    var isAuthorized = false
    var error: SpeechError?
    private(set) var runtime: Runtime = .legacySpeech

    enum SpeechError: Error, LocalizedError {
        case notAuthorized
        case audioEngineUnavailable
        case recognitionUnavailable
        var errorDescription: String? {
            switch self {
            case .notAuthorized: "语音权限未授权，请在 设置 > 隐私 > 语音识别 中开启"
            case .audioEngineUnavailable: "音频引擎不可用"
            case .recognitionUnavailable: "语音识别不可用，请检查设备设置"
            }
        }
    }

    init() {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        self.speechRecognizer?.defaultTaskHint = .dictation
    }

    @MainActor
    func requestAuthorization() async -> Bool {
        guard await Self.requestMicrophonePermission() else {
            isAuthorized = false
            return false
        }
        let status = await Self.requestSpeechAuthorization()
        isAuthorized = status == .authorized
        return isAuthorized
    }

    /// Checks the iOS 26 on-device path without downloading assets or changing
    /// the current transcript. A failure retains the editable legacy/manual path.
    func refreshRuntime(locale: Locale = Locale(identifier: "zh-CN")) async {
        if #available(iOS 26.0, *), SpeechTranscriber.isAvailable,
           let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            runtime = .speechAnalyzer(localeIdentifier: supportedLocale.identifier)
        } else if speechRecognizer?.isAvailable == true {
            runtime = .legacySpeech
        } else {
            runtime = .manualEntry
        }
    }

    var envelopeSource: VoiceCommandEnvelope.Source {
        switch runtime {
        case .speechAnalyzer: .iPhoneSpeechAnalyzer
        case .legacySpeech, .manualEntry: .iPhoneLegacySpeech
        }
    }

    /// 开始录音并识别
    func startRecording() throws {
        guard isAuthorized else { throw SpeechError.notAuthorized }
        guard !audioEngine.isRunning else { return }

        // 停止之前的任务
        stopRecording()

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw SpeechError.recognitionUnavailable
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw SpeechError.recognitionUnavailable
        }
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw SpeechError.audioEngineUnavailable
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isRecording = true
        transcribedText = ""
        error = nil

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, err in
            Task { @MainActor [weak self] in
                if let result {
                    self?.transcribedText = result.bestTranscription.formattedString
                }
                if let err {
                    self?.error = SpeechError.recognitionUnavailable
                    print("[Speech] 识别错误: \(err.localizedDescription)")
                }
            }
        }
    }

    /// 停止录音
    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
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

    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
