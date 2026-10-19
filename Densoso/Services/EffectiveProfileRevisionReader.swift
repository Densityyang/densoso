import Foundation
import SwiftData

enum EffectiveProfileRevisionReader {
    static func latest(
        in modelContext: ModelContext,
        profileKey: String,
        effectiveAt date: Date
    ) throws -> ProfileRevisionRecord? {
        let predicate = #Predicate<ProfileRevisionRecord> {
            $0.profileKey == profileKey && $0.effectiveFrom <= date
        }
        var descriptor = FetchDescriptor<ProfileRevisionRecord>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\ProfileRevisionRecord.effectiveFrom, order: .reverse),
                SortDescriptor(\ProfileRevisionRecord.createdAt, order: .reverse),
                SortDescriptor(\ProfileRevisionRecord.id, order: .reverse),
            ]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
