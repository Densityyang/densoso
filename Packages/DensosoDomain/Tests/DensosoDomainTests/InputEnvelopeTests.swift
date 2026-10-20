import DensosoDomain
import XCTest

final class InputEnvelopeTests: XCTestCase {
    func testVoiceTextImageAndCombinedEnvelopeRoundTripOnlySafeMetadata() throws {
        let image = InputEnvelope.ImageAttachment(mediaType: .jpeg)
        let envelope = InputEnvelope(
            source: .voiceAndImage,
            text: "这是我的午饭，大概吃了一半。",
            imageAttachments: [image],
            locale: "zh_CN"
        )

        XCTAssertTrue(envelope.isWellFormed)
        let encoded = try JSONEncoder().encode(envelope)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(encodedText.contains("voiceAndImage"))
        XCTAssertTrue(encodedText.contains("zh_CN"))
        XCTAssertFalse(encodedText.contains("base64Data"))
        XCTAssertFalse(encodedText.contains("audio"))
        XCTAssertEqual(try JSONDecoder().decode(InputEnvelope.self, from: encoded), envelope)

        let voice = InputEnvelope(source: .voice, text: "我刚刚吃过午饭。", locale: "zh_CN")
        let text = InputEnvelope(source: .text, text: "我想查一下今天状态。", locale: "zh_CN")
        let imageOnly = InputEnvelope(source: .image, text: nil, imageAttachments: [image], locale: "zh_CN")
        let textAndImage = InputEnvelope(
            source: .textAndImage,
            text: "请看看这张照片。",
            imageAttachments: [image],
            locale: "zh_CN"
        )
        XCTAssertTrue(voice.isWellFormed)
        XCTAssertTrue(text.isWellFormed)
        XCTAssertTrue(imageOnly.isWellFormed)
        XCTAssertTrue(textAndImage.isWellFormed)
    }

    func testEnvelopeRejectsSourceAndPayloadMismatches() {
        let image = InputEnvelope.ImageAttachment(mediaType: .jpeg)

        XCTAssertFalse(InputEnvelope(source: .text, text: "extra image", imageAttachments: [image]).isWellFormed)
        XCTAssertFalse(InputEnvelope(source: .voiceAndImage, text: "speech only").isWellFormed)
        XCTAssertFalse(InputEnvelope(source: .voice, text: nil).isWellFormed)
        XCTAssertFalse(InputEnvelope(
            source: .textAndImage,
            text: "duplicate metadata",
            imageAttachments: [image, image]
        ).isWellFormed)
    }

    func testVoiceCommandOriginMapsToCoarseEnvelopeSourceWithoutLosingLocale() {
        let image = InputEnvelope.ImageAttachment(mediaType: .jpeg)
        let voice = VoiceCommandEnvelope(
            text: "午饭照片",
            locale: Locale(identifier: "zh-CN"),
            source: .iPhoneSpeechAnalyzer
        )
        let typed = VoiceCommandEnvelope(
            text: "请看照片",
            locale: Locale(identifier: "zh-CN"),
            source: .manualText
        )

        XCTAssertEqual(voice.asInputEnvelope().source, .voice)
        XCTAssertEqual(voice.asInputEnvelope(imageAttachments: [image]).source, .voiceAndImage)
        XCTAssertEqual(typed.asInputEnvelope(imageAttachments: [image]).source, .textAndImage)
        XCTAssertEqual(voice.asInputEnvelope().locale, voice.localeIdentifier)
        XCTAssertEqual(voice.asInputEnvelope().voiceSource, .iPhoneSpeechAnalyzer)
        XCTAssertEqual(voice.asInputEnvelope(imageAttachments: [image]).voiceSource, .iPhoneSpeechAnalyzer)
        XCTAssertNil(typed.asInputEnvelope(imageAttachments: [image]).voiceSource)
    }

    func testImageAttachmentListIsBounded() {
        let images = (0..<8).map { _ in InputEnvelope.ImageAttachment(mediaType: .jpeg) }
        let envelope = InputEnvelope(
            source: .textAndImage,
            text: "看一下",
            imageAttachments: images
        )

        XCTAssertEqual(envelope.imageAttachments.count, 4)
    }
}
