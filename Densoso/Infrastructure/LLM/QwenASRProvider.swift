import Foundation

struct QwenASRProvider: CloudSpeechProvider {
    static let model = "qwen3-asr-flash"
    static let maximumRequestBytes = 10_000_000
    static let maximumAudioSeconds = 300.0

    private let endpoint: URL
    private let credentialSource: any ProviderCredentialSource
    private let executor: ProviderRequestExecutor
    private let logSink: any ProviderLogSink

    init(
        endpoint: URL,
        credentialSource: any ProviderCredentialSource = KeychainStore.shared,
        transport: any ProviderHTTPTransport = URLSessionProviderTransport(),
        clock: any ProviderRetryClock = SystemProviderRetryClock(),
        logSink: any ProviderLogSink = NoOpProviderLogSink(),
        jitter: @escaping @Sendable (Int) -> Double = { _ in Double.random(in: 0...0.25) }
    ) {
        self.endpoint = endpoint
        self.credentialSource = credentialSource
        self.executor = ProviderRequestExecutor(
            transport: transport,
            clock: clock,
            jitter: jitter
        )
        self.logSink = logSink
    }

    func transcribe(audio: SanitizedAudio, locale: Locale) async throws -> CloudTranscript {
        guard audio.mimeType == "audio/wav",
              audio.sampleRate == SpeechAudioFrame.canonicalSampleRate,
              audio.channelCount == SpeechAudioFrame.canonicalChannelCount,
              audio.durationSeconds > 0,
              audio.durationSeconds <= Self.maximumAudioSeconds else {
            throw ProviderError.schemaViolation(path: "audio")
        }
        guard let key = try credentialSource.credential(for: .qwen),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.configurationMissing(provider: .qwen)
        }

        let language = locale.language.languageCode?.identifier == "zh" ? "zh" : nil
        let requestBody = QwenASRRequest(
            audioDataURL: "data:audio/wav;base64,\(audio.data.base64EncodedString())",
            language: language
        )
        let body = try JSONEncoder().encode(requestBody)
        guard body.count <= Self.maximumRequestBytes else {
            throw ProviderError.requestTooLarge(limitBytes: Self.maximumRequestBytes)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let requestID = UUID()
        let startedAt = Date()
        let result = try await executor.execute(
            request,
            deadline: Date().addingTimeInterval(45)
        )
        logSink.record(
            ProviderLogRedactor.metadata(
                requestID: requestID,
                provider: .qwen,
                status: result.response.statusCode,
                attempt: result.attempt,
                latencyMilliseconds: Self.latencyMilliseconds(since: startedAt)
            )
        )

        let response: QwenASRResponse
        do {
            response = try JSONDecoder().decode(QwenASRResponse.self, from: result.data)
        } catch {
            throw ProviderError.malformedResponse
        }
        guard let choice = response.choices.first else {
            throw ProviderError.malformedResponse
        }
        if choice.finishReason == "content_filter" {
            throw ProviderError.contentRejected
        }
        let text = choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderError.malformedResponse }

        return CloudTranscript(
            text: text,
            model: response.model ?? Self.model,
            billedAudioSeconds: max(response.usage?.seconds ?? audio.durationSeconds, 0),
            attempt: result.attempt
        )
    }

    private static func latencyMilliseconds(since start: Date) -> Int {
        let milliseconds = max(Date().timeIntervalSince(start) * 1_000, 0)
        return Int(min(milliseconds, Double(Int.max)))
    }
}

struct ConfiguredQwenASRProvider: CloudSpeechProvider {
    private let credentialSource: any ProviderCredentialSource
    private let transport: any ProviderHTTPTransport
    private let logSink: any ProviderLogSink

    init(
        credentialSource: any ProviderCredentialSource = KeychainStore.shared,
        transport: any ProviderHTTPTransport = URLSessionProviderTransport(),
        logSink: any ProviderLogSink = NoOpProviderLogSink()
    ) {
        self.credentialSource = credentialSource
        self.transport = transport
        self.logSink = logSink
    }

    func transcribe(audio: SanitizedAudio, locale: Locale) async throws -> CloudTranscript {
        let endpoint = try UserDefaultsQwenASREndpointSource().endpoint()
        return try await QwenASRProvider(
            endpoint: endpoint,
            credentialSource: credentialSource,
            transport: transport,
            logSink: logSink
        ).transcribe(audio: audio, locale: locale)
    }
}

private struct UserDefaultsQwenASREndpointSource: Sendable {
    func endpoint() throws -> URL {
        let defaults = UserDefaults.standard
        let workspaceID = (defaults.string(forKey: "provider.qwen.workspaceID") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let region = defaults.string(forKey: "provider.qwen.region") ?? ModelStudioRegion.beijing.rawValue
        guard region == ModelStudioRegion.beijing.rawValue else {
            throw ProviderError.unsupportedCapability(.speech)
        }
        guard !workspaceID.isEmpty,
              workspaceID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              let endpoint = URL(
                  string: "https://\(workspaceID).cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
              ) else {
            throw ProviderError.configurationMissing(provider: .qwen)
        }
        return endpoint
    }
}

private struct QwenASRRequest: Encodable {
    let model = QwenASRProvider.model
    let messages: [Message]
    let stream = false
    let asrOptions: ASROptions

    init(audioDataURL: String, language: String?) {
        messages = [Message(content: [Content(inputAudio: InputAudio(data: audioDataURL))])]
        asrOptions = ASROptions(language: language, enableITN: false)
    }

    struct Message: Encodable {
        let role = "user"
        let content: [Content]
    }

    struct Content: Encodable {
        let type = "input_audio"
        let inputAudio: InputAudio

        enum CodingKeys: String, CodingKey {
            case type
            case inputAudio = "input_audio"
        }
    }

    struct InputAudio: Encodable {
        let data: String
    }

    struct ASROptions: Encodable {
        let language: String?
        let enableITN: Bool

        enum CodingKeys: String, CodingKey {
            case language
            case enableITN = "enable_itn"
        }
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case asrOptions = "asr_options"
    }
}

private struct QwenASRResponse: Decodable {
    let model: String?
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        let content: String
    }

    struct Usage: Decodable {
        let seconds: Double?
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case seconds
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}
