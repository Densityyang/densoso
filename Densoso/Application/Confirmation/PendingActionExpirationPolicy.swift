import DensosoDomain
import Foundation

enum PendingActionExpirationPolicy {
    static func isActive(expiresAt: Date, asOf date: Date) -> Bool {
        expiresAt > date
    }

    static func activeActions(_ actions: [PendingAction], asOf date: Date) -> [PendingAction] {
        actions.filter { $0.state == .pending && isActive(expiresAt: $0.expiresAt, asOf: date) }
    }

    static func nextExpiry(in actions: [PendingAction]) -> Date? {
        actions
            .filter { $0.state == .pending }
            .map(\.expiresAt)
            .min()
    }
}
