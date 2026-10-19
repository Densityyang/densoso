import Foundation

/// Safe, serializable metadata for one user turn. Image bytes and audio samples
/// are deliberately represented elsewhere as transient in-memory inputs.
public struct InputEnvelope: Codable, Equatable, Sendable {
    public enum Source: String, Codable, CaseIterable, Sendable {
        case voice
        case text
        case image
        case voiceAndImage
        /// Supports manually typed context accompanying an image without mislabeling it as speech.
        case textAndImage
    }

    public struct ImageAttachment: Codable, Equatable, Identifiable, Sendable {
        public enum MediaType: String, Codable, CaseIterable, Sendable {
            case jpeg
            case png
            case webp
        }

        public let id: UUID
        public let mediaType: MediaType

        public init(id: UUID = UUID(), mediaType: MediaType) {
            self.id = id
            self.mediaType = mediaType
        }
    }

    public let id: UUID
    public let createdAt: Date
    public let source: Source
    public let text: String?
    public let imageAttachments: [ImageAttachment]
    public let locale: String

    public var isWellFormed: Bool {
        guard imageAttachments.count <= 4,
              locale.count <= 64,
              Set(imageAttachments.map(\.id)).count == imageAttachments.count else { return false }
        let hasText = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasImages = !imageAttachments.isEmpty
        switch source {
        case .voice, .text:
            hasText && !hasImages
        case .image:
            hasImages
        case .voiceAndImage, .textAndImage:
            hasText && hasImages
        }
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        source: Source,
        text: String?,
        imageAttachments: [ImageAttachment] = [],
        locale: String = Locale.current.identifier
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.text = text
        self.imageAttachments = Array(imageAttachments.prefix(4))
        self.locale = String(locale.prefix(64))
    }
}

public extension VoiceCommandEnvelope {
    func asInputEnvelope(
        imageAttachments: [InputEnvelope.ImageAttachment] = []
    ) -> InputEnvelope {
        let isVoiceSource: Bool
        switch source {
        case .iPhoneSpeechAnalyzer, .iPhoneLegacySpeech, .qwenASR, .watchDictation:
            isVoiceSource = true
        case .appIntent, .manualText:
            isVoiceSource = false
        }

        let envelopeSource: InputEnvelope.Source
        if imageAttachments.isEmpty {
            envelopeSource = isVoiceSource ? .voice : .text
        } else {
            envelopeSource = isVoiceSource ? .voiceAndImage : .textAndImage
        }
        return InputEnvelope(
            id: UUID(),
            createdAt: capturedAt,
            source: envelopeSource,
            text: text,
            imageAttachments: imageAttachments,
            locale: localeIdentifier
        )
    }
}
