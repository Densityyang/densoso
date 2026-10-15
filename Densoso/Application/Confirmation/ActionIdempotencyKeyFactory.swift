import CryptoKit
import DensosoDomain
import Foundation

struct ActionIdempotencyKeyFactory: Sendable {
    func make(
        actionType: ActionType,
        canonicalPayloadData: Data,
        clientRequestID: UUID
    ) -> String {
        var data = Data(actionType.rawValue.utf8)
        data.append(Data("|".utf8))
        data.append(canonicalPayloadData)
        data.append(Data("|".utf8))
        data.append(Data(clientRequestID.uuidString.lowercased().utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
