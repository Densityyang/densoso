import Foundation
import SwiftData

@Model
final class WorkoutRecord {
    var id: UUID = UUID()
    var date: Date
    var type: String             // running / walking / cycling / swimming / strength / hiit / yoga / other
    var durationMinutes: Int
    var estimatedCaloriesBurned: Int
    var intensity: String        // light / moderate / vigorous
    var notes: String?
    var createdAt: Date

    init(
        date: Date = Date(),
        type: String = "other",
        durationMinutes: Int = 0,
        estimatedCaloriesBurned: Int = 0,
        intensity: String = "moderate",
        notes: String? = nil
    ) {
        self.date = date
        self.type = type
        self.durationMinutes = durationMinutes
        self.estimatedCaloriesBurned = estimatedCaloriesBurned
        self.intensity = intensity
        self.notes = notes
        self.createdAt = Date()
    }
}