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

    func allDishPriors() async throws -> [PersonalMealDishPrior] {
        let records = try modelContext.fetch(FetchDescriptor<PersonalMealDishPriorRecord>(
            sortBy: [
                SortDescriptor(\PersonalMealDishPriorRecord.dishName),
                SortDescriptor(\PersonalMealDishPriorRecord.cookingMethodKey),
                SortDescriptor(\PersonalMealDishPriorRecord.priorKey),
            ]
        ))
        return records.compactMap(Self.mapDishPrior)
    }

    func dishPrior(named dishName: String, cookingMethod: String?) async throws -> PersonalMealDishPrior? {
        guard let dishKey = MealDishPriorStorageKey.dishKey(dishName) else { return nil }
        let predicate = #Predicate<PersonalMealDishPriorRecord> { $0.dishKey == dishKey }
        let records = try modelContext.fetch(FetchDescriptor(predicate: predicate))
        let available = records.compactMap(Self.mapDishPrior).filter(\.isAvailableForAutomaticUse)
        guard !available.isEmpty else { return nil }

        let requestedMethodKey = MealDishPriorStorageKey.cookingMethodKey(cookingMethod)
        let exactMethod = available.filter {
            MealDishPriorStorageKey.cookingMethodKey($0.cookingMethod) == requestedMethodKey
        }
        if !exactMethod.isEmpty {
            return Self.uniqueManagedOrHighestLearnedPrior(exactMethod)
        }
        // An unspecified template can be a general fallback, but never reuse a
        // prior learned for a different, explicitly named cooking method.
        let generic = available.filter { $0.cookingMethod == nil }
        return Self.uniqueManagedOrHighestLearnedPrior(generic)
    }

    func saveDishPrior(_ edit: PersonalMealDishPriorEdit) async throws {
        let values = try Self.validatedDishPrior(edit)
        let existingByID: PersonalMealDishPriorRecord?
        if let id = edit.id {
            let predicate = #Predicate<PersonalMealDishPriorRecord> { $0.id == id }
            var descriptor = FetchDescriptor(predicate: predicate)
            descriptor.fetchLimit = 1
            guard let record = try modelContext.fetch(descriptor).first else {
                throw MealPortionPriorRepositoryError.notFound
            }
            existingByID = record
        } else {
            existingByID = nil
        }

        if let duplicate = try dishRecord(priorKey: values.priorKey), duplicate.id != existingByID?.id {
            throw MealPortionPriorRepositoryError.duplicateDishAndIngredients
        }

        let now = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ingredientsData = try encoder.encode(values.ingredients)
        guard let ingredientsJSON = String(data: ingredientsData, encoding: .utf8) else {
            throw MealPortionPriorRepositoryError.invalidValue
        }
        let record = existingByID ?? PersonalMealDishPriorRecord(
            priorKey: values.priorKey,
            dishKey: values.dishKey,
            dishName: values.dishName,
            cookingMethodKey: values.cookingMethodKey,
            cookingMethod: values.cookingMethod,
            ingredientsJSON: ingredientsJSON,
            observationCount: 0,
            isUserManaged: true,
            sourceActionKey: nil,
            createdAt: now,
            updatedAt: now
        )
        record.priorKey = values.priorKey
        record.dishKey = values.dishKey
        record.dishName = values.dishName
        record.cookingMethodKey = values.cookingMethodKey
        record.cookingMethod = values.cookingMethod
        record.ingredientsJSON = ingredientsJSON
        record.isUserManaged = true
        record.updatedAt = now
        if existingByID == nil { modelContext.insert(record) }
        try modelContext.save()
    }

    func deleteDishPrior(id: UUID) async throws {
        let predicate = #Predicate<PersonalMealDishPriorRecord> { $0.id == id }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(record)
        try modelContext.save()
    }

    /// Called only inside the transaction that commits a user's meal confirmation.
    /// Ordinary model estimates are ignored; only explicit ingredient portions or
    /// the per-dish template opt-in marker may create/update a personal prior.
    static func recordConfirmedDishes(
        in context: ModelContext,
        dishes: [MealDishDraft],
        sourceActionKey: String,
        now: Date
    ) throws {
        for dish in dishes {
            let isUserManaged = PersonalMealDishPriorTemplateOptIn.isOptedIn(
                in: dish.evidence,
                dishName: dish.name
            )
            let ingredients = dish.ingredients.compactMap { ingredient -> PersonalMealDishIngredientPrior? in
                guard isUserManaged || hasExplicitUserPortionEvidence(ingredient.evidence) else {
                    return nil
                }
                let provenance = sourceBackedProvenance(from: ingredient.evidence)
                return PersonalMealDishIngredientPrior(
                    foodID: ingredient.foodID,
                    name: ingredient.name,
                    lowGrams: ingredient.amountGrams.low,
                    likelyGrams: ingredient.amountGrams.likely,
                    highGrams: ingredient.amountGrams.high,
                    preparation: provenance?.preparation,
                    massBasis: provenance?.massBasis,
                    sourceID: provenance?.sourceID,
                    sourceRecordID: provenance?.sourceRecordID,
                    sourceVersion: provenance?.sourceVersion,
                    licenseStatus: provenance?.licenseStatus
                )
            }
            guard !ingredients.isEmpty,
                  let key = MealDishPriorStorageKey.make(
                    dishName: dish.name,
                    cookingMethod: dish.cookingMethod,
                    ingredients: ingredients
                  ) else {
                continue
            }
            let priorKey = key.priorKey
            let predicate = #Predicate<PersonalMealDishPriorRecord> { $0.priorKey == priorKey }
            var descriptor = FetchDescriptor(predicate: predicate)
            descriptor.fetchLimit = 1
            if let record = try context.fetch(descriptor).first {
                guard record.sourceActionKey != sourceActionKey else { continue }
                // Manual templates are user-controlled. Only a fresh, explicit
                // per-dish opt-in can intentionally replace their saved amounts.
                guard !record.isUserManaged || isUserManaged else { continue }
                let previous = Self.decodeDishIngredients(record.ingredientsJSON)
                let priorObservationCount = previous != nil
                    && (0...1_000_000).contains(record.observationCount)
                    ? record.observationCount
                    : 0
                let merged = Self.averagedDishIngredients(
                    previous: previous,
                    incoming: ingredients,
                    priorObservationCount: priorObservationCount
                )
                record.ingredientsJSON = try Self.encodeDishIngredients(merged)
                record.observationCount = min(1_000_000, priorObservationCount + 1)
                record.isUserManaged = record.isUserManaged || isUserManaged
                record.sourceActionKey = sourceActionKey
                record.updatedAt = now
            } else {
                context.insert(PersonalMealDishPriorRecord(
                    priorKey: key.priorKey,
                    dishKey: key.dishKey,
                    dishName: dish.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    cookingMethodKey: key.cookingMethodKey,
                    cookingMethod: dish.cookingMethod,
                    ingredientsJSON: try Self.encodeDishIngredients(ingredients),
                    observationCount: 1,
                    isUserManaged: isUserManaged,
                    sourceActionKey: sourceActionKey,
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }
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

    private func dishRecord(priorKey: String) throws -> PersonalMealDishPriorRecord? {
        let predicate = #Predicate<PersonalMealDishPriorRecord> { $0.priorKey == priorKey }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private static func validatedDishPrior(_ edit: PersonalMealDishPriorEdit) throws -> (
        dishKey: String,
        dishName: String,
        cookingMethodKey: String,
        cookingMethod: String?,
        ingredients: [PersonalMealDishIngredientPrior],
        priorKey: String
    ) {
        let dishName = edit.dishName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookingMethod = edit.cookingMethod?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard !dishName.isEmpty, dishName.count <= 120,
              cookingMethod.map({ $0.count <= 40 }) ?? true,
              (1...20).contains(edit.ingredients.count),
              let key = MealDishPriorStorageKey.make(
                dishName: dishName,
                cookingMethod: cookingMethod,
                ingredients: edit.ingredients
              ),
              Set(edit.ingredients.map(\.id)).count == edit.ingredients.count else {
            throw MealPortionPriorRepositoryError.invalidValue
        }
        let ingredients = edit.ingredients.compactMap { ingredient in
            PersonalMealDishIngredientPrior(
                foodID: ingredient.foodID,
                name: ingredient.name,
                lowGrams: ingredient.lowGrams,
                likelyGrams: ingredient.likelyGrams,
                highGrams: ingredient.highGrams,
                preparation: ingredient.preparation,
                massBasis: ingredient.massBasis,
                sourceID: ingredient.sourceID,
                sourceRecordID: ingredient.sourceRecordID,
                sourceVersion: ingredient.sourceVersion,
                licenseStatus: ingredient.licenseStatus
            )
        }
        guard ingredients.count == edit.ingredients.count,
              let normalizedKey = MealDishPriorStorageKey.make(
                dishName: dishName,
                cookingMethod: cookingMethod,
                ingredients: ingredients
              ) else {
            throw MealPortionPriorRepositoryError.invalidValue
        }
        return (
            key.dishKey,
            dishName,
            key.cookingMethodKey,
            cookingMethod,
            ingredients,
            normalizedKey.priorKey
        )
    }

    private static func validatedDishPrior(_ record: PersonalMealDishPriorRecord) -> PersonalMealDishPrior? {
        guard let ingredients = decodeDishIngredients(record.ingredientsJSON),
              let key = MealDishPriorStorageKey.make(
                dishName: record.dishName,
                cookingMethod: record.cookingMethod,
                ingredients: ingredients
              ),
              key.priorKey == record.priorKey,
              key.dishKey == record.dishKey,
              key.cookingMethodKey == record.cookingMethodKey else {
            return nil
        }
        return PersonalMealDishPrior(
            id: record.id,
            priorKey: record.priorKey,
            dishKey: record.dishKey,
            dishName: record.dishName,
            cookingMethod: record.cookingMethod,
            ingredients: ingredients,
            observationCount: record.observationCount,
            isUserManaged: record.isUserManaged,
            sourceActionKey: record.sourceActionKey,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private static func mapDishPrior(_ record: PersonalMealDishPriorRecord) -> PersonalMealDishPrior? {
        validatedDishPrior(record)
    }

    private static func uniqueHighestObservationPrior(_ priors: [PersonalMealDishPrior]) -> PersonalMealDishPrior? {
        guard let highestCount = priors.map(\.observationCount).max() else { return nil }
        let highest = priors.filter { $0.observationCount == highestCount }
        return highest.count == 1 ? highest[0] : nil
    }

    private static func uniqueManagedOrHighestLearnedPrior(
        _ priors: [PersonalMealDishPrior]
    ) -> PersonalMealDishPrior? {
        let managed = priors.filter(\.isUserManaged)
        guard managed.isEmpty else { return managed.count == 1 ? managed[0] : nil }
        return uniqueHighestObservationPrior(priors)
    }

    private static func decodeDishIngredients(_ encoded: String) -> [PersonalMealDishIngredientPrior]? {
        guard let data = encoded.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([PersonalMealDishIngredientPrior].self, from: data),
              (1...20).contains(decoded.count) else {
            return nil
        }
        let validated = decoded.compactMap { ingredient in
            PersonalMealDishIngredientPrior(
                foodID: ingredient.foodID,
                name: ingredient.name,
                lowGrams: ingredient.lowGrams,
                likelyGrams: ingredient.likelyGrams,
                highGrams: ingredient.highGrams,
                preparation: ingredient.preparation,
                massBasis: ingredient.massBasis,
                sourceID: ingredient.sourceID,
                sourceRecordID: ingredient.sourceRecordID,
                sourceVersion: ingredient.sourceVersion,
                licenseStatus: ingredient.licenseStatus
            )
        }
        guard validated.count == decoded.count,
              Set(validated.map(\.id)).count == validated.count else {
            return nil
        }
        return validated
    }

    private static func encodeDishIngredients(_ ingredients: [PersonalMealDishIngredientPrior]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ingredients)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw MealPortionPriorRepositoryError.invalidValue
        }
        return encoded
    }

    private static func averagedDishIngredients(
        previous: [PersonalMealDishIngredientPrior]?,
        incoming: [PersonalMealDishIngredientPrior],
        priorObservationCount: Int
    ) -> [PersonalMealDishIngredientPrior] {
        guard let previous,
              priorObservationCount > 0,
              Set(previous.map(\.id)) == Set(incoming.map(\.id)) else {
            return incoming.sorted { $0.id < $1.id }
        }
        let oldWeight = Double(priorObservationCount)
        let newWeight = 1.0
        let incomingByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        return previous.compactMap { old in
            guard let new = incomingByID[old.id] else { return nil }
            return PersonalMealDishIngredientPrior(
                foodID: new.foodID ?? old.foodID,
                name: new.name,
                lowGrams: (old.lowGrams * oldWeight + new.lowGrams * newWeight) / (oldWeight + newWeight),
                likelyGrams: (old.likelyGrams * oldWeight + new.likelyGrams * newWeight) / (oldWeight + newWeight),
                highGrams: (old.highGrams * oldWeight + new.highGrams * newWeight) / (oldWeight + newWeight),
                preparation: new.preparation ?? old.preparation,
                massBasis: new.massBasis ?? old.massBasis,
                sourceID: new.sourceID ?? old.sourceID,
                sourceRecordID: new.sourceRecordID ?? old.sourceRecordID,
                sourceVersion: new.sourceVersion ?? old.sourceVersion,
                licenseStatus: new.licenseStatus ?? old.licenseStatus
            )
        }.sorted { $0.id < $1.id }
    }

    private static func hasExplicitUserPortionEvidence(_ evidence: [EvidenceSnapshot]) -> Bool {
        if PersonalMealDishPriorUserPortionEvidence.isExplicit(in: evidence) { return true }
        if hasValidatedMealCaptureCorrection(in: evidence) { return true }
        return evidence.contains { snapshot in
            if snapshot.sourceID == MealPortionPriorCorrection.evidenceSourceID {
                return MealPortionPriorCorrection.correction(from: snapshot) != nil
            }
            return false
        }
    }

    private static func hasValidatedMealCaptureCorrection(in evidence: [EvidenceSnapshot]) -> Bool {
        let hasNumericCorrection = evidence.contains { snapshot in
            guard snapshot.grade == .userReported,
                  snapshot.sourceID == "user-corrected-portion",
                  snapshot.sourceVersion == MealEstimator.algorithmVersion,
                  snapshot.confidence == 1,
                  snapshot.summary.hasSuffix("g") else {
                return false
            }
            let gramsText = snapshot.summary.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let grams = Double(String(gramsText)), grams.isFinite else { return false }
            return (0.1...5_000).contains(grams)
        }
        guard hasNumericCorrection else { return false }

        if evidence.contains(where: {
            $0.sourceID == "portion:userCorrection"
                && $0.sourceVersion == PortionEstimator.algorithmVersion
        }) {
            return true
        }
        let hasPackageServingEstimate = evidence.contains {
            $0.sourceID == "portion:packageServing"
                && $0.sourceVersion == PortionEstimator.algorithmVersion
        }
        let hasServingLabel = evidence.contains {
            $0.grade == .label
                && ($0.sourceID == "capture:nutritionLabel" || $0.sourceID == "packaged-food-attribution")
        }
        return hasPackageServingEstimate && hasServingLabel
    }

    private static func sourceBackedProvenance(from evidence: [EvidenceSnapshot]) -> (
        preparation: FoodPreparation?,
        massBasis: FoodMassBasis?,
        sourceID: String?,
        sourceRecordID: String?,
        sourceVersion: String?,
        licenseStatus: String?
    )? {
        for snapshot in evidence
        where snapshot.grade == .databaseMatch && snapshot.sourceID?.hasPrefix("food-composition:") == true {
            var fields: [String: String] = [:]
            for field in snapshot.summary.split(separator: ";") {
                let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                fields[pair[0].trimmingCharacters(in: .whitespacesAndNewlines)] =
                    pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard fields["licenseStatus"] == "verified",
                  let sourceID = fields["sourceID"], !sourceID.isEmpty, sourceID != "not-provided",
                  let sourceRecordID = fields["sourceRecordID"], !sourceRecordID.isEmpty,
                  sourceRecordID != "not-provided",
                  let sourceVersion = snapshot.sourceVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sourceVersion.isEmpty else {
                continue
            }
            let preparation = fields["preparation"].flatMap(FoodPreparation.init(rawValue:))
            let massBasis = fields["massBasis"].flatMap(FoodMassBasis.init(rawValue:))
            return (preparation, massBasis, sourceID, sourceRecordID, sourceVersion, "verified")
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
