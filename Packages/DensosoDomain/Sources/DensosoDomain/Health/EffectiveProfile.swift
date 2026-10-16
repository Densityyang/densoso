import Foundation

public enum BiologicalSex: String, Codable, CaseIterable, Sendable {
    case female
    case male
    case other
    case unspecified
}

public enum ActivityLevel: String, Codable, CaseIterable, Sendable {
    case unspecified
    case sedentary
    case light
    case moderate
    case active
    case veryActive
}

public enum ProfileSource: String, Codable, CaseIterable, Sendable {
    case onboarding
    case userEdited
    case healthKit
    case imported
    case legacyMigration
}

public struct ProfileRevision: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let profileKey: String
    public let effectiveFrom: Date
    public let dateOfBirth: Date?
    public let biologicalSex: BiologicalSex
    public let heightCm: Double
    public let weightKg: Double?
    public let activityLevel: ActivityLevel
    public let source: ProfileSource
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        profileKey: String,
        effectiveFrom: Date,
        dateOfBirth: Date?,
        biologicalSex: BiologicalSex,
        heightCm: Double,
        weightKg: Double?,
        activityLevel: ActivityLevel,
        source: ProfileSource,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.profileKey = profileKey
        self.effectiveFrom = effectiveFrom
        self.dateOfBirth = dateOfBirth
        self.biologicalSex = biologicalSex
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.activityLevel = activityLevel
        self.source = source
        self.createdAt = createdAt
    }
}

public struct EffectiveProfile: Codable, Equatable, Sendable {
    public let profileKey: String
    public let sourceRevisionID: UUID
    public let sourceEffectiveFrom: Date
    public let effectiveAt: Date
    public let dateOfBirth: Date
    public let biologicalSex: BiologicalSex
    public let heightCm: Double
    public let weightKg: Double?
    public let activityLevel: ActivityLevel

    public var age: Int? {
        age(in: .current)
    }

    public func age(in calendar: Calendar) -> Int? {
        guard dateOfBirth <= effectiveAt else { return nil }
        return calendar.dateComponents([.year], from: dateOfBirth, to: effectiveAt).year
    }
}

/// Resolves profile facts using the revision that was effective on the requested day.
public struct EffectiveProfileResolver: Sendable {
    private let profileKey: String
    private let revisions: [ProfileRevision]

    public init(profileKey: String, revisions: [ProfileRevision]) {
        self.profileKey = profileKey
        self.revisions = revisions.filter { $0.profileKey == profileKey }
    }

    public func profile(at date: Date) -> EffectiveProfile? {
        let revision = revisions
            .filter { $0.effectiveFrom <= date }
            .sorted(by: Self.precedes)
            .last

        guard let revision,
              let dateOfBirth = revision.dateOfBirth,
              dateOfBirth <= date
        else {
            return nil
        }

        return EffectiveProfile(
            profileKey: profileKey,
            sourceRevisionID: revision.id,
            sourceEffectiveFrom: revision.effectiveFrom,
            effectiveAt: date,
            dateOfBirth: dateOfBirth,
            biologicalSex: revision.biologicalSex,
            heightCm: revision.heightCm,
            weightKg: revision.weightKg,
            activityLevel: revision.activityLevel
        )
    }

    private static func precedes(_ lhs: ProfileRevision, _ rhs: ProfileRevision) -> Bool {
        if lhs.effectiveFrom != rhs.effectiveFrom {
            return lhs.effectiveFrom < rhs.effectiveFrom
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
