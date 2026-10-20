import XCTest
@testable import Densoso

@MainActor
final class PromptVersioningTests: XCTestCase {
    func testPromptAndToolSchemaVersionsMatchMainPR111And112() {
        XCTAssertEqual(AgentSystemPrompt.version, "agent-v2")
        XCTAssertEqual(HealthContextPromptBuilder.promptVersion, "health-narrative-v1")
        XCTAssertEqual(MealCaptureApplicationService.promptVersion, "meal-v2")
        XCTAssertEqual(QwenMealVisionProvider.promptVersion, "meal-vision-v2")
        XCTAssertEqual(ToolRegistry.toolSchemaVersion, 2)
        XCTAssertEqual(ToolSchemaVersion.current, 2)
        XCTAssertTrue(ToolSchemaVersion.supportsRestore(ToolSchemaVersion.legacy))
        XCTAssertTrue(ToolSchemaVersion.supportsRestore(ToolSchemaVersion.current))
        XCTAssertFalse(ToolSchemaVersion.supportsRestore(99))
    }
}
