import Foundation
import SwiftData

@ModelActor
actor SwiftDataProviderGovernanceRepository: ProviderGovernanceRepository {
    func isConsentGranted(provider: ProviderID, dataClass: ProviderDataClass) throws -> Bool {
        let key = consentKey(provider: provider, dataClass: dataClass)
        return try modelContext.fetch(FetchDescriptor<ConsentRecord>())
            .first(where: { $0.consentKey == key })?
            .granted == true
    }

    func setConsent(
        provider: ProviderID,
        dataClass: ProviderDataClass,
        granted: Bool,
        policyVersion: String
    ) throws {
        let key = consentKey(provider: provider, dataClass: dataClass)
        if let record = try modelContext.fetch(FetchDescriptor<ConsentRecord>())
            .first(where: { $0.consentKey == key }) {
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
        estimatedCostMicros: Int64?,
        currency: String?,
        rateVersion: String
    ) throws {
        let exists = try modelContext.fetch(FetchDescriptor<ProviderUsageRecord>())
            .contains(where: { $0.usageKey == usageKey })
        guard !exists else { return }
        let record = ProviderUsageRecord(
            usageKey: usageKey,
            provider: usage.provider.rawValue,
            model: usage.model,
            capability: usage.capability.rawValue
        )
        record.inputTokens = max(usage.inputTokens, 0)
        record.outputTokens = max(usage.outputTokens, 0)
        record.audioSeconds = max(usage.audioSeconds, 0)
        record.estimatedCostMicros = estimatedCostMicros ?? -1
        record.currency = currency ?? "unavailable"
        record.rateVersion = rateVersion
        modelContext.insert(record)
        try modelContext.save()
    }

    func monthlyUsage(
        provider: ProviderID,
        monthStart: Date,
        monthEnd: Date
    ) throws -> ProviderUsageSummary {
        let records = try modelContext.fetch(FetchDescriptor<ProviderUsageRecord>())
            .filter {
                $0.provider == provider.rawValue
                    && $0.createdAt >= monthStart
                    && $0.createdAt < monthEnd
            }
        let priced = records.filter { $0.estimatedCostMicros >= 0 }
        let currencies = Set(priced.map(\.currency))
        let cost: Int64? = priced.count == records.count && currencies.count <= 1
            ? priced.reduce(0) { $0 + $1.estimatedCostMicros }
            : nil
        return ProviderUsageSummary(
            provider: provider,
            inputTokens: records.reduce(0) { $0 + $1.inputTokens },
            outputTokens: records.reduce(0) { $0 + $1.outputTokens },
            estimatedCostMicros: cost,
            currency: cost == nil ? nil : currencies.first
        )
    }

    private func consentKey(provider: ProviderID, dataClass: ProviderDataClass) -> String {
        "provider|\(provider.rawValue)|\(dataClass.rawValue)"
    }
}
