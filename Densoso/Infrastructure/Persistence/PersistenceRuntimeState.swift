import Foundation

enum PersistenceRuntimeState: Equatable, Sendable {
    case writable
    case recoveryReadOnly(diagnosticID: String, backupStoreURL: URL, sourceVersion: String?)
    case diagnosticOnly(diagnosticID: String, backupStoreURL: URL?)

    var allowsWrites: Bool {
        if case .writable = self { return true }
        return false
    }

    var diagnosticID: String? {
        switch self {
        case .writable: nil
        case .recoveryReadOnly(let id, _, _), .diagnosticOnly(let id, _): id
        }
    }
}

enum PersistenceWriteError: LocalizedError, Equatable {
    case recoveryReadOnly(diagnosticID: String)

    var errorDescription: String? {
        switch self {
        case .recoveryReadOnly(let diagnosticID):
            "本地数据正处于只读恢复模式（诊断编号 \(diagnosticID)），未写入任何新记录。"
        }
    }
}

struct PersistenceWriteGate: Sendable {
    let state: PersistenceRuntimeState

    func requireWritable() throws {
        guard state.allowsWrites else {
            throw PersistenceWriteError.recoveryReadOnly(
                diagnosticID: state.diagnosticID ?? "unknown"
            )
        }
    }
}
