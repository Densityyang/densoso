import Foundation
@testable import Densoso

enum TestPricingDescriptorCatalog {
    static let source = StaticPricingDescriptorSource(descriptors: [
        descriptor(provider: .deepSeek, model: "fixture-model", currency: "USD"),
        descriptor(provider: .deepSeek, model: "retry-fixture-model", currency: "USD"),
        descriptor(provider: .deepSeek, model: "resume-test", currency: "USD"),
        descriptor(provider: .qwen, model: "fixture-model", currency: "CNY"),
    ])

    private static func descriptor(provider: ProviderID, model: String, currency: String) -> PricingDescriptor {
        PricingDescriptor(
            provider: provider,
            model: model,
            capability: .text,
            version: "agent-test-price-v1",
            origin: .localConfiguration(identifier: "agent-test-price-v1"),
            currency: currency,
            inputMicrosPerMillionTokens: 1_000_000,
            cachedInputMicrosPerMillionTokens: 100_000,
            outputMicrosPerMillionTokens: 2_000_000,
            audioMicrosPerSecond: nil
        )
    }
}

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

    init(
        provider: ProviderID = .deepSeek,
        model: String = "fixture-model",
        scripts: [[ProviderEvent]],
        capabilities: Set<ProviderCapability> = [.text, .toolCalling]
    ) {
        descriptor = ProviderDescriptor(
            id: provider,
            model: model,
            capabilities: capabilities
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

final class FailOnceScriptedTextProvider: TextModelProvider, @unchecked Sendable {
    let descriptor = ProviderDescriptor(
        id: .deepSeek,
        model: "retry-fixture-model",
        capabilities: [.text, .toolCalling]
    )
    private let lock = NSLock()
    private var scripts: [[ProviderEvent]]
    private var requests: [ModelRequest] = []
    private var shouldFailFirstRequest = true

    init(scripts: [[ProviderEvent]]) {
        self.scripts = scripts
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        let outcome = lock.withLock { () -> Result<[ProviderEvent], ProviderError> in
            requests.append(request)
            if shouldFailFirstRequest {
                shouldFailFirstRequest = false
                return .failure(.network(code: nil))
            }
            return .success(scripts.isEmpty ? [] : scripts.removeFirst())
        }
        return AsyncThrowingStream { continuation in
            switch outcome {
            case .failure(let error): continuation.finish(throwing: error)
            case .success(let events):
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
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
    ) -> Bool {
        if let existing = usages[usageKey] {
            return existing.1 != nil && existing.2 == currency
        }
        usages[usageKey] = (usage, estimatedCostMicros, currency)
        return estimatedCostMicros != nil
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
            audioSeconds: matching.reduce(0) { $0 + $1.0.audioSeconds },
            estimatedCostMicros: costs.count == matching.count ? costs.reduce(0, +) : nil,
            currency: matching.compactMap { $0.2 }.first
        )
    }

    func usageCount() -> Int { usages.count }
    func recordedUsageKeys() -> [String] { Array(usages.keys) }
}

actor BlockingConversationRepository: ConversationRepository {
    private var appendStarted = false
    private var requests: [UUID: AgentRequestSnapshot] = [:]

    func beginAgentRequest(
        requestID: UUID,
        conversationID: UUID,
        initialBudget: AgentBudget,
        startedAt: Date,
        containsTransientImage: Bool
    ) -> AgentRequestSnapshot {
        if let existing = requests[requestID] {
            let resumed = AgentRequestSnapshot(
                requestID: existing.requestID,
                conversationID: existing.conversationID,
                startedAt: existing.startedAt,
                budget: existing.budget,
                consumption: existing.consumption,
                costBudget: existing.costBudget,
                resumeCount: existing.resumeCount + 1,
                containsTransientImage: existing.containsTransientImage,
                state: .running
            )
            requests[requestID] = resumed
            return resumed
        }
        let created = AgentRequestSnapshot(
            requestID: requestID,
            conversationID: conversationID,
            startedAt: startedAt,
            budget: initialBudget,
            consumption: .zero,
            costBudget: AgentRequestCostBudget(
                maximumCostMicros: initialBudget.maximumCostMicros,
                reservedCostMicros: 0,
                provider: nil,
                model: nil,
                currency: nil,
                pricingVersion: nil,
                lastReservedProviderRound: 0,
                lastReservedCostMicros: 0,
                state: .unresolved
            ),
            resumeCount: 0,
            containsTransientImage: containsTransientImage,
            state: .running
        )
        requests[requestID] = created
        return created
    }

    func updateAgentRequestConsumption(
        requestID: UUID,
        conversationID: UUID,
        consumption: AgentBudgetConsumption
    ) throws {
        guard let existing = requests[requestID] else { throw AgentRequestPersistenceError.requestNotFound }
        requests[requestID] = AgentRequestSnapshot(
            requestID: existing.requestID,
            conversationID: existing.conversationID,
            startedAt: existing.startedAt,
            budget: existing.budget,
            consumption: consumption,
            costBudget: existing.costBudget,
            resumeCount: existing.resumeCount,
            containsTransientImage: existing.containsTransientImage,
            state: existing.state
        )
    }

    func reserveAgentRequestCost(
        requestID: UUID,
        conversationID: UUID,
        provider: ProviderID,
        model: String,
        currency: String,
        pricingVersion: String,
        providerRound: Int,
        estimatedCostMicros: Int64?
    ) throws -> AgentRequestCostBudget {
        guard let existing = requests[requestID] else { throw AgentRequestPersistenceError.requestNotFound }
        let current = existing.costBudget
        if current.state == .unavailable {
            guard current.provider == provider && current.model == model else {
                throw AgentRequestPersistenceError.costBudgetMismatch
            }
            return current
        }
        if let currentProvider = current.provider,
           (currentProvider != provider
                || current.model != model
                || current.currency != currency
                || current.pricingVersion != pricingVersion) {
            throw AgentRequestPersistenceError.costBudgetMismatch
        }
        if current.lastReservedProviderRound == providerRound { return current }
        guard current.lastReservedProviderRound < Int.max,
              providerRound == current.lastReservedProviderRound + 1 else {
            throw AgentRequestPersistenceError.costBudgetMismatch
        }
        guard let estimatedCostMicros else {
            let unavailable = AgentRequestCostBudget(
                maximumCostMicros: current.maximumCostMicros,
                reservedCostMicros: current.reservedCostMicros,
                provider: provider,
                model: model,
                currency: current.currency ?? "unavailable",
                pricingVersion: current.pricingVersion ?? "unknown",
                lastReservedProviderRound: providerRound,
                lastReservedCostMicros: 0,
                state: .unavailable
            )
            requests[requestID] = AgentRequestSnapshot(
                requestID: existing.requestID,
                conversationID: existing.conversationID,
                startedAt: existing.startedAt,
                budget: existing.budget,
                consumption: existing.consumption,
                costBudget: unavailable,
                resumeCount: existing.resumeCount,
                containsTransientImage: existing.containsTransientImage,
                state: existing.state
            )
            return unavailable
        }
        let total = current.reservedCostMicros.addingReportingOverflow(estimatedCostMicros)
        guard !total.overflow, total.partialValue <= current.maximumCostMicros else {
            throw AgentRequestPersistenceError.costBudgetExceeded
        }
        let updated = AgentRequestCostBudget(
            maximumCostMicros: current.maximumCostMicros,
            reservedCostMicros: total.partialValue,
            provider: provider,
            model: model,
            currency: currency,
            pricingVersion: pricingVersion,
            lastReservedProviderRound: providerRound,
            lastReservedCostMicros: estimatedCostMicros,
            state: .estimated
        )
        requests[requestID] = AgentRequestSnapshot(
            requestID: existing.requestID,
            conversationID: existing.conversationID,
            startedAt: existing.startedAt,
            budget: existing.budget,
            consumption: existing.consumption,
            costBudget: updated,
            resumeCount: existing.resumeCount,
            containsTransientImage: existing.containsTransientImage,
            state: existing.state
        )
        return updated
    }

    func markAgentRequestCostUnavailable(requestID: UUID, conversationID: UUID) throws {
        guard let existing = requests[requestID] else { throw AgentRequestPersistenceError.requestNotFound }
        let current = existing.costBudget
        requests[requestID] = AgentRequestSnapshot(
            requestID: existing.requestID,
            conversationID: existing.conversationID,
            startedAt: existing.startedAt,
            budget: existing.budget,
            consumption: existing.consumption,
            costBudget: AgentRequestCostBudget(
                maximumCostMicros: current.maximumCostMicros,
                reservedCostMicros: current.reservedCostMicros,
                provider: current.provider,
                model: current.model,
                currency: current.currency,
                pricingVersion: current.pricingVersion,
                lastReservedProviderRound: current.lastReservedProviderRound,
                lastReservedCostMicros: current.lastReservedCostMicros,
                state: .unavailable
            ),
            resumeCount: existing.resumeCount,
            containsTransientImage: existing.containsTransientImage,
            state: existing.state
        )
    }

    func addAgentRequestUsage(
        requestID: UUID,
        conversationID: UUID,
        usage: AgentTokenUsage
    ) throws {
        guard let existing = requests[requestID] else { throw AgentRequestPersistenceError.requestNotFound }
        requests[requestID] = AgentRequestSnapshot(
            requestID: existing.requestID,
            conversationID: existing.conversationID,
            startedAt: existing.startedAt,
            budget: existing.budget,
            consumption: existing.consumption.adding(usage),
            costBudget: existing.costBudget,
            resumeCount: existing.resumeCount,
            containsTransientImage: existing.containsTransientImage,
            state: existing.state
        )
    }

    func updateAgentRequestState(
        requestID: UUID,
        conversationID: UUID,
        state: AgentRequestState
    ) throws {
        guard let existing = requests[requestID] else { throw AgentRequestPersistenceError.requestNotFound }
        requests[requestID] = AgentRequestSnapshot(
            requestID: existing.requestID,
            conversationID: existing.conversationID,
            startedAt: existing.startedAt,
            budget: existing.budget,
            consumption: existing.consumption,
            costBudget: existing.costBudget,
            resumeCount: existing.resumeCount,
            containsTransientImage: existing.containsTransientImage,
            state: state
        )
    }

    func agentRequest(requestID: UUID, conversationID: UUID) -> AgentRequestSnapshot? {
        requests[requestID]
    }

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

    func resumeHistory(conversationID: UUID, requestID: UUID) -> [Data] { [] }

    func containsRequestID(_ requestID: UUID, conversationID: UUID) -> Bool { false }

    func containsCompletedResponse(requestID: UUID, conversationID: UUID) -> Bool { false }

    func toolSchemaVersion(conversationID: UUID) -> Int { ToolSchemaVersion.current }

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
