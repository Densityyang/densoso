import DensosoDomain
import Foundation
import SwiftData

/// Performs bounded Agent health reads and deterministic calculations on the
/// SwiftData model actor executor. These operations never refresh or write caches.
@ModelActor
actor HealthProjectionActor {
    private let calendar: Calendar

    init(modelContainer: ModelContainer, calendar: Calendar = .current) {
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
        self.calendar = calendar
    }

    func todayHealthState(asOf date: Date = Date()) throws -> HealthStateV2? {
        try HealthIntelligenceReadModel(calendar: calendar)
            .todayHealthState(asOf: date, in: modelContext)
    }

    func healthHistory(from startDate: Date, through endDate: Date) throws -> [HealthStateHistoryPoint] {
        try HealthIntelligenceReadModel(calendar: calendar)
            .healthHistory(from: startDate, through: endDate, in: modelContext)
    }

    func healthNarrativeContext(asOf date: Date = Date()) throws -> HealthNarrativeContext {
        try HealthIntelligenceReadModel(calendar: calendar)
            .healthNarrativeContext(asOf: date, in: modelContext)
    }
}
