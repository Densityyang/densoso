import XCTest
@testable import Densoso

@MainActor
final class AgentPersistenceBoundaryTests: XCTestCase {
    func testRegistryDoesNotExposeCompletedWorkoutWriteTool() {
        let registry = ToolRegistry()
        XCTAssertFalse(registry.toolDefinitions.contains { $0.name == "log_workout" })
        XCTAssertTrue(registry.toolDefinitions.contains { $0.name == "log_meal" })
        XCTAssertTrue(registry.toolDefinitions.contains { $0.name == "log_weight" })
        XCTAssertTrue(registry.toolDefinitions.contains { $0.name == "create_workout_plan" })
    }
}
