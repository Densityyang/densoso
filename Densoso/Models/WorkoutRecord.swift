import Foundation
import SwiftData

@Model
final class WorkoutRecord {
    @Attribute(.unique) var id: UUID = UUID()
    var date: Date
    var type: String             // running / walking / cycling / swimming / strength / hiit / yoga / other
    var durationMinutes: Int
    var estimatedCaloriesBurned: Int
    var intensity: String        // light / moderate / vigorous
    var notes: String?
    var createdAt: Date
    var updatedAt: Date
    var healthKitUUID: UUID?
    var logicalSessionID: UUID?
    var workoutOrigin: String
    var energySource: String?
    var sourceBundleIdentifier: String?
    var sourceVersion: String?
    var sourceRevision: String?
    var deviceName: String?
    var deviceModel: String?
    var dataQuality: String
    var routeStatus: String
    var routePointCount: Int?

    init(
        date: Date = Date(),
        type: String = "other",
        durationMinutes: Int = 0,
        estimatedCaloriesBurned: Int = 0,
        intensity: String = "moderate",
        notes: String? = nil,
        healthKitUUID: UUID? = nil,
        logicalSessionID: UUID? = nil,
        workoutOrigin: String = "userEntered",
        energySource: String? = "userEntered",
        sourceBundleIdentifier: String? = nil,
        sourceVersion: String? = nil,
        sourceRevision: String? = nil,
        deviceName: String? = nil,
        deviceModel: String? = nil,
        dataQuality: String = "complete",
        routeStatus: String = "unavailable",
        routePointCount: Int? = nil
    ) {
        self.date = date
        self.type = type
        self.durationMinutes = durationMinutes
        self.estimatedCaloriesBurned = estimatedCaloriesBurned
        self.intensity = intensity
        self.notes = notes
        self.createdAt = Date()
        self.updatedAt = Date()
        self.healthKitUUID = healthKitUUID
        self.logicalSessionID = logicalSessionID
        self.workoutOrigin = workoutOrigin
        self.energySource = energySource
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceVersion = sourceVersion
        self.sourceRevision = sourceRevision
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.dataQuality = dataQuality
        self.routeStatus = routeStatus
        self.routePointCount = routePointCount
    }
}
