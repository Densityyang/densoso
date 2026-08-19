import DensosoDomain
import Foundation

enum PersistenceEnumError: Error, Equatable {
    case unknownValue(field: String, rawValue: String)
}

extension DensosoSchemaV3.PendingActionRecord {
    var state: PendingActionState {
        get throws {
            guard let state = PendingActionState(rawValue: stateRaw) else {
                throw PersistenceEnumError.unknownValue(field: "PendingActionRecord.stateRaw", rawValue: stateRaw)
            }
            return state
        }
    }
}

extension DensosoSchemaV3.HealthSyncOutboxEntry {
    var syncState: HealthSyncState {
        get throws {
            guard let state = HealthSyncState(rawValue: self.state) else {
                throw PersistenceEnumError.unknownValue(field: "HealthSyncOutboxEntry.state", rawValue: self.state)
            }
            return state
        }
    }
}

extension DensosoSchemaV3.CommittedActionReceiptRecord {
    var healthSyncState: HealthSyncState {
        get throws {
            guard let state = HealthSyncState(rawValue: healthSyncStateRaw) else {
                throw PersistenceEnumError.unknownValue(
                    field: "CommittedActionReceiptRecord.healthSyncStateRaw",
                    rawValue: healthSyncStateRaw
                )
            }
            return state
        }
    }
}
