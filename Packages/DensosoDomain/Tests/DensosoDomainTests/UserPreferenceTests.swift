import Foundation
import XCTest
@testable import DensosoDomain

final class UserPreferenceTests: XCTestCase {
    func testPreferenceUsesOnlySupportedCategoriesAndExplicitUserSource() throws {
        XCTAssertEqual(
            UserPreferenceCategory.allCases,
            [.food, .exercise, .communication]
        )
        XCTAssertEqual(UserPreferenceSource.allCases, [.userReported])

        for category in UserPreferenceCategory.allCases {
            let preference = UserPreference(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                category: category,
                statement: "用户明确表达的偏好",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )

            XCTAssertEqual(preference.source, .userReported)
            let decoded = try JSONDecoder().decode(
                UserPreference.self,
                from: JSONEncoder().encode(preference)
            )
            XCTAssertEqual(decoded, preference)
        }
    }

    func testPreferenceContainsNoInferredOrHealthKitFields() throws {
        let preference = UserPreference(
            category: .food,
            statement: "不吃香菜"
        )

        let data = try JSONEncoder().encode(preference)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set(fields.keys),
            ["id", "category", "statement", "createdAt", "source"]
        )
        XCTAssertEqual(fields["source"] as? String, "userReported")
        XCTAssertNil(fields["healthKitSamples"])
        XCTAssertNil(fields["inferredFromBehavior"])
        XCTAssertNil(fields["cloudContext"])
    }
}
