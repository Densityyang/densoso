import Foundation

enum SpeechCaptureStage: String, Codable, CaseIterable, Sendable {
    case idle
    case requestingPermission
    case configuringSession
    case preparingBackend
    case recording
    case finalizing
    case completed
}

enum SpeechBackendID: String, Codable, CaseIterable, Sendable {
    case speechAnalyzer
    case legacySpeechRecognizer
    case qwenASR
    case manualEntry
}

enum SpeechCaptureFailureKind: String, Codable, Sendable {
    case permissionDenied
    case sessionConfiguration
    case routeUnavailable
    case invalidAudioFormat
    case tapInstallation
    case droppedAudioFrames
    case engineStart
    case transcriptionUnavailable
    case transcriptionFailed
    case interrupted
    case routeChanged
    case mediaServicesReset
    case cloudConsentRequired
    case cloudUnavailable
    case cloudRejected
    case cancelled
    case temporaryAudio
}

struct SpeechCaptureFailure: Error, LocalizedError, Codable, Equatable, Sendable {
    let requestID: UUID
    let stage: SpeechCaptureStage
    let kind: SpeechCaptureFailureKind
    let backend: SpeechBackendID?
    let osStatus: Int?
    let underlyingDomain: String?
    let underlyingCode: Int?
    let isRecoverable: Bool

    var errorDescription: String? {
        switch kind {
        case .permissionDenied: "请先允许麦克风录音；兼容识别路径还需要语音识别权限。"
        case .sessionConfiguration: "无法配置录音会话，请检查其他音频应用后重试。"
        case .routeUnavailable: "当前没有可用的麦克风输入，请切换输入设备后重试。"
        case .invalidAudioFormat: "当前麦克风格式不可用于语音识别。"
        case .tapInstallation: "无法开始采集麦克风音频。"
        case .droppedAudioFrames: "录音帧出现丢失，本次音频未用于转写或上传。"
        case .engineStart: "录音引擎未能启动；没有音频会上传到云端。"
        case .transcriptionUnavailable: "设备端和兼容语音识别当前都不可用，可继续手动输入。"
        case .transcriptionFailed: "本地语音转写失败，可检查文字或使用已授权的单次云端兜底。"
        case .interrupted: "录音被系统中断，未自动重新开始。"
        case .routeChanged: "录音输入发生变化，请确认麦克风后重新开始。"
        case .mediaServicesReset: "系统音频服务已重置，请重新开始录音。"
        case .cloudConsentRequired: "需要单独同意上传本次临时音频。"
        case .cloudUnavailable: "云端语音兜底当前不可用，可继续手动编辑。"
        case .cloudRejected: "云端语音服务未能处理本次音频。"
        case .cancelled: "录音已取消。"
        case .temporaryAudio: "临时音频处理失败；文件已安排清理。"
        }
    }
}

enum SpeechCaptureState: Equatable, Sendable {
    case idle
    case requestingPermission
    case configuringSession
    case preparingBackend
    case recording
    case finalizing
    case completed
    case failed(SpeechCaptureFailure)

    var stage: SpeechCaptureStage {
        switch self {
        case .idle: .idle
        case .requestingPermission: .requestingPermission
        case .configuringSession: .configuringSession
        case .preparingBackend: .preparingBackend
        case .recording: .recording
        case .finalizing: .finalizing
        case .completed: .completed
        case .failed(let failure): failure.stage
        }
    }
}

struct SpeechAudioFormatSnapshot: Codable, Equatable, Sendable {
    let sampleRate: Double
    let channelCount: Int
}

struct SpeechAudioRouteSnapshot: Codable, Equatable, Sendable {
    let inputPortType: String?
    let sampleRate: Double
    let channelCount: Int

    var hasUsableInput: Bool {
        inputPortType != nil && sampleRate > 0 && channelCount > 0
    }
}

enum SpeechAudioSessionEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded
    case routeChanged(reason: Int, route: SpeechAudioRouteSnapshot)
    case mediaServicesReset
}

struct SpeechAudioFrame: Equatable, Sendable {
    static let canonicalSampleRate = 16_000.0
    static let canonicalChannelCount = 1

    let pcm16LittleEndian: Data
    let frameCount: Int
    let presentationTimeSeconds: Double?

    var durationSeconds: Double {
        Double(max(frameCount, 0)) / Self.canonicalSampleRate
    }
}

struct SpeechTranscriptUpdate: Equatable, Sendable {
    let text: String
    let isFinal: Bool
}

struct SanitizedAudio: Equatable, Sendable {
    let data: Data
    let mimeType: String
    let durationSeconds: Double
    let sampleRate: Double
    let channelCount: Int
}

struct CloudTranscript: Equatable, Sendable {
    let text: String
    let model: String
    let billedAudioSeconds: Double
    let attempt: Int
}

struct SpeechCapturePolicy: Equatable, Sendable {
    let warningAfterSeconds: Double
    let maximumDurationSeconds: Double
    let minimumCloudFallbackSeconds: Double

    static let phase4 = SpeechCapturePolicy(
        warningAfterSeconds: 55,
        maximumDurationSeconds: 60,
        minimumCloudFallbackSeconds: 0.1
    )
}

@MainActor
protocol AudioSessionControlling: AnyObject {
    func requestRecordPermission() async -> Bool
    func configureForMeasurement() throws
    func activate() throws -> SpeechAudioRouteSnapshot
    func deactivate() throws
    func eventStream() -> AsyncStream<SpeechAudioSessionEvent>
}

@MainActor
protocol AudioFrameStreaming: AnyObject {
    var isRunning: Bool { get }
    var isTapInstalled: Bool { get }
    var droppedFrameCount: Int { get }
    func prepare() throws -> SpeechAudioFormatSnapshot
    func installTap() throws -> AsyncStream<SpeechAudioFrame>
    func start() throws
    func stop()
    func removeTap()
    func resetAfterMediaServicesReset()
}

@MainActor
protocol VoiceTranscribing: AnyObject {
    var backendID: SpeechBackendID { get }
    var results: AsyncThrowingStream<SpeechTranscriptUpdate, Error> { get }
    func append(_ frame: SpeechAudioFrame)
    func finish() async throws
    func cancel() async
}

@MainActor
protocol VoiceTranscriberFactory: AnyObject {
    func isModernTranscriptionAvailable(locale: Locale) async -> Bool
    func makeModernTranscriber(locale: Locale) async throws -> any VoiceTranscribing
    func makeLegacyTranscriber(locale: Locale) async throws -> any VoiceTranscribing
}

protocol CloudSpeechProvider: Sendable {
    func transcribe(audio: SanitizedAudio, locale: Locale) async throws -> CloudTranscript
}

protocol SpeechAudioStoring: Sendable {
    func cleanupStaleFiles() async
    func begin(requestID: UUID) async throws
    func append(_ frame: SpeechAudioFrame) async throws
    func finalize() async throws -> SanitizedAudio?
    func discard() async
}

protocol SpeechDiagnosticsRecording: Sendable {
    func record(_ event: SpeechDiagnosticEvent) async
    func export() async throws -> URL
}

struct SpeechDiagnosticEvent: Codable, Equatable, Sendable {
    let requestID: UUID
    let timestamp: Date
    let stage: SpeechCaptureStage
    let backend: SpeechBackendID?
    let failureKind: SpeechCaptureFailureKind?
    let category: String
    let mode: String
    let options: [String]
    let inputPortType: String?
    let sampleRate: Double?
    let channelCount: Int?
    let engineRunning: Bool
    let osStatus: Int?
    let errorDomain: String?
    let errorCode: Int?
}
