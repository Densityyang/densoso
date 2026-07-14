import Foundation
import AVFoundation
import Speech

/// 语音识别服务 —— Apple Speech framework，on-device zh-CN
@MainActor
@Observable
final class SpeechService {
    private let speechRecognizer: SFSpeechRecognizer
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    var isRecording = false
    var transcribedText = ""
    var isAuthorized = false
    var error: SpeechError?

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
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))!
        speechRecognizer.defaultTaskHint = .dictation
    }

    @MainActor
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                self.isAuthorized = status == .authorized
                continuation.resume(returning: self.isAuthorized)
            }
        }
    }

    /// 开始录音并识别
    func startRecording() throws {
        guard isAuthorized else { throw SpeechError.notAuthorized }
        guard !audioEngine.isRunning else { return }

        // 停止之前的任务
        stopRecording()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw SpeechError.recognitionUnavailable
        }
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true  // 本地识别，隐私保护

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isRecording = true
        transcribedText = ""
        error = nil

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, err in
            if let result = result {
                self.transcribedText = result.bestTranscription.formattedString
            }
            if let err = err {
                self.error = SpeechError.recognitionUnavailable
                print("[Speech] 识别错误: \(err.localizedDescription)")
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
    }
}