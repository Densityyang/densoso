import XCTest

final class Gate01PrimaryScreenshotsTests: XCTestCase {
    func testSeededPrimaryScreensAreReachableAndCaptured() throws {
        continueAfterFailure = false
        let launchFixture = try Gate01FixtureLoader.load(
            "launch-config",
            as: Gate01LaunchFixture.self
        )
        let screenFixtures = try Gate01FixtureLoader.load(
            "expected-tabs",
            as: Gate01ScreenFixtures.self
        )
        let app = XCUIApplication()
        app.launchArguments = launchFixture.arguments + ["-ui-testing-seeded"]
        app.launchEnvironment = launchFixture.environment
        app.launch()

        XCTAssertTrue(
            app.tabBars.buttons["对话"].waitForExistence(timeout: 15),
            "The seeded UI-test profile must enter the main tab hierarchy"
        )

        for screen in screenFixtures.screens {
            let tab = app.tabBars.buttons[screen.tab]
            XCTAssertTrue(tab.exists, "Missing tab \(screen.tab)")
            tab.tap()
            XCTAssertTrue(
                app.staticTexts[screen.marker].waitForExistence(timeout: 10),
                "Missing marker for \(screen.id): \(screen.marker)"
            )
            keepScreenshot(named: "gate-01-\(screen.id)")
        }
    }
}
