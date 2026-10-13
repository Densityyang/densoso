import AVFoundation
import DensosoDomain
import PhotosUI
import SwiftUI
import UIKit

@MainActor
struct MealCaptureSheet: View {
    @Environment(Dependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

    let onStaged: (PendingAction) -> Void

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCamera = false
    @State private var review: MealCaptureReview?
    @State private var selectedFoodID: String?
    @State private var correctedGrams = ""
    @State private var oilAnswer: MealCaptureOilAnswer?
    @State private var mealType = Self.defaultMealType()
    @State private var isAnalyzing = false
    @State private var isStaging = false
    @State private var errorMessage: String?
    @State private var analysisTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("选择餐食照片") {
                    PhotosPicker(
                        selection: $selectedPhoto,
                        matching: .images,
                        preferredItemEncoding: .current
                    ) {
                        Label("从照片中选择", systemImage: "photo.on.rectangle")
                    }
                    Button("拍摄餐食", systemImage: "camera") {
                        Task { await openCamera() }
                    }
                    Text("图片仅在内存中缩放到最长边 1280px 并移除元数据；原图不会保存。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if isAnalyzing {
                    Section { ProgressView("正在先检查本地条码和营养标签") }
                }

                if let review {
                    Section("识别草稿") {
                        LabeledContent("路径", value: routeName(review.route))
                        Text(review.label).font(.headline)
                        if let attribution = review.attribution {
                            Text(attribution)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Picker("餐次", selection: $mealType) {
                            Text("早餐").tag("breakfast")
                            Text("午餐").tag("lunch")
                            Text("晚餐").tag("dinner")
                            Text("加餐").tag("snack")
                        }
                        if !review.candidateNames.isEmpty {
                            Picker("食物候选", selection: Binding(
                                get: { selectedFoodID ?? review.resolution?.autoPreselect?.id },
                                set: { selectedFoodID = $0 }
                            )) {
                                Text("请选择").tag(String?.none)
                                ForEach(review.resolution?.candidates ?? []) { candidate in
                                    Text("\(candidate.entry.name) · \(Int(candidate.score * 100))")
                                        .tag(Optional(candidate.id))
                                }
                            }
                            if let portion = review.portion {
                                Text(
                                    "约 \(Int(portion.likelyGrams.rounded()))g（\(Int(portion.lowGrams.rounded()))–\(Int(portion.highGrams.rounded()))g）"
                                )
                            }
                            if let clarification = review.clarification {
                                Label(clarification.prompt, systemImage: "questionmark.bubble")
                                    .foregroundStyle(OrbitPalette.gold)
                                if clarification.kind == .hiddenIngredient {
                                    Picker("额外用油", selection: $oilAnswer) {
                                        Text("请选择").tag(nil as MealCaptureOilAnswer?)
                                        Text("没有额外用油")
                                            .tag(MealCaptureOilAnswer.noAdditionalOil as MealCaptureOilAnswer?)
                                        Text("采用估算范围")
                                            .tag(MealCaptureOilAnswer.useEstimatedRange as MealCaptureOilAnswer?)
                                    }
                                }
                            }
                            TextField(
                                review.clarification?.kind == .portion
                                    ? "回答澄清：这一份大约多少克"
                                    : "修正克重（可选）",
                                text: $correctedGrams
                            )
                            .keyboardType(.decimalPad)
                            Label("仍需在确认卡中再次确认后才会保存", systemImage: "checkmark.shield")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("生成待确认草稿", systemImage: "doc.badge.plus") {
                                Task { await stage(review) }
                            }
                            .disabled(isStaging || !hasAnsweredClarification(for: review))
                        } else {
                            Text("目前没有可供确认的食物候选。请返回对话，用语音或文字补充食物名称和大致份量。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("返回对话补充描述", systemImage: "arrow.uturn.backward") {
                                dismiss()
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section("需要处理") {
                        Text(errorMessage).foregroundStyle(OrbitPalette.coral)
                    }
                }
            }
            .navigationTitle("照片记餐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                analysisTask?.cancel()
                analysisTask = Task { @MainActor in
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw MealCaptureApplicationError.noPhotoEvidence
                        }
                        try Task.checkCancellation()
                        await analyze(data)
                    } catch is CancellationError {
                        return
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    selectedPhoto = nil
                }
            }
            .onDisappear {
                analysisTask?.cancel()
                analysisTask = nil
            }
            .sheet(isPresented: $showCamera) {
                CameraImagePicker { result in
                    showCamera = false
                    switch result {
                    case .success(let data):
                        guard let data else { return }
                        analysisTask?.cancel()
                        analysisTask = Task { @MainActor in await analyze(data) }
                    case .failure(let error):
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func analyze(_ data: Data) async {
        isAnalyzing = true
        errorMessage = nil
        review = nil
        selectedFoodID = nil
        correctedGrams = ""
        oilAnswer = nil
        defer { isAnalyzing = false }
        do {
            let result = try await dependencies.makeMealCaptureService().analyzePhoto(data)
            review = result
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stage(_ review: MealCaptureReview) async {
        guard !isStaging else { return }
        isStaging = true
        defer { isStaging = false }
        do {
            let correction: PortionEstimate?
            if let grams = Double(correctedGrams), grams.isFinite, grams > 0 {
                correction = try PortionEstimator().estimate(
                    evidence: [.userCorrection(low: grams, likely: grams, high: grams)],
                    food: review.resolution?.candidates.first
                )
            } else {
                correction = nil
            }
            let action = try await dependencies.makeMealCaptureService().stageMeal(
                review: review,
                selectedFoodID: selectedFoodID,
                correctedPortion: correction,
                oilAnswer: oilAnswer,
                mealType: mealType
            )
            onStaged(action)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openCamera() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "当前设备没有可用相机，可从照片中选择。"
            return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed: Bool
        switch status {
        case .authorized:
            allowed = true
        case .notDetermined:
            allowed = await AVCaptureDevice.requestAccess(for: .video)
        default:
            allowed = false
        }
        if allowed { showCamera = true }
        else { errorMessage = "请在系统设置中允许相机权限。" }
    }

    private func hasAnsweredClarification(for review: MealCaptureReview) -> Bool {
        guard selectedFoodID != nil || review.resolution?.autoPreselect != nil else {
            return false
        }
        switch review.clarification?.kind {
        case .foodIdentity, nil:
            return true
        case .portion:
            guard let grams = Double(correctedGrams), grams.isFinite else { return false }
            return grams > 0
        case .hiddenIngredient:
            return oilAnswer != nil
        case .cookingMethod, .preparation:
            return true
        }
    }

    private func routeName(_ route: MealCaptureReview.Route) -> String {
        switch route {
        case .packagedBarcode: "本地条码"
        case .nutritionLabel: "本地营养标签"
        case .qwenVision: "Qwen 菜品观察"
        case .manualDescription: "语音补充"
        }
    }

    private static func defaultMealType(now: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        switch hour {
        case 5..<10: "breakfast"
        case 10..<15: "lunch"
        case 17..<22: "dinner"
        default: "snack"
        }
    }
}

@MainActor
private struct CameraImagePicker: UIViewControllerRepresentable {
    let completion: @MainActor (Result<Data?, CameraImagePickerError>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: @MainActor (Result<Data?, CameraImagePickerError>) -> Void

        init(completion: @escaping @MainActor (Result<Data?, CameraImagePickerError>) -> Void) {
            self.completion = completion
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage,
                  let jpeg = CameraImageOrientationNormalizer.uprightJPEG(from: image) else {
                completion(.failure(.unableToNormalizeOrientation))
                return
            }
            completion(.success(jpeg))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completion(.success(nil))
        }
    }
}

private enum CameraImagePickerError: Error, LocalizedError {
    case unableToNormalizeOrientation

    var errorDescription: String? {
        "无法安全校正照片方向，请改用照片库选择或重新拍摄。"
    }
}
