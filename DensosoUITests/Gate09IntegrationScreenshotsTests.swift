import XCTest

final class Gate09IntegrationScreenshotsTests: XCTestCase {
    func testTodayQuickActionPrefillsEditableComposerWithoutSubmitting() throws {
        let launchFixture = try Gate01FixtureLoader.load(
            "launch-config",
            as: Gate01LaunchFixture.self
        )
        let app = XCUIApplication()
        app.launchArguments = launchFixture.arguments + ["-ui-testing-seeded"]
        app.launchEnvironment = launchFixture.environment
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["今天"].waitForExistence(timeout: 15))
        let conversation = app.scrollViews["today-conversation-scroll"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        let weightAction = app.buttons["记录体重"]
        for _ in 0..<3 where !weightAction.exists {
            conversation.swipeUp()
        }
        XCTAssertTrue(weightAction.waitForExistence(timeout: 10))
        weightAction.tap()

        let composer = app.descendants(matching: .any)["today-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "我想记录体重")
        XCTAssertFalse(app.staticTexts["正在整理草稿"].exists)
    }

    func testVoiceBarPrioritizesVoiceAndOpensEditableTextEntry() throws {
        let launchFixture = try Gate01FixtureLoader.load(
            "launch-config",
            as: Gate01LaunchFixture.self
        )
        let app = XCUIApplication()
        app.launchArguments = launchFixture.arguments + ["-ui-testing-seeded"]
        app.launchEnvironment = launchFixture.environment
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["今天"].waitForExistence(timeout: 15))
        let voiceButton = app.buttons["today-voice-primary"]
        let photoButton = app.buttons["today-photo-secondary"]
        let textEntryButton = app.buttons["today-text-entry"]
        XCTAssertTrue(voiceButton.waitForExistence(timeout: 10))
        XCTAssertEqual(voiceButton.label, "开始说话")
        XCTAssertTrue(photoButton.exists)
        XCTAssertTrue(textEntryButton.exists)
        XCTAssertEqual(textEntryButton.label, "编辑文字")

        textEntryButton.tap()
        let composer = app.descendants(matching: .any)["today-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["today-send"].exists)
        XCTAssertFalse(app.staticTexts["正在整理草稿"].exists)
    }

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
        XCTAssertTrue(
            app.descendants(matching: .any)["daily-loop-snapshot"].waitForExistence(timeout: 10),
            "Today should show the composed DailyLoop snapshot"
        )
        XCTAssertTrue(app.descendants(matching: .any)["daily-loop-phase"].waitForExistence(timeout: 5))
        let appFrame = app.windows.firstMatch.frame
        XCTAssertGreaterThan(appFrame.width, 0)
        XCTAssertGreaterThan(appFrame.height, appFrame.width)

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
