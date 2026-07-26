import CryptoKit
import Foundation
import SwiftData

@MainActor
@Observable
final class ExportService {
    var lastExportDate: Date?
    var isExporting = false
    var lastError: String?

    private static let formatVersion = 2

    struct BackupDocument: Codable {
        let formatVersion: Int
        let checksum: String
        let payload: BackupPayload
    }

    struct BackupPayload: Codable {
        let exportedAt: Date
        let userProfile: UserProfileExport?
        let mealRecords: [MealRecordExport]
        let workoutRecords: [WorkoutRecordExport]

        struct UserProfileExport: Codable {
            let name: String
            let biologicalSex: String
            let dateOfBirth: Date
            let heightCm: Double
            let weightKg: Double
            let weightHistoryJSON: String
            let activityLevel: String
            let dailyDeficitTarget: Int
            let createdAt: Date
            let updatedAt: Date
        }

        struct MealRecordExport: Codable {
            let id: UUID
            let date: Date
            let mealType: String
            let totalCaloriesKcal: Int
            let proteinG: Double
            let fatG: Double
            let carbsG: Double
            let notes: String?
            let confidence: String
            let algorithmVersion: String
            let createdAt: Date
            let dishes: [DishExport]
        }

        struct DishExport: Codable {
            let dishName: String
            let cookingMethod: String?
            let ingredientJSON: String
            let estimatedCaloriesKcal: Int
            let estimatedProteinG: Double
            let estimatedFatG: Double
            let estimatedCarbsG: Double
            let confidenceScore: Double
            let userCorrectionFactor: Double?
            let createdAt: Date
        }

        struct WorkoutRecordExport: Codable {
            let id: UUID
            let date: Date
            let type: String
            let durationMinutes: Int
            let estimatedCaloriesBurned: Int
            let intensity: String
            let notes: String?
            let createdAt: Date
            let updatedAt: Date?
            let healthKitUUID: UUID?
            let logicalSessionID: UUID?
            let workoutOrigin: String?
            let energySource: String?
            let sourceBundleIdentifier: String?
            let sourceVersion: String?
            let sourceRevision: String?
            let deviceName: String?
            let deviceModel: String?
            let dataQuality: String?
            let routeStatus: String?
            let routePointCount: Int?
        }
    }

    enum BackupError: LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version): "Unsupported backup version: \(version)"
            case .checksumMismatch: "The backup file did not pass its integrity check."
            }
        }
    }

    func exportJSON(context: ModelContext) async throws -> URL {
        isExporting = true
        defer { isExporting = false }

        let payload = try makePayload(context: context)
        let document = BackupDocument(
            formatVersion: Self.formatVersion,
            checksum: try checksum(for: payload),
            payload: payload
        )
        let data = try encoder.encode(document)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso_backup_\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )

        lastExportDate = Date()
        return url
    }

    /// Validates the entire file before replacing local data, then reprojects derived metrics.
    func restoreJSON(url: URL, context: ModelContext) async throws -> ImportSummary {
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(BackupDocument.self, from: data)
        guard document.formatVersion == Self.formatVersion else {
            throw BackupError.unsupportedVersion(document.formatVersion)
        }
        guard try checksum(for: document.payload) == document.checksum else {
            throw BackupError.checksumMismatch
        }

        do {
            try context.delete(model: UserProfile.self)
            try context.delete(model: MealRecord.self)
            try context.delete(model: WorkoutRecord.self)
            try context.delete(model: DailyMetrics.self)
            try context.delete(model: HealthSyncOutboxEntry.self)
            try context.delete(model: HealthKitImportCursor.self)

            if let source = document.payload.userProfile {
                let profile = UserProfile(
                    name: source.name,
                    biologicalSex: source.biologicalSex,
                    dateOfBirth: source.dateOfBirth,
                    heightCm: source.heightCm,
                    weightKg: source.weightKg,
                    activityLevel: source.activityLevel,
                    dailyDeficitTarget: source.dailyDeficitTarget
                )
                profile.weightHistoryJSON = source.weightHistoryJSON
                profile.createdAt = source.createdAt
                profile.updatedAt = source.updatedAt
                context.insert(profile)
            }

            let affectedDays = Set(document.payload.mealRecords.map(\.date) + document.payload.workoutRecords.map(\.date))
            for source in document.payload.mealRecords {
                let meal = MealRecord(
                    date: source.date,
                    mealType: source.mealType,
                    totalCaloriesKcal: source.totalCaloriesKcal,
                    proteinG: source.proteinG,
                    fatG: source.fatG,
                    carbsG: source.carbsG,
                    notes: source.notes,
                    confidence: source.confidence,
                    algorithmVersion: source.algorithmVersion
                )
                meal.id = source.id
                meal.createdAt = source.createdAt
                meal.dishes = source.dishes.map { dishSource in
                    let dish = DishEntry(
                        dishName: dishSource.dishName,
                        cookingMethod: dishSource.cookingMethod,
                        ingredientJSON: dishSource.ingredientJSON,
                        estimatedCaloriesKcal: dishSource.estimatedCaloriesKcal,
                        estimatedProteinG: dishSource.estimatedProteinG,
                        estimatedFatG: dishSource.estimatedFatG,
                        estimatedCarbsG: dishSource.estimatedCarbsG,
                        confidenceScore: dishSource.confidenceScore,
                        userCorrectionFactor: dishSource.userCorrectionFactor
                    )
                    dish.createdAt = dishSource.createdAt
                    return dish
                }
                context.insert(meal)
            }

            for source in document.payload.workoutRecords {
                let workout = WorkoutRecord(
                    date: source.date,
                    type: source.type,
                    durationMinutes: source.durationMinutes,
                    estimatedCaloriesBurned: source.estimatedCaloriesBurned,
                    intensity: source.intensity,
                    notes: source.notes,
                    healthKitUUID: source.healthKitUUID,
                    logicalSessionID: source.logicalSessionID,
                    workoutOrigin: source.workoutOrigin ?? "userEntered",
                    energySource: source.energySource,
                    sourceBundleIdentifier: source.sourceBundleIdentifier,
                    sourceVersion: source.sourceVersion,
                    sourceRevision: source.sourceRevision,
                    deviceName: source.deviceName,
                    deviceModel: source.deviceModel,
                    dataQuality: source.dataQuality ?? "complete",
                    routeStatus: source.routeStatus ?? "unavailable",
                    routePointCount: source.routePointCount
                )
                workout.id = source.id
                workout.createdAt = source.createdAt
                workout.updatedAt = source.updatedAt ?? source.createdAt
                context.insert(workout)
            }

            for date in affectedDays {
                try DailyMetricsProjector.reproject(on: date, in: context)
            }
            try context.save()

            return ImportSummary(
                meals: document.payload.mealRecords.count,
                workouts: document.payload.workoutRecords.count,
                dailyMetrics: affectedDays.count
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    struct ImportSummary {
        let meals: Int
        let workouts: Int
        let dailyMetrics: Int
    }

    private func makePayload(context: ModelContext) throws -> BackupPayload {
        let profile = try context.fetch(FetchDescriptor<UserProfile>()).first
        let meals = try context.fetch(FetchDescriptor<MealRecord>())
        let workouts = try context.fetch(FetchDescriptor<WorkoutRecord>())

        return BackupPayload(
            exportedAt: Date(),
            userProfile: profile.map { source in
                .init(
                    name: source.name,
                    biologicalSex: source.biologicalSex,
                    dateOfBirth: source.dateOfBirth,
                    heightCm: source.heightCm,
                    weightKg: source.weightKg,
                    weightHistoryJSON: source.weightHistoryJSON,
                    activityLevel: source.activityLevel,
                    dailyDeficitTarget: source.dailyDeficitTarget,
                    createdAt: source.createdAt,
                    updatedAt: source.updatedAt
                )
            },
            mealRecords: meals.map { source in
                .init(
                    id: source.id,
                    date: source.date,
                    mealType: source.mealType,
                    totalCaloriesKcal: source.totalCaloriesKcal,
                    proteinG: source.proteinG,
                    fatG: source.fatG,
                    carbsG: source.carbsG,
                    notes: source.notes,
                    confidence: source.confidence,
                    algorithmVersion: source.algorithmVersion,
                    createdAt: source.createdAt,
                    dishes: source.dishes.map { dish in
                        .init(
                            dishName: dish.dishName,
                            cookingMethod: dish.cookingMethod,
                            ingredientJSON: dish.ingredientJSON,
                            estimatedCaloriesKcal: dish.estimatedCaloriesKcal,
                            estimatedProteinG: dish.estimatedProteinG,
                            estimatedFatG: dish.estimatedFatG,
                            estimatedCarbsG: dish.estimatedCarbsG,
                            confidenceScore: dish.confidenceScore,
                            userCorrectionFactor: dish.userCorrectionFactor,
                            createdAt: dish.createdAt
                        )
                    }
                )
            },
            workoutRecords: workouts.map { source in
                .init(
                    id: source.id,
                    date: source.date,
                    type: source.type,
                    durationMinutes: source.durationMinutes,
                    estimatedCaloriesBurned: source.estimatedCaloriesBurned,
                    intensity: source.intensity,
                    notes: source.notes,
                    createdAt: source.createdAt,
                    updatedAt: source.updatedAt,
                    healthKitUUID: source.healthKitUUID,
                    logicalSessionID: source.logicalSessionID,
                    workoutOrigin: source.workoutOrigin,
                    energySource: source.energySource,
                    sourceBundleIdentifier: source.sourceBundleIdentifier,
                    sourceVersion: source.sourceVersion,
                    sourceRevision: source.sourceRevision,
                    deviceName: source.deviceName,
                    deviceModel: source.deviceModel,
                    dataQuality: source.dataQuality,
                    routeStatus: source.routeStatus,
                    routePointCount: source.routePointCount
                )
            }
        )
    }

    private func checksum(for payload: BackupPayload) throws -> String {
        let digest = SHA256.hash(data: try encoder.encode(payload))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
