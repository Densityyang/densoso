import Foundation
import DensosoDomain

struct ProviderLogMetadata: Codable, Equatable, Sendable {
    let requestID: UUID
    let provider: ProviderID
    let model: String
    let status: Int?
    let attempt: Int
    let latencyMilliseconds: Int
    let providerCode: String?
    let recordedAt: Date
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
        providerCode: String? = nil,
        model: String? = nil,
        recordedAt: Date = Date()
    ) -> ProviderLogMetadata {
        ProviderLogMetadata(
            requestID: requestID,
            provider: provider,
            model: model.map(safeModel) ?? "unknown",
            status: status,
            attempt: max(attempt, 0),
            latencyMilliseconds: max(latencyMilliseconds, 0),
            providerCode: providerCode.map(safeProviderCode),
            recordedAt: recordedAt
        )
    }

    static func safeProviderCode(_ raw: String) -> String {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sharedCode = SharedErrorCode(rawValue: candidate) {
            return sharedCode.rawValue
        }
        let normalized = candidate.lowercased()
        let legacyAllowlist: Set<String> = [
            "authentication_error",
            "budget_exceeded",
            "cancelled",
            "consent_required",
            "configuration_missing",
            "content_filter",
            "invalid_request_error",
            "malformed_response",
            "model_not_found",
            "network_error",
            "quota_exhausted",
            "rate_limit",
            "rate_limit_error",
            "request_too_large",
            "schema_violation",
            "server_error",
            "timeout",
            "unsupported_capability",
        ]
        return legacyAllowlist.contains(normalized) ? normalized : "redacted"
    }

    static func safeModel(_ raw: String) -> String {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowlist: Set<String> = [
            "deepseek-flash",
            "qwen-flash",
            "qwen3-asr-flash",
            "qwen3.7-flash-2026-07-15",
        ]
        return allowlist.contains(candidate.lowercased()) ? candidate.lowercased() : "redacted"
    }

    static func errorCode(for error: Error) -> String {
        guard let error = error as? ProviderError else {
            return SharedErrorCode.providerUnavailable.rawValue
        }
        return error.sharedErrorDescriptor.code.rawValue
    }
}

/// Bounded in-memory metadata used only when the user explicitly exports diagnostics.
final class ProviderLogBuffer: ProviderLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var entries: [ProviderLogMetadata] = []

    init(capacity: Int = 100) {
        self.capacity = max(capacity, 1)
    }

    func record(_ metadata: ProviderLogMetadata) {
        lock.lock()
        entries.append(metadata)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
    }

    func recent(since date: Date, limit: Int = 50) -> [ProviderLogMetadata] {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return Array(snapshot
            .filter { $0.recordedAt >= date }
            .sorted { $0.recordedAt < $1.recordedAt }
            .suffix(max(limit, 0)))
    }
}
