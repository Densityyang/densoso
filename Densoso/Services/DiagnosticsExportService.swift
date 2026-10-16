import Foundation
import SwiftData

struct DiagnosticsRuntimeInfo: Codable, Equatable, Sendable {
    let osVersion: String
    let appVersion: String
    let appBuild: String
    let schemaVersion: String

    static func current(bundle: Bundle = .main, schemaVersion: String = "5.0.0") -> Self {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return Self(
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            appVersion: safeBuildValue(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
            appBuild: safeBuildValue(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
            schemaVersion: schemaVersion
        )
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
    let outputTokens: Int
    let audioSeconds: Double
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

/// This is an explicit whitelist. Never add user records, payloads, messages, permissions,
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

        return DiagnosticsExportDocument(
            formatVersion: 1,
            exportedAt: now,
            runtime: runtime,
            selectedProvider: DiagnosticsProviderSelection(mode: mode),
            recentRequests: recentRequests,
            usage: usage,
            sync: sync,
            projections: projections,
            watch: watch
        )
    }

    func exportJSON(
        context: ModelContext,
        mode: IntelligenceMode,
        watch: DiagnosticsWatchStatus,
        now: Date = Date()
    ) throws -> URL {
        let document = try makeDocument(context: context, mode: mode, watch: watch, now: now)
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
            group.outputTokens = Self.saturatingAdd(group.outputTokens, max(record.outputTokens, 0))
            if record.audioSeconds.isFinite, record.audioSeconds > 0 {
                group.audioSeconds = min(group.audioSeconds + record.audioSeconds, 1_000_000_000)
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
        return DiagnosticsSyncStatus(
            sampledOutboxEntries: outbox.count,
            hasMoreOutboxEntries: fetchedOutbox.count > 5_000,
            outboxStates: states,
            importCursorCount: cursors.count,
            latestSuccessfulImportAt: cursors.compactMap(\.lastSuccessfulAt).max()
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
    var outputTokens = 0
    var audioSeconds = 0.0

    var exportValue: DiagnosticsUsageGroup {
        DiagnosticsUsageGroup(
            provider: provider,
            model: model,
            capability: capability,
            requestCount: requestCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            audioSeconds: audioSeconds
        )
    }
}
