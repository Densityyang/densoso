import DensosoDomain
import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class DailyCheckInConfirmationTests: XCTestCase {
    func testToolCreatesOnlyPendingActionUntilUserConfirms() async throws {
        let container = try makeV5Container()
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let tool = StageDailyCheckInTool()
        let draft = try tool.draft(
            argumentsJSON: #"{"energy":"low","stress":"elevated","subjectiveSleep":"poor","note":"  昨晚醒了几次  "}"#,
            asOf: date
        )
        let repository = SwiftDataConfirmationRepository(modelContainer: container)
        let outbox = CountingHealthSyncOutbox()
        let coordinator = ConfirmationCoordinator(
            repository: repository,
            writeGate: PersistenceWriteGate(state: .writable),
            now: { date },
            healthSyncOutbox: outbox
        )
        let checkInPayload = ActionPayload.dailyCheckIn(draft)

        let pending = try await coordinator.stage(payload: checkInPayload, clientRequestID: UUID())
        XCTAssertEqual(pending.payload, checkInPayload)
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingActionRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyCheckInRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 0)
        XCTAssertEqual(outbox.processCount, 0)

        let receipt = try await coordinator.confirm(id: pending.id)

        XCTAssertEqual(receipt.actionType, .dailyCheckIn)
        XCTAssertEqual(receipt.healthSyncState, .notApplicable)
        XCTAssertTrue(receipt.outboxIDs.isEmpty)
        XCTAssertEqual(outbox.processCount, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyCheckInRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyHealthSnapshotRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyMetrics>()), 0)
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<DailyCheckInRecord>()).first)
        XCTAssertEqual(stored.sourceActionKey, pending.idempotencyKey)
        XCTAssertEqual(stored.occurredAt, date)
        XCTAssertEqual(stored.energyRaw, "low")
        XCTAssertEqual(stored.stressRaw, "elevated")
        XCTAssertEqual(stored.subjectiveSleepRaw, "poor")
        XCTAssertEqual(stored.note, "昨晚醒了几次")
        XCTAssertEqual(stored.sourceRaw, "userReported")
        XCTAssertEqual(receipt.localRecordID, stored.id)
    }

    func testRejectingCheckInNeverPersistsTheUserReportedFact() async throws {
        let container = try makeV5Container()
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let repository = SwiftDataConfirmationRepository(modelContainer: container)
        let coordinator = ConfirmationCoordinator(
            repository: repository,
            writeGate: PersistenceWriteGate(state: .writable),
            now: { date }
        )
        let pending = try await coordinator.stage(
            payload: .dailyCheckIn(DailyCheckIn(
                occurredAt: date,
                energy: .low,
                stress: .elevated,
                subjectiveSleep: .poor
            )),
            clientRequestID: UUID()
        )

        try await coordinator.reject(id: pending.id)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyCheckInRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CommittedActionReceiptRecord>()), 0)
    }

    func testCanonicalPayloadNormalizesNoteAndRejectsOversizedNote() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = ActionPayload.dailyCheckIn(DailyCheckIn(
            occurredAt: date,
            energy: .typical,
            stress: .low,
            subjectiveSleep: .fair,
            note: "  user report  "
        ))
        let canonical = try payload.canonicalData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: canonical) as? [String: Any])
        XCTAssertEqual(object["actionType"] as? String, "dailyCheckIn")
        let canonicalPayload = try XCTUnwrap(object["payload"] as? [String: Any])
        let values = try XCTUnwrap(canonicalPayload["dailyCheckIn"] as? [String: Any])
        XCTAssertEqual(values["note"] as? String, "user report")
        XCTAssertNil(values["healthKitSamples"])

        let oversized = ActionPayload.dailyCheckIn(DailyCheckIn(
            occurredAt: date,
            energy: .typical,
            stress: .low,
            subjectiveSleep: .fair,
            note: String(repeating: "a", count: 501)
        ))
        XCTAssertThrowsError(try oversized.canonicalData()) { error in
            XCTAssertEqual(error as? CanonicalizationError, .outOfRange(field: "dailyCheckIn.note"))
        }
    }

    func testToolUsesStrictStagingSchemaAndParsesExplicitSelfReportOnly() throws {
        let tool = StageDailyCheckInTool()
        XCTAssertEqual(tool.definition.name, "stage_daily_checkin")
        XCTAssertEqual(tool.definition.effect, .stagesAction)
        guard case .object(_, let required, let additionalProperties, _) = tool.definition.parameters else {
            return XCTFail("stage_daily_checkin must use a closed object schema")
        }
        XCTAssertEqual(Set(required), Set(["energy", "stress", "subjectiveSleep"]))
        XCTAssertFalse(additionalProperties)
        XCTAssertNoThrow(try ToolSchemaValidator.validate(.object([
            "energy": .string("low"),
            "stress": .string("elevated"),
            "subjectiveSleep": .string("poor"),
        ]), against: tool.definition.parameters))

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = try tool.draft(
            argumentsJSON: #"{"energy":"low","stress":"elevated","subjectiveSleep":"poor","occurredAt":null,"note":null}"#,
            asOf: date
        )
        XCTAssertEqual(draft.occurredAt, date)
        XCTAssertEqual(draft.energy, .low)
        XCTAssertEqual(draft.stress, .elevated)
        XCTAssertEqual(draft.subjectiveSleep, .poor)
        XCTAssertNil(draft.note)
        let oversizedArguments = try JSONSerialization.data(withJSONObject: [
            "energy": "low",
            "stress": "elevated",
            "subjectiveSleep": "poor",
            "note": String(repeating: "x", count: 501),
        ])
        XCTAssertThrowsError(try tool.draft(
            argumentsJSON: String(decoding: oversizedArguments, as: UTF8.self),
            asOf: date
        ))
    }

    func testSelfReportResolverAcceptsExplicitFieldsAndVerbatimNote() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let checkIn = DailyCheckIn(
            occurredAt: date,
            energy: .low,
            stress: .elevated,
            subjectiveSleep: .poor,
            note: "昨晚醒了几次"
        )

        XCTAssertNoThrow(try DailyCheckInSelfReportResolver().validate(
            checkIn,
            userText: "今天感觉特别累，压力很大，昨晚没睡好，备注昨晚醒了几次。",
            asOf: date
        ))
    }

    func testSelfReportResolverDoesNotInferStressFromFatigueAndSleep() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let checkIn = DailyCheckIn(
            occurredAt: date,
            energy: .low,
            stress: .elevated,
            subjectiveSleep: .poor
        )

        XCTAssertThrowsError(try DailyCheckInSelfReportResolver().validate(
            checkIn,
            userText: "今天感觉特别累，昨晚也没睡好。",
            asOf: date
        )) { error in
            XCTAssertEqual(error as? DailyCheckInSelfReportError, .missing([.stress]))
        }
    }

    func testSelfReportResolverRejectsContradictionsOtherPeopleAndInventedNotes() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let resolver = DailyCheckInSelfReportResolver()
        let contradictory = DailyCheckIn(
            occurredAt: date,
            energy: .low,
            stress: .elevated,
            subjectiveSleep: .poor
        )
        XCTAssertThrowsError(try resolver.validate(
            contradictory,
            userText: "今天精力很好、压力不大，昨晚睡得很好。",
            asOf: date
        )) { error in
            XCTAssertEqual(error as? DailyCheckInSelfReportError, .modelValueNotSupported(.energy))
        }

        XCTAssertThrowsError(try resolver.validate(
            DailyCheckIn(
                occurredAt: date,
                energy: .low,
                stress: .elevated,
                subjectiveSleep: .poor
            ),
            userText: "我朋友今天很累、压力很大，昨晚没睡好。",
            asOf: date
        )) { error in
            XCTAssertEqual(error as? DailyCheckInSelfReportError, .otherPerson)
        }

        XCTAssertThrowsError(try resolver.validate(
            DailyCheckIn(
                occurredAt: date,
                energy: .low,
                stress: .elevated,
                subjectiveSleep: .poor,
                note: "模型补出来的备注"
            ),
            userText: "今天感觉特别累，压力很大，昨晚没睡好。",
            asOf: date
        )) { error in
            XCTAssertEqual(error as? DailyCheckInSelfReportError, .noteNotReported)
        }
    }

    func testSelfReportResolverRejectsUnsupportedDateAndHonorsNegation() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let resolver = DailyCheckInSelfReportResolver()
        XCTAssertThrowsError(try resolver.validate(
            DailyCheckIn(
                occurredAt: date.addingTimeInterval(-86_400),
                energy: .typical,
                stress: .low,
                subjectiveSleep: .fair
            ),
            userText: "今天不太累，压力不大，昨晚睡得一般。",
            asOf: date
        )) { error in
            XCTAssertEqual(error as? DailyCheckInSelfReportError, .dateNotSupported)
        }

        XCTAssertNoThrow(try resolver.validate(
            DailyCheckIn(
                occurredAt: date,
                energy: .typical,
                stress: .low,
                subjectiveSleep: .fair
            ),
            userText: "今天不太累，压力不大，昨晚睡得一般。",
            asOf: date
        ))
    }

    func testAgentDoesNotStageInferredStressButStagesAndCommitsExplicitCheckIn() async throws {
        let inferredProvider = ScriptedTextProvider(scripts: [
            [
                .toolCall(dailyCheckInCall(energy: "low", stress: "elevated", sleep: "poor")),
                .completed(.toolUse),
            ],
            [.textDelta("请补充今天的压力感受，我再准备草稿。"), .completed(.completed)],
        ])
        let inferredContainer = try makeV5Container()
        let inferredSession = makeAgentSession(provider: inferredProvider, container: inferredContainer)
        _ = try await inferredSession.send(
            userText: "请记录我的每日状态：今天感觉特别累，昨晚睡眠不好。"
        )

        XCTAssertTrue(inferredSession.pendingActions.isEmpty)
        XCTAssertEqual(
            try ModelContext(inferredContainer).fetchCount(FetchDescriptor<DailyCheckInRecord>()),
            0
        )
        let secondRequest = try XCTUnwrap(inferredProvider.recordedRequests().dropFirst().first)
        let toolResult = secondRequest.messages.flatMap(\.content)
            .compactMap { content -> String? in
                if case .toolResult(_, let value) = content { return value }
                return nil
            }
            .first
        let errorText = try XCTUnwrap(toolResult)
        XCTAssertTrue(errorText.contains("压力"))

        let explicitProvider = ScriptedTextProvider(scripts: [
            [
                .toolCall(dailyCheckInCall(
                    energy: "low",
                    stress: "elevated",
                    sleep: "poor",
                    note: "昨晚醒了几次"
                )),
                .completed(.toolUse),
            ],
            [.textDelta("每日状态草稿已准备，请确认。"), .completed(.completed)],
        ])
        let explicitContainer = try makeV5Container()
        let explicitSession = makeAgentSession(provider: explicitProvider, container: explicitContainer)
        _ = try await explicitSession.send(
            userText: "请记录我的每日状态：今天感觉特别累，压力很大，昨晚睡眠不好，备注昨晚醒了几次。"
        )

        let context = ModelContext(explicitContainer)
        XCTAssertEqual(explicitSession.pendingActions.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyCheckInRecord>()), 0)
        _ = try await explicitSession.confirmPendingAction(id: try XCTUnwrap(explicitSession.pendingActions.first?.id))
        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<DailyCheckInRecord>()).first)
        XCTAssertEqual(saved.sourceRaw, "userReported")
        XCTAssertEqual(saved.energyRaw, "low")
        XCTAssertEqual(saved.stressRaw, "elevated")
        XCTAssertEqual(saved.subjectiveSleepRaw, "poor")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyMetrics>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyHealthSnapshotRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 0)
    }

    func testV4StoreMigratesToV5WithAnEmptyCheckInLedger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso-checkin-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        try createV4Store(at: storeURL)

        let schema = Schema(versionedSchema: DensosoSchemaV5.self)
        let configuration = ModelConfiguration("Densoso", schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DensosoMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyCheckInRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ConversationRecord>()), 1)
    }

    private func makeV5Container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV5.self)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func createV4Store(at storeURL: URL) throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let configuration = ModelConfiguration("Densoso", schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(ConversationRecord())
        try context.save()
    }

    private func makeAgentSession(
        provider: any TextModelProvider,
        container: ModelContainer
    ) -> AgentSession {
        let confirmationRepository = SwiftDataConfirmationRepository(modelContainer: container)
        let agentRepository = SwiftDataAgentRepository(modelContainer: container)
        let governance = InMemoryProviderGovernanceRepository(granted: [(.deepSeek, .healthText)])
        let preferences = IntelligencePreferences()
        preferences.mode = .cloudDeepSeek
        return AgentSession(
            providerSelector: TestProviderSelector(provider),
            intelligencePreferences: preferences,
            providerConfiguration: ProviderConfigurationPreferences(),
            governanceRepository: governance,
            usageLedger: ProviderUsageLedger(repository: governance),
            registry: ToolRegistry(),
            confirmationCoordinator: ConfirmationCoordinator(
                repository: confirmationRepository,
                writeGate: PersistenceWriteGate(state: .writable)
            ),
            readRepository: agentRepository,
            conversationRepository: agentRepository
        )
    }

    private func dailyCheckInCall(
        energy: String,
        stress: String,
        sleep: String,
        note: String? = nil
    ) -> ToolCall {
        var arguments: [String: JSONValue] = [
            "energy": .string(energy),
            "stress": .string(stress),
            "subjectiveSleep": .string(sleep),
        ]
        if let note { arguments["note"] = .string(note) }
        return ToolCall(
            id: "daily-check-in",
            name: "stage_daily_checkin",
            arguments: .object(arguments)
        )
    }
}

@MainActor
private final class CountingHealthSyncOutbox: HealthSyncOutboxProcessing {
    private(set) var processCount = 0

    func processPending() async {
        processCount += 1
    }
}
