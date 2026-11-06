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

private func safeWatchErrorMessage(_ error: Error) -> String {
    SharedErrorDescriptor.mapped(from: error, fallback: .watchUnavailableFallback).userMessage
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
    @ObservationIgnored private let modelContainer: ModelContainer
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let agentSession: AgentSession
    @ObservationIgnored private let healthIntelligenceService: HealthIntelligenceService
    @ObservationIgnored private let workoutPlanSchedulingService: WorkoutPlanSchedulingService
    @ObservationIgnored private let inboxStore: WatchMessageInboxStore
    @ObservationIgnored private var processingMessageIDs = Set<UUID>()
    @ObservationIgnored private var isResumingPendingCommands = false
    @ObservationIgnored private var needsAnotherResumePass = false
    @ObservationIgnored private var modelContextSaveObserver: NSObjectProtocol?
    private var snapshotRefreshOverride: WatchSnapshotRefreshState?
    private static let snapshotRevisionDefaultsKey = "densoso.watch.snapshot.revision.v1"

    private(set) var isAvailable = false
    private(set) var isActivated = false
    private(set) var pendingTranscriptRevision = 0
    private(set) var lastError: String?

    init(
        modelContainer: ModelContainer,
        agentSession: AgentSession,
        healthIntelligenceService: HealthIntelligenceService,
        workoutPlanSchedulingService: WorkoutPlanSchedulingService,
        session: WCSession = .default,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.modelContainer = modelContainer
        self.defaults = defaults
        self.now = now
        self.agentSession = agentSession
        self.healthIntelligenceService = healthIntelligenceService
        self.workoutPlanSchedulingService = workoutPlanSchedulingService
        self.inboxStore = WatchMessageInboxStore(modelContainer: modelContainer)
        self.session = session
        self.isAvailable = WCSession.isSupported()
        super.init()
        if isAvailable { session.delegate = self }
        modelContextSaveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshApplicationContext() }
        }
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
                    self.lastError = "无法恢复 Watch 命令：\(safeWatchErrorMessage(error))"
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
        try inboxStore.verifyState(state, for: messageID)
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
            lastError = "无法同步 Watch 摘要：\(safeWatchErrorMessage(error))"
        }
    }

    func nextPendingTranscript(excluding claimedIDs: Set<UUID> = []) throws -> PendingWatchTranscript? {
        try inboxStore.nextEligibleTranscript(excluding: claimedIDs)
    }

    func markTranscriptProcessed(_ messageID: UUID) throws {
        try setReceiptState(WatchReceiptState.processed, for: messageID)
    }

    func pendingActionSummaries(asOf date: Date = Date()) -> [WatchPendingActionSummary] {
        agentSession.pendingActions
            .filter {
                $0.state == .pending
                    && PendingActionExpirationPolicy.isActive(expiresAt: $0.expiresAt, asOf: date)
            }
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
        let generatedAt = now()
        let today = calendar.startOfDay(for: generatedAt)
        let dayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: today)!
        let todayBrief = healthIntelligenceService.dailyBrief.flatMap { brief in
            calendar.isDate(brief.dayStart, inSameDayAs: today) ? brief : nil
        }
        let sourceValidatedAt = todayBrief == nil ? nil : healthIntelligenceService.dailyBriefValidatedAt
        let dailyBriefFingerprint = todayBrief == nil ? nil : healthIntelligenceService.dailyBriefSourceFingerprint
        let dailyLoopSnapshot = DailyLoopSnapshotComposer(calendar: calendar).compose(
            asOf: generatedAt,
            dailyBrief: todayBrief,
            dailyBriefSourceFingerprint: dailyBriefFingerprint,
            dailyBriefValidatedAt: sourceValidatedAt,
            pendingActions: agentSession.pendingActions,
            workoutPlans: []
        )
        let sourceFingerprint = dailyLoopSnapshot.sourceFingerprint
        let refreshState: WatchSnapshotRefreshState = snapshotRefreshOverride ?? {
            switch dailyLoopSnapshot.refreshState {
            case .fresh: .fresh
            case .stale, .refreshRequired: .stale
            case .error: .failed
            }
        }()
        let received = try inboxStore.recentProcessedMessageIDs()
        let terminalCausalSequenceWatermark = try inboxStore.highestContiguousTerminalCausalSequence()
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
        let receiptPredicate = #Predicate<CommittedActionReceiptRecord> {
            $0.actionTypeRaw == "meal" || $0.actionTypeRaw == "weight"
        }
        var receiptDescriptor = FetchDescriptor<CommittedActionReceiptRecord>(
            predicate: receiptPredicate,
            sortBy: [SortDescriptor(\.committedAt, order: .reverse)]
        )
        receiptDescriptor.fetchLimit = Self.watchSnapshotEntryLimit
        let healthSyncSummaries: [WatchHealthSyncSummary] = try ModelContext(modelContainer)
            .fetch(receiptDescriptor)
            .compactMap { receipt -> WatchHealthSyncSummary? in
                guard let state = HealthSyncState(rawValue: receipt.healthSyncStateRaw) else { return nil }
                return WatchHealthSyncSummary(
                    actionID: receipt.actionID,
                    actionType: receipt.actionTypeRaw,
                    state: state,
                    updatedAt: receipt.committedAt
                )
        }
        return WatchTodaySnapshot(
            generatedAt: generatedAt,
            summary: todayBrief?.summary ?? "暂无本地健康摘要",
            domains: todayBrief?.domains.map {
                WatchHealthDomainStatus(domain: $0.domain, status: $0.status)
            } ?? [],
            pendingActions: pendingActionSummaries(asOf: generatedAt),
            workoutPlans: scheduledPlans,
            acknowledgedMessageIDs: received,
            terminalCausalSequenceWatermark: terminalCausalSequenceWatermark,
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
            },
            sourceValidatedAt: sourceValidatedAt,
            sourceFingerprint: sourceFingerprint,
            refreshState: refreshState,
            snapshotRevision: nextSnapshotRevision(),
            healthSyncSummaries: healthSyncSummaries
        )
    }

    private func nextSnapshotRevision() -> UInt64 {
        let current = defaults.string(forKey: Self.snapshotRevisionDefaultsKey).flatMap(UInt64.init) ?? 0
        let next = current == .max ? current : current + 1
        defaults.set(String(next), forKey: Self.snapshotRevisionDefaultsKey)
        return next
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
            if WatchMessageExpiryPolicy.isExpired(envelope, asOf: Date()) {
                return try rejectPendingMessage(envelope, detail: "Watch 消息已过期，未执行；请在 iPhone 查看当前状态后重试。")
            }
            if WatchMessageAuthorizationPolicy.requiresPhoneConfirmation(for: envelope.payload) {
                return try rejectPendingMessage(
                    envelope,
                    detail: "待确认事项必须在 iPhone 查看并处理；Watch 命令未执行。"
                )
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
                snapshotRefreshOverride = .refreshing
                refreshApplicationContext()
                var refreshError: Error?
                do {
                    _ = try await healthIntelligenceService.refresh()
                    snapshotRefreshOverride = nil
                } catch {
                    refreshError = error
                    snapshotRefreshOverride = .failed
                }
                do {
                    try setReceiptState(WatchReceiptState.processed, for: envelope.messageID)
                } catch {
                    snapshotRefreshOverride = refreshError == nil ? nil : .failed
                    refreshApplicationContext()
                    throw error
                }
                refreshApplicationContext()
                if let refreshError {
                    lastError = "Watch 请求的健康数据刷新失败：\(safeWatchErrorMessage(refreshError))"
                    return acknowledgement(
                        for: envelope.messageID,
                        state: .processed,
                        detail: "刷新失败，保留上次摘要并标记为过期。"
                    )
                }
                return acknowledgement(for: envelope.messageID, state: .processed, detail: "已重新验证 Today 健康摘要")
            case .confirm, .reject:
                return try rejectPendingMessage(
                    envelope,
                    detail: "待确认事项必须在 iPhone 查看并处理；Watch 命令未执行。"
                )
            case .acknowledgement, .todaySnapshot:
                try setReceiptState(WatchReceiptState.rejected, for: envelope.messageID)
                return acknowledgement(for: envelope.messageID, state: .rejected, detail: "此消息类型只能由 iPhone 发送")
            }
        } catch {
            lastError = "Watch 消息未处理：\(safeWatchErrorMessage(error))"
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
        let errorMessage = error.map(safeWatchErrorMessage)
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
