import XCTest
@testable import Densoso

@MainActor
final class PromptVersioningTests: XCTestCase {
    func testPromptAndToolSchemaVersionsMatchMainPR111And112() {
        XCTAssertEqual(AgentSystemPrompt.version, "agent-v4")
        XCTAssertEqual(HealthContextPromptBuilder.promptVersion, "health-narrative-v3")
        XCTAssertEqual(MealCaptureApplicationService.promptVersion, "meal-v2")
        XCTAssertEqual(QwenMealVisionProvider.promptVersion, "meal-vision-v2")
        XCTAssertEqual(ToolRegistry.toolSchemaVersion, 3)
        XCTAssertEqual(ToolSchemaVersion.current, 3)
        XCTAssertTrue(ToolSchemaVersion.supportsRestore(ToolSchemaVersion.legacy))
        XCTAssertTrue(ToolSchemaVersion.supportsRestore(ToolSchemaVersion.previous))
        XCTAssertTrue(ToolSchemaVersion.supportsRestore(ToolSchemaVersion.current))
        XCTAssertFalse(ToolSchemaVersion.supportsRestore(99))
    }
}
