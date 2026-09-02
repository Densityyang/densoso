import XCTest
@testable import Densoso

final class SpeechDiagnosticsRedactionTests: XCTestCase {
    func testExportContainsOnlyAllowlistedMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gate04-diagnostics-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SpeechDiagnosticsStore(exportDirectory: directory)
        let secret = "sk-secret-key"
        let transcript = "今天体重62.5kg午饭吃了红烧肉"
        await store.record(
            SpeechDiagnosticEvent(
                requestID: UUID(),
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                stage: .recording,
                backend: .speechAnalyzer,
                failureKind: .droppedAudioFrames,
                category: "record",
                mode: "measurement",
                options: [],
                inputPortType: secret,
                sampleRate: 48_000,
                channelCount: 1,
                engineRunning: true,
                osStatus: -50,
                errorDomain: transcript,
                errorCode: -50
            )
        )

        let url = try await store.export()
        let exported = try String(contentsOf: url, encoding: .utf8)
        let protection = try url.resourceValues(forKeys: [.fileProtectionKey]).fileProtection

        XCTAssertFalse(exported.contains(secret))
        XCTAssertFalse(exported.contains(transcript))
        XCTAssertFalse(exported.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(exported.localizedCaseInsensitiveContains("transcript"))
        XCTAssertFalse(exported.localizedCaseInsensitiveContains("audioData"))
        XCTAssertTrue(exported.contains("-50"))
        XCTAssertTrue(exported.contains("redacted"))
        XCTAssertTrue(
            protection == .complete || protection == .completeUntilFirstUserAuthentication,
            "Simulator must retain a protected file class"
        )
    }
}
