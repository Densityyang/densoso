import Foundation
import SwiftData

@ModelActor
actor SwiftDataProviderGovernanceRepository: ProviderGovernanceRepository {
    static let monthlyUsageBatchSize = 64

    private struct UsageCursor {
        let createdAt: Date
        let usageKey: String
    }

    func isConsentGranted(provider: ProviderID, dataClass: ProviderDataClass) throws -> Bool {
        let key = consentKey(provider: provider, dataClass: dataClass)
        var descriptor = FetchDescriptor<ConsentRecord>(
            predicate: #Predicate { $0.consentKey == key }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.granted == true
    }

    func setConsent(
        provider: ProviderID,
        dataClass: ProviderDataClass,
        granted: Bool,
        policyVersion: String
    ) throws {
        let key = consentKey(provider: provider, dataClass: dataClass)
        var descriptor = FetchDescriptor<ConsentRecord>(
            predicate: #Predicate { $0.consentKey == key }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            record.granted = granted
            record.policyVersion = policyVersion
            record.decidedAt = Date()
            record.revokedAt = granted ? nil : Date()
        } else {
            modelContext.insert(
                ConsentRecord(
                    consentKey: key,
                    kind: dataClass.rawValue,
                    policyVersion: policyVersion,
                    granted: granted,
                    revokedAt: granted ? nil : Date()
                )
            )
        }
        try modelContext.save()
    }

    func recordUsage(
        usage: ProviderUsage,
        usageKey: String,
        requestID: UUID,
        estimatedCostMicros: Int64?,
        currency: String?,
        rateVersion: String
    ) throws -> Bool {
        guard usage.requestID == nil || usage.requestID == requestID else {
            throw ProviderUsageLedgerError.requestIdentityMismatch
        }
        var descriptor = FetchDescriptor<ProviderUsageRecord>(
            predicate: #Predicate { $0.usageKey == usageKey }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            guard existing.requestID == nil || existing.requestID == requestID,
                  existing.attempt == 0 || existing.attempt == usage.attempt else {
                throw ProviderUsageLedgerError.requestIdentityMismatch
            }
            return existing.estimatedCostMicros >= 0
                && existing.rateVersion != "unknown"
                && existing.currency != "unavailable"
                && existing.currency == (currency ?? "unavailable")
                && existing.rateVersion == rateVersion
        }
        let record = ProviderUsageRecord(
            usageKey: usageKey,
            provider: usage.provider.rawValue,
            model: usage.model,
            capability: usage.capability.rawValue
        )
        record.requestID = requestID
        record.attempt = usage.attempt
        record.inputTokens = max(usage.inputTokens, 0)
        record.cachedInputTokens = max(usage.cachedInputTokens, 0)
        record.outputTokens = max(usage.outputTokens, 0)
        record.reasoningTokens = max(usage.reasoningTokens, 0)
        record.imageCount = max(usage.imageCount, 0)
        record.audioSeconds = max(usage.audioSeconds, 0)
        record.latencyMilliseconds = usage.latencyMilliseconds.map { max($0, 0) }
        record.estimatedCostMicros = estimatedCostMicros ?? -1
        record.currency = currency ?? "unavailable"
        record.rateVersion = rateVersion
        modelContext.insert(record)
        try modelContext.save()
        return record.estimatedCostMicros >= 0
    }

    func monthlyUsage(
        provider: ProviderID,
        monthStart: Date,
        monthEnd: Date
    ) throws -> ProviderUsageSummary {
        let providerRawValue = provider.rawValue
        let sortBy = [
            SortDescriptor(\ProviderUsageRecord.createdAt),
            SortDescriptor(\ProviderUsageRecord.usageKey),
        ]
        var cursor: UsageCursor?
        var recordCount = 0
        var pricedCount = 0
        var inputTokens = 0
        var cachedInputTokens = 0
        var outputTokens = 0
        var reasoningTokens = 0
        var imageCount = 0
        var audioSeconds = 0.0
        var latencyMillisecondsTotal = 0
        var latencySampleCount = 0
        var pricedCost: Int64 = 0
        var currencies = Set<String>()
        while true {
            let predicate: Predicate<ProviderUsageRecord>
            if let cursor {
                let cursorCreatedAt = cursor.createdAt
                let cursorUsageKey = cursor.usageKey
                predicate = #Predicate<ProviderUsageRecord> { record in
                    record.provider == providerRawValue
                        && record.createdAt >= monthStart
                        && record.createdAt < monthEnd
                        && (record.createdAt > cursorCreatedAt
                            || (record.createdAt == cursorCreatedAt && record.usageKey > cursorUsageKey))
                }
            } else {
                predicate = #Predicate<ProviderUsageRecord> { record in
                    record.provider == providerRawValue
                        && record.createdAt >= monthStart
                        && record.createdAt < monthEnd
                }
            }
            var descriptor = FetchDescriptor<ProviderUsageRecord>(predicate: predicate, sortBy: sortBy)
            descriptor.fetchLimit = Self.monthlyUsageBatchSize
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }

            for record in batch {
                cursor = UsageCursor(createdAt: record.createdAt, usageKey: record.usageKey)
                recordCount += 1
                inputTokens += record.inputTokens
                cachedInputTokens += record.cachedInputTokens
                outputTokens += record.outputTokens
                reasoningTokens += record.reasoningTokens
                imageCount = Self.saturatingAdd(imageCount, record.imageCount)
                audioSeconds += record.audioSeconds
                if let latency = record.latencyMilliseconds, latency >= 0 {
                    latencyMillisecondsTotal = Self.saturatingAdd(latencyMillisecondsTotal, latency)
                    latencySampleCount += 1
                }
                if record.estimatedCostMicros >= 0,
                   record.rateVersion != "unknown",
                   record.currency != "unavailable" {
                    pricedCount += 1
                    currencies.insert(record.currency)
                    pricedCost += record.estimatedCostMicros
                }
            }
        }
        let cost: Int64? = pricedCount == recordCount && currencies.count <= 1 ? pricedCost : nil
        return ProviderUsageSummary(
            provider: provider,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            imageCount: imageCount,
            audioSeconds: audioSeconds,
            averageLatencyMilliseconds: latencySampleCount > 0
                ? latencyMillisecondsTotal / latencySampleCount
                : nil,
            estimatedCostMicros: cost,
            currency: cost == nil ? nil : currencies.first
        )
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }

    private func consentKey(provider: ProviderID, dataClass: ProviderDataClass) -> String {
        "provider|\(provider.rawValue)|\(dataClass.rawValue)"
    }
}
