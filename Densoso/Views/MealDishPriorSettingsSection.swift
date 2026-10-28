import DensosoDomain
import SwiftUI

@MainActor
struct MealDishPriorSettingsSection: View {
    @Environment(Dependencies.self) private var dependencies

    @State private var priors: [PersonalMealDishPrior] = []
    @State private var selectedPrior: PersonalMealDishPrior?
    @State private var isEditorPresented = false
    @State private var errorMessage: String?

    var body: some View {
        Section("个人菜品模板") {
            Text("菜品模板只用于补充未提供的食材克重，并保留为估算。重复确认的用户份量可在两次后自动建议；手动模板可立即使用。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if priors.isEmpty {
                Text("还没有个人菜品模板")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(priors) { prior in
                    Button {
                        selectedPrior = prior
                        isEditorPresented = true
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(prior.cookingMethod.map { "\(prior.dishName) · \($0)" } ?? prior.dishName)
                                .foregroundStyle(.primary)
                            Text(prior.isUserManaged ? "手动管理 · \(prior.ingredients.count) 种食材" : "确认记录 \(prior.observationCount)/\(PersonalMealDishPrior.minimumObservationsForAutomaticUse) 次 · \(prior.ingredients.count) 种食材")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(prior.ingredients.map { "\($0.name) \(Int($0.likelyGrams.rounded()))g" }.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .swipeActions {
                        Button("删除", systemImage: "trash", role: .destructive) {
                            Task { await delete(prior.id) }
                        }
                    }
                }
            }

            Button("添加菜品模板", systemImage: "plus") {
                selectedPrior = nil
                isEditorPresented = true
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(OrbitPalette.coral)
            }
        }
        .task { await reload() }
        .sheet(isPresented: $isEditorPresented, onDismiss: {
            Task { await reload() }
        }) {
            MealDishPriorEditorSheet(prior: selectedPrior)
                .presentationBackground { OrbitBackground() }
        }
    }

    private func reload() async {
        do {
            priors = try await dependencies.mealPortionPriorRepository.allDishPriors()
            errorMessage = nil
        } catch {
            errorMessage = "读取个人菜品模板失败，请稍后重试。"
        }
    }

    private func delete(_ id: UUID) async {
        do {
            try dependencies.persistenceWriteGate.requireWritable()
            try await dependencies.mealPortionPriorRepository.deleteDishPrior(id: id)
            await reload()
        } catch let error as PersistenceWriteError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "删除菜品模板失败，请稍后重试。"
        }
    }
}

@MainActor
private struct MealDishPriorEditorSheet: View {
    @Environment(Dependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

    let prior: PersonalMealDishPrior?
    @State private var dishName: String
    @State private var cookingMethod: String
    @State private var ingredientsText: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(prior: PersonalMealDishPrior?) {
        self.prior = prior
        _dishName = State(initialValue: prior?.dishName ?? "")
        _cookingMethod = State(initialValue: prior?.cookingMethod ?? "")
        _ingredientsText = State(initialValue: prior.map(Self.ingredientText) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("菜品") {
                    TextField("菜品名称", text: $dishName)
                    TextField("烹饪方式（可选）", text: $cookingMethod)
                }
                Section("每份食材和克重") {
                    TextEditor(text: $ingredientsText)
                        .frame(minHeight: 150)
                    Text("每行填写“食材: 克重”，例如：米饭: 120g。新食材不会自动补写食品来源或生熟/购买基准。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(OrbitPalette.coral)
                    }
                }
            }
            .navigationTitle(prior == nil ? "添加菜品模板" : "编辑菜品模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
        }
    }

    private static func ingredientText(_ prior: PersonalMealDishPrior) -> String {
        prior.ingredients
            .map { "\($0.name): \(Int($0.likelyGrams.rounded()))g" }
            .joined(separator: "\n")
    }

    private func parsedIngredients() -> [PersonalMealDishIngredientPrior]? {
        let lines = ingredientsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard (1...20).contains(lines.count) else { return nil }
        var existingByName: [String: PersonalMealDishIngredientPrior] = [:]
        for existing in prior?.ingredients ?? [] {
            let key = FoodResolver.normalize(existing.name)
            if existingByName[key] == nil { existingByName[key] = existing }
        }
        let ingredients = lines.compactMap { line -> PersonalMealDishIngredientPrior? in
            let fields = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { return nil }
            let name = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let amountText = fields[1]
                .replacingOccurrences(of: "克", with: "")
                .replacingOccurrences(of: "g", with: "", options: [.caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let grams = Double(amountText), grams.isFinite, (0.1...5_000).contains(grams) else {
                return nil
            }
            let existing = existingByName[FoodResolver.normalize(name)]
            return PersonalMealDishIngredientPrior(
                foodID: existing?.foodID,
                name: name,
                lowGrams: max(0.1, grams * 0.9),
                likelyGrams: grams,
                highGrams: min(5_000, grams * 1.1),
                preparation: existing?.preparation,
                massBasis: existing?.massBasis,
                sourceID: existing?.sourceID,
                sourceRecordID: existing?.sourceRecordID,
                sourceVersion: existing?.sourceVersion,
                licenseStatus: existing?.licenseStatus
            )
        }
        return ingredients.count == lines.count ? ingredients : nil
    }

    private func save() async {
        guard let ingredients = parsedIngredients() else {
            errorMessage = "请按“食材: 克重”逐行填写 1–20 项，并使用 0.1–5000g 的有效克重。"
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try dependencies.persistenceWriteGate.requireWritable()
            try await dependencies.mealPortionPriorRepository.saveDishPrior(PersonalMealDishPriorEdit(
                id: prior?.id,
                dishName: dishName,
                cookingMethod: cookingMethod,
                ingredients: ingredients
            ))
            dismiss()
        } catch MealPortionPriorRepositoryError.duplicateDishAndIngredients {
            errorMessage = "相同菜品、烹饪方式和食材组合已存在模板。"
        } catch let error as PersistenceWriteError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "无法保存模板，请检查菜名、烹饪方式和食材克重。"
        }
    }
}
