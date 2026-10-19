import Foundation
import XCTest
@testable import Densoso

final class InMemorySpeechAudioStoreTests: XCTestCase {
    func testCreatesBoundedWAVInMemoryAndDiscardClearsIt() async throws {
        let store = InMemorySpeechAudioStore()
        try await store.begin(requestID: UUID())
        try await store.append(SpeechAudioFrame(
            pcm16LittleEndian: Data(repeating: 0x01, count: 3_200),
            frameCount: 1_600,
            presentationTimeSeconds: 0
        ))

        let finalized = try await store.finalize()
        let audio = try XCTUnwrap(finalized)
        XCTAssertEqual(audio.mimeType, "audio/wav")
        XCTAssertEqual(audio.sampleRate, 16_000)
        XCTAssertEqual(audio.channelCount, 1)
        XCTAssertEqual(audio.durationSeconds, 0.1, accuracy: 0.0001)
        XCTAssertEqual(String(data: audio.data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: audio.data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
        XCTAssertEqual(audio.data.count, 44 + 3_200)

        await store.discard()
        let discarded = try await store.finalize()
        XCTAssertNil(discarded)
    }

    func testSixtySecondMemoryCeilingFailsClosedWithoutPartialAudio() async throws {
        let store = InMemorySpeechAudioStore()
        let overLimit = SpeechAudioFrame(
            pcm16LittleEndian: Data(repeating: 0, count: 16_000 * 60 * 2 + 1),
            frameCount: 16_000 * 60,
            presentationTimeSeconds: 0
        )
        try await store.begin(requestID: UUID())

        do {
            try await store.append(overLimit)
            XCTFail("Expected bounded in-memory buffer rejection")
        } catch {
            XCTAssertEqual(error as? SpeechAudioMemoryStoreError, .durationExceeded)
        }
        let rejectedAudio = try await store.finalize()
        XCTAssertNil(rejectedAudio)
    }
}
