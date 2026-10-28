import DensosoDomain
import Foundation
import SwiftData
import SwiftUI

struct ChatScreen: View {
    @Environment(Dependencies.self) private var dependencies
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @FocusState private var composerFocused: Bool

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var inputSource: VoiceCommandEnvelope.Source = .manualText
    @State private var agentUIState: AgentUIState = .idle
    @State private var voiceUIState: VoiceCaptureUIState = .idle
    @State private var imageCaptureState: MealImageCaptureState = .idle
    @State private var pendingActionIDsAtTurnStart = Set<UUID>()
    @State private var currentTurnHasDraft = false
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
    @State private var dailyLoopSnapshotReadError: String?
    @State private var isLoadingDailyLoopSnapshot = true
    @State private var dailyLoopSnapshotRefreshQueue = DailyLoopSnapshotRefreshQueue()
    @State private var didRecordInitialTodayContent = false
    @State private var todayMeals: [MealRecord] = []
    @State private var todayMealsReadError: String?
    @State private var correctingMealID: UUID?
    @State private var mealCorrectionError: String?

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
                    await PerformanceSignposts.measureAsync("Today.InitialDataReady") {
                        await prepareInitialState()
                    }
                    restorePendingWatchTranscript()
                }
            }
            .onChange(of: dependencies.agentSession.pendingActions) { _, _ in
                Task { await refreshDailyLoopSnapshot() }
            }
            .onChange(of: dependencies.healthIntelligenceService.dailyBrief) { _, _ in
                Task { await refreshDailyLoopSnapshot() }
            }
            .onChange(of: dependencies.healthIntelligenceService.dailyBriefSourceFingerprint) { _, _ in
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
                updateVoiceUIState(from: dependencies.speechService.state, transcribedText: newValue)
                if !newValue.isEmpty { showTextEditor = true }
            }
            .onChange(of: dependencies.speechService.state) { _, newValue in
                updateVoiceUIState(from: newValue, transcribedText: dependencies.speechService.transcribedText)
            }
            .onChange(of: dependencies.agentSession.latestEvent) { _, event in
                guard let event else { return }
                transitionAgentUI(using: event)
                transitionImageUI(using: event)
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
                    .onAppear {
                        guard !didRecordInitialTodayContent else { return }
                        didRecordInitialTodayContent = true
                        PerformanceSignposts.event("Today.InitialContentRendered")
                    }

                    DailyLoopSnapshotCard(
                        snapshot: dailyLoopSnapshot,
                        errorMessage: dailyLoopSnapshotReadError,
                        isLoading: isLoadingDailyLoopSnapshot
                    ) {
                        Task { await refreshDailyLoopSnapshot(refreshHealth: true) }
                    }
                    .id("daily-loop-snapshot-anchor")

                    confirmedMealsSection

                    DailyHealthBriefCard(brief: dependencies.healthIntelligenceService.dailyBrief)

                    promptChips

                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if agentUIState.isBusy, !dependencies.agentSession.streamedText.isEmpty {
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
                                        setAgentUIState(
                                            dependencies.agentSession.pendingActions.isEmpty
                                                ? .completed
                                                : .awaitingConfirmation
                                        )
                                        await refreshDailyLoopSnapshot()
                                        dependencies.watchConnectivityCoordinator.refreshApplicationContext()
                                        addMessage(text: "已拒绝该记录草稿，未保存任何健康数据。", isUser: false)
                                    } catch {
                                        let errorMessage = SharedErrorDescriptor.mapped(
                                            from: error,
                                            fallback: .actionConflictFallback
                                        ).userMessage
                                        setAgentUIState(.failed)
                                        addMessage(text: "无法拒绝草稿：\(errorMessage)", isUser: false)
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

                    if agentUIState.isBusy || agentUIState == .draftReady || agentUIState == .awaitingConfirmation {
                        HStack(spacing: 10) {
                            if agentUIState.isBusy { ProgressView() }
                            Text(agentUIState.statusMessage ?? "正在整理你的请求")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if !agentUIState.isBusy, let voiceStatus = voiceUIState.statusMessage {
                        HStack(spacing: 10) {
                            if voiceUIState.isTransitioning { ProgressView() }
                            Text(voiceStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if imageCaptureState.shouldShowInConversation,
                       let imageStatus = imageCaptureState.statusMessage {
                        HStack(spacing: 10) {
                            if imageCaptureState.isRemoteProcessing { ProgressView() }
                            Text(imageStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { previousCount, _ in
                // Keep a fresh conversation at the top so its daily-loop header
                // and snapshot are visible; restored history and later turns
                // still follow the newest message.
                guard previousCount > 0 || didHydratePersistedMessages else { return }
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
                                let errorMessage = SharedErrorDescriptor.mapped(
                                    from: error,
                                    fallback: .actionConflictFallback
                                ).userMessage
                                addMessage(text: "待确认草稿已生成，但列表刷新失败：\(errorMessage)", isUser: false)
                            }
                        }
                    },
                    onImageStateChange: { state in
                        imageCaptureState = state
                    }
                )
                .presentationBackground { OrbitBackground() }
            }
        }
    }

    private var promptChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(dailyLoopSnapshot?.quickActions ?? DailyLoopQuickAction.allCases, id: \.rawValue) { action in
                    promptButton(for: action)
                }
            }
        }
        .contentMargins(.horizontal, 1, for: .scrollContent)
    }

    @ViewBuilder
    private var confirmedMealsSection: some View {
        if let todayMealsReadError {
            Label(todayMealsReadError, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(OrbitPalette.coral)
                .orbitCard()
        } else if !todayMeals.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("今天已确认的餐食")
                    .font(.headline)
                ForEach(todayMeals) { meal in
                    TodayConfirmedMealCard(
                        meal: meal,
                        isSaving: correctingMealID == meal.id,
                        errorMessage: mealCorrectionError,
                        onSaveCorrection: { correctedLikelyKcal in
                            saveMealCorrection(meal, correctedLikelyKcal: correctedLikelyKcal)
                        }
                    )
                }
            }
            .accessibilityIdentifier("today-confirmed-meals")
        }
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
                        .disabled(agentUIState.isBusy)
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
                    .disabled(agentUIState.isBusy || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                .disabled(agentUIState.isBusy)
                .accessibilityLabel("照片记餐")
                .accessibilityIdentifier("today-photo-secondary")

                Spacer(minLength: 0)

                Button {
                    Task { await toggleVoice() }
                } label: {
                    Label {
                        Text(voiceUIState.buttonTitle)
                    } icon: {
                        if voiceUIState == .listening {
                            VoiceActivityOrb(
                                symbol: voiceUIState.buttonSystemImage,
                                isActive: true
                            )
                        } else {
                            Image(systemName: voiceUIState.buttonSystemImage)
                        }
                    }
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(voiceUIState.isRecording ? OrbitPalette.coral : OrbitPalette.gold)
                .disabled(agentUIState.isBusy || voiceUIState.isCaptureControlLocked)
                .accessibilityLabel(voiceUIState.buttonTitle)
                .accessibilityIdentifier("today-voice-primary")

                Spacer(minLength: 0)

                if agentUIState.canCancel {
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
        refreshTodayMeals()
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

    private func refreshDailyLoopSnapshot(refreshHealth: Bool = false) async {
        refreshTodayMeals()
        guard case .start(var passRefreshesHealth) = dailyLoopSnapshotRefreshQueue.request(
            refreshHealth: refreshHealth
        ) else { return }
        isLoadingDailyLoopSnapshot = true
        defer {
            isLoadingDailyLoopSnapshot = false
        }

        while true {
            do {
                let snapshot: DailyLoopSnapshot
                if passRefreshesHealth {
                    snapshot = try await dependencies.dailyLoopSnapshotService.refreshSnapshot()
                } else {
                    snapshot = try await dependencies.dailyLoopSnapshotService.snapshot()
                }
                dailyLoopSnapshot = snapshot
                dailyLoopSnapshotReadError = nil
            } catch {
                let descriptor = SharedErrorDescriptor.mapped(
                    from: error,
                    fallback: .projectionFailedFallback
                )
                dailyLoopSnapshot = DailyLoopSnapshotComposer(calendar: .current).compose(
                    asOf: Date(),
                    dailyBrief: nil,
                    errorCode: descriptor.code.rawValue,
                    pendingActions: [],
                    workoutPlans: []
                )
                dailyLoopSnapshotReadError = "读取今日概览失败：\(descriptor.userMessage)"
            }

            guard let nextPassRefreshesHealth = dailyLoopSnapshotRefreshQueue.finishPass() else { break }
            passRefreshesHealth = nextPassRefreshesHealth
        }
    }

    private func refreshTodayMeals() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            todayMeals = []
            todayMealsReadError = "无法读取今日餐食日期范围。"
            return
        }
        let predicate = #Predicate<MealRecord> { meal in
            meal.date >= today && meal.date < tomorrow
        }
        var descriptor = FetchDescriptor<MealRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        do {
            todayMeals = try modelContext.fetch(descriptor)
            todayMealsReadError = nil
        } catch {
            todayMeals = []
            todayMealsReadError = "读取今日已确认餐食失败：\(SharedErrorDescriptor.mapped(
                from: error,
                fallback: .projectionFailedFallback
            ).userMessage)"
        }
    }

    private func saveMealCorrection(_ meal: MealRecord, correctedLikelyKcal: Double) {
        guard correctingMealID == nil else { return }
        correctingMealID = meal.id
        defer { correctingMealID = nil }
        mealCorrectionError = nil

        do {
            let originalEnergy = try EstimateRange(
                low: meal.energyLowKcal,
                likely: meal.energyLikelyKcal,
                high: meal.energyHighKcal
            )
            let correction = try ConfirmedMealCalorieCorrection(
                originalEnergy: originalEnergy,
                correctedLikelyKcal: correctedLikelyKcal,
                occurredAt: Date()
            )
            let correctedEnergy = correction.correctedEnergy
            let existingMealEvidence = try Self.decodeEvidence(meal.evidenceData)
            let encodedMealEvidence = try JSONEncoder().encode(existingMealEvidence + [correction.evidence])

            let dishUpdates = try meal.dishes.map { dish in
                let originalDishEnergy = try EstimateRange(
                    low: dish.energyLowKcal,
                    likely: dish.energyLikelyKcal,
                    high: dish.energyHighKcal
                )
                let correctedDishEnergy = try originalDishEnergy.scaled(by: correction.factor)
                let dishCorrectionEvidence = EvidenceSnapshot(
                    grade: .userReported,
                    sourceID: ConfirmedMealCalorieCorrection.evidenceSourceID,
                    sourceVersion: ConfirmedMealCalorieCorrection.evidenceSourceVersion,
                    summary: "用户于 \(correction.timestamp) 将整餐热量范围 \(Self.rangeSummary(originalDishEnergy, unit: "kcal")) 更正为 \(Self.rangeSummary(correctedDishEnergy, unit: "kcal"))；菜品“\(dish.dishName)”只调整热量。蛋白质、脂肪和碳水估算未调整，因为用户未更正这些字段；食材份量保持原值。更正前估算与证据保留。",
                    confidence: 1
                )
                let evidence = try Self.decodeEvidence(dish.evidenceData) + [dishCorrectionEvidence]
                return (
                    dish: dish,
                    energy: correctedDishEnergy,
                    evidenceData: try JSONEncoder().encode(evidence)
                )
            }

            meal.totalCaloriesKcal = Int(correctedEnergy.likely.rounded())
            meal.energyLowKcal = correctedEnergy.low
            meal.energyLikelyKcal = correctedEnergy.likely
            meal.energyHighKcal = correctedEnergy.high
            meal.evidenceData = encodedMealEvidence
            for update in dishUpdates {
                update.dish.energyLowKcal = update.energy.low
                update.dish.energyLikelyKcal = update.energy.likely
                update.dish.energyHighKcal = update.energy.high
                update.dish.estimatedCaloriesKcal = Int(update.energy.likely.rounded())
                update.dish.evidenceData = update.evidenceData
            }

            try HealthRepository(modelContext: modelContext).update(meal)
            refreshTodayMeals()
            dependencies.watchConnectivityCoordinator.refreshApplicationContext()
            addMessage(
                text: "已保存餐食热量修正，今日汇总会按更新后的估算重算；修正前后的数值与证据均已保留。",
                isUser: false
            )
            Task {
                _ = try? await dependencies.healthIntelligenceService.refresh()
                await refreshDailyLoopSnapshot(refreshHealth: true)
            }
        } catch {
            mealCorrectionError = SharedErrorDescriptor.mapped(
                from: error,
                fallback: .projectionFailedFallback
            ).userMessage
        }
    }

    private enum MealCorrectionError: Error {
        case invalidExistingEvidence
    }

    private static func decodeEvidence(_ data: Data?) throws -> [EvidenceSnapshot] {
        guard let data else { return [] }
        do {
            return try JSONDecoder().decode([EvidenceSnapshot].self, from: data)
        } catch {
            throw MealCorrectionError.invalidExistingEvidence
        }
    }

    private static func rangeSummary(_ range: EstimateRange, unit: String) -> String {
        "\(kcal(range.low))–\(kcal(range.high))（likely \(kcal(range.likely))）\(unit)"
    }

    private static func kcal(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private func focusComposer() {
        showTextEditor = true
        appState.shouldFocusComposer = false
        Task { @MainActor in
            await Task.yield()
            guard showTextEditor else { return }
            composerFocused = true
        }
    }

    private func transitionAgentUI(using event: AgentEvent) {
        if case .pendingAction(let action) = event,
           !pendingActionIDsAtTurnStart.contains(action.id) {
            currentTurnHasDraft = true
        }
        let nextState = AgentUIStateMachine.transition(
            from: agentUIState,
            event: event,
            hasDraftInCurrentTurn: currentTurnHasDraft
        )
        setAgentUIState(nextState)
        switch event {
        case .completed(_):
            pendingActionIDsAtTurnStart = []
            currentTurnHasDraft = false
        case .cancelled(_):
            break
        default:
            break
        }
    }

    private func transitionImageUI(using event: AgentEvent) {
        switch event {
        case .imageUploading:
            imageCaptureState = .uploading
        case .imageVision:
            imageCaptureState = .vision
        case .imageResolved:
            imageCaptureState = .resolved
        case .completed(_) where imageCaptureState.isRemoteProcessing:
            imageCaptureState = .resolved
        case .cancelled(_) where imageCaptureState.isRemoteProcessing:
            imageCaptureState = .cancelled
        case .failed(_) where imageCaptureState.isRemoteProcessing:
            imageCaptureState = .failed
        default:
            break
        }
    }

    private func setAgentUIState(_ state: AgentUIState) {
        agentUIState = state
        appState.isAgentProcessing = state.isBusy
    }

    private func updateVoiceUIState(from speechState: SpeechCaptureState, transcribedText: String) {
        let state = AgentUIStateMachine.voiceState(from: speechState, transcribedText: transcribedText)
        voiceUIState = state
        switch state {
        case .listening:
            setAgentUIState(.listening)
        case .transcribing, .finalizing:
            setAgentUIState(.transcribing)
        case .starting, .submitted, .completed, .cancelled, .idle:
            if agentUIState == .listening || agentUIState == .transcribing {
                setAgentUIState(.idle)
            }
        case .permissionDenied, .microphoneUnavailable, .speechUnavailable:
            setAgentUIState(.failed)
        case .processing:
            break
        case .failed(let message):
            setAgentUIState(.failed)
        }
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
            voiceUIState = .starting
            await speech.refreshRuntime()
            let authorized = await speech.requestAuthorization()
            if authorized {
                do {
                    try await speech.startRecording()
                    updateVoiceUIState(from: speech.state, transcribedText: speech.transcribedText)
                } catch {
                    updateVoiceUIState(from: speech.state, transcribedText: speech.transcribedText)
                    let errorMessage = SharedErrorDescriptor.mapped(
                        from: error,
                        fallback: SharedErrorDescriptor(
                            code: .providerUnavailable,
                            userMessage: "暂时无法启动语音，请重试或改用文字输入。",
                            subsystem: .agent,
                            reason: .unsupportedCapability
                        )
                    ).userMessage
                    addMessage(text: errorMessage, isUser: false)
                }
            } else {
                updateVoiceUIState(from: speech.state, transcribedText: speech.transcribedText)
                addMessage(text: "请在系统设置中开启麦克风和语音识别权限。", isUser: false)
            }
        }
    }

    private func send(text: String, multimodalRequest: MultimodalModelRequest? = nil) async {
        let userText = (multimodalRequest?.userText ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else { return }
        let performanceClock = ContinuousClock()
        let agentRequestStartedAt = performanceClock.now
        var recordedFirstToken = false
        var recordedActionDraft = false
        let sourceForRequest = inputSource
        guard !agentUIState.isBusy else { return }
        if multimodalRequest?.image == nil {
            imageCaptureState = .idle
        }
        pendingActionIDsAtTurnStart = Set(dependencies.agentSession.pendingActions.map(\.id))
        currentTurnHasDraft = false
        setAgentUIState(.thinking)
        if sourceForRequest != .manualText { voiceUIState = .processing }
        defer { appState.isAgentProcessing = agentUIState.isBusy }
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
                setAgentUIState(.completed)
                if sourceForRequest != .manualText { voiceUIState = .completed }
            case .cloudDeepSeek, .cloudQwen:
                let pendingActionIDsBeforeTurn = Set(dependencies.agentSession.pendingActions.map(\.id))
                let eventStream: AsyncThrowingStream<AgentEvent, Error>
                if let multimodalRequest {
                    eventStream = dependencies.agentSession.sendEvents(
                        multimodalRequest: multimodalRequest,
                        requestID: agentRequestID
                    )
                } else {
                    let inputEnvelope = VoiceCommandEnvelope(
                        text: userText,
                        source: sourceForRequest
                    ).asInputEnvelope()
                    eventStream = dependencies.agentSession.sendEvents(
                        userText: userText,
                        inputEnvelope: inputEnvelope,
                        requestID: agentRequestID
                    )
                }
                var completedResponse: AgentResponse?
                for try await event in eventStream {
                    transitionAgentUI(using: event)
                    transitionImageUI(using: event)
                    if !recordedFirstToken, case .assistantDelta = event {
                        PerformanceSignposts.event(
                            "Agent.TranscriptToFirstToken",
                            elapsedMillisecondsSince: agentRequestStartedAt,
                            clock: performanceClock
                        )
                        recordedFirstToken = true
                    }
                    if !recordedActionDraft, case .pendingAction = event {
                        PerformanceSignposts.event(
                            "Agent.TranscriptToActionDraft",
                            elapsedMillisecondsSince: agentRequestStartedAt,
                            clock: performanceClock
                        )
                        recordedActionDraft = true
                    }
                    if case .completed(let response) = event {
                        completedResponse = response
                    }
                }
                guard let response = completedResponse else {
                    throw AgentError.invalidInputEnvelope
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
                if sourceForRequest != .manualText { voiceUIState = .completed }
            case .manual:
                inputText = userText
                inputSource = sourceForRequest
                showTextEditor = true
                addMessage(text: "本地智能当前不可用；你的输入尚未保存。可在设置中选择 DeepSeek 云端处理，或继续手动编辑。", isUser: false)
                setAgentUIState(.completed)
                if sourceForRequest != .manualText { voiceUIState = .submitted }
            }
        } catch {
            if (error as? ProviderError) == .cancelled {
                let hasNewPendingAction = currentTurnHasDraft && dependencies.agentSession.pendingActions.contains {
                    !pendingActionIDsAtTurnStart.contains($0.id) && $0.state == .pending
                }
                setAgentUIState(hasNewPendingAction ? .awaitingConfirmation : .idle)
                if imageCaptureState.isRemoteProcessing { imageCaptureState = .cancelled }
                pendingActionIDsAtTurnStart = []
                currentTurnHasDraft = false
                if sourceForRequest != .manualText { voiceUIState = .cancelled }
                return
            }
            let errorMessage = SharedErrorDescriptor.mapped(
                from: error,
                fallback: .providerUnavailableFallback
            ).userMessage
            setAgentUIState(.failed)
            if imageCaptureState.isRemoteProcessing { imageCaptureState = .failed }
            if sourceForRequest != .manualText { voiceUIState = .failed(errorMessage) }
            addMessage(text: "处理失败：\(errorMessage)你的记录尚未保存。", isUser: false)
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
        setAgentUIState(.committing)
        Task {
            do {
                let message = try await dependencies.agentSession.confirmPendingAction(id: action.id)
                _ = try? await dependencies.healthIntelligenceService.refresh()
                await refreshDailyLoopSnapshot()
                dependencies.watchConnectivityCoordinator.refreshApplicationContext()
                addMessage(text: message, isUser: false)
                setAgentUIState(
                    dependencies.agentSession.pendingActions.isEmpty
                        ? .completed
                        : .awaitingConfirmation
                )
            } catch {
                let errorMessage = SharedErrorDescriptor.mapped(
                    from: error,
                    fallback: .actionConflictFallback
                ).userMessage
                setAgentUIState(.failed)
                addMessage(text: "未能保存：\(errorMessage)", isUser: false)
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
            let errorMessage = SharedErrorDescriptor.mapped(
                from: error,
                fallback: .watchUnavailableFallback
            ).userMessage
            voiceDraftSummary = "无法读取 Watch 草稿：\(errorMessage)"
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
