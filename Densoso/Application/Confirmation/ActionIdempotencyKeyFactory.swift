import CryptoKit
import DensosoDomain
import Foundation

struct ActionIdempotencyKeyFactory: Sendable {
    func make(
        actionType: ActionType,
        canonicalPayloadData: Data,
        clientRequestID: UUID,
        invocationID: String? = nil
    ) -> String {
        var data = Data(actionType.rawValue.utf8)
        data.append(Data("|".utf8))
        if let invocationID {
            data.append(Data("invocation:".utf8))
            data.append(Data(invocationID.utf8))
            data.append(Data("|".utf8))
            data.append(Data(clientRequestID.uuidString.lowercased().utf8))
        } else {
            // Preserve request/payload idempotency for direct, non-Agent callers.
            data.append(canonicalPayloadData)
            data.append(Data("|".utf8))
            data.append(Data(clientRequestID.uuidString.lowercased().utf8))
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
