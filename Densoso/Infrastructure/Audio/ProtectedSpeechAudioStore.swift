import Foundation

actor ProtectedSpeechAudioStore: SpeechAudioStoring {
    static let directoryName = "densoso-speech-audio"

    private let fileManager: FileManager
    private let directoryURL: URL
    private var activeURL: URL?
    private var activeHandle: FileHandle?
    private var pcmByteCount = 0
    private var frameCount = 0

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL
            ?? fileManager.temporaryDirectory.appendingPathComponent(
                Self.directoryName,
                isDirectory: true
            )
    }

    func cleanupStaleFiles() {
        discardCurrent()
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.pathExtension.lowercased() == "wav" {
            try? fileManager.removeItem(at: file)
        }
    }

    func begin(requestID: UUID) throws {
        discardCurrent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try applyCompleteProtection(to: directoryURL)

        let url = directoryURL.appendingPathComponent(
            "speech-\(requestID.uuidString.lowercased()).wav"
        )
        activeURL = url
        do {
            guard fileManager.createFile(
                atPath: url.path,
                contents: Self.wavHeader(pcmByteCount: 0)
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try applyCompleteProtection(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            activeHandle = handle
        } catch {
            discardCurrent()
            throw error
        }
        pcmByteCount = 0
        frameCount = 0
    }

    func append(_ frame: SpeechAudioFrame) throws {
        guard let activeHandle else { return }
        try activeHandle.write(contentsOf: frame.pcm16LittleEndian)
        pcmByteCount += frame.pcm16LittleEndian.count
        frameCount += max(frame.frameCount, 0)
    }

    func finalize() throws -> SanitizedAudio? {
        guard let url = activeURL, pcmByteCount > 0 else {
            discardCurrent()
            return nil
        }
        try activeHandle?.synchronize()
        try activeHandle?.close()
        activeHandle = nil

        let updateHandle = try FileHandle(forUpdating: url)
        try updateHandle.seek(toOffset: 0)
        try updateHandle.write(contentsOf: Self.wavHeader(pcmByteCount: pcmByteCount))
        try updateHandle.synchronize()
        try updateHandle.close()
        try applyCompleteProtection(to: url)

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SanitizedAudio(
            data: data,
            mimeType: "audio/wav",
            durationSeconds: Double(frameCount) / SpeechAudioFrame.canonicalSampleRate,
            sampleRate: SpeechAudioFrame.canonicalSampleRate,
            channelCount: SpeechAudioFrame.canonicalChannelCount
        )
    }

    func discard() {
        discardCurrent()
    }

    private func discardCurrent() {
        try? activeHandle?.close()
        activeHandle = nil
        if let activeURL { try? fileManager.removeItem(at: activeURL) }
        activeURL = nil
        pcmByteCount = 0
        frameCount = 0
    }

    private func applyCompleteProtection(to url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
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

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
