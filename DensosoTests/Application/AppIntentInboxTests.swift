import Foundation
import XCTest
@testable import Densoso

final class AppIntentInboxTests: XCTestCase {
    func testSystemDestinationsRoundTripAndAreConsumedOnce() throws {
        let suiteName = "AppIntentInboxTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            DensosoAppIntentDestination.allCases,
            [.todayStatus, .todayGuidance, .openToday, .startRecording]
        )
        for destination in DensosoAppIntentDestination.allCases {
            AppIntentInbox.store(destination: destination, defaults: defaults)
            XCTAssertEqual(AppIntentInbox.consumeDestination(defaults: defaults), destination)
            XCTAssertNil(AppIntentInbox.consumeDestination(defaults: defaults))
        }
    }
}
