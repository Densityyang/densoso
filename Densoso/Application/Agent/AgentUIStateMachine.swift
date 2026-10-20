import Foundation

enum AgentUIState: Equatable {
    case idle
    case listening
    case transcribing
    case thinking
    case toolExecuting(name: String)
    case draftReady
    case awaitingConfirmation
    case committing
    case completed
    case failed

    var isBusy: Bool {
        switch self {
        case .thinking, .toolExecuting(_), .draftReady, .committing: true
        case .idle, .listening, .transcribing, .awaitingConfirmation, .completed, .failed: false
        }
    }

    var canCancel: Bool {
        switch self {
        case .thinking, .toolExecuting(_), .draftReady: true
        case .idle, .listening, .transcribing, .awaitingConfirmation, .committing, .completed, .failed: false
        }
    }

    var statusMessage: String? {
        switch self {
        case .idle: nil
        case .listening: "正在听你说话"
        case .transcribing: "正在转写语音"
        case .thinking: "正在整理你的请求"
        case .toolExecuting(_): "正在读取或整理本机数据"
        case .draftReady: "已生成待确认草稿"
        case .awaitingConfirmation: "等待你检查并确认草稿"
        case .committing: "正在保存已确认的内容"
        case .completed: "已完成"
        case .failed: "处理未完成，你的数据没有保存；可以检查输入后重试。"
        }
    }
}

enum VoiceCaptureUIState: Equatable {
    case idle
    case starting
    case listening
    case transcribing
    case finalizing
    case submitted
    case processing
    case completed
    case cancelled
    case permissionDenied
    case microphoneUnavailable
    case speechUnavailable
    case failed(String)

    var isTransitioning: Bool {
        switch self {
        case .starting, .transcribing, .finalizing, .processing: true
        case .idle, .listening, .submitted, .completed, .cancelled,
             .permissionDenied, .microphoneUnavailable, .speechUnavailable, .failed: false
        }
    }

    var isCaptureControlLocked: Bool {
        switch self {
        case .starting, .finalizing, .processing: true
        case .idle, .listening, .transcribing, .submitted, .completed, .cancelled,
             .permissionDenied, .microphoneUnavailable, .speechUnavailable, .failed: false
        }
    }

    var statusMessage: String? {
        switch self {
        case .idle, .completed, .submitted: nil
        case .starting: "正在准备麦克风和语音识别"
        case .listening: "正在听你说话"
        case .transcribing: "正在转写语音"
        case .finalizing: "正在完成语音识别"
        case .processing: "正在处理语音请求"
        case .cancelled: "语音输入已取消"
        case .permissionDenied: "请先允许麦克风和语音识别权限。"
        case .microphoneUnavailable: "当前麦克风不可用，请检查输入设备后重试。"
        case .speechUnavailable: "当前语音识别不可用，可继续编辑文字。"
        case .failed(let message): message
        }
    }

    var buttonTitle: String {
        isRecording ? "停止录音" : "开始说话"
    }

    var buttonSystemImage: String {
        isRecording ? "stop.fill" : "mic.fill"
    }

    var isRecording: Bool {
        self == .listening || self == .transcribing
    }
}

enum AgentUIStateMachine {
    static func transition(
        from current: AgentUIState,
        event: AgentEvent,
        hasDraftInCurrentTurn: Bool = false
    ) -> AgentUIState {
        switch event {
        case .accepted(_), .providerRoundStarted(_, _), .assistantDelta(_):
            .thinking
        case .toolCallStarted(let name, _):
            .toolExecuting(name: name)
        case .pendingAction(_):
            .draftReady
        case .awaitingConfirmation:
            .awaitingConfirmation
        case .committing(_):
            .committing
        case .completed(_):
            current == .awaitingConfirmation || hasDraftInCurrentTurn ? .awaitingConfirmation : .completed
        case .cancelled(_):
            current == .awaitingConfirmation || current == .draftReady || hasDraftInCurrentTurn
                ? .awaitingConfirmation
                : .idle
        case .failed(_):
            .failed
        case .usage(_), .budgetWarning(_), .imageUploading, .imageVision, .imageResolved:
            current
        }
    }

    static func voiceState(
        from state: SpeechCaptureState,
        transcribedText: String
    ) -> VoiceCaptureUIState {
        switch state {
        case .idle:
            .idle
        case .requestingPermission, .configuringSession, .preparingBackend:
            .starting
        case .recording:
            transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .listening
                : .transcribing
        case .finalizing:
            .finalizing
        case .completed:
            transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .completed
                : .submitted
        case .failed(let failure):
            switch failure.kind {
            case .cancelled:
                .cancelled
            case .permissionDenied:
                .permissionDenied
            case .sessionConfiguration, .routeUnavailable, .invalidAudioFormat,
                 .tapInstallation, .engineStart, .interrupted, .routeChanged, .mediaServicesReset:
                .microphoneUnavailable
            case .droppedAudioFrames, .transcriptionUnavailable, .transcriptionFailed,
                 .cloudConsentRequired, .cloudUnavailable, .cloudRejected, .temporaryAudio:
                .speechUnavailable
            }
        }
    }
}
