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

/// WCSession's Objective-C reply closure is non-Sendable. This single-use box
/// transfers it across the actor hop and invokes it exactly once after inbox persistence.
private final class WatchSessionReplyHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (([String: Any]) -> Void)?

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func reply(with data: Data?) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()

        guard let handler else { return }
        if let data {
            handler(["densoso.watch.payload": data])
        } else {
            handler([:])
        }
    }
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
    @ObservationIgnored private var isResumingPendingCommands = false

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
        resumePendingCommands()
        guard isAvailable, session.activationState == .notActivated else { return }
        session.activate()
    }

    private func resumePendingCommands() {
        guard !isResumingPendingCommands else { return }

        let envelopes: [WatchMessageEnvelope]
        do {
            envelopes = try inboxStore.pendingCommandEnvelopes()
        } catch {
            lastError = "无法恢复 Watch 命令：\(error.localizedDescription)"
            return
        }
        guard !envelopes.isEmpty else { return }

        isResumingPendingCommands = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isResumingPendingCommands = false }
            for envelope in envelopes {
                guard let data = try? WatchMessageCodec.encode(envelope) else { continue }
                _ = await self.receive(data)
            }
        }
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
            .map { action in
                let requiresPhoneReview: Bool
                if case .trainingPlan = action.payload {
                    requiresPhoneReview = true
                } else {
                    requiresPhoneReview = false
                }
                return WatchPendingActionSummary(
                    actionID: action.id,
                    title: action.payload.title,
                    summary: action.payload.summary,
                    expiresAt: action.expiresAt,
                    requiresPhoneReview: requiresPhoneReview
                )
            }
    }

    private func makeTodaySnapshot() throws -> WatchTodaySnapshot {
        let context = ModelContext(modelContainer)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let metricsPredicate = #Predicate<DailyMetrics> { $0.date >= today && $0.date < tomorrow }
        var metricsDescriptor = FetchDescriptor<DailyMetrics>(predicate: metricsPredicate)
        metricsDescriptor.fetchLimit = 1
        let metrics = try context.fetch(metricsDescriptor).first
        let received = try inboxStore.recentReceivedMessageIDs()
        let singleSessionPlans = try workoutPlanSchedulingService.confirmedPlans().map {
            WatchWorkoutPlanSummary(
                actionID: $0.actionID,
                title: $0.draft.name,
                scheduledAt: $0.draft.scheduledAt,
                state: $0.state.rawValue,
                lastError: $0.lastError
            )
        }
        let multiDaySessionPlans = try workoutPlanSchedulingService.confirmedTrainingPlans().flatMap { entry in
            entry.draft.sessions.compactMap { session -> WatchWorkoutPlanSummary? in
                guard let activity = session.activity else { return nil }
                return WatchWorkoutPlanSummary(
                    actionID: session.id,
                    title: "\(entry.draft.name) · \(activity.displayName)",
                    scheduledAt: session.date,
                    state: entry.state.rawValue,
                    lastError: entry.lastError
                )
            }
        }
        let scheduledPlans = Array((singleSessionPlans + multiDaySessionPlans)
            .filter { ($0.scheduledAt ?? .distantPast) >= today && $0.state != "terminal" }
            .sorted { ($0.scheduledAt ?? .distantFuture) < ($1.scheduledAt ?? .distantFuture) }
            .prefix(10))
        return WatchTodaySnapshot(
            generatedAt: Date(),
            summary: healthIntelligenceService.dailyBrief?.summary ?? "暂无本地健康摘要",
            energyIntakeKcal: metrics?.totalIntakeKcal,
            totalExpenditureKcal: metrics?.totalExpenditureKcal,
            deficitKcal: metrics?.deficitKcal,
            domains: healthIntelligenceService.dailyBrief?.domains ?? [],
            pendingActions: pendingActionSummaries(),
            workoutPlans: scheduledPlans,
            acknowledgedMessageIDs: received
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
                if agentSession.pendingActions.contains(where: { action in
                    guard action.id == actionID else { return false }
                    if case .trainingPlan = action.payload { return true }
                    return false
                }) {
                    try inboxStore.setState(WatchReceiptState.rejected, for: envelope.messageID)
                    return acknowledgement(
                        for: envelope.messageID,
                        state: .rejected,
                        detail: "多日训练计划请在 iPhone 查看完整安排后确认。"
                    )
                }
                let receipt: CommitReceipt
                do {
                    receipt = try await confirmationCoordinator.confirm(id: actionID)
                } catch {
                    if let confirmationError = error as? ConfirmationError, !confirmationError.isRetryable {
                        try inboxStore.setState(WatchReceiptState.rejected, for: envelope.messageID)
                        return acknowledgement(
                            for: envelope.messageID,
                            state: .rejected,
                            detail: confirmationError.localizedDescription
                        )
                    }
                    throw error
                }
                var detail = "已在本机确认"
                if receipt.actionType == .workoutPlan || receipt.actionType == .trainingPlan {
                    do {
                        try await workoutPlanSchedulingService.scheduleConfirmedPlan(actionID: actionID)
                        detail = "训练计划已确认并提交给 WorkoutKit"
                    } catch {
                        detail = "训练计划已确认；系统安排待处理"
                    }
                }
                try? await agentSession.reloadPendingActions()
                try inboxStore.setState(WatchReceiptState.processed, for: envelope.messageID)
                _ = try? await healthIntelligenceService.refresh()
                refreshApplicationContext()
                return acknowledgement(for: envelope.messageID, state: .processed, detail: detail)
            case .reject(let actionID):
                do {
                    try await confirmationCoordinator.reject(id: actionID)
                } catch {
                    if let confirmationError = error as? ConfirmationError, !confirmationError.isRetryable {
                        try inboxStore.setState(WatchReceiptState.rejected, for: envelope.messageID)
                        refreshApplicationContext()
                        return acknowledgement(
                            for: envelope.messageID,
                            state: .rejected,
                            detail: confirmationError.localizedDescription
                        )
                    }
                    throw error
                }
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

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let isActivated = activationState == .activated
        let errorMessage = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isActivated = isActivated
            if let errorMessage { self.lastError = errorMessage }
            else { self.lastError = nil }
            self.refreshApplicationContext()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo["densoso.watch.payload"] as? Data else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.receive(data)
            self.refreshApplicationContext()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let reply = WatchSessionReplyHandler(replyHandler)
        guard let data = message["densoso.watch.payload"] as? Data else {
            reply.reply(with: nil)
            return
        }
        Task { @MainActor [weak self, reply] in
            guard let self else { reply.reply(with: nil); return }
            let response = await self.receive(data)
            reply.reply(with: response)
            self.refreshApplicationContext()
        }
    }
}
