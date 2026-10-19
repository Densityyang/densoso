import DensosoDomain
import Foundation
import Observation
import UserNotifications

enum BriefNotificationKind: String, Sendable {
    case morning
    case evening
    case weekly
}

enum BriefNotificationError: LocalizedError, Equatable {
    case authorizationDenied
    case invalidTime

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "未获得通知权限，健康回顾提醒保持关闭。"
        case .invalidTime:
            "提醒时间无效，请选择一天中的有效时间。"
        }
    }
}

@MainActor
protocol BriefNotificationClient {
    func requestAuthorization() async throws -> Bool
    func schedule(identifier: String, title: String, body: String, hour: Int, minute: Int, weekday: Int?) async throws
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

    func schedule(identifier: String, title: String, body: String, hour: Int, minute: Int, weekday: Int?) async throws {
        var date = DateComponents()
        date.calendar = Calendar.current
        date.timeZone = Calendar.current.timeZone
        date.hour = hour
        date.minute = minute
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
    private static let legacyDailyKey = "briefNotifications.daily.enabled"
    private static let morningKey = "briefNotifications.morning.enabled"
    private static let eveningKey = "briefNotifications.evening.enabled"
    private static let weeklyKey = "briefNotifications.weekly.enabled"
    private static let morningHourKey = "briefNotifications.morning.hour"
    private static let morningMinuteKey = "briefNotifications.morning.minute"
    private static let eveningHourKey = "briefNotifications.evening.hour"
    private static let eveningMinuteKey = "briefNotifications.evening.minute"
    private static let legacyDailyIdentifier = "densoso.brief.daily"
    private static let morningIdentifier = "densoso.brief.morning"
    private static let eveningIdentifier = "densoso.brief.evening"
    private static let weeklyIdentifier = "densoso.brief.weekly"

    private let client: any BriefNotificationClient
    private let defaults: UserDefaults
    private(set) var morningEnabled: Bool
    private(set) var eveningEnabled: Bool
    private(set) var weeklyEnabled: Bool
    private(set) var morningHour: Int
    private(set) var morningMinute: Int
    private(set) var eveningHour: Int
    private(set) var eveningMinute: Int
    private(set) var lastError: String?
    private var latestSnapshot: DailyLoopSnapshot?

    /// Retained for older UI and preference migration from the single daily reminder.
    var dailyEnabled: Bool { morningEnabled }

    init(client: any BriefNotificationClient = UserNotificationBriefClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        self.morningEnabled = defaults.object(forKey: Self.morningKey) as? Bool
            ?? defaults.bool(forKey: Self.legacyDailyKey)
        self.eveningEnabled = defaults.bool(forKey: Self.eveningKey)
        self.weeklyEnabled = defaults.bool(forKey: Self.weeklyKey)
        self.morningHour = Self.storedInteger(Self.morningHourKey, defaults: defaults, fallback: 8)
        self.morningMinute = Self.storedInteger(Self.morningMinuteKey, defaults: defaults, fallback: 0)
        self.eveningHour = Self.storedInteger(Self.eveningHourKey, defaults: defaults, fallback: 21)
        self.eveningMinute = Self.storedInteger(Self.eveningMinuteKey, defaults: defaults, fallback: 0)
    }

    func setMorningEnabled(_ enabled: Bool) async throws {
        try await setEnabled(enabled, kind: .morning)
    }

    func setEveningEnabled(_ enabled: Bool) async throws {
        try await setEnabled(enabled, kind: .evening)
    }

    /// Compatibility for callers from the single daily reminder phase.
    func setDailyEnabled(_ enabled: Bool) async throws {
        try await setMorningEnabled(enabled)
    }

    func setWeeklyEnabled(_ enabled: Bool) async throws {
        try await setEnabled(enabled, kind: .weekly)
    }

    func setMorningTime(hour: Int, minute: Int) async throws {
        guard Self.isValidTime(hour: hour, minute: minute) else { throw BriefNotificationError.invalidTime }
        morningHour = hour
        morningMinute = minute
        defaults.set(hour, forKey: Self.morningHourKey)
        defaults.set(minute, forKey: Self.morningMinuteKey)
        if morningEnabled { try await schedule(.morning) }
    }

    func setEveningTime(hour: Int, minute: Int) async throws {
        guard Self.isValidTime(hour: hour, minute: minute) else { throw BriefNotificationError.invalidTime }
        eveningHour = hour
        eveningMinute = minute
        defaults.set(hour, forKey: Self.eveningHourKey)
        defaults.set(minute, forKey: Self.eveningMinuteKey)
        if eveningEnabled { try await schedule(.evening) }
    }

    /// Refreshes reminder copy from the latest local snapshot without invoking a provider.
    func updateSnapshot(_ snapshot: DailyLoopSnapshot?) async {
        latestSnapshot = snapshot
        do {
            if morningEnabled { try await schedule(.morning) }
            if eveningEnabled { try await schedule(.evening) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Reinstalls schedules the user already enabled without requesting permission again.
    func restoreSchedules(snapshot: DailyLoopSnapshot? = nil) async {
        latestSnapshot = snapshot
        client.remove(identifier: Self.legacyDailyIdentifier)
        do {
            if morningEnabled { try await schedule(.morning) }
            if eveningEnabled { try await schedule(.evening) }
            if weeklyEnabled { try await schedule(.weekly) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func setEnabled(_ enabled: Bool, kind: BriefNotificationKind) async throws {
        let identifier = Self.identifier(for: kind)
        if !enabled {
            client.remove(identifier: identifier)
            if kind == .morning { client.remove(identifier: Self.legacyDailyIdentifier) }
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
        if kind == .morning { client.remove(identifier: Self.legacyDailyIdentifier) }
        persist(true, kind: kind)
        lastError = nil
    }

    private func schedule(_ kind: BriefNotificationKind) async throws {
        switch kind {
        case .morning, .evening:
            let phase: DailyLoopPhase = kind == .morning ? .morning : .evening
            let copy = DailyLoopNotificationCopy.make(snapshot: latestSnapshot, phase: phase)
            let hour = kind == .morning ? morningHour : eveningHour
            let minute = kind == .morning ? morningMinute : eveningMinute
            try await client.schedule(
                identifier: Self.identifier(for: kind),
                title: copy.title,
                body: copy.body,
                hour: hour,
                minute: minute,
                weekday: nil
            )
        case .weekly:
            try await client.schedule(
                identifier: Self.weeklyIdentifier,
                title: "densoso 本周回顾",
                body: "打开应用查看上周趋势；通知不包含健康数值。",
                hour: 8,
                minute: 0,
                weekday: 2 // Calendar weekday 2 is Monday in the Gregorian calendar.
            )
        }
    }

    private func persist(_ enabled: Bool, kind: BriefNotificationKind) {
        switch kind {
        case .morning:
            morningEnabled = enabled
            defaults.set(enabled, forKey: Self.morningKey)
            defaults.set(enabled, forKey: Self.legacyDailyKey)
        case .evening:
            eveningEnabled = enabled
            defaults.set(enabled, forKey: Self.eveningKey)
        case .weekly:
            weeklyEnabled = enabled
            defaults.set(enabled, forKey: Self.weeklyKey)
        }
    }

    private static func identifier(for kind: BriefNotificationKind) -> String {
        switch kind {
        case .morning: return morningIdentifier
        case .evening: return eveningIdentifier
        case .weekly: return weeklyIdentifier
        }
    }

    private static func storedInteger(_ key: String, defaults: UserDefaults, fallback: Int) -> Int {
        guard let value = defaults.object(forKey: key) as? Int else { return fallback }
        return value
    }

    private static func isValidTime(hour: Int, minute: Int) -> Bool {
        (0..<24).contains(hour) && (0..<60).contains(minute)
    }
}

private struct DailyLoopNotificationCopy {
    let title: String
    let body: String

    static func make(snapshot: DailyLoopSnapshot?, phase: DailyLoopPhase) -> Self {
        let label = phase == .morning ? "早间" : "晚间"
        let title = "densoso \(label)健康回顾"
        if let headline = snapshot?.todayState?.headline,
           !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self(title: title, body: "\(headline)。打开 densoso 查看本地健康摘要。")
        }
        return Self(title: title, body: "打开 densoso 查看\(label)健康回顾。")
    }
}
