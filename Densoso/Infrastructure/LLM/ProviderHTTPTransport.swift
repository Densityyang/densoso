import Foundation

protocol ProviderHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class URLSessionProviderTransport: ProviderHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ProviderError.malformedResponse
        }
        return (data, response)
    }
}

protocol ProviderRetryClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

struct SystemProviderRetryClock: ProviderRetryClock {
    func now() -> Date { Date() }

    func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}

struct ProviderHTTPResult: Sendable {
    let data: Data
    let response: HTTPURLResponse
    let attempt: Int
}

struct ProviderRequestExecutor: Sendable {
    let transport: any ProviderHTTPTransport
    let clock: any ProviderRetryClock
    let maximumRetries: Int
    let jitter: @Sendable (Int) -> Double

    init(
        transport: any ProviderHTTPTransport,
        clock: any ProviderRetryClock = SystemProviderRetryClock(),
        maximumRetries: Int = 2,
        jitter: @escaping @Sendable (Int) -> Double = { _ in Double.random(in: 0...0.25) }
    ) {
        self.transport = transport
        self.clock = clock
        self.maximumRetries = maximumRetries
        self.jitter = jitter
    }

    func execute(_ request: URLRequest, deadline: Date) async throws -> ProviderHTTPResult {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            guard clock.now() < deadline else { throw ProviderError.timeout }
            attempt += 1
            do {
                let (data, response) = try await data(for: request, deadline: deadline)
                switch response.statusCode {
                case 200...299:
                    return ProviderHTTPResult(data: data, response: response, attempt: attempt)
                case 401, 403:
                    throw ProviderError.unauthorized(status: response.statusCode)
                case 429:
                    let retryAfter = retryAfterSeconds(response: response)
                    guard attempt <= maximumRetries else {
                        throw ProviderError.rateLimited(retryAfterSeconds: retryAfter)
                    }
                    try await waitBeforeRetry(
                        attempt: attempt,
                        retryAfterSeconds: retryAfter,
                        deadline: deadline
                    )
                case 500...599:
                    guard attempt <= maximumRetries else {
                        throw ProviderError.server(status: response.statusCode)
                    }
                    try await waitBeforeRetry(attempt: attempt, deadline: deadline)
                default:
                    throw ProviderError.requestRejected(status: response.statusCode)
                }
            } catch is CancellationError {
                throw ProviderError.cancelled
            } catch let error as ProviderError {
                throw error
            } catch let error as URLError {
                if error.code == .cancelled { throw ProviderError.cancelled }
                if error.code == .timedOut, attempt > maximumRetries { throw ProviderError.timeout }
                guard attempt <= maximumRetries else {
                    throw ProviderError.network(code: error.errorCode)
                }
                try await waitBeforeRetry(attempt: attempt, deadline: deadline)
            } catch {
                guard attempt <= maximumRetries else {
                    throw ProviderError.network(code: nil)
                }
                try await waitBeforeRetry(attempt: attempt, deadline: deadline)
            }
        }
    }

    private func data(
        for request: URLRequest,
        deadline: Date
    ) async throws -> (Data, HTTPURLResponse) {
        let remaining = deadline.timeIntervalSince(clock.now())
        guard remaining > 0 else { throw ProviderError.timeout }

        var boundedRequest = request
        boundedRequest.timeoutInterval = max(remaining, 0.001)

        return try await withThrowingTaskGroup(of: DeadlineRaceResult.self) { group in
            group.addTask {
                let (data, response) = try await transport.data(for: boundedRequest)
                return .response(data, response)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(remaining))
                return .deadlineReached
            }
            defer { group.cancelAll() }

            guard let first = try await group.next() else {
                throw ProviderError.malformedResponse
            }
            switch first {
            case .response(let data, let response):
                return (data, response)
            case .deadlineReached:
                throw ProviderError.timeout
            }
        }
    }

    private func waitBeforeRetry(
        attempt: Int,
        retryAfterSeconds: Double? = nil,
        deadline: Date
    ) async throws {
        let exponential = min(pow(2, Double(max(attempt - 1, 0))) * 0.5, 8)
        let delay = max(retryAfterSeconds ?? exponential, 0) + max(jitter(attempt), 0)
        guard clock.now().addingTimeInterval(delay) < deadline else {
            throw ProviderError.timeout
        }
        do {
            try await clock.sleep(seconds: delay)
        } catch is CancellationError {
            throw ProviderError.cancelled
        }
    }

    private func retryAfterSeconds(response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(date.timeIntervalSince(clock.now()), 0)
    }
}

private enum DeadlineRaceResult: @unchecked Sendable {
    case response(Data, HTTPURLResponse)
    case deadlineReached
}
