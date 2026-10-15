import DensosoDomain
import SwiftUI

struct ChatScreen: View {
    @Environment(Dependencies.self) private var dependencies
    @Environment(AppState.self) private var appState

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var inputSource: VoiceCommandEnvelope.Source = .manualText
    @State private var isProcessing = false
    @State private var voiceDraftSummary: String?
    @State private var didHydratePersistedMessages = false
    @State private var showMealCapture = false
    @State private var pendingWatchMessageID: UUID?
    @State private var claimedWatchMessageIDs = Set<UUID>()
    @State private var displayedWatchTranscriptIDs = Set<UUID>()
    @State private var pendingWatchOriginalText: String?
    @State private var pendingWatchAttemptText: String?
    @State private var pendingWatchAttemptRequestID: UUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                conversation
                composer
            }
            .navigationTitle("今天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    runtimeBadge
                }
            }
            .onAppear(perform: prepareInitialState)
            .task { restorePendingWatchTranscript() }
            .onChange(of: dependencies.agentSession.restoredVisibleMessages.count) { _, _ in
                hydratePersistedMessagesIfNeeded()
            }
            .onChange(of: dependencies.watchConnectivityCoordinator.pendingTranscriptRevision) { _, _ in
                restorePendingWatchTranscript()
            }
            .onChange(of: dependencies.speechService.transcribedText) { _, newValue in
                inputText = newValue
                inputSource = dependencies.speechService.envelopeSource
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    OrbitScreenHeader(
                        eyebrow: "Conversation is capture",
                        title: "今天，想记录什么？",
                        subtitle: "告诉我吃了什么、练了什么；涉及写入时会先生成可检查的草稿。"
                    )
                    .padding(.bottom, 4)

                    DailyHealthBriefCard(brief: dependencies.healthIntelligenceService.dailyBrief)

                    promptChips

                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if isProcessing, !dependencies.agentSession.streamedText.isEmpty {
                        MessageBubble(
                            message: ChatMessage(
                                text: dependencies.agentSession.streamedText,
                                isUser: false
                            )
                        )
                    }

                    if !dependencies.agentSession.pendingActions.isEmpty {
                        ForEach(dependencies.agentSession.pendingActions) { action in
                            PendingActionConfirmationCard(action: action) {
                                confirm(action)
                            } onReject: {
                                Task {
                                    do {
                                        try await dependencies.agentSession.rejectPendingAction(id: action.id)
                                        dependencies.watchConnectivityCoordinator.refreshApplicationContext()
                                        addMessage(text: "已拒绝该记录草稿，未保存任何健康数据。", isUser: false)
                                    } catch {
                                        addMessage(text: "无法拒绝草稿：\(error.localizedDescription)", isUser: false)
                                    }
                                }
                            }
                        }
                    }

                    if let voiceDraftSummary {
                        Label(voiceDraftSummary, systemImage: "waveform.badge.checkmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .orbitCard()
                    }

                    if isProcessing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在整理草稿")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: dependencies.agentSession.streamedText) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .sheet(isPresented: $showMealCapture) {
                MealCaptureSheet { action in
                    Task {
                        try? await dependencies.agentSession.reloadPendingActions()
                        voiceDraftSummary = "照片餐食草稿已生成：\(action.payload.summary)；确认前不会保存。"
                    }
                }
                .presentationBackground { OrbitBackground() }
            }
        }
    }

    private var promptChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                promptButton("记录午餐", systemImage: "fork.knife", text: "我想记录午餐")
                promptButton("生成训练计划", systemImage: "figure.strengthtraining.traditional", text: "帮我生成训练计划")
                promptButton("查看本周", systemImage: "chart.bar.xaxis", text: "查看本周热量缺口")
            }
        }
        .contentMargins(.horizontal, 1, for: .scrollContent)
    }

    private func promptButton(_ title: String, systemImage: String, text: String) -> some View {
        Button(title, systemImage: systemImage) {
            inputText = text
            inputSource = .manualText
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Button {
                showMealCapture = true
            } label: {
                Image(systemName: "camera.fill")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel("照片记餐")

            Button {
                Task { await toggleVoice() }
            } label: {
                Image(systemName: dependencies.speechService.isRecording ? "stop.fill" : "mic.fill")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(dependencies.speechService.isRecording ? OrbitPalette.coral : OrbitPalette.gold)
            .accessibilityLabel(dependencies.speechService.isRecording ? "停止录音" : "开始录音")

            TextField("输入或语音…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .disabled(isProcessing)
                .onSubmit {
                    Task { await send(text: inputText) }
                }

            Button {
                if isProcessing {
                    dependencies.agentSession.cancelActiveRequest()
                } else {
                    Task { await send(text: inputText) }
                }
            } label: {
                Image(systemName: isProcessing ? "xmark" : "arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(!isProcessing && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(isProcessing ? "取消请求" : "发送")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var runtimeBadge: some View {
        switch dependencies.speechService.runtime {
        case .speechAnalyzer:
            OrbitStatusBadge(text: "设备端语音", tone: .success)
        case .legacySpeech:
            OrbitStatusBadge(text: "兼容语音", tone: .blue)
        case .qwenASR:
            OrbitStatusBadge(text: "Qwen 语音兜底", tone: .gold)
        case .manualEntry:
            OrbitStatusBadge(text: "手动输入")
        }
    }

    private func prepareInitialState() {
        _ = try? dependencies.healthIntelligenceService.refresh()
        hydratePersistedMessagesIfNeeded()
        if messages.isEmpty {
            addMessage(text: "你好，我是 densoso。使用语音或文字告诉我你吃了什么、练了什么。", isUser: false)
        }
        if let pendingMealText = appState.pendingMealText {
            inputText = pendingMealText
            appState.pendingMealText = nil
            addMessage(text: "已收到系统语音转写草稿，请检查后再发送；尚未保存任何餐食记录。", isUser: false)
        }
        Task { await dependencies.speechService.refreshRuntime() }
    }

    private func hydratePersistedMessagesIfNeeded() {
        guard !didHydratePersistedMessages,
              !dependencies.agentSession.restoredVisibleMessages.isEmpty else {
            return
        }
        messages = dependencies.agentSession.restoredVisibleMessages.map {
            ChatMessage(text: $0.text, isUser: $0.isUser)
        }
        didHydratePersistedMessages = true
    }

    private func toggleVoice() async {
        let speech = dependencies.speechService
        if speech.isRecording {
            await speech.stopRecording()
            inputText = speech.transcribedText
            inputSource = speech.envelopeSource
            if !speech.transcribedText.isEmpty {
                let envelope = VoiceCommandEnvelope(
                    text: speech.transcribedText,
                    source: speech.envelopeSource
                )
                let kind = VoiceCommandRouter().route(envelope)
                voiceDraftSummary = "已生成\(kind.displayName)草稿，请检查文字后点击发送；尚未保存任何记录。"
            }
        } else {
            await speech.refreshRuntime()
            let authorized = await speech.requestAuthorization()
            if authorized {
                do {
                    try await speech.startRecording()
                } catch {
                    addMessage(text: "无法启动语音：\(error.localizedDescription)。", isUser: false)
                }
            } else {
                addMessage(text: "请在系统设置中开启麦克风和语音识别权限。", isUser: false)
            }
        }
    }

    private func send(text: String) async {
        let userText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else { return }
        guard !isProcessing else { return }
        isProcessing = true
        appState.isAgentProcessing = true
        defer {
            isProcessing = false
            appState.isAgentProcessing = false
        }
        let sourceForRequest = inputSource
        let watchMessageID = sourceForRequest == .watchDictation ? pendingWatchMessageID : nil
        let agentRequestID: UUID?
        if let watchMessageID {
            if userText == pendingWatchOriginalText {
                agentRequestID = watchMessageID
            } else {
                if pendingWatchAttemptText != userText {
                    pendingWatchAttemptText = userText
                    pendingWatchAttemptRequestID = UUID()
                }
                agentRequestID = pendingWatchAttemptRequestID
            }
        } else {
            agentRequestID = nil
        }
        var watchTranscriptWasDurablyHandled = false
        let route = VoiceCommandRouter().route(
            VoiceCommandEnvelope(text: userText, source: sourceForRequest)
        )
        inputText = ""
        inputSource = .manualText
        defer {
            if let watchMessageID {
                if watchTranscriptWasDurablyHandled {
                    try? dependencies.watchConnectivityCoordinator.markTranscriptProcessed(watchMessageID)
                    claimedWatchMessageIDs.remove(watchMessageID)
                    pendingWatchMessageID = nil
                    pendingWatchOriginalText = nil
                    pendingWatchAttemptText = nil
                    pendingWatchAttemptRequestID = nil
                } else {
                    inputText = userText
                    inputSource = .watchDictation
                    voiceDraftSummary = "尚未生成可恢复的云端草稿；Watch 转写仍保存在本机，可检查后重试。"
                }
            }
            dependencies.watchConnectivityCoordinator.refreshApplicationContext()
        }
        voiceDraftSummary = "正在处理\(route.displayName)草稿；涉及写入时仍需在确认卡片中确认。"
        if let watchMessageID {
            let requestWasPersisted: Bool
            if let agentRequestID {
                requestWasPersisted = await dependencies.agentSession.hasPersistedRequestHistory(for: agentRequestID)
            } else {
                requestWasPersisted = false
            }
            if displayedWatchTranscriptIDs.insert(watchMessageID).inserted && !requestWasPersisted {
                addMessage(text: userText, isUser: true)
            }
        } else {
            addMessage(text: userText, isUser: true)
        }

        let path = IntelligenceRoutingPolicy().path(
            for: dependencies.intelligencePreferences.mode,
            capabilities: .current
        )
        do {
            switch path {
            case .localOnDevice:
                let result = try await dependencies.localIntelligence.extract(from: userText)
                addMessage(text: result.reply, isUser: false)
                if let suggestion = result.suggestion {
                    let amount = suggestion.amount.map { "（\($0)）" } ?? ""
                    addMessage(
                        text: "已生成本地\(suggestion.kind == .meal ? "餐食" : "训练")草稿：\(suggestion.item)\(amount)。尚未保存，请在确认界面补全并确认。",
                        isUser: false
                    )
                }
            case .cloudDeepSeek, .cloudQwen:
                let response = try await dependencies.agentSession.send(userText: userText, requestID: agentRequestID)
                watchTranscriptWasDurablyHandled = watchMessageID != nil
                addMessage(text: response.text, isUser: false)
            case .manual:
                addMessage(text: "本地智能当前不可用；你的输入尚未保存。可在设置中选择 DeepSeek 云端处理，或继续手动编辑。", isUser: false)
            }
        } catch {
            addMessage(text: "处理失败：\(error.localizedDescription)。你的记录尚未保存。", isUser: false)
        }
    }

    private func addMessage(text: String, isUser: Bool) {
        messages.append(ChatMessage(text: text, isUser: isUser))
    }

    private func confirm(_ action: PendingAction) {
        Task {
            do {
                let message = try await dependencies.agentSession.confirmPendingAction(id: action.id)
                _ = try? dependencies.healthIntelligenceService.refresh()
                dependencies.watchConnectivityCoordinator.refreshApplicationContext()
                addMessage(text: message, isUser: false)
            } catch {
                addMessage(text: "未能保存：\(error.localizedDescription)", isUser: false)
            }
        }
    }

    private func restorePendingWatchTranscript() {
        guard inputText.isEmpty, pendingWatchMessageID == nil else { return }
        do {
            guard let pending = try dependencies.watchConnectivityCoordinator.nextPendingTranscript(
                excluding: claimedWatchMessageIDs
            ) else { return }
            pendingWatchMessageID = pending.messageID
            claimedWatchMessageIDs.insert(pending.messageID)
            pendingWatchOriginalText = pending.text
            pendingWatchAttemptText = nil
            pendingWatchAttemptRequestID = nil
            inputText = pending.text
            inputSource = .watchDictation
            voiceDraftSummary = "已收到 Watch 系统听写；检查或编辑后发送，涉及写入时仍需确认。"
        } catch {
            voiceDraftSummary = "无法读取 Watch 草稿：\(error.localizedDescription)"
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let last = messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}

private extension VoiceCommandKind {
    var displayName: String {
        switch self {
        case .mealDraft: "餐食"
        case .workoutPlanDraft: "训练计划"
        case .strengthSetDraft: "力量组次"
        case .readOnlyQuery: "查询"
        case .unclassified: "文本"
        }
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 44) }

            Group {
                if message.isUser {
                    Text(message.text)
                } else {
                    AssistantBlockView(document: RestrictedMarkdownRenderer.parse(message.text))
                }
            }
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(message.isUser ? Color.primary : OrbitPalette.surface)
                .foregroundStyle(message.isUser ? Color(.systemBackground) : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    if !message.isUser {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(OrbitPalette.hairline, lineWidth: 0.5)
                    }
                }

            if !message.isUser { Spacer(minLength: 44) }
        }
    }
}

#Preview {
    ChatScreen()
        .modelContainer(for: [UserProfile.self, MealRecord.self], inMemory: true)
        .environment(Dependencies())
        .environment(AppState.shared)
}
