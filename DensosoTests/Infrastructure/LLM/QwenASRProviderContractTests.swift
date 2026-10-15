import XCTest
@testable import Densoso

@MainActor
final class QwenASRProviderContractTests: XCTestCase {
    func testOpenAICompatibleAudioRequestAndResponseContract() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [
                .response(
                    status: 200,
                    data: try Gate03FixtureLoader.data("qwen3-asr-flash-response")
                )
            ]
        )
        let clock = TestProviderRetryClock()
        let provider = QwenASRProvider(
            endpoint: URL(string: "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions")!,
            credentialSource: TestCredentialSource(values: [.qwen: "secret-qwen-key"]),
            transport: transport,
            clock: clock,
            jitter: { _ in 0 }
        )
        let audio = SanitizedAudio(
            data: Data("RIFF-gate04".utf8),
            mimeType: "audio/wav",
            durationSeconds: 1,
            sampleRate: 16_000,
            channelCount: 1
        )

        let transcript = try await provider.transcribe(
            audio: audio,
            locale: Locale(identifier: "zh-CN")
        )

        XCTAssertEqual(transcript.text, "午饭吃了米饭二百克")
        XCTAssertEqual(transcript.model, "qwen3-asr-flash")
        XCTAssertEqual(transcript.billedAudioSeconds, 1)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-qwen-key")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "qwen3-asr-flash")
        XCTAssertEqual(object["stream"] as? Bool, false)
        XCTAssertNil(object["tools"])
        let options = try XCTUnwrap(object["asr_options"] as? [String: Any])
        XCTAssertEqual(options["language"] as? String, "zh")
        XCTAssertEqual(options["enable_itn"] as? Bool, false)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "input_audio")
        let inputAudio = try XCTUnwrap(content.first?["input_audio"] as? [String: Any])
        XCTAssertTrue((inputAudio["data"] as? String)?.hasPrefix("data:audio/wav;base64,") == true)
    }

    func testMalformedASRResponseBecomesTypedError() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [
                .response(
                    status: 200,
                    data: try Gate03FixtureLoader.data("malformed-asr")
                )
            ]
        )
        let provider = QwenASRProvider(
            endpoint: URL(string: "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions")!,
            credentialSource: TestCredentialSource(values: [.qwen: "fixture"]),
            transport: transport,
            jitter: { _ in 0 }
        )

        do {
            _ = try await provider.transcribe(audio: fixtureAudio(), locale: Locale(identifier: "zh-CN"))
            XCTFail("Expected malformed response")
        } catch {
            XCTAssertEqual(error as? ProviderError, .malformedResponse)
        }
    }

    func testOversizedEncodedRequestFailsBeforeNetwork() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [.response(status: 200, data: Data("{}".utf8))]
        )
        let provider = QwenASRProvider(
            endpoint: URL(string: "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions")!,
            credentialSource: TestCredentialSource(values: [.qwen: "fixture"]),
            transport: transport,
            jitter: { _ in 0 }
        )
        let audio = SanitizedAudio(
            data: Data(repeating: 0, count: 7_600_000),
            mimeType: "audio/wav",
            durationSeconds: 60,
            sampleRate: 16_000,
            channelCount: 1
        )

        do {
            _ = try await provider.transcribe(audio: audio, locale: Locale(identifier: "zh-CN"))
            XCTFail("Expected local size rejection")
        } catch {
            XCTAssertEqual(
                error as? ProviderError,
                .requestTooLarge(limitBytes: QwenASRProvider.maximumRequestBytes)
            )
        }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    private func fixtureAudio() -> SanitizedAudio {
        SanitizedAudio(
            data: Data("RIFF-gate04".utf8),
            mimeType: "audio/wav",
            durationSeconds: 1,
            sampleRate: 16_000,
            channelCount: 1
        )
    }
}
