import DensosoDomain
import SwiftData
import SwiftUI

@MainActor
struct MealPortionPriorSettingsSection: View {
    @Environment(Dependencies.self) private var dependencies
    @Query(sort: \PersonalMealPortionPriorRecord.foodName)
    private var records: [PersonalMealPortionPriorRecord]

    @State private var selectedPrior: PersonalMealPortionPrior?
    @State private var isEditorPresented = false
    @State private var errorMessage: String?

    var body: some View {
        Section("个人份量先验") {
            Text("只根据你明确提供并确认的单位与克重保存，也可在这里手动维护。后续估算按食材和单位使用；模型猜测不会自动修改先验。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if records.isEmpty {
                Text("还没有个人份量先验")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records) { record in
                    if let prior = makePrior(from: record) {
                        Button {
                            selectedPrior = prior
                            isEditorPresented = true
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(record.foodName) · \(MealPortionPriorPresentation.unitLabel(record.unit))")
                                    .foregroundStyle(.primary)
                                Text("每单位约 \(Int(record.p50Grams.rounded()))g（\(Int(record.p10Grams.rounded()))–\(Int(record.p90Grams.rounded()))g）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                Task { await delete(prior.id) }
                            }
                        }
                    }
                }
            }

            Button("添加个人份量先验", systemImage: "plus") {
                selectedPrior = nil
                isEditorPresented = true
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(OrbitPalette.coral)
            }
        }
        .sheet(isPresented: $isEditorPresented) {
            MealPortionPriorEditorSheet(prior: selectedPrior)
                .presentationBackground { OrbitBackground() }
        }
    }

    private func makePrior(from record: PersonalMealPortionPriorRecord) -> PersonalMealPortionPrior? {
        guard record.p10Grams.isFinite,
              record.p50Grams.isFinite,
              record.p90Grams.isFinite,
              record.p10Grams > 0,
              record.p10Grams <= record.p50Grams,
              record.p50Grams <= record.p90Grams,
              record.p90Grams <= 5_000 else {
            return nil
        }
        return PersonalMealPortionPrior(
            id: record.id,
            priorKey: record.priorKey,
            foodID: record.foodID,
            foodName: record.foodName,
            prior: HouseholdPortionPrior(
                unit: record.unit,
                p10Grams: record.p10Grams,
                p50Grams: record.p50Grams,
                p90Grams: record.p90Grams,
                version: MealPortionPriorCorrection.evidenceVersion
            ),
            sourceActionKey: record.sourceActionKey,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private func delete(_ id: UUID) async {
        do {
            try dependencies.persistenceWriteGate.requireWritable()
            try await dependencies.mealPortionPriorRepository.delete(id: id)
            errorMessage = nil
        } catch let error as PersistenceWriteError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "删除份量先验失败，请稍后重试。"
        }
    }
}

@MainActor
private struct MealPortionPriorEditorSheet: View {
    @Environment(Dependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

    let prior: PersonalMealPortionPrior?
    @State private var foodName: String
    @State private var unit: String
    @State private var gramsPerUnit: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(prior: PersonalMealPortionPrior?) {
        self.prior = prior
        _foodName = State(initialValue: prior?.foodName ?? "")
        _unit = State(initialValue: prior.map { MealPortionPriorPresentation.unitLabel($0.prior.unit) } ?? "")
        _gramsPerUnit = State(
            initialValue: prior.map { String(Int($0.prior.p50Grams.rounded())) } ?? ""
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("单位和克重") {
                    TextField("食材名称", text: $foodName)
                    TextField("单位（如 碗、egg、cup）", text: $unit)
                        .textInputAutocapitalization(.never)
                    TextField("每单位克重", text: $gramsPerUnit)
                        .keyboardType(.decimalPad)
                    Text("保存后会采用该克重上下 10% 的估算范围。")
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
            .navigationTitle(prior == nil ? "添加份量先验" : "编辑份量先验")
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

    private func save() async {
        guard let grams = Double(gramsPerUnit) else {
            errorMessage = "请输入有效克重。"
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try dependencies.persistenceWriteGate.requireWritable()
            try await dependencies.mealPortionPriorRepository.save(PersonalMealPortionPriorEdit(
                id: prior?.id,
                foodID: prior?.foodID,
                foodName: foodName,
                unit: unit,
                gramsPerUnit: grams
            ))
            dismiss()
        } catch MealPortionPriorRepositoryError.duplicateFoodAndUnit {
            errorMessage = "这个食材和单位已经有份量先验。"
        } catch let error as PersistenceWriteError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "无法保存份量先验，请检查食材、单位和克重。"
        }
    }
}
