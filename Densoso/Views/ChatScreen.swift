import DensosoDomain
import SwiftUI

struct ChatScreen: View {
    @Environment(Dependencies.self) private var dependencies
    @Environment(AppState.self) private var appState
    @FocusState private var composerFocused: Bool

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var inputSource: VoiceCommandEnvelope.Source = .manualText
    @State private var isProcessing = false
    @State private var voiceDraftSummary: String?
    @State private var didHydratePersistedMessages = false
    @State private var showMealCapture = false
    @State private var showTextEditor = false
    @State private var pendingWatchMessageID: UUID?
    @State private var claimedWatchMessageIDs = Set<UUID>()
    @State private var displayedWatchTranscriptIDs = Set<UUID>()
    @State private var pendingWatchOriginalText: String?
    @State private var pendingWatchAttemptText: String?
    @State private var pendingWatchAttemptRequestID: UUID?
    @State private var dailyLoopSnapshot: DailyLoopSnapshot?

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
            .onAppear {
                Task {
                    await prepareInitialState()
                    restorePendingWatchTranscript()
                }
            }
            .onChange(of: dependencies.agentSession.pendingActions) { _, _ in
                Task { await refreshDailyLoopSnapshot() }
            }
            .onChange(of: dependencies.healthIntelligenceService.dailyBrief) { _, _ in
                Task { await refreshDailyLoopSnapshot() }
            }
            .onChange(of: appState.shouldFocusComposer) { _, shouldFocus in
                if shouldFocus { focusComposer() }
            }
            .onChange(of: appState.pendingMealText) { _, pendingMealText in
                receivePendingMealText(pendingMealText)
            }
            .onChange(of: dependencies.agentSession.restoredVisibleMessages.count) { _, _ in
                hydratePersistedMessagesIfNeeded()
            }
            .onChange(of: dependencies.watchConnectivityCoordinator.pendingTranscriptRevision) { _, _ in
                restorePendingWatchTranscript()
            }
            .onChange(of: dependencies.speechService.transcribedText) { _, newValue in
                inputText = newValue
                inputSource = dependencies.speechService.envelopeSource
                if !newValue.isEmpty { showTextEditor = true }
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

                    DailyLoopSnapshotCard(snapshot: dailyLoopSnapshot)
                        .id("daily-loop-snapshot-anchor")

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
                                        await refreshDailyLoopSnapshot()
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
            .onChange(of: appState.shouldScrollToDailyLoop) { _, shouldScroll in
                guard shouldScroll else { return }
                Task { await refreshDailyLoopSnapshot() }
                withAnimation { proxy.scrollTo("daily-loop-snapshot-anchor", anchor: .top) }
                appState.shouldScrollToDailyLoop = false
            }
            .accessibilityIdentifier("today-conversation-scroll")
            .onChange(of: dependencies.agentSession.streamedText) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .sheet(isPresented: $showMealCapture) {
                MealCaptureSheet(
                    supplementalText: inputText,
                    onSendToAgent: { request in
                        let requestWithSupplement = request.includingSupplementalText(
                            inputText,
                            source: inputSource
                        )
                        Task {
                            await send(
                                text: requestWithSupplement.userText,
                                multimodalRequest: requestWithSupplement
                            )
                        }
                    },
                    onLocalPendingAction: { _ in
                        inputText = ""
                        inputSource = .manualText
                        Task {
                            do {
                                try await dependencies.agentSession.reloadPendingActions()
                                await refreshDailyLoopSnapshot()
                                dependencies.watchConnectivityCoordinator.refreshApplicationContext()
                                addMessage(text: "本机识别已生成待确认餐食草稿，请检查后确认。", isUser: false)
                            } catch {
                                addMessage(text: "待确认草稿已生成，但列表刷新失败：\(error.localizedDescription)", isUser: false)
                            }
                        }
                    }
                )
                .presentationBackground { OrbitBackground() }
            }
        }
    }

    private var promptChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(dailyLoopSnapshot?.quickActions ?? [], id: \.rawValue) { action in
                    promptButton(for: action)
                }
            }
        }
        .contentMargins(.horizontal, 1, for: .scrollContent)
    }

    private func promptButton(for action: DailyLoopQuickAction) -> some View {
        let details = quickActionDetails(for: action)
        return Button(details.title, systemImage: details.systemImage) {
            inputText = details.prompt
            inputSource = .manualText
            showTextEditor = true
            voiceDraftSummary = nil
            focusComposer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(details.title)
    }

    private func quickActionDetails(for action: DailyLoopQuickAction) -> (title: String, systemImage: String, prompt: String) {
        switch action {
        case .logMeal:
            return ("记录餐食", "fork.knife", "我想记录一餐")
        case .logWeight:
            return ("记录体重", "scalemass", "我想记录体重")
        case .planWorkout:
            return ("训练计划", "figure.run", "帮我生成训练计划")
        case .dailyCheckIn:
            return ("记录今日状态", "heart.text.square", "我想记录今天的状态")
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if showTextEditor {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("检查或编辑文字", text: $inputText, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .focused($composerFocused)
                        .submitLabel(.send)
                        .disabled(isProcessing)
                        .accessibilityIdentifier("today-composer")
                        .onSubmit {
                            Task { await send(text: inputText) }
                        }

                    Button {
                        Task { await send(text: inputText) }
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .disabled(isProcessing || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("发送")
                    .accessibilityIdentifier("today-send")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(OrbitPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityElement(children: .contain)
            }

            HStack(spacing: 14) {
                Button {
                    showMealCapture = true
                } label: {
                    Image(systemName: "camera.fill")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(isProcessing)
                .accessibilityLabel("照片记餐")
                .accessibilityIdentifier("today-photo-secondary")

                Spacer(minLength: 0)

                Button {
                    Task { await toggleVoice() }
                } label: {
                    Label(
                        dependencies.speechService.isRecording ? "停止录音" : "开始说话",
                        systemImage: dependencies.speechService.isRecording ? "stop.fill" : "mic.fill"
                    )
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(dependencies.speechService.isRecording ? OrbitPalette.coral : OrbitPalette.gold)
                .disabled(isProcessing)
                .accessibilityLabel(dependencies.speechService.isRecording ? "停止录音" : "开始说话")
                .accessibilityIdentifier("today-voice-primary")

                Spacer(minLength: 0)

                if isProcessing {
                    Button {
                        dependencies.agentSession.cancelActiveRequest()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .accessibilityLabel("取消请求")
                } else {
                    Button {
                        showTextEditor.toggle()
                        if showTextEditor {
                            focusComposer()
                        } else {
                            composerFocused = false
                        }
                    } label: {
                        Label(showTextEditor ? "收起文字" : "文字", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel(showTextEditor ? "收起文字编辑" : "编辑文字")
                    .accessibilityIdentifier("today-text-entry")
                }
            }
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

    private func prepareInitialState() async {
        _ = try? await dependencies.healthIntelligenceService.refresh()
        await refreshDailyLoopSnapshot()
        if appState.shouldFocusComposer { focusComposer() }
        hydratePersistedMessagesIfNeeded()
        if messages.isEmpty {
            addMessage(text: "你好，我是 densoso。使用语音或文字告诉我你吃了什么、练了什么。", isUser: false)
        }
        receivePendingMealText(appState.pendingMealText)
        Task { await dependencies.speechService.refreshRuntime() }
    }

    private func receivePendingMealText(_ pendingMealText: String?) {
        guard let pendingMealText,
              appState.pendingMealText == pendingMealText else { return }
        appState.pendingMealText = nil
        inputText = AppIntentInbox.mergedMealText(existing: inputText, incoming: pendingMealText)
        inputSource = .appIntent
        showTextEditor = true
        addMessage(text: "已收到系统语音转写草稿并加入文字输入框，请检查编辑；尚未保存任何餐食记录。", isUser: false)
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

    private func refreshDailyLoopSnapshot() async {
        do {
            dailyLoopSnapshot = try await dependencies.dailyLoopSnapshotService.snapshot()
        } catch {
            dailyLoopSnapshot = nil
        }
    }

    private func focusComposer() {
        showTextEditor = true
        composerFocused = true
        appState.shouldFocusComposer = false
    }

    private func toggleVoice() async {
        let speech = dependencies.speechService
        if speech.isRecording {
            await speech.stopRecording()
            inputText = speech.transcribedText
            inputSource = speech.envelopeSource
            if !speech.transcribedText.isEmpty {
                showTextEditor = true
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

    private func send(text: String, multimodalRequest: MultimodalModelRequest? = nil) async {
        let userText = (multimodalRequest?.userText ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
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
            if multimodalRequest?.image != nil, path != .cloudDeepSeek {
                throw ProviderError.unsupportedCapability(.vision)
            }
            switch path {
            case .localOnDevice:
                let result = try await dependencies.localIntelligence.extract(from: userText)
                present(
                    AgentTurnContract.local(result),
                    originalText: userText,
                    source: sourceForRequest
                )
            case .cloudDeepSeek, .cloudQwen:
                let pendingActionIDsBeforeTurn = Set(dependencies.agentSession.pendingActions.map(\.id))
                let response: AgentResponse
                if let multimodalRequest {
                    response = try await dependencies.agentSession.send(
                        multimodalRequest: multimodalRequest,
                        requestID: agentRequestID
                    )
                } else {
                    let inputEnvelope = VoiceCommandEnvelope(
                        text: userText,
                        source: sourceForRequest
                    ).asInputEnvelope()
                    response = try await dependencies.agentSession.send(
                        userText: userText,
                        inputEnvelope: inputEnvelope,
                        requestID: agentRequestID
                    )
                }
                let stagedActions = dependencies.agentSession.pendingActions.filter {
                    !pendingActionIDsBeforeTurn.contains($0.id)
                }
                present(
                    AgentTurnContract.cloud(reply: response.text, stagedActions: stagedActions),
                    originalText: userText,
                    source: sourceForRequest
                )
                watchTranscriptWasDurablyHandled = watchMessageID != nil
                await refreshDailyLoopSnapshot()
            case .manual:
                addMessage(text: "本地智能当前不可用；你的输入尚未保存。可在设置中选择 DeepSeek 云端处理，或继续手动编辑。", isUser: false)
            }
        } catch {
            addMessage(text: "处理失败：\(error.localizedDescription)。你的记录尚未保存。", isUser: false)
        }
    }

    private func present(
        _ turn: AgentTurnResult,
        originalText: String,
        source: VoiceCommandEnvelope.Source
    ) {
        addMessage(text: turn.text, isUser: false)
        let proposal = turn.intents.compactMap { intent -> LocalRecordSuggestion? in
            guard case .captureProposal(let suggestion) = intent else { return nil }
            return suggestion
        }.first
        guard let suggestion = proposal else {
            // PendingActionConfirmationCard reads the shared AgentSession queue.
            return
        }

        let subject = switch suggestion.kind {
        case .meal: "餐食"
        case .workoutPlan: "未来训练计划"
        }
        let amount = suggestion.amount.map { "（\($0)）" } ?? ""
        inputText = originalText
        inputSource = source
        showTextEditor = true
        addMessage(
            text: "本机识别到可能的\(subject)意图（\(suggestion.item)\(amount)），目前还没有待确认草稿，也没有保存数据。原话保留在编辑框，可修改后切换云端代理继续生成统一确认草稿。",
            isUser: false
        )
    }

    private func addMessage(text: String, isUser: Bool) {
        messages.append(ChatMessage(text: text, isUser: isUser))
    }

    private func confirm(_ action: PendingAction) {
        Task {
            do {
                let message = try await dependencies.agentSession.confirmPendingAction(id: action.id)
                _ = try? await dependencies.healthIntelligenceService.refresh()
                await refreshDailyLoopSnapshot()
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
            showTextEditor = true
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
