import Foundation

enum MealImageCaptureState: Equatable {
    case idle
    case selected
    case sanitizing
    case localScanning
    case localResolved
    case deepseekRequired
    case consent
    case uploading
    case vision
    case resolved
    case cancelled
    case failed

    var statusMessage: String? {
        switch self {
        case .idle: nil
        case .selected: "已选择照片，尚未上传。"
        case .sanitizing: "正在本机清理照片元数据。"
        case .localScanning: "正在本机扫描条码和营养标签。"
        case .localResolved: "本机已整理照片线索；结果仍需检查和确认。"
        case .deepseekRequired: "开放照片需要 DeepSeek 视觉能力。"
        case .consent: "发送前需要单独同意上传处理后的照片。"
        case .uploading: "已同意，正在发送处理后的照片。"
        case .vision: "视觉模型正在分析处理后的照片。"
        case .resolved: "照片已处理；任何记录仍需你确认。"
        case .cancelled: "照片处理已取消，临时图像已清除。"
        case .failed: "无法处理这张照片，可重试或用文字描述。"
        }
    }

    func canSend(preparedRequestExists: Bool, consentGranted: Bool) -> Bool {
        self == .consent && preparedRequestExists && consentGranted
    }

    var isRemoteProcessing: Bool {
        self == .uploading || self == .vision
    }

    var shouldShowInConversation: Bool {
        isRemoteProcessing || self == .resolved || self == .cancelled || self == .failed
    }
}

enum MealImageCaptureStateMachine {
    static func transition(
        from current: MealImageCaptureState,
        event: MealImageCaptureEvent,
        preparedRequestExists: Bool = false,
        consentGranted: Bool = false
    ) -> MealImageCaptureState {
        switch event {
        case .selected: .selected
        case .sanitizing: .sanitizing
        case .localScanning: .localScanning
        case .localResolved: .localResolved
        case .deepseekRequired: .deepseekRequired
        case .consentPrompt, .consentGranted: .consent
        case .uploadStarted where current.canSend(
            preparedRequestExists: preparedRequestExists,
            consentGranted: consentGranted
        ): .uploading
        case .uploadStarted: .consent
        case .visionStarted where current.isRemoteProcessing: .vision
        case .visionStarted: current
        case .resolved: .resolved
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }
}

enum MealImageCaptureEvent: Equatable {
    case selected
    case sanitizing
    case localScanning
    case localResolved
    case deepseekRequired
    case consentPrompt
    case consentGranted
    case uploadStarted
    case visionStarted
    case resolved
    case cancelled
    case failed
}
