import DensosoDomain
import Foundation

struct ConfirmedWorkoutPlanEntry: Codable, Equatable, Sendable {
    enum State: String, Codable, Equatable, Sendable {
        case queued
        case retryable
        case scheduled
        case terminal
    }

    static let notesPrefix = "densoso-workout-plan-v1:"

    let actionID: UUID
    let idempotencyKey: String
    let draft: WorkoutPlanDraft
    var state: State
    var lastError: String?

    init(actionID: UUID, idempotencyKey: String, draft: WorkoutPlanDraft, state: State = .queued, lastError: String? = nil) {
        self.actionID = actionID
        self.idempotencyKey = idempotencyKey
        self.draft = draft
        self.state = state
        self.lastError = lastError
    }

    func encodedNotes() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return Self.notesPrefix + data.base64EncodedString()
    }

    static func decode(notes: String?) -> ConfirmedWorkoutPlanEntry? {
        guard let notes, notes.hasPrefix(notesPrefix),
              let data = Data(base64Encoded: String(notes.dropFirst(notesPrefix.count))) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(ConfirmedWorkoutPlanEntry.self, from: data)
    }
}
