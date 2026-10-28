import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class DiagnosticsExportPrivacyTests: XCTestCase {
    func testExportContainsOnlyWhitelistedDiagnosticsAndIsReadOnly() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let schema = Schema(versionedSchema: DensosoSchemaV12.self)
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
        usage.cachedInputTokens = 21
        usage.outputTokens = 123
        usage.reasoningTokens = 13
        usage.imageCount = 2
        usage.requestID = UUID()
        usage.attempt = 1
        usage.latencyMilliseconds = 84
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
        let privatePolicyHash = "PRIVATE-POLICY-HASH-DO-NOT-EXPORT"
        let privatePolicyClasses = "PRIVATE-POLICY-CLASSES-DO-NOT-EXPORT"
        context.insert(
            CloudHealthContextPolicyRecord(
                policyKey: "deepSeek",
                schemaVersion: 1,
                policyID: UUID(),
                providerRaw: "deepSeek",
                revision: 4,
                stateRaw: "confirmed",
                allowedClassesRaw: privatePolicyClasses,
                createdAt: now.addingTimeInterval(-300),
                updatedAt: now.addingTimeInterval(-120),
                confirmedAt: now.addingTimeInterval(-120),
                policyHash: privatePolicyHash,
                changeSourceRaw: "userConfirmed"
            )
        )
        context.insert(
            CloudHealthContextPolicyRecord(
                policyKey: "qwen",
                schemaVersion: 1,
                policyID: UUID(),
                providerRaw: "qwen",
                revision: 9,
                stateRaw: "confirmed",
                allowedClassesRaw: privatePolicyClasses,
                createdAt: now.addingTimeInterval(-300),
                updatedAt: now.addingTimeInterval(-120),
                confirmedAt: now.addingTimeInterval(-120),
                policyHash: privatePolicyHash,
                changeSourceRaw: "userConfirmed"
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
            context.fetch(FetchDescriptor<CloudHealthContextPolicyRecord>()).count,
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

        let dailyLoopStatus = DiagnosticsDailyLoopStatus(
            lastGeneratedAt: now.addingTimeInterval(-120),
            nextRefreshEarliestAt: now.addingTimeInterval(3_600)
        )
        let document = try DiagnosticsExportService(providerLogs: logs).makeDocument(
            context: context,
            mode: .cloudQwen,
            watch: DiagnosticsWatchStatus(isAvailable: true, isActivated: false, hasError: true),
            dailyLoop: dailyLoopStatus,
            now: now,
            runtime: DiagnosticsRuntimeInfo(
                osVersion: "18.0.1",
                appVersion: "1.2.3",
                appBuild: "45",
                schemaVersion: "12.0.0"
            )
        )
        let exportService = DiagnosticsExportService(providerLogs: logs)
        let exportedURL = try exportService.exportJSON(
            context: context,
            mode: .cloudQwen,
            watch: DiagnosticsWatchStatus(isAvailable: true, isActivated: false, hasError: true),
            dailyLoop: dailyLoopStatus,
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
        XCTAssertTrue(json.contains("12.0.0"))
        XCTAssertTrue(sharedJSON.contains("12.0.0"))
        XCTAssertTrue(json.contains("qwen-flash"))
        XCTAssertTrue(json.contains("84"))
        XCTAssertTrue(json.contains("321"))
        XCTAssertTrue(json.contains("123"))
        XCTAssertTrue(json.contains("21"))
        XCTAssertTrue(json.contains("13"))
        let usageGroup = try XCTUnwrap(document.usage.groups.first)
        XCTAssertEqual(usageGroup.imageCount, 2)
        XCTAssertEqual(usageGroup.averageLatencyMilliseconds, 84)
        XCTAssertTrue(json.contains("retryable"))
        XCTAssertTrue(json.contains("complete"))
        XCTAssertTrue(json.contains("watch_error"))
        XCTAssertEqual(document.dailyLoop, dailyLoopStatus)
        XCTAssertEqual(
            document.cloudPolicyRevisions,
            [
                DiagnosticsProviderPolicyRevision(provider: "deepseek", revision: 4),
                DiagnosticsProviderPolicyRevision(provider: "qwen", revision: 9),
            ]
        )
        XCTAssertEqual(document.healthCoverage.analysisWindowDays, 42)
        XCTAssertEqual(
            document.healthCoverage.metrics.map(\.metric),
            ["activeEnergy", "bodyMass", "dailyDeficitKcal", "energyIntake", "proteinGrams", "sleep", "steps"]
        )
        XCTAssertTrue(document.healthCoverage.metrics.allSatisfy { $0.expectedCalendarDays == 42 })
        let sleepCoverage = try XCTUnwrap(document.healthCoverage.metrics.first { $0.metric == "sleep" })
        XCTAssertEqual(sleepCoverage.coverageStatus, .unknown)
        XCTAssertNil(sleepCoverage.validCalendarDays)
        XCTAssertNil(sleepCoverage.missingCalendarDays)
        XCTAssertNil(sleepCoverage.authorizationLimited)
        XCTAssertNil(sleepCoverage.dataAvailabilityLimited)
        XCTAssertTrue(json.contains("healthCoverage"))
        XCTAssertFalse(json.contains("targetWindowStart"))
        XCTAssertFalse(json.contains("actualEarliestDate"))
        XCTAssertEqual(document.sync.importCursorCount, 1)
        XCTAssertEqual(
            document.sync.importCursors,
            [DiagnosticsImportCursorStatus(
                stream: "other",
                lastSuccessfulAt: now.addingTimeInterval(-120),
                lookbackStart: nil
            )]
        )
        XCTAssertTrue(json.contains("dailyLoop"))
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
            privatePolicyHash,
            privatePolicyClasses,
            "policyHash",
            "allowedClassesRaw",
            "confirmedAt",
            "changeSourceRaw",
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
            context.fetch(FetchDescriptor<CloudHealthContextPolicyRecord>()).count,
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
            "ProviderUnavailable"
        )
        XCTAssertEqual(
            ProviderLogRedactor.errorCode(for: ProviderError.schemaViolation(path: "PRIVATE-ERROR-PATH")),
            "ToolArgumentsInvalid"
        )
        XCTAssertEqual(
            ProviderLogRedactor.errorCode(for: ProviderError.network(code: 45_678)),
            "NetworkUnavailable"
        )
        XCTAssertEqual(ProviderLogRedactor.safeProviderCode("server_error"), "server_error")
        XCTAssertEqual(ProviderLogRedactor.safeProviderCode("ProviderUnavailable"), "ProviderUnavailable")
        XCTAssertEqual(
            ProviderError.schemaViolation(path: "PRIVATE-ERROR-PATH").errorDescription,
            "请求参数暂时无法处理，请重试。"
        )
        XCTAssertEqual(
            ProviderError.requestRejected(status: 400).sharedErrorDescriptor.code,
            .providerUnavailable
        )
        XCTAssertEqual(
            ProviderError.requestRejected(status: 400).sharedErrorDescriptor.reason,
            .requestRejected
        )
        XCTAssertEqual(
            ProviderError.contentRejected.sharedErrorDescriptor.code,
            .providerUnavailable
        )
    }
}
