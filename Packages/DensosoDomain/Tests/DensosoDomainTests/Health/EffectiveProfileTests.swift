import XCTest
@testable import DensosoDomain

final class EffectiveProfileTests: XCTestCase {
    func testResolvesProfileRevisionAtHistoricalDate() throws {
        let first = revision(
            effectiveFrom: date(2024, 1, 1),
            dateOfBirth: date(1990, 6, 15),
            heightCm: 170
        )
        let second = revision(
            effectiveFrom: date(2025, 1, 1),
            dateOfBirth: date(1990, 6, 15),
            heightCm: 172
        )
        let resolver = EffectiveProfileResolver(profileKey: "primary", revisions: [second, first])

        let historical = try XCTUnwrap(resolver.profile(at: date(2024, 7, 1)))
        let current = try XCTUnwrap(resolver.profile(at: date(2025, 7, 1)))

        XCTAssertEqual(historical.sourceRevisionID, first.id)
        XCTAssertEqual(historical.heightCm, 170)
        XCTAssertEqual(historical.age(in: gregorianUTC), 34)
        XCTAssertEqual(current.sourceRevisionID, second.id)
        XCTAssertEqual(current.heightCm, 172)
        XCTAssertEqual(current.age(in: gregorianUTC), 35)
    }

    func testDoesNotUseOtherProfileOrFutureRevision() {
        let unrelated = revision(
            profileKey: "other",
            effectiveFrom: date(2020, 1, 1),
            dateOfBirth: date(1990, 1, 1)
        )
        let future = revision(
            effectiveFrom: date(2027, 1, 1),
            dateOfBirth: date(1990, 1, 1)
        )
        let resolver = EffectiveProfileResolver(profileKey: "primary", revisions: [unrelated, future])

        XCTAssertNil(resolver.profile(at: date(2026, 12, 31)))
    }

    func testLatestUnknownBirthDateDoesNotFallBackToOlderRevision() {
        let known = revision(
            effectiveFrom: date(2024, 1, 1),
            dateOfBirth: date(1990, 1, 1)
        )
        let unknown = revision(
            effectiveFrom: date(2025, 1, 1),
            dateOfBirth: nil
        )
        let resolver = EffectiveProfileResolver(profileKey: "primary", revisions: [known, unknown])

        XCTAssertNil(resolver.profile(at: date(2025, 6, 1)))
    }

    private var gregorianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func revision(
        id: UUID = UUID(),
        profileKey: String = "primary",
        effectiveFrom: Date,
        dateOfBirth: Date?,
        heightCm: Double = 170
    ) -> ProfileRevision {
        ProfileRevision(
            id: id,
            profileKey: profileKey,
            effectiveFrom: effectiveFrom,
            dateOfBirth: dateOfBirth,
            biologicalSex: .female,
            heightCm: heightCm,
            weightKg: 60,
            activityLevel: .moderate,
            source: .userEdited,
            createdAt: effectiveFrom
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        gregorianUTC.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
