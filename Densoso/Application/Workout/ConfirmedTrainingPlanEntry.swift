import DensosoDomain
import Foundation

struct ConfirmedTrainingPlanEntry: Codable, Equatable, Sendable {
    enum State: String, Codable, Equatable, Sendable {
        case queued
        case retryable
        case scheduled
        case terminal
    }

    static let notesPrefix = "densoso-training-plan-v1:"

    let actionID: UUID
    let idempotencyKey: String
    let draft: TrainingPlanDraft
    var scheduledSessionIDs: [UUID]
    var state: State
    var lastError: String?

    init(
        actionID: UUID,
        idempotencyKey: String,
        draft: TrainingPlanDraft,
        scheduledSessionIDs: [UUID] = [],
        state: State = .queued,
        lastError: String? = nil
    ) {
        self.actionID = actionID
        self.idempotencyKey = idempotencyKey
        self.draft = draft
        self.scheduledSessionIDs = Array(Set(scheduledSessionIDs)).sorted { $0.uuidString < $1.uuidString }
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

    static func decode(notes: String?) -> ConfirmedTrainingPlanEntry? {
        guard let notes, notes.hasPrefix(notesPrefix),
              let data = Data(base64Encoded: String(notes.dropFirst(notesPrefix.count))) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(ConfirmedTrainingPlanEntry.self, from: data)
    }
}
