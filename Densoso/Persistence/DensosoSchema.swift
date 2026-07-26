import SwiftData

enum DensosoSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            UserProfile.self,
            MealRecord.self,
            DishEntry.self,
            WorkoutRecord.self,
            DailyMetrics.self,
            WeeklyReport.self,
            ScheduleEvent.self,
            HealthSyncOutboxEntry.self
        ]
    }
}

enum DensosoSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            UserProfile.self,
            MealRecord.self,
            DishEntry.self,
            WorkoutRecord.self,
            DailyMetrics.self,
            WeeklyReport.self,
            ScheduleEvent.self,
            HealthSyncOutboxEntry.self,
            HealthKitImportCursor.self
        ]
    }
}

enum DensosoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [DensosoSchemaV1.self, DensosoSchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: DensosoSchemaV1.self, toVersion: DensosoSchemaV2.self)]
    }
}
