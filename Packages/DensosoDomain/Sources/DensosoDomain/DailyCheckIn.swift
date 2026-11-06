import Foundation

/// A user's self-reported energy level. This is not derived from HealthKit data.
public enum UserReportedEnergy: String, Codable, CaseIterable, Sendable {
    case low
    case typical
    case high
}

/// A user's self-reported stress level. This is not a clinical assessment.
public enum UserReportedStress: String, Codable, CaseIterable, Sendable {
    case low
    case typical
    case elevated
}

/// A user's subjective description of sleep quality, separate from sleep samples.
public enum SubjectiveSleepQuality: String, Codable, CaseIterable, Sendable {
    case poor
    case fair
    case good
}

/// Facts explicitly reported by the user for a day. These values must remain separate
/// from objective HealthKit samples and must not be synthesized from biometric data.
public struct DailyCheckIn: Codable, Equatable, Sendable {
    public let occurredAt: Date
    public let energy: UserReportedEnergy
    public let stress: UserReportedStress
    public let subjectiveSleep: SubjectiveSleepQuality
    public let note: String?

    public init(
        occurredAt: Date,
        energy: UserReportedEnergy,
        stress: UserReportedStress,
        subjectiveSleep: SubjectiveSleepQuality,
        note: String? = nil
    ) {
        self.occurredAt = occurredAt
        self.energy = energy
        self.stress = stress
        self.subjectiveSleep = subjectiveSleep
        self.note = note
    }
}
