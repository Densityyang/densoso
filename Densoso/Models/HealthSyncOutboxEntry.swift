import Foundation
import SwiftData

/// A durable local record of health-data changes awaiting an external HealthKit sync.
@Model
final class HealthSyncOutboxEntry {
    @Attribute(.unique) var id: UUID
    var operation: String
    var recordID: UUID
    var createdAt: Date
    var state: String
    var lastError: String?

    init(operation: String, recordID: UUID, state: String = "pending") {
        self.id = UUID()
        self.operation = operation
        self.recordID = recordID
        self.createdAt = Date()
        self.state = state
    }
}
