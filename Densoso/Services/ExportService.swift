import CryptoKit
import Foundation
import SwiftData

@MainActor
@Observable
final class ExportService {
    var lastExportDate: Date?
    var isExporting = false
    var lastError: String?

    private static let formatVersion = 3
    private static let supportedFormatVersions: Set<Int> = [2, 3]

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
            let sourceActionKey: String?
            let energyLowKcal: Double?
            let energyLikelyKcal: Double?
            let energyHighKcal: Double?
            let proteinLowG: Double?
            let proteinLikelyG: Double?
            let proteinHighG: Double?
            let fatLowG: Double?
            let fatLikelyG: Double?
            let fatHighG: Double?
            let carbsLowG: Double?
            let carbsLikelyG: Double?
            let carbsHighG: Double?
            let evidenceData: Data?
            let dishes: [DishExport]

            private enum CodingKeys: String, CodingKey {
                case id, date, mealType, totalCaloriesKcal, proteinG, fatG, carbsG
                case notes, confidence, algorithmVersion, createdAt, sourceActionKey
                case energyLowKcal, energyLikelyKcal, energyHighKcal
                case proteinLowG, proteinLikelyG, proteinHighG
                case fatLowG, fatLikelyG, fatHighG
                case carbsLowG, carbsLikelyG, carbsHighG, evidenceData, dishes
            }

            init(
                id: UUID,
                date: Date,
                mealType: String,
                totalCaloriesKcal: Int,
                proteinG: Double,
                fatG: Double,
                carbsG: Double,
                notes: String?,
                confidence: String,
                algorithmVersion: String,
                createdAt: Date,
                sourceActionKey: String? = nil,
                energyLowKcal: Double? = nil,
                energyLikelyKcal: Double? = nil,
                energyHighKcal: Double? = nil,
                proteinLowG: Double? = nil,
                proteinLikelyG: Double? = nil,
                proteinHighG: Double? = nil,
                fatLowG: Double? = nil,
                fatLikelyG: Double? = nil,
                fatHighG: Double? = nil,
                carbsLowG: Double? = nil,
                carbsLikelyG: Double? = nil,
                carbsHighG: Double? = nil,
                evidenceData: Data? = nil,
                dishes: [DishExport]
            ) {
                self.id = id
                self.date = date
                self.mealType = mealType
                self.totalCaloriesKcal = totalCaloriesKcal
                self.proteinG = proteinG
                self.fatG = fatG
                self.carbsG = carbsG
                self.notes = notes
                self.confidence = confidence
                self.algorithmVersion = algorithmVersion
                self.createdAt = createdAt
                self.sourceActionKey = sourceActionKey
                self.energyLowKcal = energyLowKcal
                self.energyLikelyKcal = energyLikelyKcal
                self.energyHighKcal = energyHighKcal
                self.proteinLowG = proteinLowG
                self.proteinLikelyG = proteinLikelyG
                self.proteinHighG = proteinHighG
                self.fatLowG = fatLowG
                self.fatLikelyG = fatLikelyG
                self.fatHighG = fatHighG
                self.carbsLowG = carbsLowG
                self.carbsLikelyG = carbsLikelyG
                self.carbsHighG = carbsHighG
                self.evidenceData = evidenceData
                self.dishes = dishes
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(UUID.self, forKey: .id)
                date = try container.decode(Date.self, forKey: .date)
                mealType = try container.decode(String.self, forKey: .mealType)
                totalCaloriesKcal = try container.decode(Int.self, forKey: .totalCaloriesKcal)
                proteinG = try container.decode(Double.self, forKey: .proteinG)
                fatG = try container.decode(Double.self, forKey: .fatG)
                carbsG = try container.decode(Double.self, forKey: .carbsG)
                notes = try container.decodeIfPresent(String.self, forKey: .notes)
                confidence = try container.decode(String.self, forKey: .confidence)
                algorithmVersion = try container.decode(String.self, forKey: .algorithmVersion)
                createdAt = try container.decode(Date.self, forKey: .createdAt)
                sourceActionKey = try container.decodeIfPresent(String.self, forKey: .sourceActionKey)
                energyLowKcal = try container.decodeIfPresent(Double.self, forKey: .energyLowKcal)
                energyLikelyKcal = try container.decodeIfPresent(Double.self, forKey: .energyLikelyKcal)
                energyHighKcal = try container.decodeIfPresent(Double.self, forKey: .energyHighKcal)
                proteinLowG = try container.decodeIfPresent(Double.self, forKey: .proteinLowG)
                proteinLikelyG = try container.decodeIfPresent(Double.self, forKey: .proteinLikelyG)
                proteinHighG = try container.decodeIfPresent(Double.self, forKey: .proteinHighG)
                fatLowG = try container.decodeIfPresent(Double.self, forKey: .fatLowG)
                fatLikelyG = try container.decodeIfPresent(Double.self, forKey: .fatLikelyG)
                fatHighG = try container.decodeIfPresent(Double.self, forKey: .fatHighG)
                carbsLowG = try container.decodeIfPresent(Double.self, forKey: .carbsLowG)
                carbsLikelyG = try container.decodeIfPresent(Double.self, forKey: .carbsLikelyG)
                carbsHighG = try container.decodeIfPresent(Double.self, forKey: .carbsHighG)
                evidenceData = try container.decodeIfPresent(Data.self, forKey: .evidenceData)
                dishes = try container.decode([DishExport].self, forKey: .dishes)
            }
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
            let id: UUID?
            let energyLowKcal: Double?
            let energyLikelyKcal: Double?
            let energyHighKcal: Double?
            let proteinLowG: Double?
            let proteinLikelyG: Double?
            let proteinHighG: Double?
            let fatLowG: Double?
            let fatLikelyG: Double?
            let fatHighG: Double?
            let carbsLowG: Double?
            let carbsLikelyG: Double?
            let carbsHighG: Double?
            let portionLowG: Double?
            let portionLikelyG: Double?
            let portionHighG: Double?
            let evidenceData: Data?
            let algorithmVersion: String?

            init(
                dishName: String,
                cookingMethod: String?,
                ingredientJSON: String,
                estimatedCaloriesKcal: Int,
                estimatedProteinG: Double,
                estimatedFatG: Double,
                estimatedCarbsG: Double,
                confidenceScore: Double,
                userCorrectionFactor: Double?,
                createdAt: Date,
                id: UUID? = nil,
                energyLowKcal: Double? = nil,
                energyLikelyKcal: Double? = nil,
                energyHighKcal: Double? = nil,
                proteinLowG: Double? = nil,
                proteinLikelyG: Double? = nil,
                proteinHighG: Double? = nil,
                fatLowG: Double? = nil,
                fatLikelyG: Double? = nil,
                fatHighG: Double? = nil,
                carbsLowG: Double? = nil,
                carbsLikelyG: Double? = nil,
                carbsHighG: Double? = nil,
                portionLowG: Double? = nil,
                portionLikelyG: Double? = nil,
                portionHighG: Double? = nil,
                evidenceData: Data? = nil,
                algorithmVersion: String? = nil
            ) {
                self.dishName = dishName
                self.cookingMethod = cookingMethod
                self.ingredientJSON = ingredientJSON
                self.estimatedCaloriesKcal = estimatedCaloriesKcal
                self.estimatedProteinG = estimatedProteinG
                self.estimatedFatG = estimatedFatG
                self.estimatedCarbsG = estimatedCarbsG
                self.confidenceScore = confidenceScore
                self.userCorrectionFactor = userCorrectionFactor
                self.createdAt = createdAt
                self.id = id
                self.energyLowKcal = energyLowKcal
                self.energyLikelyKcal = energyLikelyKcal
                self.energyHighKcal = energyHighKcal
                self.proteinLowG = proteinLowG
                self.proteinLikelyG = proteinLikelyG
                self.proteinHighG = proteinHighG
                self.fatLowG = fatLowG
                self.fatLikelyG = fatLikelyG
                self.fatHighG = fatHighG
                self.carbsLowG = carbsLowG
                self.carbsLikelyG = carbsLikelyG
                self.carbsHighG = carbsHighG
                self.portionLowG = portionLowG
                self.portionLikelyG = portionLikelyG
                self.portionHighG = portionHighG
                self.evidenceData = evidenceData
                self.algorithmVersion = algorithmVersion
            }

            private enum CodingKeys: String, CodingKey {
                case dishName, cookingMethod, ingredientJSON, estimatedCaloriesKcal
                case estimatedProteinG, estimatedFatG, estimatedCarbsG, confidenceScore
                case userCorrectionFactor, createdAt, id, energyLowKcal, energyLikelyKcal
                case energyHighKcal, proteinLowG, proteinLikelyG, proteinHighG
                case fatLowG, fatLikelyG, fatHighG, carbsLowG, carbsLikelyG, carbsHighG
                case portionLowG, portionLikelyG, portionHighG, evidenceData, algorithmVersion
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                dishName = try container.decode(String.self, forKey: .dishName)
                cookingMethod = try container.decodeIfPresent(String.self, forKey: .cookingMethod)
                ingredientJSON = try container.decode(String.self, forKey: .ingredientJSON)
                estimatedCaloriesKcal = try container.decode(Int.self, forKey: .estimatedCaloriesKcal)
                estimatedProteinG = try container.decode(Double.self, forKey: .estimatedProteinG)
                estimatedFatG = try container.decode(Double.self, forKey: .estimatedFatG)
                estimatedCarbsG = try container.decode(Double.self, forKey: .estimatedCarbsG)
                confidenceScore = try container.decode(Double.self, forKey: .confidenceScore)
                userCorrectionFactor = try container.decodeIfPresent(Double.self, forKey: .userCorrectionFactor)
                createdAt = try container.decode(Date.self, forKey: .createdAt)
                id = try container.decodeIfPresent(UUID.self, forKey: .id)
                energyLowKcal = try container.decodeIfPresent(Double.self, forKey: .energyLowKcal)
                energyLikelyKcal = try container.decodeIfPresent(Double.self, forKey: .energyLikelyKcal)
                energyHighKcal = try container.decodeIfPresent(Double.self, forKey: .energyHighKcal)
                proteinLowG = try container.decodeIfPresent(Double.self, forKey: .proteinLowG)
                proteinLikelyG = try container.decodeIfPresent(Double.self, forKey: .proteinLikelyG)
                proteinHighG = try container.decodeIfPresent(Double.self, forKey: .proteinHighG)
                fatLowG = try container.decodeIfPresent(Double.self, forKey: .fatLowG)
                fatLikelyG = try container.decodeIfPresent(Double.self, forKey: .fatLikelyG)
                fatHighG = try container.decodeIfPresent(Double.self, forKey: .fatHighG)
                carbsLowG = try container.decodeIfPresent(Double.self, forKey: .carbsLowG)
                carbsLikelyG = try container.decodeIfPresent(Double.self, forKey: .carbsLikelyG)
                carbsHighG = try container.decodeIfPresent(Double.self, forKey: .carbsHighG)
                portionLowG = try container.decodeIfPresent(Double.self, forKey: .portionLowG)
                portionLikelyG = try container.decodeIfPresent(Double.self, forKey: .portionLikelyG)
                portionHighG = try container.decodeIfPresent(Double.self, forKey: .portionHighG)
                evidenceData = try container.decodeIfPresent(Data.self, forKey: .evidenceData)
                algorithmVersion = try container.decodeIfPresent(String.self, forKey: .algorithmVersion)
            }
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
        guard Self.supportedFormatVersions.contains(document.formatVersion) else {
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
                    algorithmVersion: source.algorithmVersion,
                    sourceActionKey: source.sourceActionKey,
                    energyLowKcal: source.energyLowKcal,
                    energyLikelyKcal: source.energyLikelyKcal,
                    energyHighKcal: source.energyHighKcal,
                    proteinLowG: source.proteinLowG,
                    proteinLikelyG: source.proteinLikelyG,
                    proteinHighG: source.proteinHighG,
                    fatLowG: source.fatLowG,
                    fatLikelyG: source.fatLikelyG,
                    fatHighG: source.fatHighG,
                    carbsLowG: source.carbsLowG,
                    carbsLikelyG: source.carbsLikelyG,
                    carbsHighG: source.carbsHighG,
                    evidenceData: source.evidenceData
                )
                meal.id = source.id
                meal.createdAt = source.createdAt
                meal.dishes = source.dishes.map { dishSource in
                    let dish = DishEntry(
                        id: dishSource.id ?? UUID(),
                        dishName: dishSource.dishName,
                        cookingMethod: dishSource.cookingMethod,
                        ingredientJSON: dishSource.ingredientJSON,
                        estimatedCaloriesKcal: dishSource.estimatedCaloriesKcal,
                        estimatedProteinG: dishSource.estimatedProteinG,
                        estimatedFatG: dishSource.estimatedFatG,
                        estimatedCarbsG: dishSource.estimatedCarbsG,
                        confidenceScore: dishSource.confidenceScore,
                        userCorrectionFactor: dishSource.userCorrectionFactor,
                        energyLowKcal: dishSource.energyLowKcal,
                        energyLikelyKcal: dishSource.energyLikelyKcal,
                        energyHighKcal: dishSource.energyHighKcal,
                        proteinLowG: dishSource.proteinLowG,
                        proteinLikelyG: dishSource.proteinLikelyG,
                        proteinHighG: dishSource.proteinHighG,
                        fatLowG: dishSource.fatLowG,
                        fatLikelyG: dishSource.fatLikelyG,
                        fatHighG: dishSource.fatHighG,
                        carbsLowG: dishSource.carbsLowG,
                        carbsLikelyG: dishSource.carbsLikelyG,
                        carbsHighG: dishSource.carbsHighG,
                        portionLowG: dishSource.portionLowG,
                        portionLikelyG: dishSource.portionLikelyG,
                        portionHighG: dishSource.portionHighG,
                        evidenceData: dishSource.evidenceData,
                        algorithmVersion: dishSource.algorithmVersion ?? source.algorithmVersion
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
                    sourceActionKey: source.sourceActionKey,
                    energyLowKcal: source.energyLowKcal,
                    energyLikelyKcal: source.energyLikelyKcal,
                    energyHighKcal: source.energyHighKcal,
                    proteinLowG: source.proteinLowG,
                    proteinLikelyG: source.proteinLikelyG,
                    proteinHighG: source.proteinHighG,
                    fatLowG: source.fatLowG,
                    fatLikelyG: source.fatLikelyG,
                    fatHighG: source.fatHighG,
                    carbsLowG: source.carbsLowG,
                    carbsLikelyG: source.carbsLikelyG,
                    carbsHighG: source.carbsHighG,
                    evidenceData: source.evidenceData,
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
                            createdAt: dish.createdAt,
                            id: dish.id,
                            energyLowKcal: dish.energyLowKcal,
                            energyLikelyKcal: dish.energyLikelyKcal,
                            energyHighKcal: dish.energyHighKcal,
                            proteinLowG: dish.proteinLowG,
                            proteinLikelyG: dish.proteinLikelyG,
                            proteinHighG: dish.proteinHighG,
                            fatLowG: dish.fatLowG,
                            fatLikelyG: dish.fatLikelyG,
                            fatHighG: dish.fatHighG,
                            carbsLowG: dish.carbsLowG,
                            carbsLikelyG: dish.carbsLikelyG,
                            carbsHighG: dish.carbsHighG,
                            portionLowG: dish.portionLowG,
                            portionLikelyG: dish.portionLikelyG,
                            portionHighG: dish.portionHighG,
                            evidenceData: dish.evidenceData,
                            algorithmVersion: dish.algorithmVersion
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

    func checksum(for payload: BackupPayload) throws -> String {
        let digest = SHA256.hash(data: try encoder.encode(payload))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
