import XCTest
@testable import Densoso

@MainActor
final class AgentPersistenceBoundaryTests: XCTestCase {
    func testDeepSeekRequestsDisableThinking() throws {
        let request = DeepSeekClient.Request(
            model: "test",
            maxTokens: 1,
            system: nil,
            messages: [],
            tools: nil,
            toolChoice: nil,
            thinking: .disabled
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        let thinking = object?["thinking"] as? [String: String]
        XCTAssertEqual(thinking?["type"], "disabled")
    }

    func testRegistryDoesNotExposeCompletedWorkoutWriteTool() {
        let registry = ToolRegistry()
        XCTAssertFalse(registry.toolDefinitions.contains { $0.name == "log_workout" })
        XCTAssertTrue(registry.toolDefinitions.contains { $0.name == "log_meal" })
        XCTAssertTrue(registry.toolDefinitions.contains { $0.name == "log_weight" })
    }
}
