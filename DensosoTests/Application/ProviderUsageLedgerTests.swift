import XCTest
import SwiftData
@testable import Densoso

@MainActor
final class ProviderUsageLedgerTests: XCTestCase {
    func testPreflightCostUsesInputUpperBoundMaximumOutputAndRetryAttempts() async throws {
        let ledger = ProviderUsageLedger(
            repository: InMemoryProviderGovernanceRepository(),
            pricingDescriptorSource: StaticPricingDescriptorSource(descriptors: [
                PricingDescriptor(
                    provider: .deepSeek,
                    model: "fixture",
                    capability: .text,
                    version: "fixture-v1",
                    origin: .localConfiguration(identifier: "fixture-v1"),
                    currency: "USD",
                    inputMicrosPerMillionTokens: 1_000_000,
                    cachedInputMicrosPerMillionTokens: 0,
                    outputMicrosPerMillionTokens: 2_000_000,
                    audioMicrosPerSecond: nil
                ),
            ])
        )
        let provider = ProviderDescriptor(id: .deepSeek, model: "fixture", capabilities: [.text])
        let request = ModelRequest(
            requestID: UUID(),
            conversationID: UUID(),
            systemPrompt: "sys",
            messages: [ModelMessage(role: .user, text: "hello")],
            tools: [],
            maxOutputTokens: 100,
            thinking: .none,
            deadline: .distantFuture
        )

        let estimateValue = await ledger.maximumRequestCostEstimate(provider: provider, request: request)
        let estimate = try XCTUnwrap(estimateValue)

        // Input estimate includes the system prompt, empty tool schema, fixed overhead, and message.
        // Each attempt reserves the input estimate plus 200 output micros; all three attempts are covered.
        XCTAssertEqual(estimate.maximumCostMicros, 3_846)
        XCTAssertEqual(estimate.currency, "USD")
        XCTAssertEqual(estimate.pricingVersion, "fixture-v1")
    }

    func testUsageIsIdempotentAndUsesVersionedIntegerRates() async throws {
        let repository = InMemoryProviderGovernanceRepository()
        let ledger = ProviderUsageLedger(
            repository: repository,
            pricingDescriptorSource: StaticPricingDescriptorSource(descriptors: [
                PricingDescriptor(
                    provider: .deepSeek,
                    model: "fixture",
                    capability: .text,
                    version: "fixture-v1",
                    origin: .localConfiguration(identifier: "fixture-v1"),
                    currency: "USD",
                    inputMicrosPerMillionTokens: 1_000_000,
                    cachedInputMicrosPerMillionTokens: 0,
                    outputMicrosPerMillionTokens: 2_000_000,
                    audioMicrosPerSecond: nil
                )
            ])
        )
        let requestID = UUID()
        let usage = ProviderUsage(
            provider: .deepSeek,
            model: "fixture",
            capability: .text,
            inputTokens: 1_000,
            outputTokens: 500,
            audioSeconds: 0,
            attempt: 1
        )

        try await ledger.record(usage, requestID: requestID)
        try await ledger.record(usage, requestID: requestID)
        let summary = try await ledger.monthlySummary(provider: .deepSeek)

        let usageCount = await repository.usageCount()
        XCTAssertEqual(usageCount, 1)
        XCTAssertEqual(summary.inputTokens, 1_000)
        XCTAssertEqual(summary.outputTokens, 500)
        XCTAssertEqual(summary.estimatedCostMicros, 2_000)
        XCTAssertEqual(summary.currency, "USD")
        let exceeded = try await ledger.isSoftBudgetExceeded(
            provider: .deepSeek,
            monthlyBudgetMicros: 1_500
        )
        XCTAssertTrue(exceeded)
    }

    func testUsageIdentityImageCountAndLatencyAreRetainedInLedgerSummary() async throws {
        let repository = InMemoryProviderGovernanceRepository()
        let ledger = ProviderUsageLedger(
            repository: repository,
            pricingDescriptorSource: StaticPricingDescriptorSource.unconfigured
        )
        let requestID = UUID()
        let usage = ProviderUsage(
            provider: .deepSeek,
            model: "fixture",
            capability: .vision,
            inputTokens: 200,
            outputTokens: 30,
            audioSeconds: 0,
            attempt: 2,
            cachedInputTokens: 20,
            reasoningTokens: 5,
            imageCount: 2,
            requestID: requestID,
            latencyMilliseconds: 340
        )

        try await ledger.record(usage, requestID: requestID)

        let summary = try await ledger.monthlySummary(provider: .deepSeek)
        XCTAssertEqual(summary.inputTokens, 200)
        XCTAssertEqual(summary.cachedInputTokens, 20)
        XCTAssertEqual(summary.outputTokens, 30)
        XCTAssertEqual(summary.reasoningTokens, 5)
        XCTAssertEqual(summary.imageCount, 2)
        XCTAssertEqual(summary.averageLatencyMilliseconds, 340)
    }

    func testUsageWithMismatchedRequestIdentityIsRejectedBeforePersistence() async throws {
        let repository = InMemoryProviderGovernanceRepository()
        let ledger = ProviderUsageLedger(repository: repository)

        do {
            try await ledger.record(
                ProviderUsage(
                    provider: .deepSeek,
                    model: "fixture",
                    capability: .text,
                    inputTokens: 1,
                    outputTokens: 1,
                    audioSeconds: 0,
                    attempt: 1,
                    requestID: UUID()
                ),
                requestID: UUID()
            )
            XCTFail("A usage row must not be relabeled with another request identity")
        } catch {
            XCTAssertEqual(error as? ProviderUsageLedgerError, .requestIdentityMismatch)
        }
        let usageCount = await repository.usageCount()
        XCTAssertEqual(usageCount, 0)
    }

    func testInvalidProviderUsageIsRejectedBeforePersistence() async throws {
        let repository = InMemoryProviderGovernanceRepository()
        let ledger = ProviderUsageLedger(repository: repository)
        let invalidUsages = [
            ProviderUsage(
                provider: .deepSeek,
                model: "fixture",
                capability: .text,
                inputTokens: 10,
                outputTokens: 2,
                audioSeconds: 0,
                attempt: 1,
                cachedInputTokens: 11
            ),
            ProviderUsage(
                provider: .qwen,
                model: "fixture",
                capability: .speech,
                inputTokens: 0,
                outputTokens: 0,
                audioSeconds: .infinity,
                attempt: 1
            ),
        ]

        for usage in invalidUsages {
            do {
                try await ledger.record(usage, requestID: UUID())
                XCTFail("Malformed provider usage must not be persisted")
            } catch {
                XCTAssertEqual(error as? ProviderUsageLedgerError, .invalidUsage)
            }
        }

        let usageCount = await repository.usageCount()
        XCTAssertEqual(usageCount, 0)
    }

    func testLegacyUsagePayloadDecodesWithUnknownImageAndLatencyMetadata() throws {
        let data = Data(
            #"{"provider":"deepSeek","model":"fixture","capability":"text","inputTokens":10,"cachedInputTokens":2,"outputTokens":3,"reasoningTokens":1,"audioSeconds":0,"attempt":1}"#.utf8
        )

        let usage = try JSONDecoder().decode(ProviderUsage.self, from: data)

        XCTAssertEqual(usage.imageCount, 0)
        XCTAssertNil(usage.requestID)
        XCTAssertNil(usage.latencyMilliseconds)
    }

    func testMissingRateIsUnavailableRatherThanZero() async throws {
        let repository = InMemoryProviderGovernanceRepository()
        let ledger = ProviderUsageLedger(
            repository: repository,
            pricingDescriptorSource: StaticPricingDescriptorSource.unconfigured
        )
        let costWasPriced = try await ledger.recordWithCostAvailability(
            ProviderUsage(
                provider: ProviderID.qwen,
                model: "fixture",
                capability: .text,
                inputTokens: 10,
                outputTokens: 5,
                audioSeconds: 0,
                attempt: 1
            ),
            requestID: UUID()
        )
        XCTAssertFalse(costWasPriced)

        let summary = try await ledger.monthlySummary(provider: ProviderID.qwen)
        XCTAssertNil(summary.estimatedCostMicros)
        let exceeded = try await ledger.isSoftBudgetExceeded(
            provider: ProviderID.qwen,
            monthlyBudgetMicros: 1
        )
        XCTAssertFalse(exceeded)

        let qwenEstimate = PricingDescriptorCatalog.phase3Conservative.estimate(
            ProviderUsage(
                provider: .qwen,
                model: "qwen-flash",
                capability: .text,
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                audioSeconds: 0,
                attempt: 1
            )
        )
        XCTAssertEqual(qwenEstimate?.micros, 1_650_000)
        XCTAssertEqual(qwenEstimate?.currency, "CNY")
    }

    func testCachedInputUsesDescriptorPriceWithoutDoubleCounting() {
        let descriptor = PricingDescriptor(
            provider: .deepSeek,
            model: "fixture",
            capability: .text,
            version: "fixture-v2",
            origin: .localConfiguration(identifier: "fixture-v2"),
            currency: "USD",
            inputMicrosPerMillionTokens: 1_000_000,
            cachedInputMicrosPerMillionTokens: 100_000,
            outputMicrosPerMillionTokens: 2_000_000,
            audioMicrosPerSecond: nil
        )
        let usage = ProviderUsage(
            provider: .deepSeek,
            model: "fixture",
            capability: .text,
            inputTokens: 1_000,
            outputTokens: 500,
            audioSeconds: 0,
            attempt: 1,
            cachedInputTokens: 400
        )

        XCTAssertEqual(descriptor.estimate(usage)?.micros, 1_640)
    }

    func testFractionalMicroCostsRoundUpForConservativeEstimate() {
        let descriptor = PricingDescriptor(
            provider: .deepSeek,
            model: "fixture",
            capability: .text,
            version: "fixture-v1",
            origin: .localConfiguration(identifier: "fixture-v1"),
            currency: "USD",
            inputMicrosPerMillionTokens: 500_000,
            cachedInputMicrosPerMillionTokens: 0,
            outputMicrosPerMillionTokens: 0,
            audioMicrosPerSecond: nil
        )
        let usage = ProviderUsage(
            provider: .deepSeek,
            model: "fixture",
            capability: .text,
            inputTokens: 1,
            outputTokens: 0,
            audioSeconds: 0,
            attempt: 1
        )

        XCTAssertEqual(descriptor.estimate(usage)?.micros, 1)
    }

    func testSpeechCostRejectsUnrepresentableInt64BoundaryWithoutTrap() {
        let descriptor = PricingDescriptor(
            provider: .qwen,
            model: "fixture",
            capability: .speech,
            version: "fixture-v1",
            origin: .localConfiguration(identifier: "fixture-v1"),
            currency: "CNY",
            inputMicrosPerMillionTokens: nil,
            cachedInputMicrosPerMillionTokens: nil,
            outputMicrosPerMillionTokens: nil,
            audioMicrosPerSecond: 1
        )
        let representableUsage = ProviderUsage(
            provider: .qwen,
            model: "fixture",
            capability: .speech,
            inputTokens: 0,
            outputTokens: 0,
            audioSeconds: 12.5,
            attempt: 1
        )
        XCTAssertEqual(descriptor.estimate(representableUsage)?.micros, 13)

        // Double(Int64.max) rounds to 2^63, which cannot be converted to Int64.
        let boundaryUsage = ProviderUsage(
            provider: .qwen,
            model: "fixture",
            capability: .speech,
            inputTokens: 0,
            outputTokens: 0,
            audioSeconds: Double(Int64.max),
            attempt: 1
        )
        XCTAssertNil(descriptor.estimate(boundaryUsage))
    }

    func testQwenSpeechUsageWithoutPricingDescriptorKeepsCostUnknown() async throws {
        let repository = InMemoryProviderGovernanceRepository()
        let ledger = ProviderUsageLedger(repository: repository)
        try await ledger.record(
            ProviderUsage(
                provider: .qwen,
                model: "qwen3-asr-flash",
                capability: .speech,
                inputTokens: 999_999,
                outputTokens: 999_999,
                audioSeconds: 1.25,
                attempt: 1
            ),
            requestID: UUID()
        )

        let summary = try await ledger.monthlySummary(provider: .qwen)

        XCTAssertEqual(summary.audioSeconds, 1.25, accuracy: 0.0001)
        XCTAssertNil(summary.estimatedCostMicros)
        XCTAssertNil(summary.currency)
    }

    func testProductionRateTableProvidesConservativeSoftBudgetEstimates() async throws {
        let repository = InMemoryProviderGovernanceRepository()
        let ledger = ProviderUsageLedger(repository: repository)
        try await ledger.record(
            ProviderUsage(
                provider: .deepSeek,
                model: "deepseek-flash",
                capability: .text,
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                audioSeconds: 0,
                attempt: 1
            ),
            requestID: UUID()
        )

        let summary = try await ledger.monthlySummary(provider: .deepSeek)
        XCTAssertEqual(summary.estimatedCostMicros, 1_500_000)
        XCTAssertEqual(summary.currency, "USD")
        let exceeded = try await ledger.isSoftBudgetExceeded(
            provider: .deepSeek,
            monthlyBudgetMicros: 2_000_000
        )
        XCTAssertFalse(exceeded)
    }

    func testSwiftDataLedgerSurvivesRepositoryRecreation() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV9.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let first = SwiftDataProviderGovernanceRepository(modelContainer: container)
        let ledger = ProviderUsageLedger(
            repository: first,
            pricingDescriptorSource: StaticPricingDescriptorSource(descriptors: [
                PricingDescriptor(
                    provider: .deepSeek,
                    model: "fixture",
                    capability: .text,
                    version: "fixture-v1",
                    origin: .localConfiguration(identifier: "fixture-v1"),
                    currency: "USD",
                    inputMicrosPerMillionTokens: 1_000_000,
                    cachedInputMicrosPerMillionTokens: 1_000_000,
                    outputMicrosPerMillionTokens: 1_000_000,
                    audioMicrosPerSecond: nil
                )
            ])
        )
        try await ledger.record(
            ProviderUsage(
                provider: .deepSeek,
                model: "fixture",
                capability: .text,
                inputTokens: 100,
                outputTokens: 50,
                audioSeconds: 0,
                attempt: 1
            ),
            requestID: UUID()
        )

        let recreated = ProviderUsageLedger(
            repository: SwiftDataProviderGovernanceRepository(modelContainer: container)
        )
        let summary = try await recreated.monthlySummary(provider: .deepSeek)
        XCTAssertEqual(summary.inputTokens, 100)
        XCTAssertEqual(summary.outputTokens, 50)
        let records = try container.mainContext.fetch(FetchDescriptor<ProviderUsageRecord>())
        XCTAssertEqual(records.first?.rateVersion, "fixture-v1")
    }

    func testPricingDescriptorRequiresExactModelAndCapability() {
        let source = PricingDescriptorCatalog.phase3Conservative
        let usage = ProviderUsage(
            provider: .deepSeek,
            model: "deepseek-flash",
            capability: .text,
            inputTokens: 10,
            outputTokens: 2,
            audioSeconds: 0,
            attempt: 1
        )

        XCTAssertEqual(source.descriptor(for: usage)?.version, "deepseek-2026-09-10-peak-upper-bound")
        XCTAssertEqual(
            source.descriptor(for: usage)?.origin,
            .publishedPriceList(documentID: "deepseek-pricing", checkedOn: "2026-10-23")
        )
        XCTAssertNil(source.descriptor(for: ProviderUsage(
            provider: .deepSeek,
            model: "deepseek-next-model",
            capability: .text,
            inputTokens: 10,
            outputTokens: 2,
            audioSeconds: 0,
            attempt: 1
        )))
        XCTAssertNil(source.descriptor(for: ProviderUsage(
            provider: .deepSeek,
            model: "deepseek-flash",
            capability: .vision,
            inputTokens: 10,
            outputTokens: 2,
            audioSeconds: 0,
            attempt: 1
        )))
    }

    func testMissingCachedPriceAndUnlistedVisionModelKeepCostUnknown() {
        let missingCachedPrice = PricingDescriptor(
            provider: .deepSeek,
            model: "fixture",
            capability: .text,
            version: "fixture-v1",
            origin: .localConfiguration(identifier: "fixture-v1"),
            currency: "USD",
            inputMicrosPerMillionTokens: 1_000_000,
            cachedInputMicrosPerMillionTokens: nil,
            outputMicrosPerMillionTokens: 2_000_000,
            audioMicrosPerSecond: nil
        )
        let cachedUsage = ProviderUsage(
            provider: .deepSeek,
            model: "fixture",
            capability: .text,
            inputTokens: 100,
            outputTokens: 0,
            audioSeconds: 0,
            attempt: 1,
            cachedInputTokens: 20
        )
        let visionUsage = ProviderUsage(
            provider: .qwen,
            model: "qwen3-vl-flash",
            capability: .vision,
            inputTokens: 1_000,
            outputTokens: 20,
            audioSeconds: 0,
            attempt: 1
        )

        XCTAssertNil(missingCachedPrice.estimate(cachedUsage))
        XCTAssertNil(PricingDescriptorCatalog.phase3Conservative.estimate(visionUsage))
    }
}
