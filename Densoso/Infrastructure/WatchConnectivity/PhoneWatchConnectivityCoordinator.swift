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
    private static let watchSnapshotEntryLimit = 10

    @ObservationIgnored private let session: WCSession
    @ObservationIgnored private let confirmationCoordinator: ConfirmationCoordinator
    @ObservationIgnored private let agentSession: AgentSession
    @ObservationIgnored private let healthIntelligenceService: HealthIntelligenceService
    @ObservationIgnored private let workoutPlanSchedulingService: WorkoutPlanSchedulingService
    @ObservationIgnored private let inboxStore: WatchMessageInboxStore
    @ObservationIgnored private var processingMessageIDs = Set<UUID>()
    @ObservationIgnored private var isResumingPendingCommands = false
    @ObservationIgnored private var needsAnotherResumePass = false

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

    private func finishResumingPendingCommands() {
        isResumingPendingCommands = false
        if needsAnotherResumePass {
            needsAnotherResumePass = false
            resumePendingCommands()
        }
    }

    private func resumePendingCommands() {
        guard !isResumingPendingCommands else {
            needsAnotherResumePass = true
            return
        }

        isResumingPendingCommands = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.needsAnotherResumePass = false
                let envelopes: [WatchMessageEnvelope]
                do {
                    envelopes = try self.inboxStore.pendingReplayEnvelopes()
                } catch {
                    self.lastError = "无法恢复 Watch 命令：\(error.localizedDescription)"
                    self.finishResumingPendingCommands()
                    return
                }

                var reachedTerminalState = false
                for envelope in envelopes {
                    guard let data = try? WatchMessageCodec.encode(envelope) else { continue }
                    let response = await self.receive(data)
                    reachedTerminalState = reachedTerminalState || Self.isTerminalAcknowledgement(response)
                }
                if reachedTerminalState { self.needsAnotherResumePass = true }
            } while self.needsAnotherResumePass
            self.finishResumingPendingCommands()
        }
    }

    private static func isTerminalAcknowledgement(_ data: Data?) -> Bool {
        guard let data,
              let envelope = try? WatchMessageCodec.decode(data),
              case .acknowledgement(let acknowledgement) = envelope.payload else { return false }
        switch acknowledgement.state {
        case .processed, .duplicate, .rejected:
            return true
        case .accepted:
            return false
        }
    }

    private func setReceiptState(_ state: String, for messageID: UUID) throws {
        _ = try inboxStore.setState(state, for: messageID)
        if isResumingPendingCommands {
            needsAnotherResumePass = true
        } else {
            resumePendingCommands()
        }
        refreshApplicationContext()
    }

    private func rejectPendingMessage(
        _ envelope: WatchMessageEnvelope,
        detail: String
    ) throws -> Data? {
        try setReceiptState(WatchReceiptState.rejected, for: envelope.messageID)
        return acknowledgement(for: envelope.messageID, state: .rejected, detail: detail)
    }

    private func dependencyState(for envelope: WatchMessageEnvelope) throws -> WatchCommandDependencyDecision {
        let states = try inboxStore.causalSequenceStates(for: [envelope])
        if let sequence = envelope.causalSequence, states[sequence] == .conflict {
            return .rejectedBecause(sequence)
        }
        return WatchCommandDependencyPolicy.decision(for: envelope, sequenceStates: states)
    }

    private func isCommandOrTranscript(_ payload: WatchPayload) -> Bool {
        switch payload {
        case .transcript, .confirm, .reject:
            return true
        case .requestTodaySnapshot, .acknowledgement, .todaySnapshot:
            return false
        }
    }

    private func resumeIfNotAlreadyReplaying() {
        if !isResumingPendingCommands { resumePendingCommands() }
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
        try inboxStore.nextEligibleTranscript(excluding: claimedIDs)
    }

    func markTranscriptProcessed(_ messageID: UUID) throws {
        try setReceiptState(WatchReceiptState.processed, for: messageID)
    }

    func pendingActionSummaries() -> [WatchPendingActionSummary] {
        agentSession.pendingActions
            .filter { $0.state == .pending }
            .sorted { lhs, rhs in
                if lhs.expiresAt != rhs.expiresAt { return lhs.expiresAt < rhs.expiresAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(Self.watchSnapshotEntryLimit)
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
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: today)!
        let todayBrief = healthIntelligenceService.dailyBrief.flatMap { brief in
            calendar.isDate(brief.dayStart, inSameDayAs: today) ? brief : nil
        }
        let received = try inboxStore.recentProcessedMessageIDs()
        let singleSessionPlans = try workoutPlanSchedulingService
            .upcomingConfirmedPlans(from: today, limit: Self.watchSnapshotEntryLimit)
            .map {
                WatchWorkoutPlanSummary(
                    actionID: $0.actionID,
                    title: $0.draft.name,
                    scheduledAt: $0.draft.scheduledAt,
                    state: $0.state.rawValue,
                    lastError: $0.lastError
                )
            }
        let multiDaySessionPlans = try workoutPlanSchedulingService
            .upcomingConfirmedTrainingSessions(in: today..<dayAfterTomorrow, limit: Self.watchSnapshotEntryLimit)
            .map {
                WatchWorkoutPlanSummary(
                    actionID: $0.sessionID,
                    title: "\($0.planName) · \($0.activity.displayName)",
                    scheduledAt: $0.scheduledAt,
                    state: $0.state.rawValue,
                    lastError: $0.lastError
                )
            }
        let scheduledPlans = Array((singleSessionPlans + multiDaySessionPlans)
            .sorted { lhs, rhs in
                let leftDate = lhs.scheduledAt ?? .distantFuture
                let rightDate = rhs.scheduledAt ?? .distantFuture
                if leftDate != rightDate { return leftDate < rightDate }
                return lhs.actionID.uuidString < rhs.actionID.uuidString
            }
            .prefix(Self.watchSnapshotEntryLimit))
        return WatchTodaySnapshot(
            generatedAt: Date(),
            summary: todayBrief?.summary ?? "暂无本地健康摘要",
            domains: todayBrief?.domains.map {
                WatchHealthDomainStatus(domain: $0.domain, status: $0.status)
            } ?? [],
            pendingActions: pendingActionSummaries(),
            workoutPlans: scheduledPlans,
            acknowledgedMessageIDs: received,
            tomorrowGuidance: todayBrief?.healthState?.tomorrowGuidance.map { guidance in
                WatchTomorrowGuidanceSummary(
                    expectedState: guidance.expectedState,
                    confidence: guidance.confidence,
                    recommendedAction: guidance.recommendedAction,
                    conditionalNote: guidance.conditionalNote
                )
            },
            recoverySummary: todayBrief?.healthState.map { healthState in
                WatchRecoverySummary(
                    status: healthState.recovery.status,
                    confidence: healthState.recovery.confidence,
                    recommendedAction: healthState.recovery.recommendedAction
                )
            }
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
            if isCommandOrTranscript(envelope.payload) {
                switch try dependencyState(for: envelope) {
                case .ready:
                    if try inboxStore.hasEarlierPendingCommand(before: envelope.messageID) {
                        resumeIfNotAlreadyReplaying()
                        return acknowledgement(
                            for: envelope.messageID,
                            state: .accepted,
                            detail: "已保存，等待更早的 Watch 消息处理完成"
                        )
                    }
                case .waitingFor(let sequence):
                    resumeIfNotAlreadyReplaying()
                    return acknowledgement(
                        for: envelope.messageID,
                        state: .accepted,
                        detail: "已保存，等待前序命令 \(sequence) 完成"
                    )
                case .rejectedBecause(let sequence):
                    return try rejectPendingMessage(
                        envelope,
                        detail: "前序命令 \(sequence) 已拒绝或存在序号冲突，当前消息未执行。"
                    )
                }
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
                try setReceiptState(WatchReceiptState.processed, for: envelope.messageID)
                refreshApplicationContext()
                return acknowledgement(for: envelope.messageID, state: .processed, detail: "已更新 Today 摘要")
            case .confirm(let actionID):
                if agentSession.pendingActions.contains(where: { action in
                    guard action.id == actionID else { return false }
                    if case .trainingPlan = action.payload { return true }
                    return false
                }) {
                    try setReceiptState(WatchReceiptState.rejected, for: envelope.messageID)
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
                        try setReceiptState(WatchReceiptState.rejected, for: envelope.messageID)
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
                try setReceiptState(WatchReceiptState.processed, for: envelope.messageID)
                _ = try? await healthIntelligenceService.refresh()
                refreshApplicationContext()
                return acknowledgement(for: envelope.messageID, state: .processed, detail: detail)
            case .reject(let actionID):
                do {
                    try await confirmationCoordinator.reject(id: actionID)
                } catch {
                    if let confirmationError = error as? ConfirmationError, !confirmationError.isRetryable {
                        try setReceiptState(WatchReceiptState.rejected, for: envelope.messageID)
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
                try setReceiptState(WatchReceiptState.processed, for: envelope.messageID)
                refreshApplicationContext()
                return acknowledgement(for: envelope.messageID, state: .processed, detail: "草稿已拒绝")
            case .acknowledgement, .todaySnapshot:
                try setReceiptState(WatchReceiptState.rejected, for: envelope.messageID)
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
