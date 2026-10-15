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
