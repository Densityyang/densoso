import XCTest
@testable import Densoso

@MainActor
final class ProviderRetryPolicyTests: XCTestCase {
    func testUnauthorizedDoesNotRetry() async throws {
        for status in [401, 403] {
            let transport = ScriptedProviderHTTPTransport(
                steps: [.response(status: status, data: Data())]
            )
            let clock = TestProviderRetryClock()
            let executor = ProviderRequestExecutor(
                transport: transport,
                clock: clock,
                jitter: { _ in 0 }
            )

            await XCTAssertProviderError(
                try await executor.execute(request(), deadline: clock.now().addingTimeInterval(45)),
                equals: .unauthorized(status: status)
            )
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testRateLimitUsesRetryAfterThenSucceeds() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [
                .response(status: 429, headers: ["Retry-After": "2"], data: Data()),
                .response(status: 200, data: Data("{}".utf8)),
            ]
        )
        let clock = TestProviderRetryClock()
        let executor = ProviderRequestExecutor(
            transport: transport,
            clock: clock,
            jitter: { _ in 0 }
        )

        let result = try await executor.execute(request(), deadline: clock.now().addingTimeInterval(45))

        XCTAssertEqual(result.attempt, 2)
        XCTAssertEqual(clock.sleeps(), [2])
    }

    func testServerFailureRetriesAtMostTwice() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [
                .response(status: 503, data: Data()),
                .response(status: 503, data: Data()),
                .response(status: 503, data: Data()),
            ]
        )
        let clock = TestProviderRetryClock()
        let executor = ProviderRequestExecutor(
            transport: transport,
            clock: clock,
            jitter: { _ in 0 }
        )

        await XCTAssertProviderError(
            try await executor.execute(request(), deadline: clock.now().addingTimeInterval(45)),
            equals: .server(status: 503)
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
    }

    func testNetworkFailureRetriesThenSucceeds() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [
                .urlError(.networkConnectionLost),
                .response(status: 200, data: Data("{}".utf8)),
            ]
        )
        let clock = TestProviderRetryClock()
        let executor = ProviderRequestExecutor(
            transport: transport,
            clock: clock,
            jitter: { _ in 0 }
        )

        let result = try await executor.execute(request(), deadline: clock.now().addingTimeInterval(45))
        XCTAssertEqual(result.attempt, 2)
    }

    func testDeepSeekStreamRetryRevalidatesCapturedPolicyRevision() async throws {
        let authorization = RetryPolicyAuthorization(
            provider: .deepSeek,
            allowedClasses: [.healthText]
        )
        let transport = RetryPolicyChangingTransport {
            await authorization.revokeAndReconfirm(.healthText)
        }
        let clock = TestProviderRetryClock()
        let provider = DeepSeekProvider(
            credentialSource: TestCredentialSource(values: [.deepSeek: "fixture"]),
            transport: transport,
            clock: clock,
            jitter: { _ in 0 }
        )
        var providerRequest = ModelRequest(
            requestID: UUID(),
            conversationID: UUID(),
            systemPrompt: nil,
            messages: [ModelMessage(role: .user, text: "retry policy")],
            tools: [],
            maxOutputTokens: 32,
            thinking: .none,
            deadline: clock.now().addingTimeInterval(45)
        )
        providerRequest.preSerializationGate = { serialize in try serialize() }
        providerRequest.networkAttemptGate = {
            try await authorization.authorize(
                expectedRevision: 4,
                requiredClasses: [.healthText]
            )
        }

        do {
            _ = try await collect(provider.stream(providerRequest))
            XCTFail("A stale DeepSeek body must not be retried after its policy revision changes")
        } catch {
            XCTAssertEqual(error as? ProviderError, .consentPolicyChanged(provider: .deepSeek))
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testQwenTextRetryRevalidatesCapturedPolicyRevision() async throws {
        let authorization = RetryPolicyAuthorization(
            provider: .qwen,
            allowedClasses: [.healthText]
        )
        let transport = RetryPolicyChangingTransport {
            await authorization.revokeAndReconfirm(.healthText)
        }
        let clock = TestProviderRetryClock()
        let provider = QwenProvider(
            endpoint: URL(string: "https://provider.example.test/v1/chat/completions")!,
            credentialSource: TestCredentialSource(values: [.qwen: "fixture"]),
            transport: transport,
            clock: clock,
            jitter: { _ in 0 }
        )
        var providerRequest = ModelRequest(
            requestID: UUID(),
            conversationID: UUID(),
            systemPrompt: nil,
            messages: [ModelMessage(role: .user, text: "retry policy")],
            tools: [],
            maxOutputTokens: 32,
            thinking: .none,
            deadline: clock.now().addingTimeInterval(45)
        )
        providerRequest.preSerializationGate = { serialize in try serialize() }
        providerRequest.networkAttemptGate = {
            try await authorization.authorize(
                expectedRevision: 4,
                requiredClasses: [.healthText]
            )
        }

        do {
            _ = try await collect(provider.stream(providerRequest))
            XCTFail("A stale Qwen body must not be retried after its policy revision changes")
        } catch {
            XCTAssertEqual(error as? ProviderError, .consentPolicyChanged(provider: .qwen))
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testQwenASRRetryRejectsRevokedAndReconfirmedSpeechAudioConsent() async throws {
        let authorization = RetryPolicyAuthorization(
            provider: .qwen,
            allowedClasses: [.speechAudio]
        )
        let transport = RetryPolicyChangingTransport {
            await authorization.revokeAndReconfirm(.speechAudio)
        }
        let clock = TestProviderRetryClock()
        let provider = QwenASRProvider(
            endpoint: URL(string: "https://provider.example.test/v1/chat/completions")!,
            credentialSource: TestCredentialSource(values: [.qwen: "fixture"]),
            transport: transport,
            clock: clock,
            jitter: { _ in 0 }
        )

        do {
            _ = try await provider.transcribe(
                audio: SanitizedAudio(
                    data: Data("RIFF-retry".utf8),
                    mimeType: "audio/wav",
                    durationSeconds: 1,
                    sampleRate: 16_000,
                    channelCount: 1
                ),
                locale: .current,
                requestID: UUID(),
                beforeNetworkAttempt: {
                    try await authorization.authorize(
                        expectedRevision: 4,
                        requiredClasses: [.speechAudio]
                    )
                }
            )
            XCTFail("Qwen ASR must reject old audio after speech-audio consent is revoked and reconfirmed")
        } catch {
            XCTAssertEqual(error as? ProviderError, .consentPolicyChanged(provider: .qwen))
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testDeadlineStopsRetryBeforeSleepingPastBudget() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [.response(status: 503, data: Data())]
        )
        let clock = TestProviderRetryClock()
        let executor = ProviderRequestExecutor(
            transport: transport,
            clock: clock,
            jitter: { _ in 0 }
        )

        await XCTAssertProviderError(
            try await executor.execute(request(), deadline: clock.now().addingTimeInterval(0.1)),
            equals: .timeout
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testHungTransportIsCancelledByHardDeadline() async throws {
        let transport = ScriptedProviderHTTPTransport(steps: [.delay])
        let executor = ProviderRequestExecutor(
            transport: transport,
            jitter: { _ in 0 }
        )
        let continuousClock = ContinuousClock()
        let started = continuousClock.now

        await XCTAssertProviderError(
            try await executor.execute(
                request(),
                deadline: Date().addingTimeInterval(0.05)
            ),
            equals: .timeout
        )

        let elapsed = started.duration(to: continuousClock.now)
        XCTAssertLessThan(elapsed, .seconds(1))
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(requests.first).timeoutInterval, 0.1)
    }

    func testClientProtocolFailureDoesNotMasqueradeAsServerOutage() async throws {
        for status in [400, 422] {
            let transport = ScriptedProviderHTTPTransport(
                steps: [.response(status: status, data: Data())]
            )
            let executor = ProviderRequestExecutor(
                transport: transport,
                jitter: { _ in 0 }
            )

            await XCTAssertProviderError(
                try await executor.execute(
                    request(),
                    deadline: Date().addingTimeInterval(45)
                ),
                equals: .requestRejected(status: status)
            )
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testProviderStreamCancellationCancelsTransportTask() async throws {
        let transport = ScriptedProviderHTTPTransport(steps: [.delay])
        let provider = DeepSeekProvider(
            credentialSource: TestCredentialSource(values: [.deepSeek: "fixture"]),
            transport: transport,
            jitter: { _ in 0 }
        )
        let request = ModelRequest(
            requestID: UUID(),
            conversationID: UUID(),
            systemPrompt: nil,
            messages: [ModelMessage(role: .user, text: "cancel")],
            tools: [],
            maxOutputTokens: 10,
            thinking: .disabled,
            deadline: Date().addingTimeInterval(45)
        )
        let task = Task { try await collect(provider.stream(request)) }
        let clock = ContinuousClock()
        let startTimeout = clock.now.advanced(by: .seconds(1))
        while (await transport.recordedRequests()).isEmpty {
            guard clock.now < startTimeout else {
                task.cancel()
                return XCTFail("Transport task did not start")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // AsyncThrowingStream cancellation may surface at the consumer.
        } catch {
            XCTAssertEqual(error as? ProviderError, .cancelled)
        }

        let timeout = clock.now.advanced(by: .seconds(1))
        while await transport.recordedCancellationCount() == 0 {
            guard clock.now < timeout else {
                return XCTFail("Transport task did not receive cancellation")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let cancellationCount = await transport.recordedCancellationCount()
        XCTAssertEqual(cancellationCount, 1)
    }

    private func request() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://provider.example.test/v1/messages")!)
        request.httpMethod = "POST"
        return request
    }
}

actor RetryPolicyAuthorization {
    private let provider: ProviderID
    private var revision = 4
    private var allowedClasses: Set<ProviderDataClass>

    init(provider: ProviderID, allowedClasses: Set<ProviderDataClass>) {
        self.provider = provider
        self.allowedClasses = allowedClasses
    }

    func authorize(
        expectedRevision: Int,
        requiredClasses: Set<ProviderDataClass>
    ) throws {
        guard revision == expectedRevision else {
            throw ProviderError.consentPolicyChanged(provider: provider)
        }
        for dataClass in requiredClasses where !allowedClasses.contains(dataClass) {
            throw ProviderError.consentRequired(provider: provider, dataClass: dataClass)
        }
    }

    func revokeAndReconfirm(_ dataClass: ProviderDataClass) {
        allowedClasses.remove(dataClass)
        revision += 1
        allowedClasses.insert(dataClass)
        revision += 1
    }
}

actor RetryPolicyChangingTransport: ProviderHTTPTransport {
    private let onFirstRequest: @Sendable () async -> Void
    private var requests: [URLRequest] = []

    init(onFirstRequest: @escaping @Sendable () async -> Void) {
        self.onFirstRequest = onFirstRequest
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if requests.count == 1 {
            await onFirstRequest()
            return (Data(), response(for: request, status: 503))
        }
        return (Data("{}".utf8), response(for: request, status: 200))
    }

    func recordedRequests() -> [URLRequest] { requests }

    private func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}

@MainActor
private func XCTAssertProviderError<T>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: ProviderError
) async {
    do {
        _ = try await expression()
        XCTFail("Expected ProviderError")
    } catch {
        XCTAssertEqual(error as? ProviderError, expected)
    }
}
