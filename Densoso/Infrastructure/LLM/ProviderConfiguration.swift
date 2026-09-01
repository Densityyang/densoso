import Foundation
import Observation

protocol ProviderCredentialSource: Sendable {
    func credential(for provider: ProviderID) throws -> String?
}

enum ProviderCapabilityCatalog {
    static let qwenAvailable: Set<ProviderCapability> = [
        .text, .toolCalling, .structuredOutput, .vision, .speech,
    ]
    static let phase3Enabled: Set<ProviderCapability> = [
        .text, .toolCalling, .structuredOutput,
    ]

    static func qwenFlash(in region: ModelStudioRegion) -> Set<ProviderCapability> {
        switch region {
        case .beijing:
            phase3Enabled
        case .singapore:
            // The Singapore qwen-flash endpoint does not advertise Function Calling.
            [.text]
        }
    }
}

extension KeychainStore: ProviderCredentialSource {
    func credential(for provider: ProviderID) throws -> String? {
        switch provider {
        case .deepSeek: try readAPIKey()
        case .qwen: try readModelStudioAPIKey()
        }
    }
}

enum ModelStudioRegion: String, Codable, CaseIterable, Sendable {
    case beijing
    case singapore

    var domain: String {
        switch self {
        case .beijing: "cn-beijing.maas.aliyuncs.com"
        case .singapore: "ap-southeast-1.maas.aliyuncs.com"
        }
    }

    var phase3Capabilities: Set<ProviderCapability> {
        ProviderCapabilityCatalog.qwenFlash(in: self)
    }
}

@MainActor
@Observable
final class ProviderConfigurationPreferences {
    private enum Key {
        static let qwenWorkspaceID = "provider.qwen.workspaceID"
        static let qwenRegion = "provider.qwen.region"
        static let deepSeekMonthlyBudgetMicros = "provider.deepseek.monthlyBudgetMicros"
        static let qwenMonthlyBudgetMicros = "provider.qwen.monthlyBudgetMicros"
    }

    var qwenWorkspaceID: String {
        didSet { UserDefaults.standard.set(qwenWorkspaceID, forKey: Key.qwenWorkspaceID) }
    }
    var qwenRegion: ModelStudioRegion {
        didSet { UserDefaults.standard.set(qwenRegion.rawValue, forKey: Key.qwenRegion) }
    }
    var deepSeekMonthlyBudgetMicros: Int64 {
        didSet { UserDefaults.standard.set(deepSeekMonthlyBudgetMicros, forKey: Key.deepSeekMonthlyBudgetMicros) }
    }
    var qwenMonthlyBudgetMicros: Int64 {
        didSet { UserDefaults.standard.set(qwenMonthlyBudgetMicros, forKey: Key.qwenMonthlyBudgetMicros) }
    }

    init() {
        qwenWorkspaceID = UserDefaults.standard.string(forKey: Key.qwenWorkspaceID) ?? ""
        let storedRegion = ModelStudioRegion(
            rawValue: UserDefaults.standard.string(forKey: Key.qwenRegion) ?? ""
        ) ?? .beijing
        // Phase 3 requires Function Calling. Migrate an older Singapore choice
        // to the only qwen-flash region that satisfies that contract.
        qwenRegion = storedRegion.phase3Capabilities.contains(.toolCalling)
            ? storedRegion
            : .beijing
        let deepSeekStored = UserDefaults.standard.object(forKey: Key.deepSeekMonthlyBudgetMicros) as? NSNumber
        let qwenStored = UserDefaults.standard.object(forKey: Key.qwenMonthlyBudgetMicros) as? NSNumber
        deepSeekMonthlyBudgetMicros = deepSeekStored?.int64Value ?? 2_000_000
        qwenMonthlyBudgetMicros = qwenStored?.int64Value ?? 10_000_000
    }

    func qwenEndpoint() throws -> URL {
        guard qwenRegion.phase3Capabilities.isSuperset(of: ProviderCapabilityCatalog.phase3Enabled) else {
            throw ProviderError.unsupportedCapability(.toolCalling)
        }
        let workspaceID = qwenWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceID.isEmpty,
              workspaceID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw ProviderError.configurationMissing(provider: .qwen)
        }
        guard let url = URL(
            string: "https://\(workspaceID).\(qwenRegion.domain)/compatible-mode/v1/chat/completions"
        ) else {
            throw ProviderError.configurationMissing(provider: .qwen)
        }
        return url
    }
}
