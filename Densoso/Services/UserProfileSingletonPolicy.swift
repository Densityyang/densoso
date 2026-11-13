import Foundation
import SwiftData

/// The local store represents one person. Older supported schemas did not
/// enforce that invariant, so startup resolves duplicates deterministically.
@MainActor
enum UserProfileSingletonPolicy {
    static func primary(in modelContext: ModelContext) throws -> UserProfile? {
        try modelContext.fetch(FetchDescriptor<UserProfile>()).sorted(by: preferred).first
    }

    @discardableResult
    static func normalize(in modelContext: ModelContext) throws -> UserProfile? {
        let profiles = try modelContext.fetch(FetchDescriptor<UserProfile>())
        let ordered = profiles.sorted(by: preferred)
        guard let primary = ordered.first else { return nil }

        var changed = false
        if primary.profileKey != "primary" {
            primary.profileKey = "primary"
            changed = true
        }
        for duplicate in ordered.dropFirst() {
            modelContext.delete(duplicate)
            changed = true
        }
        guard changed else { return primary }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        return primary
    }

    private static func preferred(_ lhs: UserProfile, _ rhs: UserProfile) -> Bool {
        let lhsPrimary = lhs.profileKey == "primary"
        let rhsPrimary = rhs.profileKey == "primary"
        if lhsPrimary != rhsPrimary { return lhsPrimary }

        let lhsComplete = !lhs.profileNeedsCompletion && lhs.dateOfBirth != nil
        let rhsComplete = !rhs.profileNeedsCompletion && rhs.dateOfBirth != nil
        if lhsComplete != rhsComplete { return lhsComplete }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        if lhs.biologicalSex != rhs.biologicalSex { return lhs.biologicalSex < rhs.biologicalSex }
        if lhs.heightCm != rhs.heightCm { return lhs.heightCm < rhs.heightCm }
        if lhs.weightKg != rhs.weightKg { return lhs.weightKg < rhs.weightKg }
        return lhs.profileKey < rhs.profileKey
    }
}
