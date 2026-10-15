import Foundation
import Observation
import UserNotifications

enum BriefNotificationKind: String, Sendable {
    case daily
    case weekly
}

enum BriefNotificationError: LocalizedError, Equatable {
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "未获得通知权限，日报和周报提醒保持关闭。"
        }
    }
}

@MainActor
protocol BriefNotificationClient {
    func requestAuthorization() async throws -> Bool
    func schedule(identifier: String, title: String, body: String, hour: Int, weekday: Int?) async throws
    func remove(identifier: String)
}

@MainActor
final class UserNotificationBriefClient: BriefNotificationClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func schedule(identifier: String, title: String, body: String, hour: Int, weekday: Int?) async throws {
        var date = DateComponents()
        date.calendar = Calendar.current
        date.timeZone = Calendar.current.timeZone
        date.hour = hour
        date.minute = 0
        date.weekday = weekday

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
        )
        try await center.add(request)
    }

    func remove(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

@MainActor
@Observable
final class BriefNotificationScheduler {
    private static let dailyKey = "briefNotifications.daily.enabled"
    private static let weeklyKey = "briefNotifications.weekly.enabled"
    private static let dailyIdentifier = "densoso.brief.daily"
    private static let weeklyIdentifier = "densoso.brief.weekly"

    private let client: any BriefNotificationClient
    private let defaults: UserDefaults
    private(set) var dailyEnabled: Bool
    private(set) var weeklyEnabled: Bool
    private(set) var lastError: String?

    init(client: any BriefNotificationClient = UserNotificationBriefClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        self.dailyEnabled = defaults.bool(forKey: Self.dailyKey)
        self.weeklyEnabled = defaults.bool(forKey: Self.weeklyKey)
    }

    func setDailyEnabled(_ enabled: Bool) async throws {
        try await setEnabled(enabled, kind: .daily)
    }

    func setWeeklyEnabled(_ enabled: Bool) async throws {
        try await setEnabled(enabled, kind: .weekly)
    }

    /// Reinstalls schedules the user already enabled without requesting permission again.
    func restoreSchedules() async {
        do {
            if dailyEnabled { try await schedule(.daily) }
            if weeklyEnabled { try await schedule(.weekly) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func setEnabled(_ enabled: Bool, kind: BriefNotificationKind) async throws {
        let identifier = kind == .daily ? Self.dailyIdentifier : Self.weeklyIdentifier
        if !enabled {
            client.remove(identifier: identifier)
            persist(false, kind: kind)
            lastError = nil
            return
        }

        guard try await client.requestAuthorization() else {
            persist(false, kind: kind)
            client.remove(identifier: identifier)
            lastError = BriefNotificationError.authorizationDenied.localizedDescription
            throw BriefNotificationError.authorizationDenied
        }
        try await schedule(kind)
        persist(true, kind: kind)
        lastError = nil
    }

    private func schedule(_ kind: BriefNotificationKind) async throws {
        switch kind {
        case .daily:
            try await client.schedule(
                identifier: Self.dailyIdentifier,
                title: "densoso 今日摘要",
                body: "打开应用查看本地健康摘要；通知不包含健康数值。",
                hour: 8,
                weekday: nil
            )
        case .weekly:
            try await client.schedule(
                identifier: Self.weeklyIdentifier,
                title: "densoso 本周回顾",
                body: "打开应用查看上周趋势；通知不包含健康数值。",
                hour: 8,
                weekday: 2 // Calendar weekday 2 is Monday in the Gregorian calendar.
            )
        }
    }

    private func persist(_ enabled: Bool, kind: BriefNotificationKind) {
        switch kind {
        case .daily:
            dailyEnabled = enabled
            defaults.set(enabled, forKey: Self.dailyKey)
        case .weekly:
            weeklyEnabled = enabled
            defaults.set(enabled, forKey: Self.weeklyKey)
        }
    }
}
