import Foundation
import SwiftData

/// Stores an anchored-query cursor in the same transaction as its imported records.
@Model
final class HealthKitImportCursor {
    @Attribute(.unique) var stream: String
    var anchorData: Data?
    var updatedAt: Date

    init(stream: String, anchorData: Data? = nil) {
        self.stream = stream
        self.anchorData = anchorData
        self.updatedAt = Date()
    }
}
