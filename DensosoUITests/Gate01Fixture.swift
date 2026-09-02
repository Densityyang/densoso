import Foundation
import XCTest

struct Gate01LaunchFixture: Decodable {
    let arguments: [String]
    let environment: [String: String]
}

struct Gate01ScreenFixture: Decodable {
    let id: String
    let tab: String
    let marker: String
}

struct Gate01ScreenFixtures: Decodable {
    let screens: [Gate01ScreenFixture]
}

enum Gate01FixtureLoader {
    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let bundle = Bundle(for: Gate01FixtureBundleToken.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "json"),
            "Missing UI test fixture \(name).json"
        )
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

private final class Gate01FixtureBundleToken {}

extension XCTestCase {
    func keepScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
