import Foundation
@testable import Densoso

struct TestCredentialSource: ProviderCredentialSource {
    let values: [ProviderID: String]

    func credential(for provider: ProviderID) throws -> String? {
        values[provider]
    }
}

final class RecordingProviderLogSink: ProviderLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [ProviderLogMetadata] = []

    func record(_ metadata: ProviderLogMetadata) {
        lock.withLock { records.append(metadata) }
    }

    func recordedMetadata() -> [ProviderLogMetadata] {
        lock.withLock { records }
    }
}

actor ScriptedProviderHTTPTransport: ProviderHTTPTransport {
    enum Step: Sendable {
        case response(status: Int, headers: [String: String] = [:], data: Data)
        case urlError(URLError.Code)
        case delay
    }

    private var steps: [Step]
    private var requests: [URLRequest] = []
    private var cancellationCount = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        let step = steps.removeFirst()
        switch step {
        case .response(let status, let headers, let data):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (data, response)
        case .urlError(let code):
            throw URLError(code)
        case .delay:
            do {
                try await Task.sleep(for: .seconds(60))
                throw URLError(.timedOut)
            } catch is CancellationError {
                cancellationCount += 1
                throw CancellationError()
            }
        }
    }

    func recordedRequests() -> [URLRequest] { requests }
    func recordedCancellationCount() -> Int { cancellationCount }
}

final class TestProviderRetryClock: ProviderRetryClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var recordedSleeps: [Double] = []

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = now
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func sleep(seconds: Double) async throws {
        lock.withLock {
            recordedSleeps.append(seconds)
            current = current.addingTimeInterval(seconds)
        }
    }

    func sleeps() -> [Double] {
        lock.withLock { recordedSleeps }
    }
}

final class ScriptedTextProvider: TextModelProvider, @unchecked Sendable {
    let descriptor: ProviderDescriptor
    private let lock = NSLock()
    private var scripts: [[ProviderEvent]]
    private var requests: [ModelRequest] = []

    init(provider: ProviderID = .deepSeek, scripts: [[ProviderEvent]]) {
        descriptor = ProviderDescriptor(
            id: provider,
            model: "fixture-model",
            capabilities: [.text, .toolCalling]
        )
        self.scripts = scripts
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        let events = lock.withLock {
            requests.append(request)
            return scripts.isEmpty ? [] : scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func recordedRequests() -> [ModelRequest] {
        lock.withLock { requests }
    }
}

final class DelayedTextProvider: TextModelProvider, @unchecked Sendable {
    let descriptor = ProviderDescriptor(
        id: .deepSeek,
        model: "delayed-fixture-model",
        capabilities: [.text, .toolCalling]
    )
    private let delaySeconds: Double
    private let events: [ProviderEvent]

    init(delaySeconds: Double, events: [ProviderEvent]) {
        self.delaySeconds = delaySeconds
        self.events = events
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .seconds(delaySeconds))
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

@MainActor
final class TestProviderSelector: ProviderSelecting {
    let selectedProvider: any TextModelProvider

    init(_ provider: any TextModelProvider) {
        selectedProvider = provider
    }

    func provider(for mode: IntelligenceMode) throws -> any TextModelProvider {
        selectedProvider
    }
}

actor InMemoryProviderGovernanceRepository: ProviderGovernanceRepository {
    private var consents: Set<String> = []
    private var usages: [String: (ProviderUsage, Int64?, String?)] = [:]

    init(granted: [(ProviderID, ProviderDataClass)] = []) {
        consents = Set(granted.map { "\($0.0.rawValue)|\($0.1.rawValue)" })
    }

    func isConsentGranted(provider: ProviderID, dataClass: ProviderDataClass) -> Bool {
        consents.contains("\(provider.rawValue)|\(dataClass.rawValue)")
    }

    func setConsent(
        provider: ProviderID,
        dataClass: ProviderDataClass,
        granted: Bool,
        policyVersion: String
    ) {
        let key = "\(provider.rawValue)|\(dataClass.rawValue)"
        if granted { consents.insert(key) } else { consents.remove(key) }
    }

    func recordUsage(
        usage: ProviderUsage,
        usageKey: String,
        estimatedCostMicros: Int64?,
        currency: String?,
        rateVersion: String
    ) {
        usages[usageKey] = (usage, estimatedCostMicros, currency)
    }

    func monthlyUsage(
        provider: ProviderID,
        monthStart: Date,
        monthEnd: Date
    ) -> ProviderUsageSummary {
        let matching = usages.values.filter { $0.0.provider == provider }
        let costs = matching.compactMap { $0.1 }
        return ProviderUsageSummary(
            provider: provider,
            inputTokens: matching.reduce(0) { $0 + $1.0.inputTokens },
            outputTokens: matching.reduce(0) { $0 + $1.0.outputTokens },
            estimatedCostMicros: costs.count == matching.count ? costs.reduce(0, +) : nil,
            currency: matching.compactMap { $0.2 }.first
        )
    }

    func usageCount() -> Int { usages.count }
}

actor BlockingConversationRepository: ConversationRepository {
    private var appendStarted = false

    func ensureConversation(id: UUID) {}

    func appendMessage(
        conversationID: UUID,
        role: String,
        contentData: Data,
        toolSummaryData: Data?,
        requestID: UUID?
    ) async throws {
        appendStarted = true
        try await Task.sleep(for: .seconds(60))
    }

    func messageData(conversationID: UUID) -> [Data] { [] }

    func reset(conversationID: UUID) {}

    func hasAppendStarted() -> Bool { appendStarted }
}

enum Gate03FixtureLoader {
    static func data(_ name: String, extension ext: String = "json") throws -> Data {
        let bundle = Bundle(for: Gate03BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}

private final class Gate03BundleToken {}
