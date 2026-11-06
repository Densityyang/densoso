import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class UserProfileSingletonPolicyTests: XCTestCase {
    func testDuplicateProfilesResolveToOneDeterministicPrimary() throws {
        let container = try ModelContainer(
            for: UserProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let older = UserProfile(name: "Older", dateOfBirth: Date(timeIntervalSince1970: 700_000_000))
        older.profileNeedsCompletion = false
        older.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let newest = UserProfile(name: "Newest", dateOfBirth: Date(timeIntervalSince1970: 800_000_000))
        newest.profileNeedsCompletion = false
        newest.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(older)
        context.insert(newest)
        try context.save()

        let resolved = try XCTUnwrap(UserProfileSingletonPolicy.normalize(in: context))

        XCTAssertEqual(resolved.name, "Newest")
        XCTAssertEqual(resolved.profileKey, "primary")
        let persistedContext = ModelContext(container)
        let persistedProfiles = try persistedContext.fetch(FetchDescriptor<UserProfile>())
        XCTAssertEqual(persistedProfiles.count, 1)
        XCTAssertEqual(persistedProfiles.first?.name, "Newest")
    }
}
