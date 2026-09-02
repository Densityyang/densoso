import Foundation
import XCTest

struct Gate02Seed: Decodable {
    let version: String
    let mealID: UUID
    let workoutID: UUID
    let recordedAt: TimeInterval
    let mealCalories: Int
    let mealAlgorithmVersion: String
    let workoutCalories: Int
    let cursorBytes: [UInt8]?
}

struct Gate02ExpectedMigration: Decodable {
    let legacyEvidenceGrade: String
    let v1WorkoutOrigin: String
    let v1WorkoutDataQuality: String
    let v1WorkoutRouteStatus: String
    let outboxAttemptCount: Int
    let outboxState: String
}

enum Gate02FixtureLoader {
    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let bundle = Bundle(for: Gate02FixtureBundleToken.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

private final class Gate02FixtureBundleToken {}
