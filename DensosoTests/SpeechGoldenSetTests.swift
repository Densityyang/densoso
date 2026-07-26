import XCTest
@testable import Densoso

final class SpeechGoldenSetTests: XCTestCase {
    private let goldenSet = SpeechGoldenSet.zhCNV1

    func testV1ContainsThreeHundredChineseMealAndWorkoutCases() {
        XCTAssertEqual(goldenSet.cases.count, 300)
        XCTAssertEqual(goldenSet.cases.filter { $0.domain == .meal }.count, 150)
        XCTAssertEqual(goldenSet.cases.filter { $0.domain == .workout }.count, 150)
        XCTAssertEqual(Set(goldenSet.cases.map(\.id)).count, 300)
    }

    func testV1CoversBrandsUnitsChineseNumbersAndSafeDraftLanguage() {
        let transcripts = goldenSet.cases.map(\.referenceTranscript)

        XCTAssertTrue(transcripts.contains { $0.contains("康师傅") })
        XCTAssertTrue(transcripts.contains { $0.contains("公斤") })
        XCTAssertTrue(transcripts.contains { $0.contains("毫升") })
        XCTAssertTrue(transcripts.contains { $0.contains("二百") })
        XCTAssertTrue(transcripts.contains { $0.contains("不保存") })
    }

    func testEveryCaseHasNonEmptyTranscriptAndExpectedSlots() {
        for sample in goldenSet.cases {
            XCTAssertFalse(sample.referenceTranscript.isEmpty, sample.id)
            XCTAssertFalse(sample.expectedSlots.isEmpty, sample.id)
            XCTAssertFalse(sample.expectedSlots.values.contains(where: { $0.isEmpty }), sample.id)
        }
    }
}
