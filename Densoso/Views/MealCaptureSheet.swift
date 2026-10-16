import AVFoundation
import DensosoDomain
import PhotosUI
import SwiftUI
import UIKit

@MainActor
struct MealCaptureSheet: View {
    @Environment(Dependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

    let onSendToAgent: (MultimodalModelRequest) -> Void

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCamera = false
    @State private var preparedRequest: MultimodalModelRequest?
    @State private var isPreparing = false
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
                    Text("照片会先在本机缩放并移除元数据，再交给当前 Agent。原图和图像字节不会保存到对话历史。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if isPreparing {
                    Section { ProgressView("正在本机清理照片并提取标签线索") }
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
                        await prepareForAgent(data)
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
            }
            .sheet(isPresented: $showCamera) {
                CameraImagePicker { result in
                    showCamera = false
                    switch result {
                    case .success(let data):
                        guard let data else { return }
                        preparationTask?.cancel()
                        preparationTask = Task { @MainActor in await prepareForAgent(data) }
                    case .failure(let error):
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func prepareForAgent(_ originalData: Data) async {
        isPreparing = true
        preparedRequest = nil
        errorMessage = nil
        defer { isPreparing = false }
        do {
            preparedRequest = try await dependencies.makeMealCaptureService()
                .prepareForAgent(originalData: originalData)
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
