import XCTest

@MainActor
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

        let todayTabExists = app.tabBars.buttons["今天"].waitForExistence(timeout: 15)
        XCTAssertTrue(todayTabExists)
        let conversation = app.scrollViews["today-conversation-scroll"]
        let conversationExists = conversation.waitForExistence(timeout: 10)
        XCTAssertTrue(conversationExists)
        let weightAction = app.buttons["记录体重"]
        for _ in 0..<3 where !weightAction.exists {
            conversation.swipeUp()
        }
        let weightActionExists = weightAction.waitForExistence(timeout: 10)
        XCTAssertTrue(weightActionExists)
        weightAction.tap()

        let composer = app.textFields["today-composer"]
        let composerExists = composer.waitForExistence(timeout: 5)
        XCTAssertTrue(composerExists)
        let composerValue = composer.value as? String
        XCTAssertEqual(composerValue, "我想记录体重")
        let draftStatusExists = app.staticTexts["正在整理草稿"].exists
        XCTAssertFalse(draftStatusExists)
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

        let todayTabExists = app.tabBars.buttons["今天"].waitForExistence(timeout: 15)
        XCTAssertTrue(todayTabExists)
        let voiceButton = app.buttons["today-voice-primary"]
        let photoButton = app.buttons["today-photo-secondary"]
        let textEntryButton = app.buttons["today-text-entry"]
        let voiceButtonExists = voiceButton.waitForExistence(timeout: 10)
        XCTAssertTrue(voiceButtonExists)
        let voiceButtonLabel = voiceButton.label
        XCTAssertEqual(voiceButtonLabel, "开始说话")
        let photoButtonExists = photoButton.exists
        XCTAssertTrue(photoButtonExists)
        let textEntryButtonExists = textEntryButton.exists
        XCTAssertTrue(textEntryButtonExists)
        let textEntryButtonLabel = textEntryButton.label
        XCTAssertEqual(textEntryButtonLabel, "编辑文字")

        textEntryButton.tap()
        let composer = app.textFields["today-composer"]
        let composerExists = composer.waitForExistence(timeout: 5)
        XCTAssertTrue(composerExists)
        let sendButtonExists = app.buttons["today-send"].exists
        XCTAssertTrue(sendButtonExists)
        let draftStatusExists = app.staticTexts["正在整理草稿"].exists
        XCTAssertFalse(draftStatusExists)
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

        let todayTabExists = app.tabBars.buttons["今天"].waitForExistence(timeout: 15)
        XCTAssertTrue(todayTabExists)
        let dailyLoopSnapshotExists = app.descendants(matching: .any)["daily-loop-snapshot"]
            .waitForExistence(timeout: 10)
        XCTAssertTrue(dailyLoopSnapshotExists, "Today should show the composed DailyLoop snapshot")
        let dailyLoopPhaseExists = app.descendants(matching: .any)["daily-loop-phase"]
            .waitForExistence(timeout: 5)
        XCTAssertTrue(dailyLoopPhaseExists)
        let appFrame = app.windows.firstMatch.frame
        XCTAssertGreaterThan(appFrame.width, 0)
        XCTAssertGreaterThan(appFrame.height, appFrame.width)

        for screen in screenFixtures.screens {
            let tab = app.tabBars.buttons[screen.tab]
            let tabExists = tab.exists
            XCTAssertTrue(tabExists, "Missing accessible tab label: \(screen.tab)")
            let tabLabel = tab.label
            XCTAssertEqual(tabLabel, screen.tab)
            tab.tap()
            let markerExists = app.staticTexts[screen.marker].waitForExistence(timeout: 10)
            XCTAssertTrue(markerExists, "Missing marker for \(screen.id): \(screen.marker)")
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

        let todayTabExists = app.tabBars.buttons["今天"].waitForExistence(timeout: 15)
        XCTAssertTrue(todayTabExists)
        for screen in screenFixtures.screens {
            let tab = app.tabBars.buttons[screen.tab]
            let tabExists = tab.exists
            XCTAssertTrue(tabExists, "Missing accessible tab in large-text/dark mode: \(screen.tab)")
            // The app launches on Today. The fresh conversation should keep its
            // heading visible without a no-op tab tap or a recovery swipe.
            if screen.id != "today" { tab.tap() }
            let markerExists = app.staticTexts[screen.marker].waitForExistence(timeout: 10)
            XCTAssertTrue(markerExists, "Missing marker in large-text/dark mode for \(screen.id): \(screen.marker)")
            keepScreenshot(named: "gate-09-\(screen.id)-dark-large-text")
        }
    }
}
