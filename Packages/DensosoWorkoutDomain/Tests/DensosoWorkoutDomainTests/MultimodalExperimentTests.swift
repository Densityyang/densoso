import XCTest
@testable import DensosoWorkoutDomain

final class MultimodalExperimentTests: XCTestCase {
    func testFlagsAreOffByDefaultAndCannotBypassPlatformGate() {
        let disabled = LocalMultimodalExperimentFlags()
        XCTAssertFalse(disabled.permits(.foundationModelVision, osMajorVersion: 27))

        let enabled = LocalMultimodalExperimentFlags(enabled: [.foundationModelVision])
        XCTAssertFalse(enabled.permits(.foundationModelVision, osMajorVersion: 26))
        XCTAssertTrue(enabled.permits(.foundationModelVision, osMajorVersion: 27))
    }

    func testPromotionRequiresPrivacyAndEveryQualityGate() {
        let gate = MultimodalExperimentPromotionGate(
            minimumTopKAccuracy: 0.9,
            minimumIntervalCoverage: 0.9,
            maximumP95LatencyMilliseconds: 800,
            maximumPeakMemoryMegabytes: 300,
            maximumEnergyMilliwattHours: 5
        )
        let passing = MultimodalExperimentMetrics(
            identityTopKAccuracy: 0.91,
            portionIntervalCoverage: 0.92,
            p95LatencyMilliseconds: 700,
            peakMemoryMegabytes: 240,
            energyMilliwattHours: 4,
            rawPhotoRetentionCount: 0
        )
        let retainsPhoto = MultimodalExperimentMetrics(
            identityTopKAccuracy: 0.99,
            portionIntervalCoverage: 0.99,
            p95LatencyMilliseconds: 100,
            peakMemoryMegabytes: 10,
            energyMilliwattHours: 1,
            rawPhotoRetentionCount: 1
        )

        XCTAssertTrue(gate.permitsPromotion(of: passing))
        XCTAssertFalse(gate.permitsPromotion(of: retainsPhoto))
    }

    func testMetadataRecordsReproducibilityFieldsWithoutPayload() throws {
        let metadata = MultimodalEvaluationMetadata(
            experiment: .foundationModelVision,
            promptVersion: "food-photo-zh-CN-v1",
            outputSchemaVersion: "meal-evidence-v1",
            modelIdentifier: "system-model",
            deviceModel: "iPhone17,1",
            osVersion: "27.0"
        )
        let encoded = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(MultimodalEvaluationMetadata.self, from: encoded)

        XCTAssertEqual(decoded, metadata)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("image"))
    }
}
