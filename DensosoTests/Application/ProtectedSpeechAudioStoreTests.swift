import XCTest
@testable import Densoso

final class ProtectedSpeechAudioStoreTests: XCTestCase {
    func testWritesCanonicalWAVAndDeletesItAfterDiscard() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gate04-audio-store-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProtectedSpeechAudioStore(directoryURL: directory)

        try await store.begin(requestID: UUID())
        try await store.append(Gate04Fixtures.frame(frameCount: 1_600))
        let finalized = try await store.finalize()
        let audio = try XCTUnwrap(finalized)

        XCTAssertEqual(audio.sampleRate, 16_000)
        XCTAssertEqual(audio.channelCount, 1)
        XCTAssertEqual(audio.durationSeconds, 0.1, accuracy: 0.0001)
        XCTAssertEqual(String(data: audio.data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: audio.data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
        let filesBeforeDiscard = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileProtectionKey]
        )
        let wav = try XCTUnwrap(filesBeforeDiscard.first { $0.pathExtension == "wav" })
        let protection = try wav.resourceValues(forKeys: [.fileProtectionKey]).fileProtection
        XCTAssertEqual(protection, .complete)

        await store.discard()
        let filesAfterDiscard = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(filesAfterDiscard.contains { $0.pathExtension == "wav" })
    }

    func testColdLaunchCleanupRemovesOnlyOwnedWAVFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gate04-audio-cleanup-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staleWAV = directory.appendingPathComponent("speech-stale.wav")
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data("RIFF".utf8).write(to: staleWAV)
        try Data("keep".utf8).write(to: unrelated)
        let store = ProtectedSpeechAudioStore(directoryURL: directory)

        await store.cleanupStaleFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleWAV.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testBeginFailureLeavesNoCandidateWAV() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gate04-audio-begin-failure-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let blockedDirectory = parent.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blockedDirectory)
        let store = ProtectedSpeechAudioStore(directoryURL: blockedDirectory)

        do {
            try await store.begin(requestID: UUID())
            XCTFail("Expected begin failure")
        } catch {
            // Expected: the configured directory is an ordinary file.
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(children.contains { $0.pathExtension == "wav" })
    }
}
