import AVFoundation
import DensosoDomain
import PhotosUI
import SwiftUI
import UIKit

@MainActor
struct MealCaptureSheet: View {
    @Environment(Dependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

    let supplementalText: String
    let onSendToAgent: (MultimodalModelRequest) -> Void
    let onLocalPendingAction: (PendingAction) -> Void

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCamera = false
    @State private var preparedRequest: MultimodalModelRequest?
    @State private var localReview: MealCaptureReview?
    @State private var textOnlyFallback: String?
    @State private var selectedLocalFoodID: String?
    @State private var portionAnswerText = ""
    @State private var isPreparing = false
    @State private var isStagingLocal = false
    @State private var errorMessage: String?
    @State private var preparationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("餐食照片") {
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
                    Text("照片会先在本机清理。条码和完整营养标签可在本机生成待确认草稿，不会把图片发给 Agent；开放照片才会进入当前 Agent。原图不会保存到对话历史。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if isPreparing {
                    Section { ProgressView("正在本机清理照片并提取标签线索") }
                }

                if let localReview {
                    Section("本机识别结果") {
                        LabeledContent("食物", value: localReview.label)
                        if let automatic = localReview.resolution?.autoPreselect {
                            LabeledContent("候选", value: automatic.entry.name)
                        } else if let resolution = localReview.resolution {
                            Picker("选择最接近的候选", selection: $selectedLocalFoodID) {
                                Text("请选择").tag(nil as String?)
                                ForEach(resolution.candidates) { candidate in
                                    Text(candidate.entry.name).tag(Optional(candidate.id))
                                }
                            }
                        }
                        if let portion = localReview.portion {
                            Text("标签或包装每份约 \(Int(portion.likelyGrams.rounded())) 克；请填写本次实际吃下的克数或份数。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let clarification = localReview.clarification,
                           clarification.kind == .portion {
                            Text(clarification.prompt)
                                .font(.footnote)
                        }
                        TextField(portionAnswerPrompt, text: $portionAnswerText)
                        Text("图片和 OCR 原文只在本机处理；这里仅创建待确认草稿，确认前不会写入健康记录。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("生成本机待确认草稿", systemImage: "checkmark.circle") {
                            Task { await stageLocalReview(localReview) }
                        }
                        .disabled(isPreparing || isStagingLocal || !canStageLocalReview(localReview))
                    }
                }

                if let textOnlyFallback {
                    Section("需要补充信息") {
                        Text(textOnlyFallback)
                            .font(.footnote)
                        Button("继续用文字整理", systemImage: "text.bubble") {
                            onSendToAgent(MultimodalModelRequest(userText: textOnlyFallback))
                            dismiss()
                        }
                        .disabled(isPreparing || isStagingLocal)
                    }
                }

                if let preparedRequest {
                    Section("本机提取的线索") {
                        if preparedRequest.mealEvidence.isEmpty {
                            Text("未识别到条码或营养标签；Agent 会根据照片准备可检查的草稿。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(preparedRequest.mealEvidence) { evidence in
                                LabeledContent(evidence.kind.rawValue, value: String(evidence.value.prefix(120)))
                            }
                        }
                        Text("照片观察和 OCR 线索都属于不可信输入。涉及餐食写入时仍会由 Agent 生成待确认草稿，必须由你确认后保存。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("发送给 Agent 整理待确认草稿", systemImage: "paperplane") {
                            onSendToAgent(preparedRequest)
                            dismiss()
                        }
                        .disabled(isPreparing)
                    }
                }

                if let errorMessage {
                    Section("需要处理") {
                        Text(errorMessage)
                            .foregroundStyle(OrbitPalette.coral)
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
                preparationTask?.cancel()
                preparationTask = Task { @MainActor in
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw MealCaptureApplicationError.noPhotoEvidence
                        }
                        try Task.checkCancellation()
                        await prepareCapture(data)
                    } catch is CancellationError {
                        return
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    selectedPhoto = nil
                }
            }
            .onDisappear {
                preparationTask?.cancel()
                preparationTask = nil
                preparedRequest = nil
                localReview = nil
                textOnlyFallback = nil
            }
            .sheet(isPresented: $showCamera) {
                CameraImagePicker { result in
                    showCamera = false
                    switch result {
                    case .success(let data):
                        guard let data else { return }
                        preparationTask?.cancel()
                        preparationTask = Task { @MainActor in await prepareCapture(data) }
                    case .failure(let error):
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func prepareCapture(_ originalData: Data) async {
        isPreparing = true
        preparedRequest = nil
        localReview = nil
        textOnlyFallback = nil
        errorMessage = nil
        defer { isPreparing = false }
        do {
            let result = try await dependencies.makeMealCaptureService()
                .prepareForAgent(originalData: originalData)
            switch result {
            case .agentRequest(let request):
                preparedRequest = request
            case .localReview(let review):
                localReview = review
                selectedLocalFoodID = review.resolution?.autoPreselect?.id
                if let answer = LocalMealPortionAnswerParser().parse(
                    supplementalText,
                    matching: review.label,
                    allowBareAmount: false
                ) {
                    if case .servings = answer,
                       review.portion?.source != .packageServing {
                        portionAnswerText = ""
                    } else {
                        portionAnswerText = displayText(for: answer)
                    }
                } else {
                    portionAnswerText = ""
                }
            case .textOnlyFallback(let prompt):
                textOnlyFallback = prompt
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func canStageLocalReview(_ review: MealCaptureReview) -> Bool {
        guard let resolution = review.resolution,
              resolution.autoPreselect != nil || selectedLocalFoodID != nil else {
            return false
        }
        if review.clarification?.kind == .portion {
            guard let answer = parsedPortionAnswer(for: review) else { return false }
            switch answer {
            case .grams:
                return true
            case .servings:
                return review.portion?.source == .packageServing
            }
        }
        return review.portion != nil
    }

    private var portionAnswerPrompt: String {
        guard localReview?.portion?.source == .packageServing else {
            return "本次实际份量（克，例如 180g）"
        }
        return "本次实际份量（克或份数，如 180g、半份、2份）"
    }

    private func parsedPortionAnswer(for review: MealCaptureReview) -> LocalMealPortionAnswer? {
        LocalMealPortionAnswerParser().parse(
            portionAnswerText,
            matching: review.label,
            allowBareAmount: true
        )
    }

    private func stageLocalReview(_ review: MealCaptureReview) async {
        guard canStageLocalReview(review), let resolution = review.resolution else { return }
        isStagingLocal = true
        defer { isStagingLocal = false }
        do {
            let selectedCandidate = resolution.candidates.first {
                $0.id == selectedLocalFoodID
            } ?? resolution.autoPreselect
            let correction: PortionEstimate?
            if let answer = parsedPortionAnswer(for: review) {
                switch answer {
                case .grams(let grams):
                    correction = try PortionEstimator().estimate(
                        evidence: [.userCorrection(low: grams, likely: grams, high: grams)],
                        food: selectedCandidate
                    )
                case .servings(let count):
                    guard let packagePortion = review.portion,
                          packagePortion.source == .packageServing else {
                        errorMessage = "本机没有可换算的每份重量，请填写克数。"
                        return
                    }
                    correction = try PortionEstimator().estimate(
                        evidence: [
                            .packageServing(gramsPerServing: packagePortion.likelyGrams, count: count),
                        ],
                        food: selectedCandidate
                    )
                }
            } else {
                correction = nil
            }
            let explicitSelection = selectedLocalFoodID == resolution.autoPreselect?.id
                ? nil
                : selectedLocalFoodID
            let action = try await dependencies.makeMealCaptureService().stageMeal(
                review: review,
                selectedFoodID: explicitSelection,
                correctedPortion: correction,
                userNote: supplementalText
            )
            onLocalPendingAction(action)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func displayText(for answer: LocalMealPortionAnswer) -> String {
        switch answer {
        case .grams(let grams): return "\(grams) 克"
        case .servings(let count): return count == 0.5 ? "半份" : "\(count)份"
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
