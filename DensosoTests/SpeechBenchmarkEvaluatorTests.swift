import XCTest
@testable import Densoso

final class SpeechBenchmarkEvaluatorTests: XCTestCase {
    private let evaluator = SpeechBenchmarkEvaluator()

    func testChineseTranscriptIgnoresWhitespaceAndPunctuation() {
        let report = evaluator.evaluate([
            SpeechBenchmarkSample(
                id: "meal-rice",
                referenceTranscript: "午饭吃了米饭 200 克。",
                hypothesisTranscript: "午饭吃了米饭200克",
                expectedSlots: ["food": "米饭", "grams": "200"],
                observedSlots: ["food": "米饭", "grams": "200"],
                endToEndLatencyMilliseconds: 180
            )
        ])

        XCTAssertEqual(report.transcriptErrorRate, 0)
        XCTAssertEqual(report.slotAccuracy, 1)
        XCTAssertEqual(report.medianLatencyMilliseconds, 180)
    }

    func testReportAggregatesTranscriptErrorsSlotsAndLatency() {
        let report = evaluator.evaluate([
            SpeechBenchmarkSample(
                id: "meal-noodles",
                referenceTranscript: "牛肉面一碗",
                hypothesisTranscript: "牛肉粉一碗",
                expectedSlots: ["food": "牛肉面", "serving": "一碗"],
                observedSlots: ["food": "牛肉粉", "serving": "一碗"],
                endToEndLatencyMilliseconds: 120
            ),
            SpeechBenchmarkSample(
                id: "workout-squats",
                referenceTranscript: "深蹲三组每组十二次",
                hypothesisTranscript: "深蹲三组每组十二次",
                expectedSlots: ["exercise": "深蹲", "sets": "3", "reps": "12"],
                observedSlots: ["exercise": "深蹲", "sets": "3", "reps": "12"],
                endToEndLatencyMilliseconds: 180
            ),
            SpeechBenchmarkSample(
                id: "workout-deadlift",
                referenceTranscript: "硬拉五组五次六十公斤",
                hypothesisTranscript: "硬拉五组五次六十公斤",
                expectedSlots: ["exercise": "硬拉", "sets": "5", "reps": "5", "weight": "60公斤"],
                observedSlots: ["exercise": "硬拉", "sets": "5", "reps": "5", "weight": "60公斤"],
                endToEndLatencyMilliseconds: 260
            )
        ])

        XCTAssertEqual(report.sampleCount, 3)
        XCTAssertEqual(report.transcriptErrorRate, 1.0 / 24.0, accuracy: 0.0001)
        XCTAssertEqual(report.slotAccuracy, 8.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(report.medianLatencyMilliseconds, 180)
        XCTAssertEqual(report.p95LatencyMilliseconds, 260)
    }

    func testEmptyEvaluationHasNoLatencyAndNoErrors() {
        let report = evaluator.evaluate([])

        XCTAssertEqual(report.sampleCount, 0)
        XCTAssertEqual(report.transcriptErrorRate, 0)
        XCTAssertEqual(report.slotAccuracy, 0)
        XCTAssertNil(report.medianLatencyMilliseconds)
        XCTAssertNil(report.p95LatencyMilliseconds)
    }
}
