import DensosoDomain
import Foundation
import Observation
import SwiftData
@preconcurrency import WatchConnectivity

struct PendingWatchTranscript: Equatable, Identifiable, Sendable {
    let messageID: UUID
    let text: String

    var id: UUID { messageID }
}

@MainActor
@Observable
final class PhoneWatchConnectivityCoordinator: NSObject, WCSessionDelegate {
    private static let payloadKey = "densoso.watch.payload"

    @ObservationIgnored private let session: WCSession
    @ObservationIgnored private let modelContainer: ModelContainer
    @ObservationIgnored private let confirmationCoordinator: ConfirmationCoordinator
    @ObservationIgnored private let agentSession: AgentSession
    @ObservationIgnored private let healthIntelligenceService: HealthIntelligenceService
    @ObservationIgnored private let workoutPlanSchedulingService: WorkoutPlanSchedulingService
    @ObservationIgnored private let inboxStore: WatchMessageInboxStore
    @ObservationIgnored private var processingMessageIDs = Set<UUID>()

    private(set) var isAvailable = false
    private(set) var isActivated = false
    private(set) var pendingTranscriptRevision = 0
    private(set) var lastError: String?

    init(
        modelContainer: ModelContainer,
        confirmationCoordinator: ConfirmationCoordinator,
        agentSession: AgentSession,
        healthIntelligenceService: HealthIntelligenceService,
        workoutPlanSchedulingService: WorkoutPlanSchedulingService,
        session: WCSession = .default
    ) {
        self.modelContainer = modelContainer
        self.confirmationCoordinator = confirmationCoordinator
        self.agentSession = agentSession
        self.healthIntelligenceService = healthIntelligenceService
        self.workoutPlanSchedulingService = workoutPlanSchedulingService
        self.inboxStore = WatchMessageInboxStore(modelContainer: modelContainer)
        self.session = session
        self.isAvailable = WCSession.isSupported()
        super.init()
        if isAvailable { session.delegate = self }
    }

    func activate() {
        guard isAvailable, session.activationState == .notActivated else { return }
        session.activate()
    }

    func refreshApplicationContext() {
        guard isAvailable, session.activationState == .activated else { return }
        do {
            let context = try makeTodaySnapshot()
            let envelope = WatchMessageEnvelope(payload: .todaySnapshot(context))
            let data = try WatchMessageCodec.encode(envelope)
            try session.updateApplicationContext([Self.payloadKey: data])
            lastError = nil
        } catch {
            lastError = "无法同步 Watch 摘要：\(error.localizedDescription)"
        }
    }

    func nextPendingTranscript(excluding claimedIDs: Set<UUID> = []) throws -> PendingWatchTranscript? {
        try inboxStore.pendingTranscripts(excluding: claimedIDs).first
    }

    func markTranscriptProcessed(_ messageID: UUID) throws {
        try inboxStore.setState(WatchReceiptState.processed, for: messageID)
        refreshApplicationContext()
    }

    func pendingActionSummaries() -> [WatchPendingActionSummary] {
        agentSession.pendingActions
            .filter { $0.state == .pending }
            .map {
                WatchPendingActionSummary(
                    actionID: $0.id,
                    title: $0.payload.title,
                    summary: $0.payload.summary,
                    expiresAt: $0.expiresAt
                )
            }
    }

    private func makeTodaySnapshot() throws -> WatchTodaySnapshot {
        let context = ModelContext(modelContainer)
        let today = Calendar.current.startOfDay(for: Date())
        let metrics = try context.fetch(FetchDescriptor<DailyMetrics>())
            .first(where: { Calendar.current.isDate($0.date, inSameDayAs: today) })
        let processed = try inboxStore.recentProcessedMessageIDs()
        let scheduledPlans = try workoutPlanSchedulingService.confirmedPlans().map {
            WatchWorkoutPlanSummary(
                actionID: $0.actionID,
                title: $0.draft.name,
                scheduledAt: $0.draft.scheduledAt,
                state: $0.state.rawValue,
                lastError: $0.lastError
            )
        }
        return WatchTodaySnapshot(
            generatedAt: Date(),
            summary: healthIntelligenceService.dailyBrief?.summary ?? "暂无本地健康摘要",
            energyIntakeKcal: metrics?.totalIntakeKcal,
            totalExpenditureKcal: metrics?.totalExpenditureKcal,
            deficitKcal: metrics?.deficitKcal,
            domains: healthIntelligenceService.dailyBrief?.domains ?? [],
            pendingActions: pendingActionSummaries(),
            workoutPlans: scheduledPlans,
            acknowledgedMessageIDs: Array(processed.suffix(100))
        )
    }

    private func receive(_ data: Data) async -> Data? {
        do {
            let envelope = try WatchMessageCodec.decode(data)
            let disposition = try inboxStore.ingest(envelope)
            if disposition == .payloadConflict {
                return acknowledgement(for: envelope.messageID, state: .rejected, detail: "messageID 已用于其他内容")
            }
            if disposition == .duplicateProcessed {
                return acknowledgement(for: envelope.messageID, state: .duplicate, detail: nil)
            }
            guard processingMessageIDs.insert(envelope.messageID).inserted else {
                return acknowledgement(for: envelope.messageID, state: .accepted, detail: "消息正在处理")
            }
            defer { processingMessageIDs.remove(envelope.messageID) }

            switch envelope.payload {
            case .transcript:
                pendingTranscriptRevision += 1
                refreshApplicationContext()
                return acknowledgement(for: envelope.messageID, state: .accepted, detail: "转写已保存在本机，等待你检查")
            case .requestTodaySnapshot:
                try inboxStore.setState(WatchReceiptState.processed, for: envelope.messageID)
                refreshApplicationContext()
                return acknowledgement(for: envelope.messageID, state: .processed, detail: "已更新 Today 摘要")
            case .confirm(let actionID):
                let receipt: CommitReceipt
                do {
                    receipt = try await confirmationCoordinator.confirm(id: actionID)
                } catch {
                    try inboxStore.setState(WatchReceiptState.rejected, for: envelope.messageID)
                    return acknowledgement(for: envelope.messageID, state: .rejected, detail: error.localizedDescription)
                }
                var detail = "已在本机确认"
                if receipt.actionType == .workoutPlan {
                    do {
                        try await workoutPlanSchedulingService.scheduleConfirmedPlan(actionID: actionID)
                        detail = "训练计划已确认并提交给 WorkoutKit"
                    } catch {
                        detail = "训练计划已确认；系统安排待处理"
                    }
                }
                try? await agentSession.reloadPendingActions()
                try inboxStore.setState(WatchReceiptState.processed, for: envelope.messageID)
                _ = try? healthIntelligenceService.refresh()
                refreshApplicationContext()
                return acknowledgement(for: envelope.messageID, state: .processed, detail: detail)
            case .reject(let actionID):
                try await confirmationCoordinator.reject(id: actionID)
                try? await agentSession.reloadPendingActions()
                try inboxStore.setState(WatchReceiptState.processed, for: envelope.messageID)
                refreshApplicationContext()
                return acknowledgement(for: envelope.messageID, state: .processed, detail: "草稿已拒绝")
            case .acknowledgement, .todaySnapshot:
                try inboxStore.setState(WatchReceiptState.rejected, for: envelope.messageID)
                return acknowledgement(for: envelope.messageID, state: .rejected, detail: "此消息类型只能由 iPhone 发送")
            }
        } catch {
            lastError = "Watch 消息未处理：\(error.localizedDescription)"
            return nil
        }
    }

    private func acknowledgement(
        for messageID: UUID,
        state: WatchAcknowledgementState,
        detail: String?
    ) -> Data? {
        let envelope = WatchMessageEnvelope(
            messageID: messageID,
            payload: .acknowledgement(WatchAcknowledgement(messageID: messageID, state: state, detail: detail))
        )
        return try? WatchMessageCodec.encode(envelope)
    }

    private func receiveDictionary(_ dictionary: [String: Any]) async -> [String: Any] {
        guard let data = dictionary[Self.payloadKey] as? Data,
              let acknowledgement = await receive(data) else { return [:] }
        return [Self.payloadKey: acknowledgement]
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isActivated = activationState == .activated
            if let error { self.lastError = error.localizedDescription }
            else { self.lastError = nil }
            self.refreshApplicationContext()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor [weak self] in
            guard let self, let data = userInfo["densoso.watch.payload"] as? Data else { return }
            _ = await self.receive(data)
            self.refreshApplicationContext()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { replyHandler([:]); return }
            replyHandler(await self.receiveDictionary(message))
        }
    }
}
