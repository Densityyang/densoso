import Foundation

struct ProviderLogMetadata: Codable, Equatable, Sendable {
    let requestID: UUID
    let provider: ProviderID
    let status: Int?
    let attempt: Int
    let latencyMilliseconds: Int
    let providerCode: String?
}

protocol ProviderLogSink: Sendable {
    func record(_ metadata: ProviderLogMetadata)
}

struct NoOpProviderLogSink: ProviderLogSink {
    func record(_ metadata: ProviderLogMetadata) {}
}

enum ProviderLogRedactor {
    static func metadata(
        requestID: UUID,
        provider: ProviderID,
        status: Int?,
        attempt: Int,
        latencyMilliseconds: Int,
        providerCode: String? = nil
    ) -> ProviderLogMetadata {
        ProviderLogMetadata(
            requestID: requestID,
            provider: provider,
            status: status,
            attempt: attempt,
            latencyMilliseconds: max(latencyMilliseconds, 0),
            providerCode: providerCode.map(safeProviderCode)
        )
    }

    private static func safeProviderCode(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowlist: Set<String> = [
            "authentication_error",
            "cancelled",
            "content_filter",
            "invalid_request_error",
            "malformed_response",
            "model_not_found",
            "rate_limit",
            "rate_limit_error",
            "request_too_large",
            "server_error",
            "timeout",
        ]
        return allowlist.contains(normalized) ? normalized : "redacted"
    }
}
