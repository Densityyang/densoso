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

            // 底部输入区
            HStack(spacing: 12) {
                Button {
                    Task { await toggleVoice() }
                } label: {
                    Image(systemName: appState.isRecording ? "mic.fill" : "mic")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(appState.isRecording ? Color.red : Color.blue)
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
            speech.stopRecording()
            if !inputText.isEmpty {
                await send(text: inputText)
            }
        } else {
            let authorized = await speech.requestAuthorization()
            if authorized {
                try? speech.startRecording()
            } else {
                addMessage(text: "请在设置中开启语音识别权限。", isUser: false)
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

        do {
            let response = try await dependencies.agentSession.send(
                userText: userText,
                modelContext: modelContext
            )
            addMessage(text: response.text, isUser: false)
        } catch {
            addMessage(text: "抱歉，处理出错了：\(error.localizedDescription)", isUser: false)
        }

        isProcessing = false
        appState.isAgentProcessing = false
    }

    private func addMessage(text: String, isUser: Bool) {
        messages.append(ChatMessage(text: text, isUser: isUser))
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
