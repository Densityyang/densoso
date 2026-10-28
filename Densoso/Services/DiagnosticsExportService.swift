import Foundation
import SwiftData
import DensosoDomain

struct DiagnosticsRuntimeInfo: Codable, Equatable, Sendable {
    let osVersion: String
    let appVersion: String
    let appBuild: String
    let schemaVersion: String

    static func current(bundle: Bundle = .main, schemaVersion: String? = nil) -> Self {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return Self(
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            appVersion: safeBuildValue(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
            appBuild: safeBuildValue(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
            schemaVersion: schemaVersion ?? currentSchemaVersion
        )
    }

    private static var currentSchemaVersion: String {
        // Keep diagnostics aligned with the app's active persistence schema.
        let version = DensosoSchemaV12.versionIdentifier
        return "\(version.major).\(version.minor).\(version.patch)"
    }

    private static func safeBuildValue(_ value: String?) -> String {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= 32,
              value.unicodeScalars.allSatisfy(\.isASCII),
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else {
            return "unknown"
        }
        return value
    }
}

struct DiagnosticsProviderSelection: Codable, Equatable, Sendable {
    let provider: String
    let model: String?

    init(mode: IntelligenceMode) {
        switch mode {
        case .localOnly:
            provider = "local"
            model = nil
        case .cloudDeepSeek:
            provider = "deepseek"
            model = "deepseek-flash"
        case .cloudQwen:
            provider = "qwen"
            model = "qwen-flash"
        }
    }
}

struct DiagnosticsProviderRequest: Codable, Equatable, Sendable {
    let provider: String
    let model: String
    let status: Int?
    let latencyMilliseconds: Int
    let errorCode: String?
    let recordedAt: Date
}

struct DiagnosticsUsageGroup: Codable, Equatable, Sendable {
    let provider: String
    let model: String
    let capability: String
    let requestCount: Int
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let imageCount: Int
    let audioSeconds: Double
    let averageLatencyMilliseconds: Int?
}

struct DiagnosticsUsageStatus: Codable, Equatable, Sendable {
    let windowStart: Date
    let requestCount: Int
    let hasMore: Bool
    let groups: [DiagnosticsUsageGroup]
}

struct DiagnosticsSyncStatus: Codable, Equatable, Sendable {
    let sampledOutboxEntries: Int
    let hasMoreOutboxEntries: Bool
    let outboxStates: [String: Int]
    let importCursorCount: Int
    let latestSuccessfulImportAt: Date?
    let importCursors: [DiagnosticsImportCursorStatus]
}

struct DiagnosticsImportCursorStatus: Codable, Equatable, Sendable {
    let stream: String
    let lastSuccessfulAt: Date?
    let lookbackStart: Date?
}

struct DiagnosticsProjectionStatus: Codable, Equatable, Sendable {
    let sampledDays: Int
    let hasMoreDays: Bool
    let requiresRecomputeCount: Int
    let qualityCounts: [String: Int]
}

struct DiagnosticsWatchStatus: Codable, Equatable, Sendable {
    let isAvailable: Bool
    let isActivated: Bool
    let hasError: Bool
    let errorCode: String?

    init(isAvailable: Bool, isActivated: Bool, hasError: Bool) {
        self.isAvailable = isAvailable
        self.isActivated = isActivated
        self.hasError = hasError
        self.errorCode = hasError ? "watch_error" : nil
    }
}

struct DiagnosticsDailyLoopStatus: Codable, Equatable, Sendable {
    let lastGeneratedAt: Date?
    let nextRefreshEarliestAt: Date?

    static let unavailable = Self(lastGeneratedAt: nil, nextRefreshEarliestAt: nil)
}

struct DiagnosticsProviderPolicyRevision: Codable, Equatable, Sendable {
    let provider: String
    let revision: Int?
}

enum DiagnosticsCoverageStatus: String, Codable, Equatable, Sendable {
    case known
    case unknown
}

struct DiagnosticsMetricCoverage: Codable, Equatable, Sendable {
    let metric: String
    let expectedCalendarDays: Int
    let coverageStatus: DiagnosticsCoverageStatus
    let validCalendarDays: Int?
    let missingCalendarDays: Int?
    let authorizationLimited: Bool?
    let dataAvailabilityLimited: Bool?
}

struct DiagnosticsHealthCoverage: Codable, Equatable, Sendable {
    let analysisWindowDays: Int
    let metrics: [DiagnosticsMetricCoverage]
}

/// This is an explicit whitelist. Never add user records, payloads, messages, permission grants,
/// credentials, endpoints, workspace identifiers, or consent details to this document.
struct DiagnosticsExportDocument: Codable, Equatable, Sendable {
    let formatVersion: Int
    let exportedAt: Date
    let runtime: DiagnosticsRuntimeInfo
    let selectedProvider: DiagnosticsProviderSelection
    let recentRequests: [DiagnosticsProviderRequest]
    let usage: DiagnosticsUsageStatus
    let sync: DiagnosticsSyncStatus
    let projections: DiagnosticsProjectionStatus
    let watch: DiagnosticsWatchStatus
    let dailyLoop: DiagnosticsDailyLoopStatus
    let cloudPolicyRevisions: [DiagnosticsProviderPolicyRevision]
    let healthCoverage: DiagnosticsHealthCoverage
}

@MainActor
final class DiagnosticsExportService {
    private let providerLogs: ProviderLogBuffer
    private let fileManager: FileManager

    init(providerLogs: ProviderLogBuffer, fileManager: FileManager = .default) {
        self.providerLogs = providerLogs
        self.fileManager = fileManager
    }

    func makeDocument(
        context: ModelContext,
        mode: IntelligenceMode,
        watch: DiagnosticsWatchStatus,
        dailyLoop: DiagnosticsDailyLoopStatus = .unavailable,
        now: Date = Date(),
        runtime: DiagnosticsRuntimeInfo = .current()
    ) throws -> DiagnosticsExportDocument {
        let windowStart = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let requestEntries = providerLogs.recent(since: windowStart, limit: 50)
        let recentRequests = requestEntries.map { entry in
            DiagnosticsProviderRequest(
                provider: Self.safeProvider(entry.provider.rawValue),
                model: ProviderLogRedactor.safeModel(entry.model),
                status: entry.status.flatMap { (100...599).contains($0) ? $0 : nil },
                latencyMilliseconds: min(max(entry.latencyMilliseconds, 0), 3_600_000),
                errorCode: entry.providerCode.map(ProviderLogRedactor.safeProviderCode),
                recordedAt: entry.recordedAt
            )
        }

        let usage = try makeUsageStatus(context: context, windowStart: windowStart, now: now)
        let sync = try makeSyncStatus(context: context)
        let projections = try makeProjectionStatus(context: context, windowStart: windowStart, now: now)
        let cloudPolicyRevisions = try makeCloudPolicyRevisions(context: context)
        let healthCoverage = try makeHealthCoverage(context: context, asOf: now)

        return DiagnosticsExportDocument(
            formatVersion: 1,
            exportedAt: now,
            runtime: runtime,
            selectedProvider: DiagnosticsProviderSelection(mode: mode),
            recentRequests: recentRequests,
            usage: usage,
            sync: sync,
            projections: projections,
            watch: watch,
            dailyLoop: dailyLoop,
            cloudPolicyRevisions: cloudPolicyRevisions,
            healthCoverage: healthCoverage
        )
    }

    func exportJSON(
        context: ModelContext,
        mode: IntelligenceMode,
        watch: DiagnosticsWatchStatus,
        dailyLoop: DiagnosticsDailyLoopStatus = .unavailable,
        now: Date = Date()
    ) throws -> URL {
        let document = try makeDocument(
            context: context,
            mode: mode,
            watch: watch,
            dailyLoop: dailyLoop,
            now: now
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("densoso-diagnostics-\(UUID().uuidString.lowercased())")
            .appendingPathExtension("json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    private func makeUsageStatus(
        context: ModelContext,
        windowStart: Date,
        now: Date
    ) throws -> DiagnosticsUsageStatus {
        let predicate = #Predicate<ProviderUsageRecord> {
            $0.createdAt >= windowStart && $0.createdAt <= now
        }
        var descriptor = FetchDescriptor<ProviderUsageRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\ProviderUsageRecord.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 5_001
        let fetchedRecords = try context.fetch(descriptor)
        let records = Array(fetchedRecords.prefix(5_000))
        var grouped: [String: UsageAccumulator] = [:]
        for record in records {
            let provider = Self.safeProvider(record.provider)
            let model = ProviderLogRedactor.safeModel(record.model)
            let capability = Self.safeCapability(record.capability)
            let key = "\(provider)|\(model)|\(capability)"
            var group = grouped[key] ?? UsageAccumulator(
                provider: provider,
                model: model,
                capability: capability
            )
            group.requestCount = Self.saturatingAdd(group.requestCount, 1)
            group.inputTokens = Self.saturatingAdd(group.inputTokens, max(record.inputTokens, 0))
            group.cachedInputTokens = Self.saturatingAdd(group.cachedInputTokens, max(record.cachedInputTokens, 0))
            group.outputTokens = Self.saturatingAdd(group.outputTokens, max(record.outputTokens, 0))
            group.reasoningTokens = Self.saturatingAdd(group.reasoningTokens, max(record.reasoningTokens, 0))
            group.imageCount = Self.saturatingAdd(group.imageCount, max(record.imageCount, 0))
            if record.audioSeconds.isFinite, record.audioSeconds > 0 {
                group.audioSeconds = min(group.audioSeconds + record.audioSeconds, 1_000_000_000)
            }
            if let latency = record.latencyMilliseconds, latency >= 0 {
                group.latencyMillisecondsTotal = Self.saturatingAdd(group.latencyMillisecondsTotal, latency)
                group.latencySampleCount = Self.saturatingAdd(group.latencySampleCount, 1)
            }
            grouped[key] = group
        }
        let groups = grouped.values
            .map(\.exportValue)
            .sorted {
                if $0.provider != $1.provider { return $0.provider < $1.provider }
                if $0.model != $1.model { return $0.model < $1.model }
                return $0.capability < $1.capability
            }
        return DiagnosticsUsageStatus(
            windowStart: windowStart,
            requestCount: records.count,
            hasMore: fetchedRecords.count > 5_000,
            groups: groups
        )
    }

    private func makeSyncStatus(context: ModelContext) throws -> DiagnosticsSyncStatus {
        var outboxDescriptor = FetchDescriptor<HealthSyncOutboxEntry>(
            sortBy: [SortDescriptor(\HealthSyncOutboxEntry.createdAt, order: .reverse)]
        )
        outboxDescriptor.fetchLimit = 5_001
        let fetchedOutbox = try context.fetch(outboxDescriptor)
        let outbox = Array(fetchedOutbox.prefix(5_000))
        var states = ["pending": 0, "sending": 0, "succeeded": 0, "retryable": 0, "terminal": 0, "unknown": 0]
        for entry in outbox {
            let state = states[entry.state] == nil ? "unknown" : entry.state
            states[state, default: 0] += 1
        }

        let cursors = try context.fetch(FetchDescriptor<HealthKitImportCursor>())
        let importCursors = cursors
            .sorted { $0.stream < $1.stream }
            .prefix(64)
            .map { cursor in
                DiagnosticsImportCursorStatus(
                    stream: Self.safeHealthStream(cursor.stream),
                    lastSuccessfulAt: cursor.lastSuccessfulAt,
                    lookbackStart: cursor.lookbackStart
                )
            }
        return DiagnosticsSyncStatus(
            sampledOutboxEntries: outbox.count,
            hasMoreOutboxEntries: fetchedOutbox.count > 5_000,
            outboxStates: states,
            importCursorCount: cursors.count,
            latestSuccessfulImportAt: cursors.compactMap(\.lastSuccessfulAt).max(),
            importCursors: importCursors
        )
    }

    private func makeProjectionStatus(
        context: ModelContext,
        windowStart: Date,
        now: Date
    ) throws -> DiagnosticsProjectionStatus {
        let predicate = #Predicate<DailyMetrics> {
            $0.date >= windowStart && $0.date <= now
        }
        var descriptor = FetchDescriptor<DailyMetrics>(
            predicate: predicate,
            sortBy: [SortDescriptor(\DailyMetrics.date, order: .reverse)]
        )
        descriptor.fetchLimit = 501
        let fetchedMetrics = try context.fetch(descriptor)
        let metrics = Array(fetchedMetrics.prefix(500))
        var qualities = [
            "complete": 0,
            "partial": 0,
            "estimated": 0,
            "unavailable": 0,
            "legacy": 0,
            "unknown": 0,
        ]
        for metric in metrics {
            let quality = qualities[metric.energyQuality] == nil ? "unknown" : metric.energyQuality
            qualities[quality, default: 0] += 1
        }
        return DiagnosticsProjectionStatus(
            sampledDays: metrics.count,
            hasMoreDays: fetchedMetrics.count > 500,
            requiresRecomputeCount: metrics.filter(\.requiresRecompute).count,
            qualityCounts: qualities
        )
    }

    private func makeCloudPolicyRevisions(context: ModelContext) throws -> [DiagnosticsProviderPolicyRevision] {
        // Export only the provider and revision; policy state and contents stay local.
        var descriptor = FetchDescriptor<CloudHealthContextPolicyRecord>()
        descriptor.fetchLimit = 64
        let records = try context.fetch(descriptor)
        var latestRevisionByProvider: [ProviderID: Int] = [:]
        for record in records {
            guard let provider = ProviderID(rawValue: record.providerRaw) else { continue }
            let revision = max(record.revision, 0)
            latestRevisionByProvider[provider] = max(latestRevisionByProvider[provider] ?? 0, revision)
        }
        return ProviderID.allCases.map { provider in
            DiagnosticsProviderPolicyRevision(
                provider: Self.safeProvider(provider.rawValue),
                revision: latestRevisionByProvider[provider]
            )
        }
    }

    private func makeHealthCoverage(context: ModelContext, asOf date: Date) throws -> DiagnosticsHealthCoverage {
        // The exported shape intentionally drops exact dates and all health values.
        let calendar = Calendar.current
        let days = try HealthIntelligenceReadModel(calendar: calendar).loadDays(through: date, in: context)
        let summary = HealthIntelligenceEngine(calendar: calendar).makeContextSummary(
            days: days,
            asOf: date,
            goals: nil,
            recommendations: []
        )
        let metrics = Self.diagnosticsCoverageMetricKeys.compactMap { metric in
            guard let coverage = summary.analysisWindowCoverage[metric] else { return nil }
            return DiagnosticsMetricCoverage(
                metric: metric,
                expectedCalendarDays: coverage.expectedCalendarDays,
                coverageStatus: coverage.validCalendarDays != nil && coverage.missingCalendarDays != nil
                    ? .known
                    : .unknown,
                validCalendarDays: coverage.validCalendarDays,
                missingCalendarDays: coverage.missingCalendarDays,
                authorizationLimited: coverage.authorizationLimited,
                dataAvailabilityLimited: coverage.dataAvailabilityLimited
            )
        }
        return DiagnosticsHealthCoverage(
            analysisWindowDays: HealthDataWindowContract.analysisLookbackDays,
            metrics: metrics
        )
    }

    private static let diagnosticsCoverageMetricKeys = [
        "activeEnergy",
        "bodyMass",
        "dailyDeficitKcal",
        "energyIntake",
        "proteinGrams",
        "sleep",
        "steps",
    ]

    private static func safeProvider(_ raw: String) -> String {
        switch raw.lowercased() {
        case "deepseek": "deepseek"
        case "qwen": "qwen"
        case "local": "local"
        default: "other"
        }
    }

    private static func safeCapability(_ raw: String) -> String {
        switch raw.lowercased() {
        case "text", "toolcalling", "structuredoutput", "vision", "speech", "reasoning", "streaming":
            raw.lowercased()
        default: "other"
        }
    }

    private static func safeHealthStream(_ raw: String) -> String {
        if raw == "workouts" { return "workouts" }
        return HealthMetricID(rawValue: raw)?.rawValue ?? "other"
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }
}

private struct UsageAccumulator {
    let provider: String
    let model: String
    let capability: String
    var requestCount = 0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var imageCount = 0
    var audioSeconds = 0.0
    var latencyMillisecondsTotal = 0
    var latencySampleCount = 0

    var exportValue: DiagnosticsUsageGroup {
        DiagnosticsUsageGroup(
            provider: provider,
            model: model,
            capability: capability,
            requestCount: requestCount,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            imageCount: imageCount,
            audioSeconds: audioSeconds,
            averageLatencyMilliseconds: latencySampleCount > 0
                ? latencyMillisecondsTotal / latencySampleCount
                : nil
        )
    }
}
