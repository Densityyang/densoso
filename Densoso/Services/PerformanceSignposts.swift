import Foundation
import OSLog

enum PerformanceSignposts {
    private static let signposter = OSSignposter(
        subsystem: "com.densoso.densoso",
        category: "Performance"
    )

    static func measure<T>(_ name: StaticString, operation: () throws -> T) rethrows -> T {
        let interval = signposter.beginInterval(name)
        defer { signposter.endInterval(name, interval) }
        return try operation()
    }

    @MainActor
    static func measureAsync<T>(
        _ name: StaticString,
        operation: () async throws -> T
    ) async rethrows -> T {
        let interval = signposter.beginInterval(name)
        defer { signposter.endInterval(name, interval) }
        return try await operation()
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    static func event(_ name: StaticString, count: Int) {
        signposter.emitEvent(name, "count: \(count, privacy: .public)")
    }

    static func event(
        _ name: StaticString,
        elapsedMillisecondsSince start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) {
        let elapsedMilliseconds = elapsedMilliseconds(since: start, clock: clock)
        signposter.emitEvent(name, "elapsed_ms: \(elapsedMilliseconds, privacy: .public)")
    }

    static func event(
        _ name: StaticString,
        count: Int,
        elapsedMillisecondsSince start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) {
        let elapsedMilliseconds = elapsedMilliseconds(since: start, clock: clock)
        signposter.emitEvent(
            name,
            "count: \(count, privacy: .public), elapsed_ms: \(elapsedMilliseconds, privacy: .public)"
        )
    }

    private static func elapsedMilliseconds(
        since start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> Int {
        let duration = start.duration(to: clock.now).components
        return max(
            Int(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000),
            0
        )
    }
}
