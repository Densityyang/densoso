import Foundation

public enum UserPreferenceCategory: String, Codable, CaseIterable, Sendable {
    case food
    case exercise
    case communication
}

/// Preference provenance is intentionally restricted to explicit user statements.
public enum UserPreferenceSource: String, Codable, CaseIterable, Sendable {
    case userReported
}

/// A lightweight preference explicitly stated by the user. The application must
/// stage it through a PendingAction and persist it only after user confirmation;
/// it must not be inferred from behavior or automatically included in cloud context.
public struct UserPreference: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let category: UserPreferenceCategory
    public let statement: String
    public let createdAt: Date
    public let source: UserPreferenceSource

    public init(
        id: UUID = UUID(),
        category: UserPreferenceCategory,
        statement: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.statement = statement
        self.createdAt = createdAt
        self.source = .userReported
    }
}
