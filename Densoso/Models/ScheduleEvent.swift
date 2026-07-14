import Foundation
import SwiftData

@Model
final class ScheduleEvent {
    var date: Date
    var title: String
    var notes: String?
    var startTime: Date
    var endTime: Date?
    var createdAt: Date

    init(
        date: Date = Date(),
        title: String = "",
        notes: String? = nil,
        startTime: Date = Date(),
        endTime: Date? = nil
    ) {
        self.date = date
        self.title = title
        self.notes = notes
        self.startTime = startTime
        self.endTime = endTime
        self.createdAt = Date()
    }
}