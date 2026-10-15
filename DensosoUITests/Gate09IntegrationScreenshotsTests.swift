import XCTest

final class Gate09IntegrationScreenshotsTests: XCTestCase {
    func testAllPrimaryTabsCapturePortraitScreensWithAccessibilityLabels() throws {
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

        XCTAssertTrue(app.tabBars.buttons["今天"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.windows.firstMatch.frame.width, XCUIScreen.main.bounds.width, accuracy: 2)
        XCTAssertGreaterThan(app.windows.firstMatch.frame.height, app.windows.firstMatch.frame.width)

        for screen in screenFixtures.screens {
            let tab = app.tabBars.buttons[screen.tab]
            XCTAssertTrue(tab.exists, "Missing accessible tab label: \(screen.tab)")
            XCTAssertEqual(tab.label, screen.tab)
            tab.tap()
            XCTAssertTrue(
                app.staticTexts[screen.marker].waitForExistence(timeout: 10),
                "Missing marker for \(screen.id): \(screen.marker)"
            )
            keepScreenshot(named: "gate-09-\(screen.id)-portrait")
        }
    }

    func testPrimaryTabsRemainReachableWithLargeTextAndDarkAppearance() throws {
        let launchFixture = try Gate01FixtureLoader.load(
            "launch-config",
            as: Gate01LaunchFixture.self
        )
        let screenFixtures = try Gate01FixtureLoader.load(
            "expected-tabs",
            as: Gate01ScreenFixtures.self
        )
        let app = XCUIApplication()
        app.launchArguments = launchFixture.arguments + [
            "-ui-testing-seeded",
            "-AppleInterfaceStyle",
            "Dark",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityL",
        ]
        app.launchEnvironment = launchFixture.environment
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["今天"].waitForExistence(timeout: 15))
        for screen in screenFixtures.screens {
            let tab = app.tabBars.buttons[screen.tab]
            XCTAssertTrue(tab.exists, "Missing accessible tab in large-text/dark mode: \(screen.tab)")
            tab.tap()
            XCTAssertTrue(app.staticTexts[screen.marker].waitForExistence(timeout: 10))
            keepScreenshot(named: "gate-09-\(screen.id)-dark-large-text")
        }
    }
}
