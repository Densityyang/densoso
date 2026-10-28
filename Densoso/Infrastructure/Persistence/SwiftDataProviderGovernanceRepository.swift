import Foundation
import SwiftData

@ModelActor
actor SwiftDataProviderGovernanceRepository: ProviderGovernanceRepository, CloudHealthContextPolicySnapshotRepository {
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
        if granted,
           (dataClass.isHealthContextClass || dataClass.isConversationHistoryClass),
           try isConsentGranted(provider: provider, dataClass: dataClass) == false {
            throw CloudHealthContextPolicyError.expansionRequiresConfirmation
        }
        let now = Date()
        let previousPolicy = try currentCloudHealthContextPolicySnapshot(provider: provider)
        let key = consentKey(provider: provider, dataClass: dataClass)
        var descriptor = FetchDescriptor<ConsentRecord>(
            predicate: #Predicate { $0.consentKey == key }
        )
        descriptor.fetchLimit = 1
        do {
            if let record = try modelContext.fetch(descriptor).first {
                record.granted = granted
                record.policyVersion = policyVersion
                record.decidedAt = now
                record.revokedAt = granted ? nil : now
            } else {
                modelContext.insert(
                    ConsentRecord(
                        consentKey: key,
                        kind: dataClass.rawValue,
                        policyVersion: policyVersion,
                        granted: granted,
                        decidedAt: now,
                        revokedAt: granted ? nil : now
                    )
                )
            }
            var allowed = try currentGrantedHealthContextClasses(for: provider)
            if try isConsentGranted(provider: provider, dataClass: .conversationHistory) {
                allowed.insert(.conversationHistory)
            }
            let changesHealthPolicy = dataClass.isHealthContextClass || dataClass.isConversationHistoryClass
            let state: CloudHealthPolicyState = changesHealthPolicy
                ? (allowed.isEmpty ? .revoked : .active)
                : previousPolicy.state
            let snapshot = CloudHealthContextPolicySnapshot.make(
                provider: provider,
                policyID: previousPolicy.policyID,
                revision: previousPolicy.revision + 1,
                state: state,
                allowedClasses: allowed,
                createdAt: previousPolicy.createdAt == .distantPast ? now : previousPolicy.createdAt,
                updatedAt: now,
                confirmedAt: changesHealthPolicy && granted ? now : previousPolicy.confirmedAt,
                changeSource: .settings
            )
            guard upsertPolicySnapshot(snapshot) else {
                throw CloudHealthContextPolicyError.snapshotRepositoryUnavailable
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func currentCloudHealthContextPolicySnapshot(
        provider: ProviderID
    ) throws -> CloudHealthContextPolicySnapshot {
        let key = policyKey(provider: provider)
        var descriptor = FetchDescriptor<CloudHealthContextPolicyRecord>(
            predicate: #Predicate { $0.policyKey == key }
        )
        descriptor.fetchLimit = 1
        if let records = try? modelContext.fetch(descriptor) {
            if let record = records.first {
                if let decoded = decodePolicySnapshot(record) { return decoded }
                return CloudHealthContextPolicySnapshot.make(
                    provider: provider,
                    policyID: record.policyID,
                    revision: record.revision,
                    state: .needsReconfirmation,
                    allowedClasses: [],
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt,
                    confirmedAt: nil,
                    changeSource: .backupRestore
                )
            }
            let legacy = try legacyPolicySnapshot(provider: provider)
            if legacy.state != .notConfigured, upsertPolicySnapshot(legacy) {
                try modelContext.save()
            }
            return legacy
        }
        return try legacyPolicySnapshot(provider: provider)
    }

    func withCurrentSendAuthorization<Result: Sendable>(
        provider: ProviderID,
        expectedSnapshot: CloudHealthContextPolicySnapshot,
        requiredClasses: Set<ProviderDataClass>,
        operation: @Sendable () throws -> Result
    ) async throws -> Result {
        let currentSnapshot = try currentCloudHealthContextPolicySnapshot(provider: provider)
        guard expectedSnapshot.provider == provider, currentSnapshot == expectedSnapshot else {
            throw ProviderError.consentPolicyChanged(provider: provider)
        }
        for dataClass in requiredClasses.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard try isConsentGranted(provider: provider, dataClass: dataClass) else {
                throw ProviderError.consentRequired(provider: provider, dataClass: dataClass)
            }
        }
        return try operation()
    }

    func updateCloudHealthContextPolicy(
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        changeSource: CloudHealthPolicyChangeSource,
        confirmedAt: Date?
    ) throws -> CloudHealthContextPolicySnapshot {
        let allowed = allowedClasses.intersection(Set(CloudHealthContextPolicy.dataClasses))
        let prior = try currentCloudHealthContextPolicySnapshot(provider: provider)
        let expansion = allowed.subtracting(prior.allowedClasses)
        guard expansion.isEmpty || confirmedAt != nil else {
            throw CloudHealthContextPolicyError.expansionRequiresConfirmation
        }

        let now = Date()
        do {
            for dataClass in CloudHealthContextPolicy.dataClasses {
                try upsertConsentRecord(
                    provider: provider,
                    dataClass: dataClass,
                    granted: allowed.contains(dataClass),
                    policyVersion: "cloud-health-context-v1",
                    decidedAt: now
                )
            }
            var snapshotClasses = allowed
            if try isConsentGranted(provider: provider, dataClass: .conversationHistory) {
                snapshotClasses.insert(.conversationHistory)
            }
            let snapshot = CloudHealthContextPolicySnapshot.make(
                provider: provider,
                policyID: prior.policyID,
                revision: prior.revision + 1,
                state: snapshotClasses.isEmpty ? .revoked : .active,
                allowedClasses: snapshotClasses,
                createdAt: prior.createdAt == .distantPast ? now : prior.createdAt,
                updatedAt: now,
                confirmedAt: confirmedAt ?? prior.confirmedAt,
                changeSource: changeSource
            )
            guard upsertPolicySnapshot(snapshot) else {
                throw CloudHealthContextPolicyError.snapshotRepositoryUnavailable
            }
            try modelContext.save()
            return snapshot
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func stageCloudHealthContextPolicyDraft(
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        changeSource: CloudHealthPolicyChangeSource
    ) throws -> CloudHealthContextPolicySnapshot {
        let target = allowedClasses.intersection(
            Set(CloudHealthContextPolicy.dataClasses).union([.conversationHistory])
        )
        let prior = try currentCloudHealthContextPolicySnapshot(provider: provider)
        guard !target.subtracting(prior.allowedClasses).isEmpty else { return prior }
        let now = Date()
        let snapshot = CloudHealthContextPolicySnapshot.make(
            provider: provider,
            policyID: prior.policyID,
            revision: prior.revision + 1,
            state: .draft,
            allowedClasses: target,
            createdAt: prior.createdAt == .distantPast ? now : prior.createdAt,
            updatedAt: now,
            confirmedAt: prior.confirmedAt,
            changeSource: changeSource
        )
        guard upsertPolicySnapshot(snapshot) else {
            throw CloudHealthContextPolicyError.snapshotRepositoryUnavailable
        }
        try modelContext.save()
        return snapshot
    }

    func updateConversationHistoryConsent(
        provider: ProviderID,
        allowed: Bool,
        changeSource: CloudHealthPolicyChangeSource,
        confirmedAt: Date?
    ) throws -> CloudHealthContextPolicySnapshot {
        let prior = try currentCloudHealthContextPolicySnapshot(provider: provider)
        let wasAllowed = try isConsentGranted(provider: provider, dataClass: .conversationHistory)
        guard !allowed || wasAllowed || confirmedAt != nil else {
            throw CloudHealthContextPolicyError.expansionRequiresConfirmation
        }
        let now = Date()
        do {
            try upsertConsentRecord(
                provider: provider,
                dataClass: .conversationHistory,
                granted: allowed,
                policyVersion: "cloud-conversation-history-v1",
                decidedAt: now
            )
            var snapshotClasses = try currentGrantedHealthContextClasses(for: provider)
            if allowed { snapshotClasses.insert(.conversationHistory) }
            let snapshot = CloudHealthContextPolicySnapshot.make(
                provider: provider,
                policyID: prior.policyID,
                revision: prior.revision + 1,
                state: snapshotClasses.isEmpty ? .revoked : .active,
                allowedClasses: snapshotClasses,
                createdAt: prior.createdAt == .distantPast ? now : prior.createdAt,
                updatedAt: now,
                confirmedAt: allowed && !wasAllowed ? confirmedAt : prior.confirmedAt,
                changeSource: changeSource
            )
            guard upsertPolicySnapshot(snapshot) else {
                throw CloudHealthContextPolicyError.snapshotRepositoryUnavailable
            }
            try modelContext.save()
            return snapshot
        } catch {
            modelContext.rollback()
            throw error
        }
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

    private func policyKey(provider: ProviderID) -> String {
        "cloud-health-context-policy|\(provider.rawValue)"
    }

    private func currentGrantedHealthContextClasses(for provider: ProviderID) throws -> Set<ProviderDataClass> {
        Set(try CloudHealthContextPolicy.dataClasses.filter {
            try isConsentGranted(provider: provider, dataClass: $0)
        })
    }

    private func legacyPolicySnapshot(provider: ProviderID) throws -> CloudHealthContextPolicySnapshot {
        let policyClasses = CloudHealthContextPolicy.dataClasses + [.conversationHistory]
        let records = try modelContext.fetch(FetchDescriptor<ConsentRecord>())
        let relevant = records.filter { record in
            policyClasses.contains { dataClass in
                record.consentKey == consentKey(provider: provider, dataClass: dataClass)
            }
        }
        guard !relevant.isEmpty else { return .unconfigured(provider: provider) }
        let allowed = Set<ProviderDataClass>(relevant.compactMap { record -> ProviderDataClass? in
            guard record.granted,
                  let dataClass = policyClasses.first(where: {
                      consentKey(provider: provider, dataClass: $0) == record.consentKey
                  }) else { return nil }
            return dataClass
        })
        let createdAt = relevant.map(\.decidedAt).min() ?? .distantPast
        let updatedAt = relevant.map(\.decidedAt).max() ?? createdAt
        let confirmedAt = relevant.filter(\.granted).map(\.decidedAt).max()
        return CloudHealthContextPolicySnapshot.make(
            provider: provider,
            policyID: CloudHealthContextPolicySnapshot.unconfigured(provider: provider).policyID,
            revision: 1,
            state: allowed.isEmpty ? .revoked : .active,
            allowedClasses: allowed,
            createdAt: createdAt,
            updatedAt: updatedAt,
            confirmedAt: confirmedAt,
            changeSource: .legacyConsent
        )
    }

    private func decodePolicySnapshot(
        _ record: CloudHealthContextPolicyRecord
    ) -> CloudHealthContextPolicySnapshot? {
        guard record.schemaVersion == CloudHealthContextPolicySnapshot.currentSchemaVersion,
              let provider = ProviderID(rawValue: record.providerRaw),
              let state = CloudHealthPolicyState(rawValue: record.stateRaw),
              let changeSource = CloudHealthPolicyChangeSource(rawValue: record.changeSourceRaw) else {
            return nil
        }
        let allowed = Set(record.allowedClassesRaw.split(separator: ",").compactMap {
            ProviderDataClass(rawValue: String($0))
        }).intersection(Set(CloudHealthContextPolicy.dataClasses).union([.conversationHistory]))
        let snapshot = CloudHealthContextPolicySnapshot.make(
            provider: provider,
            policyID: record.policyID,
            revision: record.revision,
            state: state,
            allowedClasses: allowed,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            confirmedAt: record.confirmedAt,
            changeSource: changeSource
        )
        guard provider.rawValue == record.providerRaw,
              snapshot.policyHash == record.policyHash else { return nil }
        return snapshot
    }

    @discardableResult
    private func upsertPolicySnapshot(_ snapshot: CloudHealthContextPolicySnapshot) -> Bool {
        let key = policyKey(provider: snapshot.provider)
        var descriptor = FetchDescriptor<CloudHealthContextPolicyRecord>(
            predicate: #Predicate { $0.policyKey == key }
        )
        descriptor.fetchLimit = 1
        guard let records = try? modelContext.fetch(descriptor) else { return false }
        let allowedClassesRaw = snapshot.allowedClasses.map(\.rawValue).sorted().joined(separator: ",")
        if let record = records.first {
            record.schemaVersion = snapshot.schemaVersion
            record.policyID = snapshot.policyID
            record.providerRaw = snapshot.provider.rawValue
            record.revision = snapshot.revision
            record.stateRaw = snapshot.state.rawValue
            record.allowedClassesRaw = allowedClassesRaw
            record.createdAt = snapshot.createdAt
            record.updatedAt = snapshot.updatedAt
            record.confirmedAt = snapshot.confirmedAt
            record.policyHash = snapshot.policyHash
            record.changeSourceRaw = snapshot.changeSource.rawValue
        } else {
            modelContext.insert(CloudHealthContextPolicyRecord(
                policyKey: key,
                schemaVersion: snapshot.schemaVersion,
                policyID: snapshot.policyID,
                providerRaw: snapshot.provider.rawValue,
                revision: snapshot.revision,
                stateRaw: snapshot.state.rawValue,
                allowedClassesRaw: allowedClassesRaw,
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.updatedAt,
                confirmedAt: snapshot.confirmedAt,
                policyHash: snapshot.policyHash,
                changeSourceRaw: snapshot.changeSource.rawValue
            ))
        }
        return true
    }

    private func upsertConsentRecord(
        provider: ProviderID,
        dataClass: ProviderDataClass,
        granted: Bool,
        policyVersion: String,
        decidedAt: Date
    ) throws {
        let key = consentKey(provider: provider, dataClass: dataClass)
        var descriptor = FetchDescriptor<ConsentRecord>(predicate: #Predicate { $0.consentKey == key })
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            record.granted = granted
            record.policyVersion = policyVersion
            record.decidedAt = decidedAt
            record.revokedAt = granted ? nil : decidedAt
        } else {
            modelContext.insert(ConsentRecord(
                consentKey: key,
                kind: dataClass.rawValue,
                policyVersion: policyVersion,
                granted: granted,
                decidedAt: decidedAt,
                revokedAt: granted ? nil : decidedAt
            ))
        }
    }
}
