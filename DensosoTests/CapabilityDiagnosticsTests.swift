import XCTest
@testable import Densoso

final class CapabilityDiagnosticsTests: XCTestCase {
    func testPermissionLabelsDistinguishPrivacyBoundaryFromDenial() {
        XCTAssertEqual(CapabilityPermissionState.authorized.displayName, "已允许")
        XCTAssertEqual(CapabilityPermissionState.denied.displayName, "已拒绝")
        XCTAssertEqual(CapabilityPermissionState.privacyProtected.displayName, "系统保护")
        XCTAssertNotEqual(
            CapabilityPermissionState.privacyProtected.displayName,
            CapabilityPermissionState.denied.displayName
        )
    }

    func testDefaultSnapshotDoesNotClaimReadAuthorization() {
        let snapshot = CapabilityDiagnosticsSnapshot()
        XCTAssertEqual(snapshot.healthReadPermission, .privacyProtected)
        XCTAssertEqual(snapshot.dietaryEnergyWritePermission, .unknown)
        XCTAssertNil(snapshot.lastHealthImportAt)
    }
}
