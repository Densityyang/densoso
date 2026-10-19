import Foundation

enum PricingDescriptorOrigin: Equatable, Sendable {
    case publishedPriceList(documentID: String, checkedOn: String)
    case localConfiguration(identifier: String)
}

struct PricingDescriptor: Equatable, Sendable {
    let provider: ProviderID
    let model: String
    let capability: ProviderCapability
    let version: String
    let origin: PricingDescriptorOrigin
    let currency: String
    let inputMicrosPerMillionTokens: Int64?
    let cachedInputMicrosPerMillionTokens: Int64?
    let outputMicrosPerMillionTokens: Int64?
    let audioMicrosPerSecond: Int64?

    func estimate(_ usage: ProviderUsage) -> (micros: Int64, currency: String)? {
        guard usage.provider == provider,
              usage.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == model,
              usage.capability == capability else { return nil }
        if capability == .speech {
            guard let audioMicrosPerSecond,
                  audioMicrosPerSecond >= 0,
                  usage.audioSeconds.isFinite,
                  usage.audioSeconds >= 0 else { return nil }
            let rawCost = usage.audioSeconds * Double(audioMicrosPerSecond)
            guard rawCost.isFinite, rawCost <= Double(Int64.max) else { return nil }
            return (Int64(rawCost.rounded(.up)), currency)
        }

        guard usage.inputTokens >= 0,
              usage.outputTokens >= 0,
              usage.cachedInputTokens >= 0,
              usage.cachedInputTokens <= usage.inputTokens,
              let inputMicrosPerMillionTokens,
              let outputMicrosPerMillionTokens else { return nil }

        let uncachedInputTokens = usage.inputTokens - usage.cachedInputTokens
        guard let input = Self.scaledCost(
            tokens: uncachedInputTokens,
            microsPerMillion: inputMicrosPerMillionTokens
        ) else { return nil }
        let cachedInput: Int64
        if usage.cachedInputTokens == 0 {
            cachedInput = 0
        } else {
            guard let cachedInputMicrosPerMillionTokens,
                  let cost = Self.scaledCost(
                      tokens: usage.cachedInputTokens,
                      microsPerMillion: cachedInputMicrosPerMillionTokens
                  ) else { return nil }
            cachedInput = cost
        }
        guard let output = Self.scaledCost(
            tokens: usage.outputTokens,
            microsPerMillion: outputMicrosPerMillionTokens
        ) else { return nil }

        let inputAndCache = input.addingReportingOverflow(cachedInput)
        guard !inputAndCache.overflow else { return nil }
        let total = inputAndCache.partialValue.addingReportingOverflow(output)
        guard !total.overflow else { return nil }
        return (max(total.partialValue, 0), currency)
    }

    private static func scaledCost(tokens: Int, microsPerMillion: Int64) -> Int64? {
        guard tokens >= 0, microsPerMillion >= 0 else { return nil }
        let product = Int64(tokens).multipliedReportingOverflow(by: microsPerMillion)
        guard !product.overflow else { return nil }
        let quotient = product.partialValue / 1_000_000
        let remainder = product.partialValue % 1_000_000
        guard remainder != 0 else { return quotient }
        let rounded = quotient.addingReportingOverflow(1)
        return rounded.overflow ? nil : rounded.partialValue
    }
}

protocol PricingDescriptorSource: Sendable {
    func descriptor(for usage: ProviderUsage) -> PricingDescriptor?
}

struct StaticPricingDescriptorSource: PricingDescriptorSource, Sendable {
    let descriptors: [PricingDescriptor]

    func descriptor(for usage: ProviderUsage) -> PricingDescriptor? {
        let normalizedModel = usage.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return descriptors.first {
            $0.provider == usage.provider
                && $0.model == normalizedModel
                && $0.capability == usage.capability
        }
    }

    func estimate(_ usage: ProviderUsage) -> (micros: Int64, currency: String)? {
        descriptor(for: usage)?.estimate(usage)
    }

    static let unconfigured = StaticPricingDescriptorSource(descriptors: [])
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
    private let pricingDescriptorSource: any PricingDescriptorSource

    init(
        repository: any ProviderGovernanceRepository,
        pricingDescriptorSource: any PricingDescriptorSource = PricingDescriptorCatalog.phase3Conservative
    ) {
        self.repository = repository
        self.pricingDescriptorSource = pricingDescriptorSource
    }

    func record(
        _ usage: ProviderUsage,
        requestID: UUID,
        providerRound: Int = 1
    ) async throws {
        let descriptor = pricingDescriptorSource.descriptor(for: usage)
        let estimate = descriptor?.estimate(usage)
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
            rateVersion: estimate == nil ? "unknown" : descriptor?.version ?? "unknown"
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
