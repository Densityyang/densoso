import XCTest
import SwiftData
@testable import Densoso

@MainActor
final class ProviderUsageLedgerTests: XCTestCase {
    func testUsageIsIdempotentAndUsesVersionedIntegerRates() async throws {
        let repository = InMemoryProviderGovernanceRepository()
        let ledger = ProviderUsageLedger(
            repository: repository,
            rateTable: ProviderRateTable(
                version: "fixture-v1",
                rates: [
                    .deepSeek: ProviderTokenRate(
                        inputMicrosPerMillionTokens: 1_000_000,
                        outputMicrosPerMillionTokens: 2_000_000,
                        currency: "USD"
                    )
                ]
            )
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

    func testMissingRateIsUnavailableRatherThanZero() async throws {
        let repository = InMemoryProviderGovernanceRepository()
        let ledger = ProviderUsageLedger(repository: repository, rateTable: .unconfigured)
        try await ledger.record(
            ProviderUsage(
                provider: .qwen,
                model: "fixture",
                capability: .text,
                inputTokens: 10,
                outputTokens: 5,
                audioSeconds: 0,
                attempt: 1
            ),
            requestID: UUID()
        )

        let summary = try await ledger.monthlySummary(provider: .qwen)
        XCTAssertNil(summary.estimatedCostMicros)
        let exceeded = try await ledger.isSoftBudgetExceeded(
            provider: .qwen,
            monthlyBudgetMicros: 1
        )
        XCTAssertFalse(exceeded)

        let qwenEstimate = ProviderRateTable.phase3Conservative.estimate(
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

    func testProductionRateTableProvidesConservativeSoftBudgetEstimates() async throws {
        let repository = InMemoryProviderGovernanceRepository()
        let ledger = ProviderUsageLedger(repository: repository)
        try await ledger.record(
            ProviderUsage(
                provider: .deepSeek,
                model: "deepseek-v4-flash",
                capability: .text,
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                audioSeconds: 0,
                attempt: 1
            ),
            requestID: UUID()
        )

        let summary = try await ledger.monthlySummary(provider: .deepSeek)
        XCTAssertEqual(summary.estimatedCostMicros, 1_760_000)
        XCTAssertEqual(summary.currency, "USD")
        let exceeded = try await ledger.isSoftBudgetExceeded(
            provider: .deepSeek,
            monthlyBudgetMicros: 2_000_000
        )
        XCTAssertFalse(exceeded)
    }

    func testSwiftDataLedgerSurvivesRepositoryRecreation() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV3.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let first = SwiftDataProviderGovernanceRepository(modelContainer: container)
        let ledger = ProviderUsageLedger(
            repository: first,
            rateTable: ProviderRateTable(
                version: "fixture-v1",
                rates: [
                    .deepSeek: ProviderTokenRate(
                        inputMicrosPerMillionTokens: 1_000_000,
                        outputMicrosPerMillionTokens: 1_000_000,
                        currency: "USD"
                    )
                ]
            )
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
    }
}
