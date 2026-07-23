import SwiftUI
import SwiftData

struct ChatScreen: View {
    @Environment(Dependencies.self) private var dependencies
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isProcessing = false

    var body: some View {
        VStack(spacing: 0) {
            // 消息列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: appState.agentStreamedText) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            if !dependencies.agentSession.pendingActions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(dependencies.agentSession.pendingActions) { action in
                        PendingActionConfirmationCard(action: action) {
                            confirm(action)
                        } onReject: {
                            dependencies.agentSession.rejectPendingAction(id: action.id)
                            addMessage(text: "已拒绝该记录草稿，未保存任何健康数据。", isUser: false)
                        }
                    }
                }
                .padding(.horizontal)
            }

            // 底部输入区
            HStack(spacing: 12) {
                Button {
                    Task { await toggleVoice() }
                } label: {
                    Image(systemName: dependencies.speechService.isRecording ? "mic.fill" : "mic")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(dependencies.speechService.isRecording ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .clipShape(Circle())
                }

                TextField("输入或语音...", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isProcessing)

                Button {
                    Task { await send(text: inputText) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.title3.bold())
                        .frame(width: 44, height: 44)
                        .background(inputText.isEmpty || isProcessing ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .clipShape(Circle())
                }
                .disabled(inputText.isEmpty || isProcessing)
            }
            .padding()
        }
        .onAppear {
            if messages.isEmpty {
                addMessage(text: "你好，我是 densoso。按住麦克风或输入文字，告诉我你吃了什么、练了什么。", isUser: false)
            }
        }
        .onChange(of: dependencies.speechService.transcribedText) { _, newValue in
            inputText = newValue
        }
    }

    private func toggleVoice() async {
        let speech = dependencies.speechService
        if speech.isRecording {
            await speech.stopRecording()
            if !inputText.isEmpty {
                await send(text: inputText)
            }
        } else {
            let authorized = await speech.requestAuthorization()
            if authorized {
                do {
                    try await speech.startRecording()
                } catch {
                    addMessage(text: "无法启动语音：\(error.localizedDescription)。", isUser: false)
                }
            } else {
                addMessage(text: "请在设置中开启麦克风和语音识别权限。", isUser: false)
            }
        }
    }

    private func send(text: String) async {
        guard !text.isEmpty else { return }
        let userText = text
        inputText = ""
        addMessage(text: userText, isUser: true)

        isProcessing = true
        appState.isAgentProcessing = true

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
            case .cloudDeepSeek:
                let response = try await dependencies.agentSession.send(
                    userText: userText,
                    modelContext: modelContext
                )
                addMessage(text: response.text, isUser: false)
            case .manual:
                addMessage(text: "本地智能当前不可用；你的输入尚未保存。可在设置中选择 DeepSeek 云端处理，或使用支持的设备继续。", isUser: false)
            }
        } catch {
            addMessage(text: "处理失败：\(error.localizedDescription)。你的记录尚未保存。", isUser: false)
        }

        isProcessing = false
        appState.isAgentProcessing = false
    }

    private func addMessage(text: String, isUser: Bool) {
        messages.append(ChatMessage(text: text, isUser: isUser))
    }

    private func confirm(_ action: PendingAction) {
        Task {
            do {
                let message = try dependencies.agentSession.confirmPendingAction(id: action.id, modelContext: modelContext)
                addMessage(text: message, isUser: false)
            } catch {
                addMessage(text: "未能保存：\(error.localizedDescription)", isUser: false)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let last = messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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
            if message.isUser { Spacer() }

            Text(message.text)
                .padding(12)
                .background(message.isUser ? Color.blue : Color(.systemGray5))
                .foregroundStyle(message.isUser ? .white : .primary)
                .cornerRadius(16)
                .frame(maxWidth: 260, alignment: message.isUser ? .trailing : .leading)

            if !message.isUser { Spacer() }
        }
    }
}

#Preview {
    ChatScreen()
        .modelContainer(for: [UserProfile.self, MealRecord.self])
        .environment(Dependencies())
        .environment(AppState.shared)
}
