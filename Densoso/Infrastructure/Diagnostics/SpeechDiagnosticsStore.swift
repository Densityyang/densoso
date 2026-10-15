import Foundation

actor SpeechDiagnosticsStore: SpeechDiagnosticsRecording {
    private struct ExportDocument: Codable {
        let formatVersion: Int
        let exportedAt: Date
        let events: [SpeechDiagnosticEvent]
    }

    private let fileManager: FileManager
    private let exportDirectory: URL
    private let maximumRecords: Int
    private var records: [SpeechDiagnosticEvent] = []

    init(
        fileManager: FileManager = .default,
        exportDirectory: URL? = nil,
        maximumRecords: Int = 200
    ) {
        self.fileManager = fileManager
        self.exportDirectory = exportDirectory ?? fileManager.temporaryDirectory
        self.maximumRecords = max(maximumRecords, 1)
    }

    func record(_ event: SpeechDiagnosticEvent) {
        records.append(Self.sanitized(event))
        if records.count > maximumRecords {
            records.removeFirst(records.count - maximumRecords)
        }
    }

    func export() throws -> URL {
        let document = ExportDocument(
            formatVersion: 1,
            exportedAt: Date(),
            events: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let url = exportDirectory.appendingPathComponent(
            "densoso_speech_diagnostics_\(UUID().uuidString.lowercased()).json"
        )
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        return url
    }

    private static func sanitized(_ event: SpeechDiagnosticEvent) -> SpeechDiagnosticEvent {
        SpeechDiagnosticEvent(
            requestID: event.requestID,
            timestamp: event.timestamp,
            stage: event.stage,
            backend: event.backend,
            failureKind: event.failureKind,
            category: allowlisted(event.category, values: ["record"]),
            mode: allowlisted(event.mode, values: ["measurement"]),
            options: event.options.map {
                allowlisted($0, values: ["notifyOthersOnDeactivation"])
            },
            inputPortType: event.inputPortType.map {
                allowlisted(
                    $0,
                    values: [
                        "MicrophoneBuiltIn", "MicrophoneWired", "BluetoothHFP",
                        "USBAudio", "CarAudio", "LineIn", "builtInMic",
                        "headsetMic", "bluetoothHFP", "usbAudio", "carAudio", "lineIn",
                    ]
                )
            },
            sampleRate: event.sampleRate,
            channelCount: event.channelCount,
            engineRunning: event.engineRunning,
            osStatus: event.osStatus,
            errorDomain: event.errorDomain.map {
                allowlisted(
                    $0,
                    values: [
                        NSOSStatusErrorDomain, NSCocoaErrorDomain, NSURLErrorDomain,
                        "kAFAssistantErrorDomain", "com.apple.coreaudio.avfaudio",
                    ]
                )
            },
            errorCode: event.errorCode
        )
    }

    private static func allowlisted(_ value: String, values: Set<String>) -> String {
        values.contains(value) ? value : "redacted"
    }
}
