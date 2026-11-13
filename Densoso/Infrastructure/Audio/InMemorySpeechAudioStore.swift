import Foundation

/// Holds the optional Qwen fallback buffer only in RAM. The production capture
/// policy caps recording at sixty seconds, so this store also enforces the
/// corresponding PCM byte ceiling independently.
actor InMemorySpeechAudioStore: SpeechAudioStoring {
    private static let maximumPCMBytes = Int(SpeechAudioFrame.canonicalSampleRate * 60 * 2)

    private var pcmData = Data()

    func cleanupStaleFiles() {
        discardBuffer()
    }

    func begin(requestID: UUID) throws {
        discardBuffer()
    }

    func append(_ frame: SpeechAudioFrame) throws {
        guard frame.pcm16LittleEndian.count <= Self.maximumPCMBytes - pcmData.count else {
            throw SpeechAudioMemoryStoreError.durationExceeded
        }
        pcmData.append(frame.pcm16LittleEndian)
    }

    func finalize() throws -> SanitizedAudio? {
        guard !pcmData.isEmpty else { return nil }
        let duration = Double(pcmData.count / MemoryLayout<Int16>.size)
            / SpeechAudioFrame.canonicalSampleRate
        var wavData = Self.wavHeader(pcmByteCount: pcmData.count)
        wavData.append(pcmData)
        discardBuffer()
        return SanitizedAudio(
            data: wavData,
            mimeType: "audio/wav",
            durationSeconds: duration,
            sampleRate: SpeechAudioFrame.canonicalSampleRate,
            channelCount: SpeechAudioFrame.canonicalChannelCount
        )
    }

    func discard() {
        discardBuffer()
    }

    private func discardBuffer() {
        pcmData.removeAll(keepingCapacity: false)
    }

    private static func wavHeader(pcmByteCount: Int) -> Data {
        let boundedBytes = UInt32(clamping: max(pcmByteCount, 0))
        let sampleRate = UInt32(SpeechAudioFrame.canonicalSampleRate)
        let channelCount = UInt16(SpeechAudioFrame.canonicalChannelCount)
        let bitsPerSample: UInt16 = 16
        let blockAlign = channelCount * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) &+ boundedBytes)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(boundedBytes)
        return data
    }
}

enum SpeechAudioMemoryStoreError: Error, Equatable, Sendable {
    case durationExceeded
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
