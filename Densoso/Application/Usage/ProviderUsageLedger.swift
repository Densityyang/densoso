import Foundation

struct ProviderTokenRate: Equatable, Sendable {
    let inputMicrosPerMillionTokens: Int64
    let outputMicrosPerMillionTokens: Int64
    let audioMicrosPerSecond: Int64?
    let currency: String

    init(
        inputMicrosPerMillionTokens: Int64,
        outputMicrosPerMillionTokens: Int64,
        audioMicrosPerSecond: Int64? = nil,
        currency: String
    ) {
        self.inputMicrosPerMillionTokens = inputMicrosPerMillionTokens
        self.outputMicrosPerMillionTokens = outputMicrosPerMillionTokens
        self.audioMicrosPerSecond = audioMicrosPerSecond
        self.currency = currency
    }
}

struct ProviderRateTable: Sendable {
    let version: String
    let rates: [ProviderID: ProviderTokenRate]

    static let unconfigured = ProviderRateTable(version: "unconfigured", rates: [:])
    /// Conservative Phase 3 estimates, intentionally biased against under-reporting.
    /// DeepSeek uses the peak, cache-miss V4 Flash price; Qwen uses Beijing's
    /// standard, non-cached <=128k tier. These are estimates, not invoice totals.
    static let phase3Conservative = ProviderRateTable(
        version: "phase4-conservative-2026-09-02",
        rates: [
            .deepSeek: ProviderTokenRate(
                inputMicrosPerMillionTokens: 440_000,
                outputMicrosPerMillionTokens: 1_320_000,
                currency: "USD"
            ),
            .qwen: ProviderTokenRate(
                inputMicrosPerMillionTokens: 150_000,
                outputMicrosPerMillionTokens: 1_500_000,
                audioMicrosPerSecond: 220,
                currency: "CNY"
            ),
        ]
    )

    func estimate(_ usage: ProviderUsage) -> (micros: Int64, currency: String)? {
        guard let rate = rates[usage.provider] else { return nil }
        if usage.capability == .speech {
            guard let audioRate = rate.audioMicrosPerSecond,
                  audioRate >= 0,
                  usage.audioSeconds.isFinite,
                  usage.audioSeconds >= 0 else { return nil }
            let rawCost = usage.audioSeconds * Double(audioRate)
            guard rawCost.isFinite, rawCost <= Double(Int64.max) else { return nil }
            return (Int64(rawCost.rounded(.up)), rate.currency)
        }
        guard
              usage.inputTokens >= 0,
              usage.outputTokens >= 0,
              let input = scaledCost(
                tokens: usage.inputTokens,
                microsPerMillion: rate.inputMicrosPerMillionTokens
              ),
              let output = scaledCost(
                tokens: usage.outputTokens,
                microsPerMillion: rate.outputMicrosPerMillionTokens
              ) else { return nil }
        let sum = input.addingReportingOverflow(output)
        guard !sum.overflow else { return nil }
        return (max(sum.partialValue, 0), rate.currency)
    }

    private func scaledCost(tokens: Int, microsPerMillion: Int64) -> Int64? {
        guard microsPerMillion >= 0 else { return nil }
        let product = Int64(tokens).multipliedReportingOverflow(by: microsPerMillion)
        guard !product.overflow else { return nil }
        return product.partialValue / 1_000_000
    }
}

struct ProviderUsageSummary: Equatable, Sendable {
    let provider: ProviderID
    let inputTokens: Int
    let outputTokens: Int
    let audioSeconds: Double
    let estimatedCostMicros: Int64?
    let currency: String?
}

protocol ProviderGovernanceRepository: Sendable {
    func isConsentGranted(provider: ProviderID, dataClass: ProviderDataClass) async throws -> Bool
    func setConsent(
        provider: ProviderID,
        dataClass: ProviderDataClass,
        granted: Bool,
        policyVersion: String
    ) async throws
    func recordUsage(
        usage: ProviderUsage,
        usageKey: String,
        estimatedCostMicros: Int64?,
        currency: String?,
        rateVersion: String
    ) async throws
    func monthlyUsage(provider: ProviderID, monthStart: Date, monthEnd: Date) async throws -> ProviderUsageSummary
}

actor ProviderUsageLedger {
    private let repository: any ProviderGovernanceRepository
    private let rateTable: ProviderRateTable

    init(
        repository: any ProviderGovernanceRepository,
        rateTable: ProviderRateTable = .phase3Conservative
    ) {
        self.repository = repository
        self.rateTable = rateTable
    }

    func record(
        _ usage: ProviderUsage,
        requestID: UUID,
        providerRound: Int = 1
    ) async throws {
        let estimate = rateTable.estimate(usage)
        let key = [
            usage.provider.rawValue,
            requestID.uuidString.lowercased(),
            String(providerRound),
            String(usage.attempt),
        ].joined(separator: "|")
        try await repository.recordUsage(
            usage: usage,
            usageKey: key,
            estimatedCostMicros: estimate?.micros,
            currency: estimate?.currency,
            rateVersion: rateTable.version
        )
    }

    func monthlySummary(provider: ProviderID, referenceDate: Date = Date()) async throws -> ProviderUsageSummary {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: referenceDate)
        let monthStart = calendar.date(from: components) ?? referenceDate
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? referenceDate
        return try await repository.monthlyUsage(
            provider: provider,
            monthStart: monthStart,
            monthEnd: monthEnd
        )
    }

    func isSoftBudgetExceeded(
        provider: ProviderID,
        monthlyBudgetMicros: Int64,
        referenceDate: Date = Date()
    ) async throws -> Bool {
        let summary = try await monthlySummary(provider: provider, referenceDate: referenceDate)
        guard let cost = summary.estimatedCostMicros else { return false }
        return cost >= max(monthlyBudgetMicros, 0)
    }
}
