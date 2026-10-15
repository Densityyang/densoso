import DensosoDomain
import Foundation
import Observation
@preconcurrency import WatchConnectivity

@MainActor
@Observable
final class WatchConnectivityClient: NSObject, WCSessionDelegate {
    private static let payloadKey = "densoso.watch.payload"
    private static let outboxKey = "watch.message.outbox.v1"

    @ObservationIgnored private let session: WCSession
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var outbox = WatchMessageOutbox()
    @ObservationIgnored private var dispatchedIDs = Set<UUID>()

    private(set) var isAvailable: Bool
    private(set) var isActivated = false
    private(set) var isReachable = false
    private(set) var todaySnapshot: WatchTodaySnapshot?
    private(set) var statusMessage = "正在连接 iPhone…"

    init(session: WCSession = .default, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        self.isAvailable = WCSession.isSupported()
        super.init()
        if let data = defaults.data(forKey: Self.outboxKey),
           let saved = try? JSONDecoder().decode(WatchMessageOutbox.self, from: data) {
            outbox = saved
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
        let envelope = WatchMessageEnvelope(payload: payload)
        do {
            _ = try outbox.enqueue(envelope)
            persistOutbox()
            dispatch(envelope)
            statusMessage = "消息已排队；确认仍由 iPhone 本地事务处理。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func dispatchPendingMessages() {
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
                    Task { @MainActor in self?.receive(reply) }
                },
                errorHandler: { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.dispatchedIDs.remove(envelope.messageID)
                        self.statusMessage = "即时消息未送达，已转入离线队列。"
                        self.session.transferUserInfo(payload)
                        _ = error
                    }
                }
            )
        } else {
            session.transferUserInfo(payload)
            statusMessage = "iPhone 暂不可达，消息已进入离线队列。"
        }
    }

    private func receive(_ dictionary: [String: Any]) {
        guard let data = dictionary[Self.payloadKey] as? Data else { return }
        do {
            let envelope = try WatchMessageCodec.decode(data)
            switch envelope.payload {
            case .acknowledgement(let acknowledgement):
                outbox.acknowledge(acknowledgement)
                persistOutbox()
                statusMessage = acknowledgement.detail ?? acknowledgementLabel(acknowledgement.state)
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
        outbox.acknowledge(messageIDs: snapshot.acknowledgedMessageIDs)
        persistOutbox()
        if snapshot.acknowledgedMessageIDs.isEmpty {
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

    private func persistOutbox() {
        guard let data = try? JSONEncoder().encode(outbox) else { return }
        defaults.set(data, forKey: Self.outboxKey)
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isActivated = activationState == .activated
            self.isReachable = session.isReachable
            if let error { self.statusMessage = error.localizedDescription }
            else { self.statusMessage = self.isReachable ? "已连接 iPhone。" : "iPhone 暂不可达；可离线排队。" }
            self.dispatchPendingMessages()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isReachable = session.isReachable
            self.statusMessage = self.isReachable ? "已连接 iPhone。" : "iPhone 暂不可达；可离线排队。"
            if self.isReachable { self.dispatchPendingMessages() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor [weak self] in self?.receive(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor [weak self] in self?.receive(userInfo) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor [weak self] in
            self?.receive(message)
            replyHandler([:])
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                self.statusMessage = "离线消息传输失败，可重试：\(error.localizedDescription)"
                if let data = userInfoTransfer.userInfo[Self.payloadKey] as? Data,
                   let envelope = try? WatchMessageCodec.decode(data) {
                    self.dispatchedIDs.remove(envelope.messageID)
                }
            }
        }
    }
}
