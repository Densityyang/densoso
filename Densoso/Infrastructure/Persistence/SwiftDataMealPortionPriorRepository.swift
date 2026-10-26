import DensosoDomain
import Foundation
import SwiftData

@ModelActor
actor SwiftDataMealPortionPriorRepository: MealPortionPriorRepository {
    func all() async throws -> [PersonalMealPortionPrior] {
        let records = try modelContext.fetch(FetchDescriptor<PersonalMealPortionPriorRecord>(
            sortBy: [
                SortDescriptor(\PersonalMealPortionPriorRecord.foodName),
                SortDescriptor(\PersonalMealPortionPriorRecord.unit),
            ]
        ))
        return records.compactMap(Self.map)
    }

    func prior(
        foodID: String?,
        foodName: String,
        unit: String
    ) async throws -> HouseholdPortionPrior? {
        guard let normalizedUnit = MealPortionPriorCorrection.normalizeSupportedUnit(unit) else { return nil }
        let keys = [
            MealPortionPriorStorageKey.make(foodID: foodID, foodName: foodName, unit: normalizedUnit),
            MealPortionPriorStorageKey.make(foodID: nil, foodName: foodName, unit: normalizedUnit),
        ].compactMap { $0 }
        var seenKeys = Set<String>()
        for key in keys where seenKeys.insert(key).inserted {
            if let record = try record(priorKey: key), let prior = Self.householdPrior(from: record) {
                return prior
            }
        }
        return nil
    }

    func save(_ edit: PersonalMealPortionPriorEdit) async throws {
        let values = try Self.validated(edit)
        let existingByID: PersonalMealPortionPriorRecord?
        if let id = edit.id {
            let predicate = #Predicate<PersonalMealPortionPriorRecord> { $0.id == id }
            var descriptor = FetchDescriptor(predicate: predicate)
            descriptor.fetchLimit = 1
            guard let record = try modelContext.fetch(descriptor).first else {
                throw MealPortionPriorRepositoryError.notFound
            }
            existingByID = record
        } else {
            existingByID = nil
        }

        if let existingByKey = try record(priorKey: values.priorKey),
           existingByKey.id != existingByID?.id {
            throw MealPortionPriorRepositoryError.duplicateFoodAndUnit
        }

        let now = Date()
        let record = existingByID ?? PersonalMealPortionPriorRecord(
            priorKey: values.priorKey,
            foodID: values.foodID,
            foodName: values.foodName,
            unit: values.unit,
            p10Grams: values.p10,
            p50Grams: values.p50,
            p90Grams: values.p90,
            sourceActionKey: nil,
            createdAt: now,
            updatedAt: now
        )
        record.priorKey = values.priorKey
        record.foodID = values.foodID
        record.foodName = values.foodName
        record.unit = values.unit
        record.p10Grams = values.p10
        record.p50Grams = values.p50
        record.p90Grams = values.p90
        record.sourceActionKey = nil
        record.updatedAt = now
        if case nil = existingByID { modelContext.insert(record) }
        try modelContext.save()
    }

    func delete(id: UUID) async throws {
        let predicate = #Predicate<PersonalMealPortionPriorRecord> { $0.id == id }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(record)
        try modelContext.save()
    }

    static func recordConfirmedCorrections(
        in context: ModelContext,
        ingredients: [MealIngredientDraft],
        sourceActionKey: String,
        now: Date
    ) throws {
        for ingredient in ingredients {
            guard let correction = ingredient.evidence.compactMap(MealPortionPriorCorrection.correction(from:)).first,
                  let key = MealPortionPriorStorageKey.make(
                    foodID: ingredient.foodID,
                    foodName: ingredient.name,
                    unit: correction.unit
                  ) else {
                continue
            }
            let grams = correction.gramsPerUnit
            guard grams.isFinite, (0.1...5_000).contains(grams) else { continue }
            let p10 = max(0.1, grams * 0.9)
            let p90 = min(5_000, grams * 1.1)
            let predicate = #Predicate<PersonalMealPortionPriorRecord> { $0.priorKey == key }
            var descriptor = FetchDescriptor(predicate: predicate)
            descriptor.fetchLimit = 1
            if let record = try context.fetch(descriptor).first {
                record.foodID = ingredient.foodID
                record.foodName = ingredient.name
                record.unit = correction.unit
                record.p10Grams = p10
                record.p50Grams = grams
                record.p90Grams = p90
                record.sourceActionKey = sourceActionKey
                record.updatedAt = now
            } else {
                context.insert(PersonalMealPortionPriorRecord(
                    priorKey: key,
                    foodID: ingredient.foodID,
                    foodName: ingredient.name,
                    unit: correction.unit,
                    p10Grams: p10,
                    p50Grams: grams,
                    p90Grams: p90,
                    sourceActionKey: sourceActionKey,
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }
    }

    static func validated(_ edit: PersonalMealPortionPriorEdit) throws -> (
        foodID: String?, foodName: String, unit: String, p10: Double, p50: Double, p90: Double, priorKey: String
    ) {
        let foodName = edit.foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !foodName.isEmpty, foodName.count <= 120,
              edit.gramsPerUnit.isFinite, (0.1...5_000).contains(edit.gramsPerUnit),
              let unit = MealPortionPriorCorrection.normalizeSupportedUnit(edit.unit),
              let priorKey = MealPortionPriorStorageKey.make(foodID: edit.foodID, foodName: foodName, unit: unit) else {
            throw MealPortionPriorRepositoryError.invalidValue
        }
        return (
            edit.foodID,
            foodName,
            unit,
            max(0.1, edit.gramsPerUnit * 0.9),
            edit.gramsPerUnit,
            min(5_000, edit.gramsPerUnit * 1.1),
            priorKey
        )
    }

    private func record(priorKey: String) throws -> PersonalMealPortionPriorRecord? {
        let predicate = #Predicate<PersonalMealPortionPriorRecord> { $0.priorKey == priorKey }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private static func map(_ record: PersonalMealPortionPriorRecord) -> PersonalMealPortionPrior? {
        guard let prior = householdPrior(from: record) else { return nil }
        return PersonalMealPortionPrior(
            id: record.id,
            priorKey: record.priorKey,
            foodID: record.foodID,
            foodName: record.foodName,
            prior: prior,
            sourceActionKey: record.sourceActionKey,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private static func householdPrior(from record: PersonalMealPortionPriorRecord) -> HouseholdPortionPrior? {
        guard MealPortionPriorCorrection.normalizeSupportedUnit(record.unit) != nil,
              record.p10Grams.isFinite,
              record.p50Grams.isFinite,
              record.p90Grams.isFinite,
              record.p10Grams > 0,
              record.p10Grams <= record.p50Grams,
              record.p50Grams <= record.p90Grams,
              record.p90Grams <= 5_000 else {
            return nil
        }
        return HouseholdPortionPrior(
            unit: record.unit,
            p10Grams: record.p10Grams,
            p50Grams: record.p50Grams,
            p90Grams: record.p90Grams,
            version: MealPortionPriorCorrection.evidenceVersion
        )
    }
}
