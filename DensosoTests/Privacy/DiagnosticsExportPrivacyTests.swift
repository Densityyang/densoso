import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class DiagnosticsExportPrivacyTests: XCTestCase {
    func testExportContainsOnlyWhitelistedDiagnosticsAndIsReadOnly() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let schema = Schema(versionedSchema: DensosoSchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let privateMarker = "PRIVATE-USER-DATA-DO-NOT-EXPORT"
        let apiKeyMarker = "sk-private-api-key-do-not-export"

        let usage = ProviderUsageRecord(
            usageKey: "PRIVATE-USAGE-IDENTIFIER",
            provider: "qwen",
            model: "qwen-flash",
            capability: "text"
        )
        usage.createdAt = now.addingTimeInterval(-60)
        usage.inputTokens = 321
        usage.outputTokens = 123
        usage.audioSeconds = 0
        usage.currency = "PRIVATE-CURRENCY"
        usage.estimatedCostMicros = 987_654
        context.insert(usage)

        let outbox = HealthSyncOutboxEntry(
            operation: privateMarker,
            recordID: UUID(),
            payloadData: Data(privateMarker.utf8),
            state: "retryable"
        )
        outbox.lastError = privateMarker
        context.insert(outbox)

        context.insert(
            HealthKitImportCursor(
                stream: privateMarker,
                anchorData: Data(privateMarker.utf8),
                lastSuccessfulAt: now.addingTimeInterval(-120)
            )
        )
        context.insert(
            DailyHealthSnapshotRecord(
                dayKey: privateMarker,
                timezoneID: "PRIVATE-TIMEZONE",
                payloadData: Data("PRIVATE-HEALTH-SAMPLE-\(privateMarker)".utf8),
                snapshotHash: privateMarker,
                algorithmVersion: privateMarker
            )
        )
        let projection = DailyMetrics(
            date: now,
            bmrKcal: 1_481,
            totalIntakeKcal: 2_333,
            steps: 8_765,
            weightKg: 62.5,
            energyQuality: "complete",
            dataCoverageJSON: privateMarker,
            sourceFingerprint: privateMarker,
            requiresRecompute: true
        )
        context.insert(projection)

        context.insert(MealRecord(date: now, totalCaloriesKcal: 777, notes: privateMarker))
        context.insert(WeightRecord(sourceActionKey: privateMarker, measuredAt: now, kilograms: 62.5))
        context.insert(
            DailyCheckInRecord(
                sourceActionKey: privateMarker,
                occurredAt: now,
                energyRaw: "high",
                stressRaw: "low",
                subjectiveSleepRaw: "poor",
                note: "PRIVATE-DRAFT-NOTE-\(privateMarker)"
            )
        )
        context.insert(
            MessageRecord(
                conversationID: UUID(),
                roleRaw: "user",
                contentData: Data("PRIVATE-TRANSCRIPT-\(privateMarker)".utf8),
                ordinal: 1
            )
        )
        context.insert(
            UserPreferenceRecord(
                sourceActionKey: privateMarker,
                categoryRaw: "food",
                statement: "PRIVATE-PREFERENCE-\(privateMarker)"
            )
        )
        context.insert(
            ConsentRecord(
                consentKey: privateMarker,
                kind: "healthText",
                policyVersion: "PRIVATE-CONSENT-\(privateMarker)",
                granted: true
            )
        )
        try context.save()

        let before = try [
            context.fetch(FetchDescriptor<ProviderUsageRecord>()).count,
            context.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).count,
            context.fetch(FetchDescriptor<HealthKitImportCursor>()).count,
            context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).count,
            context.fetch(FetchDescriptor<DailyMetrics>()).count,
            context.fetch(FetchDescriptor<MealRecord>()).count,
            context.fetch(FetchDescriptor<WeightRecord>()).count,
            context.fetch(FetchDescriptor<DailyCheckInRecord>()).count,
            context.fetch(FetchDescriptor<MessageRecord>()).count,
            context.fetch(FetchDescriptor<UserPreferenceRecord>()).count,
            context.fetch(FetchDescriptor<ConsentRecord>()).count,
        ]
        let logs = ProviderLogBuffer()
        logs.record(
            ProviderLogRedactor.metadata(
                requestID: UUID(),
                provider: .qwen,
                status: 200,
                attempt: 2,
                latencyMilliseconds: 84,
                model: "qwen-flash",
                recordedAt: now
            )
        )
        logs.record(
            ProviderLogRedactor.metadata(
                requestID: UUID(),
                provider: .deepSeek,
                status: nil,
                attempt: 1,
                latencyMilliseconds: 900,
                providerCode: "\(apiKeyMarker) \(privateMarker)",
                model: "private model name \(privateMarker)",
                recordedAt: now
            )
        )

        let document = try DiagnosticsExportService(providerLogs: logs).makeDocument(
            context: context,
            mode: .cloudQwen,
            watch: DiagnosticsWatchStatus(isAvailable: true, isActivated: false, hasError: true),
            now: now,
            runtime: DiagnosticsRuntimeInfo(
                osVersion: "18.0.1",
                appVersion: "1.2.3",
                appBuild: "45",
                schemaVersion: "5.0.0"
            )
        )
        let exportService = DiagnosticsExportService(providerLogs: logs)
        let exportedURL = try exportService.exportJSON(
            context: context,
            mode: .cloudQwen,
            watch: DiagnosticsWatchStatus(isAvailable: true, isActivated: false, hasError: true),
            now: now
        )
        defer { try? FileManager.default.removeItem(at: exportedURL) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(document), encoding: .utf8)!
        let sharedJSON = try String(contentsOf: exportedURL, encoding: .utf8)
        XCTAssertTrue(exportedURL.lastPathComponent.hasSuffix(".json"))
        XCTAssertTrue(sharedJSON.contains("recentRequests"))

        XCTAssertTrue(json.contains("18.0.1"))
        XCTAssertTrue(json.contains("1.2.3"))
        XCTAssertTrue(json.contains("5.0.0"))
        XCTAssertTrue(json.contains("qwen-flash"))
        XCTAssertTrue(json.contains("84"))
        XCTAssertTrue(json.contains("321"))
        XCTAssertTrue(json.contains("123"))
        XCTAssertTrue(json.contains("retryable"))
        XCTAssertTrue(json.contains("complete"))
        XCTAssertTrue(json.contains("watch_error"))
        XCTAssertTrue(json.contains("redacted"))

        for forbidden in [
            privateMarker,
            apiKeyMarker,
            "PRIVATE-USAGE-IDENTIFIER",
            "PRIVATE-CURRENCY",
            "PRIVATE-TRANSCRIPT",
            "PRIVATE-HEALTH-SAMPLE",
            "PRIVATE-DRAFT-NOTE",
            "PRIVATE-PREFERENCE",
            "PRIVATE-CONSENT",
            "estimatedCostMicros",
            "currency",
            "requestID",
            "usageKey",
            "payloadData",
            "lastError",
            "anchorData",
            "sourceFingerprint",
            "MealRecord",
            "WeightRecord",
            "62.5",
            "1481",
            "2333",
            "8765",
            "777",
        ] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(forbidden), "Unexpected export field/value: \(forbidden)")
            XCTAssertFalse(sharedJSON.localizedCaseInsensitiveContains(forbidden), "Unexpected shared export field/value: \(forbidden)")
        }

        let after = try [
            context.fetch(FetchDescriptor<ProviderUsageRecord>()).count,
            context.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).count,
            context.fetch(FetchDescriptor<HealthKitImportCursor>()).count,
            context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).count,
            context.fetch(FetchDescriptor<DailyMetrics>()).count,
            context.fetch(FetchDescriptor<MealRecord>()).count,
            context.fetch(FetchDescriptor<WeightRecord>()).count,
            context.fetch(FetchDescriptor<DailyCheckInRecord>()).count,
            context.fetch(FetchDescriptor<MessageRecord>()).count,
            context.fetch(FetchDescriptor<UserPreferenceRecord>()).count,
            context.fetch(FetchDescriptor<ConsentRecord>()).count,
        ]
        XCTAssertEqual(before, after)
    }

    func testProviderLogBufferIsBoundedAndRedactsModelAndErrorCode() {
        let buffer = ProviderLogBuffer(capacity: 2)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<3 {
            buffer.record(
                ProviderLogRedactor.metadata(
                    requestID: UUID(),
                    provider: .qwen,
                    status: 200,
                    attempt: 1,
                    latencyMilliseconds: index,
                    providerCode: "secret-provider-response-\(index)",
                    model: "private model with user content",
                    recordedAt: date.addingTimeInterval(Double(index))
                )
            )
        }

        let records = buffer.recent(since: date, limit: 10)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.model, "redacted")
        XCTAssertEqual(records.first?.providerCode, "redacted")
        XCTAssertEqual(records.map(\.latencyMilliseconds), [1, 2])
    }

    func testProviderErrorsExportOnlyAllowlistedCodes() {
        XCTAssertEqual(
            ProviderLogRedactor.errorCode(for: ProviderError.server(status: 503)),
            "server_error"
        )
        XCTAssertEqual(
            ProviderLogRedactor.errorCode(for: ProviderError.schemaViolation(path: "PRIVATE-ERROR-PATH")),
            "schema_violation"
        )
        XCTAssertEqual(
            ProviderLogRedactor.errorCode(for: ProviderError.network(code: 45_678)),
            "network_error"
        )
    }
}
