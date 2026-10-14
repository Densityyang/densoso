import Foundation
import Observation
import DensosoDomain

/// User-initiated permission entry point. Completion means the system request returned,
/// not that any read scope was granted (HealthKit does not disclose that state).
@MainActor
@Observable
final class HealthKitService {
    enum HealthError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unavailable: "此设备无法使用 Apple Health。"
            }
        }
    }

    let client: HealthKitHealthStoreClient
    var hasRequestedAuthorization: Bool {
        didSet { HealthKitConnectionPreference.hasRequestedAuthorization = hasRequestedAuthorization }
    }

    init(client: HealthKitHealthStoreClient = HealthKitHealthStoreClient()) {
        self.client = client
        self.hasRequestedAuthorization = HealthKitConnectionPreference.hasRequestedAuthorization
    }

    func requestAuthorization() async throws {
        guard await client.isAvailable() else { throw HealthError.unavailable }
        try await client.requestAuthorization(.application)
        hasRequestedAuthorization = true
    }
}

enum HealthKitConnectionPreference {
    private static let key = "densoso.healthkit.authorization-requested.v1"

    static var hasRequestedAuthorization: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
