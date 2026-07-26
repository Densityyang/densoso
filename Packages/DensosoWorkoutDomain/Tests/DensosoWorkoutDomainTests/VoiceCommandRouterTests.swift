import XCTest
@testable import DensosoWorkoutDomain

final class VoiceCommandRouterTests: XCTestCase {
    private let router = VoiceCommandRouter()

    func testEquivalentSourcesProduceSameMealDraftRoute() {
        let text = "午餐吃了鸡胸肉和米饭"
        let routes = [
            VoiceCommandEnvelope(text: text, locale: Locale(identifier: "zh-CN"), source: .iPhoneLegacySpeech),
            VoiceCommandEnvelope(text: text, locale: Locale(identifier: "zh-CN"), source: .watchDictation),
            VoiceCommandEnvelope(text: text, locale: Locale(identifier: "zh-CN"), source: .manualText),
        ].map(router.route)
        XCTAssertEqual(routes, [.mealDraft, .mealDraft, .mealDraft])
    }

    func testStrengthAndWorkoutIntentStaySeparate() {
        XCTAssertEqual(router.route(.init(text: "明天做 5×5 深蹲", source: .iPhoneSpeechAnalyzer)), .workoutPlanDraft)
        XCTAssertEqual(router.route(.init(text: "深蹲补一组 5 次 80 公斤", source: .watchDictation)), .strengthSetDraft)
    }

    func testEmptyTranscriptIsUnclassified() {
        XCTAssertEqual(router.route(.init(text: "   ", source: .manualText)), .unclassified)
    }
}
