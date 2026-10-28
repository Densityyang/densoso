import CryptoKit
import DensosoDomain
import Foundation

extension ActionPayload {
    /// Hash the canonical payload bytes at the application persistence boundary.
    /// The Domain package remains Foundation-only while persisted SHA-256 hashes
    /// remain byte-for-byte compatible with existing confirmation records.
    func canonicalPayloadHash(
        schemaVersion: Int = ActionPayload.currentSchemaVersion
    ) throws -> String {
        let data = try canonicalData(schemaVersion: schemaVersion)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
