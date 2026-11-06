import Foundation
import XCTest
@testable import DensosoDomain

final class DailyCheckInTests: XCTestCase {
    func testDailyCheckInRepresentsOnlyUserReportedFields() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let checkIn = DailyCheckIn(
            occurredAt: date,
            energy: .low,
            stress: .elevated,
            subjectiveSleep: .poor,
            note: "昨晚醒了几次"
        )

        let data = try JSONEncoder().encode(checkIn)
        let decoded = try JSONDecoder().decode(DailyCheckIn.self, from: data)
        XCTAssertEqual(decoded, checkIn)

        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["occurredAt", "energy", "stress", "subjectiveSleep", "note"])
        XCTAssertEqual(fields["energy"] as? String, "low")
        XCTAssertEqual(fields["stress"] as? String, "elevated")
        XCTAssertEqual(fields["subjectiveSleep"] as? String, "poor")
        XCTAssertNil(fields["healthKitSamples"])
        XCTAssertNil(fields["heartRate"])
    }

    func testDailyCheckInNoteIsOptional() throws {
        let checkIn = DailyCheckIn(
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            energy: .typical,
            stress: .low,
            subjectiveSleep: .fair
        )

        XCTAssertNil(checkIn.note)
        let decoded = try JSONDecoder().decode(DailyCheckIn.self, from: JSONEncoder().encode(checkIn))
        XCTAssertEqual(decoded, checkIn)
    }
}
