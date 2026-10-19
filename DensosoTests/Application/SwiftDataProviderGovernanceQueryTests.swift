import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class SwiftDataProviderGovernanceQueryTests: XCTestCase {
    func testConsentAndUsageDedupResolveExactKeysWithoutDuplicatingRows() async throws {
        let container = try makeContainer()
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)

        let initiallyGranted = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthText)
        XCTAssertFalse(initiallyGranted)
        try await repository.setConsent(
            provider: .deepSeek,
            dataClass: .healthText,
            granted: true,
            policyVersion: "fixture-v1"
        )
        let granted = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthText)
        XCTAssertTrue(granted)

        let usage = ProviderUsage(
            provider: .deepSeek,
            model: "fixture",
            capability: .text,
            inputTokens: 40,
            outputTokens: 5,
            audioSeconds: 0,
            attempt: 1
        )
        try await repository.recordUsage(
            usage: usage,
            usageKey: "exact-usage-key",
            estimatedCostMicros: 12,
            currency: "USD",
            rateVersion: "fixture-v1"
        )
        try await repository.recordUsage(
            usage: ProviderUsage(
                provider: .deepSeek,
                model: "fixture",
                capability: .text,
                inputTokens: 999,
                outputTokens: 999,
                audioSeconds: 0,
                attempt: 1
            ),
            usageKey: "exact-usage-key",
            estimatedCostMicros: 999,
            currency: "USD",
            rateVersion: "fixture-v2"
        )

        let context = ModelContext(container)
        let consents = try context.fetch(FetchDescriptor<ConsentRecord>())
        let records = try context.fetch(FetchDescriptor<ProviderUsageRecord>())
        XCTAssertEqual(consents.count, 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.inputTokens, 40)
        XCTAssertEqual(records.first?.estimatedCostMicros, 12)
        XCTAssertEqual(records.first?.rateVersion, "fixture-v1")
    }

    func testMonthlyUsageQueriesProviderAndHalfOpenDateWindowAndKeepsUnknownCost() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let monthStart = Date(timeIntervalSince1970: 1_800_000_000)
        let monthEnd = monthStart.addingTimeInterval(30 * 86_400)
        let insideEnd = monthEnd.addingTimeInterval(-1)

        [
            usageRecord(key: "start", provider: .deepSeek, createdAt: monthStart, input: 10, output: 1, cost: 100),
            usageRecord(key: "inside-end", provider: .deepSeek, createdAt: insideEnd, input: 20, output: 2, cost: 200),
            usageRecord(key: "before", provider: .deepSeek, createdAt: monthStart.addingTimeInterval(-1), input: 500, output: 50, cost: 500),
            usageRecord(key: "end-exclusive", provider: .deepSeek, createdAt: monthEnd, input: 600, output: 60, cost: 600),
            usageRecord(key: "other-provider", provider: .qwen, createdAt: monthStart, input: 700, output: 70, cost: 700),
        ].forEach(context.insert)
        try context.save()

        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        let pricedSummary = try await repository.monthlyUsage(
            provider: .deepSeek,
            monthStart: monthStart,
            monthEnd: monthEnd
        )
        XCTAssertEqual(pricedSummary.inputTokens, 30)
        XCTAssertEqual(pricedSummary.outputTokens, 3)
        XCTAssertEqual(pricedSummary.estimatedCostMicros, 300)
        XCTAssertEqual(pricedSummary.currency, "USD")

        context.insert(usageRecord(
            key: "unknown-price",
            provider: .deepSeek,
            createdAt: monthStart.addingTimeInterval(10),
            input: 5,
            output: 1,
            cost: -1,
            currency: "unavailable"
        ))
        try context.save()
        let summaryWithUnknownPrice = try await repository.monthlyUsage(
            provider: .deepSeek,
            monthStart: monthStart,
            monthEnd: monthEnd
        )
        XCTAssertEqual(summaryWithUnknownPrice.inputTokens, 35)
        XCTAssertNil(summaryWithUnknownPrice.estimatedCostMicros)
        XCTAssertNil(summaryWithUnknownPrice.currency)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func usageRecord(
        key: String,
        provider: ProviderID,
        createdAt: Date,
        input: Int,
        output: Int,
        cost: Int64,
        currency: String = "USD"
    ) -> ProviderUsageRecord {
        let record = ProviderUsageRecord(
            usageKey: key,
            provider: provider.rawValue,
            model: "fixture",
            capability: ProviderCapability.text.rawValue
        )
        record.createdAt = createdAt
        record.inputTokens = input
        record.outputTokens = output
        record.estimatedCostMicros = cost
        record.currency = currency
        record.rateVersion = cost < 0 ? "unknown" : "fixture-v1"
        return record
    }
}
