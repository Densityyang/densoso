import AVFoundation
import Foundation

enum AudioCapturePlatformError: Error, LocalizedError, Equatable {
    case invalidInputFormat
    case converterUnavailable
    case tapAlreadyInstalled

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat: "The active microphone has no usable audio format."
        case .converterUnavailable: "The microphone format cannot be converted to 16 kHz mono PCM."
        case .tapAlreadyInstalled: "An audio input tap is already installed."
        }
    }
}

@MainActor
final class AVAudioSessionController: AudioSessionControlling {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func configureForMeasurement() throws {
        try session.setCategory(.record, mode: .measurement, options: [])
    }

    func activate() throws -> SpeechAudioRouteSnapshot {
        try session.setActive(true, options: [])
        return routeSnapshot()
    }

    func deactivate() throws {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func eventStream() -> AsyncStream<SpeechAudioSessionEvent> {
        AsyncStream { continuation in
            let center = NotificationCenter.default
            let tokens = NotificationObserverTokens(center: center)
            tokens.append(center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                let rawReason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.intValue ?? -1
                Task { @MainActor in
                    guard let self else { return }
                    continuation.yield(.routeChanged(reason: rawReason, route: self.routeSnapshot()))
                }
            })
            tokens.append(center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { notification in
                let rawType = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                let type = rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                continuation.yield(type == .began ? .interruptionBegan : .interruptionEnded)
            })
            tokens.append(center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: session,
                queue: .main
            ) { _ in
                continuation.yield(.mediaServicesReset)
            })
            continuation.onTermination = { @Sendable _ in
                tokens.removeAll()
            }
        }
    }

    private func routeSnapshot() -> SpeechAudioRouteSnapshot {
        SpeechAudioRouteSnapshot(
            inputPortType: session.currentRoute.inputs.first?.portType.rawValue,
            sampleRate: session.sampleRate,
            channelCount: session.inputNumberOfChannels
        )
    }
}

private final class NotificationObserverTokens: @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    func append(_ token: NSObjectProtocol) {
        lock.withLock { tokens.append(token) }
    }

    func removeAll() {
        let snapshot = lock.withLock { () -> [NSObjectProtocol] in
            defer { tokens.removeAll() }
            return tokens
        }
        for token in snapshot { center.removeObserver(token) }
    }
}

@MainActor
final class AVAudioFrameStreamer: AudioFrameStreaming {
    private var engine: AVAudioEngine
    private var converter: SpeechPCM16Converter?
    private var frameContinuation: AsyncStream<SpeechAudioFrame>.Continuation?
    private var rawFrameContinuation: AsyncStream<CapturedSpeechBuffer>.Continuation?
    private var processingTask: Task<Void, Never>?
    private let droppedFrames = LockedCounter()

    private(set) var isTapInstalled = false
    var isRunning: Bool { engine.isRunning }
    var droppedFrameCount: Int { droppedFrames.value }

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    func prepare() throws -> SpeechAudioFormatSnapshot {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCapturePlatformError.invalidInputFormat
        }
        guard let converter = SpeechPCM16Converter(sourceFormat: format) else {
            throw AudioCapturePlatformError.converterUnavailable
        }
        self.converter = converter
        return SpeechAudioFormatSnapshot(
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )
    }

    func installTap() throws -> AsyncStream<SpeechAudioFrame> {
        guard !isTapInstalled else { throw AudioCapturePlatformError.tapAlreadyInstalled }
        guard let converter else { throw AudioCapturePlatformError.converterUnavailable }

        let (stream, continuation) = AsyncStream<SpeechAudioFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        frameContinuation = continuation
        let (rawFrames, rawContinuation) = AsyncStream<CapturedSpeechBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        rawFrameContinuation = rawContinuation
        droppedFrames.reset()
        let droppedFrames = self.droppedFrames
        processingTask = Task.detached {
            [rawFrames, converter, continuation, droppedFrames] in
            for await captured in rawFrames {
                guard !Task.isCancelled else { break }
                guard let frame = converter.convert(
                    captured.buffer,
                    presentationTimeSeconds: captured.presentationTimeSeconds
                ) else {
                    droppedFrames.increment()
                    continue
                }
                if case .dropped = continuation.yield(frame) {
                    droppedFrames.increment()
                }
            }
            continuation.finish()
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, time in
            guard let captured = CapturedSpeechBuffer(copying: buffer, at: time) else {
                droppedFrames.increment()
                return
            }
            if case .dropped = rawContinuation.yield(captured) {
                droppedFrames.increment()
            }
        }
        isTapInstalled = true
        return stream
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    func removeTap() {
        guard isTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        rawFrameContinuation?.finish()
        rawFrameContinuation = nil
        isTapInstalled = false
    }

    func resetAfterMediaServicesReset() {
        stop()
        removeTap()
        processingTask?.cancel()
        processingTask = nil
        frameContinuation?.finish()
        frameContinuation = nil
        converter = nil
        engine = AVAudioEngine()
    }
}

private final class CapturedSpeechBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let presentationTimeSeconds: Double?

    init?(copying source: AVAudioPCMBuffer, at time: AVAudioTime?) {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            var destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData else { return nil }
            let byteCount = min(sourceBuffer.mDataByteSize, destinationBuffer.mDataByteSize)
            memcpy(destinationData, sourceData, Int(byteCount))
            destinationBuffer.mDataByteSize = byteCount
            destinationBuffers[index] = destinationBuffer
        }
        buffer = copy
        if let time, time.isSampleTimeValid, time.sampleRate > 0 {
            presentationTimeSeconds = Double(time.sampleTime) / time.sampleRate
        } else {
            presentationTimeSeconds = nil
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
    func reset() { lock.withLock { storage = 0 } }
}

private final class SpeechPCM16Converter: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat

    init?(sourceFormat: AVAudioFormat) {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: SpeechAudioFrame.canonicalSampleRate,
            channels: AVAudioChannelCount(SpeechAudioFrame.canonicalChannelCount),
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }
        self.targetFormat = targetFormat
        self.converter = converter
    }

    func convert(
        _ source: AVAudioPCMBuffer,
        presentationTimeSeconds: Double?
    ) -> SpeechAudioFrame? {
        lock.withLock {
            let ratio = targetFormat.sampleRate / max(source.format.sampleRate, 1)
            let capacity = AVAudioFrameCount(
                max(1, Int((Double(source.frameLength) * ratio).rounded(.up)) + 1)
            )
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: capacity
            ) else { return nil }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard !suppliedInput else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return source
            }
            guard status != .error,
                  conversionError == nil,
                  output.frameLength > 0,
                  let samples = output.int16ChannelData?[0] else { return nil }

            let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
            let data = Data(bytes: samples, count: byteCount)
            return SpeechAudioFrame(
                pcm16LittleEndian: data,
                frameCount: Int(output.frameLength),
                presentationTimeSeconds: presentationTimeSeconds
            )
        }
    }
}
