import DensosoDomain
import Foundation
import Observation
@preconcurrency import WatchConnectivity

@MainActor
@Observable
final class WatchConnectivityClient: NSObject, WCSessionDelegate {
    private static let payloadKey = "densoso.watch.payload"

    @ObservationIgnored private let session: WCSession
    @ObservationIgnored private let outboxStore: WatchMessageOutboxStore
    @ObservationIgnored private var outbox = WatchMessageOutbox()
    @ObservationIgnored private var outboxPersistenceAvailable = true
    @ObservationIgnored private var dispatchedIDs = Set<UUID>()

    private(set) var isAvailable: Bool
    private(set) var isActivated = false
    private(set) var isReachable = false
    private(set) var todaySnapshot: WatchTodaySnapshot?
    private(set) var statusMessage = "正在连接 iPhone…"

    init(session: WCSession = .default, defaults: UserDefaults = .standard) {
        self.session = session
        self.outboxStore = WatchMessageOutboxStore(defaults: defaults)
        self.isAvailable = WCSession.isSupported()
        super.init()
        do {
            outbox = try outboxStore.load()
        } catch {
            outboxPersistenceAvailable = false
            statusMessage = "本机待发队列无法读取，暂不能发送 Watch 命令。"
        }
        if isAvailable { session.delegate = self }
    }

    var pendingMessageCount: Int { outbox.pending.count }

    func activate() {
        guard isAvailable else {
            statusMessage = "当前 Watch 不支持与 iPhone 同步。"
            return
        }
        if session.activationState == .notActivated {
            session.activate()
        } else {
            isActivated = session.activationState == .activated
            isReachable = session.isReachable
            dispatchPendingMessages()
        }
    }

    func sendTranscript(_ transcript: String) {
        enqueue(.transcript(transcript))
    }

    func confirm(actionID: UUID) {
        enqueue(.confirm(actionID: actionID))
    }

    func reject(actionID: UUID) {
        enqueue(.reject(actionID: actionID))
    }

    func requestTodaySnapshot() {
        enqueue(.requestTodaySnapshot)
    }

    private func enqueue(_ payload: WatchPayload) {
        guard outboxPersistenceAvailable else {
            statusMessage = "本机待发队列不可用，Watch 命令未发送。"
            return
        }
        if case .requestTodaySnapshot = payload,
           !WatchSnapshotRequestCoalescingPolicy.shouldEnqueue(pendingMessages: outbox.pending) {
            statusMessage = "刷新请求已在队列中，等待 iPhone 确认。"
            return
        }
        do {
            let envelope: WatchMessageEnvelope
            switch payload {
            case .transcript, .confirm, .reject:
                let predecessorSequence = outbox.latestPendingCausalSequence
                envelope = try outbox.enqueueCausalCommand(
                    payload,
                    dependsOn: predecessorSequence
                )
            case .requestTodaySnapshot, .acknowledgement, .todaySnapshot:
                envelope = WatchMessageEnvelope(payload: payload)
                _ = try outbox.enqueue(envelope)
            }
            guard persistOutbox() else { return }
            dispatch(envelope)
            statusMessage = "消息已排队；确认仍由 iPhone 本地事务处理。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func dispatchPendingMessages() {
        guard outboxPersistenceAvailable else { return }
        for envelope in outbox.pending { dispatch(envelope) }
    }

    private func dispatch(_ envelope: WatchMessageEnvelope) {
        guard isAvailable,
              isActivated,
              dispatchedIDs.insert(envelope.messageID).inserted,
              let data = try? WatchMessageCodec.encode(envelope) else { return }
        let payload = [Self.payloadKey: data]
        if isReachable {
            session.sendMessage(
                payload,
                replyHandler: { [weak self] reply in
                    guard let replyData = reply["densoso.watch.payload"] as? Data else {
                        Task { @MainActor in
                            guard let self else { return }
                            self.dispatchedIDs.remove(envelope.messageID)
                            self.statusMessage = "iPhone 未确认消息已本地接收，已转入离线队列。"
                            self.session.transferUserInfo(["densoso.watch.payload": data])
                        }
                        return
                    }
                    Task { @MainActor in self?.receive(replyData) }
                },
                errorHandler: { [weak self] error in
                    let errorMessage = error.localizedDescription
                    Task { @MainActor in
                        guard let self else { return }
                        self.dispatchedIDs.remove(envelope.messageID)
                        self.statusMessage = "即时消息未送达，已转入离线队列。\(errorMessage)"
                        self.session.transferUserInfo(["densoso.watch.payload": data])
                    }
                }
            )
        } else {
            session.transferUserInfo(payload)
            statusMessage = "iPhone 暂不可达，消息已进入离线队列。"
        }
    }

    private func receive(_ data: Data) {
        do {
            let envelope = try WatchMessageCodec.decode(data)
            switch envelope.payload {
            case .acknowledgement(let acknowledgement):
                outbox.acknowledge(acknowledgement)
                dispatchedIDs.remove(acknowledgement.messageID)
                if persistOutbox() {
                    statusMessage = acknowledgement.detail ?? acknowledgementLabel(acknowledgement.state)
                }
            case .todaySnapshot(let snapshot):
                apply(snapshot)
            case .transcript, .confirm, .reject, .requestTodaySnapshot:
                break
            }
        } catch {
            statusMessage = "收到无法识别的 iPhone 消息。"
        }
    }

    private func apply(_ snapshot: WatchTodaySnapshot) {
        todaySnapshot = snapshot
        var acknowledgedIDs = Set(snapshot.acknowledgedMessageIDs)
        outbox.acknowledge(messageIDs: snapshot.acknowledgedMessageIDs)
        if let watermark = snapshot.terminalCausalSequenceWatermark {
            acknowledgedIDs.formUnion(outbox.acknowledge(throughCausalSequence: watermark))
        }
        dispatchedIDs.subtract(acknowledgedIDs)
        guard persistOutbox() else { return }
        if acknowledgedIDs.isEmpty {
            statusMessage = "已更新 Today 摘要。"
        } else {
            statusMessage = "已更新摘要并同步确认状态。"
        }
    }

    private func acknowledgementLabel(_ state: WatchAcknowledgementState) -> String {
        switch state {
        case .accepted: "iPhone 已接收，等待处理。"
        case .processed: "iPhone 已处理。"
        case .duplicate: "重复消息未重复写入。"
        case .rejected: "消息未处理，请检查计划或草稿状态。"
        }
    }

    @discardableResult
    private func persistOutbox() -> Bool {
        guard outboxPersistenceAvailable else { return false }
        do {
            try outboxStore.save(outbox)
            return true
        } catch {
            outboxPersistenceAvailable = false
            statusMessage = "本机待发队列无法保存，后续 Watch 命令已停止发送。"
            return false
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let isActivated = activationState == .activated
        let isReachable = session.isReachable
        let errorMessage = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isActivated = isActivated
            self.isReachable = isReachable
            if let errorMessage { self.statusMessage = errorMessage }
            else { self.statusMessage = self.isReachable ? "已连接 iPhone。" : "iPhone 暂不可达；可离线排队。" }
            if self.isActivated {
                self.dispatchedIDs.removeAll()
                self.dispatchPendingMessages()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isReachable = isReachable
            self.statusMessage = self.isReachable ? "已连接 iPhone。" : "iPhone 暂不可达；可离线排队。"
            if self.isReachable {
                self.dispatchedIDs.removeAll()
                self.dispatchPendingMessages()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["densoso.watch.payload"] as? Data else { return }
        Task { @MainActor [weak self] in self?.receive(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo["densoso.watch.payload"] as? Data else { return }
        Task { @MainActor [weak self] in self?.receive(data) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        replyHandler([:])
        guard let data = message["densoso.watch.payload"] as? Data else { return }
        Task { @MainActor [weak self] in self?.receive(data) }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        let data = userInfoTransfer.userInfo["densoso.watch.payload"] as? Data
        let errorMessage = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let errorMessage {
                self.statusMessage = "离线消息传输失败，可重试：\(errorMessage)"
                if let data, let envelope = try? WatchMessageCodec.decode(data) {
                    self.dispatchedIDs.remove(envelope.messageID)
                }
            }
        }
    }
}
