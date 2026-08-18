import XCTest

final class Gate01LaunchSmokeTests: XCTestCase {
    func testFreshInMemoryLaunchShowsOnboarding() throws {
        continueAfterFailure = false
        let fixture = try Gate01FixtureLoader.load(
            "launch-config",
            as: Gate01LaunchFixture.self
        )
        let app = XCUIApplication()
        app.launchArguments = fixture.arguments
        app.launchEnvironment = fixture.environment
        app.launch()

        XCTAssertTrue(
            app.staticTexts["你的记录，先由你决定去向。"].waitForExistence(timeout: 15),
            "A fresh UI-test store must launch into onboarding"
        )
        keepScreenshot(named: "gate-01-onboarding")
    }
}
