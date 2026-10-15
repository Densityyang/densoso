import XCTest
@testable import Densoso

final class AppLaunchConfigurationTests: XCTestCase {
    func testDefaultLaunchKeepsProductionServicesEnabled() {
        let configuration = AppLaunchConfiguration.resolve(
            arguments: ["Densoso"],
            environment: [:]
        )

        XCTAssertFalse(configuration.isUITesting)
        XCTAssertFalse(configuration.usesSeededProfile)
    }

    func testSeededProfileRequiresUITestMode() {
        let configuration = AppLaunchConfiguration.resolve(
            arguments: ["Densoso", "-ui-testing-seeded"],
            environment: [:]
        )

        XCTAssertFalse(configuration.isUITesting)
        XCTAssertFalse(configuration.usesSeededProfile)
    }

    func testUITestArgumentsEnableDeterministicSeed() {
        let configuration = AppLaunchConfiguration.resolve(
            arguments: ["Densoso", "-ui-testing", "-ui-testing-seeded"],
            environment: ["DENSOSO_UI_TESTING": "1"]
        )

        XCTAssertTrue(configuration.isUITesting)
        XCTAssertTrue(configuration.usesSeededProfile)
    }
}
