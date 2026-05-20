@preconcurrency import AVFoundation
#if os(macOS)
import CoreAudio
#endif

// MARK: - System audio (macOS only)

#if os(macOS)

// clientData = Unmanaged-retained SystemAudioContext pointer
private func jasub_system_ioProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let raw = clientData else { return noErr }
    let ctx = Unmanaged<SystemAudioContext>.fromOpaque(raw).takeUnretainedValue()
    let byteCount = Int(inputData.pointee.mBuffers.mDataByteSize)
    let frameCount = byteCount / MemoryLayout<Float>.size
    guard frameCount > 0, let ptr = inputData.pointee.mBuffers.mData else { return noErr }
    let samples = Array(UnsafeBufferPointer(
        start: ptr.assumingMemoryBound(to: Float.self), count: frameCount))
    ctx.feed(samples)
    return noErr
}

// Bridges between the real-time IOProc thread and the async pipeline.
private final class SystemAudioContext: @unchecked Sendable {
    private let rawCont: AsyncStream<[Float]>.Continuation
    let task: Task<Void, Never>

    init(mainCont: AsyncStream<[Float]>.Continuation, nativeSampleRate: Double) {
        let (rawStream, rawCont) = AsyncStream<[Float]>.makeStream()
        self.rawCont = rawCont

        let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: nativeSampleRate, channels: 1, interleaved: false)!
        let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: srcFmt, to: dstFmt)!
        let chunkSize = Int(nativeSampleRate / 10)

        task = Task.detached {
            var pending: [Float] = []
            for await batch in rawStream {
                if Task.isCancelled { break }
                pending.append(contentsOf: batch)

                while pending.count >= chunkSize {
                    let chunk = Array(pending.prefix(chunkSize))
                    pending.removeFirst(chunkSize)

                    guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFmt,
                                                       frameCapacity: AVAudioFrameCount(chunkSize))
                    else { continue }
                    inBuf.frameLength = AVAudioFrameCount(chunkSize)
                    chunk.withUnsafeBufferPointer { p in
                        inBuf.floatChannelData![0].update(from: p.baseAddress!, count: chunkSize)
                    }

                    let outCapacity = AVAudioFrameCount(Double(chunkSize) * (16_000 / nativeSampleRate) + 32)
                    guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: outCapacity)
                    else { continue }

                    final class Once: @unchecked Sendable { var done = false }
                    let once = Once()
                    var convErr: NSError?
                    converter.convert(to: outBuf, error: &convErr) { _, status in
                        if once.done { status.pointee = .noDataNow; return nil }
                        once.done = true; status.pointee = .haveData; return inBuf
                    }

                    guard convErr == nil, outBuf.frameLength > 0,
                          let data = outBuf.floatChannelData else { continue }
                    mainCont.yield(Array(UnsafeBufferPointer(start: data[0],
                                                              count: Int(outBuf.frameLength))))
                }
            }
        }
    }

    func feed(_ samples: [Float]) { rawCont.yield(samples) }
    func finish() { task.cancel(); rawCont.finish() }
}

#endif // os(macOS)

// MARK: - AudioEngine

final class AudioEngine {
    private var avEngine: AVAudioEngine?
    private var fileReadTask: Task<Void, Never>?

    #if os(macOS)
    private var tapID: AudioObjectID = 0
    private var agDevID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var systemCtx: SystemAudioContext?
    private var systemCtxPtr: UnsafeMutableRawPointer?
    #endif

    // MARK: Microphone — macOS (with optional device selection)

    #if os(macOS)
    func start(deviceID: AudioDeviceID?, continuation: AsyncStream<[Float]>.Continuation) throws {
        let engine = AVAudioEngine()
        if let deviceID {
            let audioUnit = engine.inputNode.audioUnit!
            var dev = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0, &dev,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                throw AudioEngineError.deviceSetFailed(status)
            }
        }
        try startAVEngine(engine, continuation: continuation)
    }
    #else
    // MARK: Microphone — iOS (always default mic, no device selection)
    func start(continuation: AsyncStream<[Float]>.Continuation) throws {
        let session = AVAudioSession.sharedInstance()
        // .default enables iOS beamforming, AGC and noise reduction —
        // better than .measurement for far-field meeting capture
        try session.setCategory(.record, mode: .default)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        try startAVEngine(AVAudioEngine(), continuation: continuation)
    }

    // MARK: File import — iOS
    func startFromFile(
        _ url: URL,
        onProgress: @escaping @Sendable (Double) -> Void,
        continuation: AsyncStream<[Float]>.Continuation
    ) throws {
        let file = try AVAudioFile(forReading: url)
        let total = file.length
        let srcFmt = file.processingFormat
        let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: srcFmt, to: dstFmt) else {
            throw AudioEngineError.noConverter
        }
        let chunkFrames = AVAudioFrameCount(srcFmt.sampleRate * 0.1)

        fileReadTask = Task.detached {
            var read: AVAudioFramePosition = 0
            defer { continuation.finish() }
            while !Task.isCancelled {
                guard let buf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: chunkFrames) else { break }
                do { try file.read(into: buf) } catch { break }
                guard buf.frameLength > 0 else { break }

                read += AVAudioFramePosition(buf.frameLength)
                if total > 0 { onProgress(Double(read) / Double(total)) }

                let outCap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / srcFmt.sampleRate + 32)
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: outCap) else { continue }

                final class Once: @unchecked Sendable { var done = false }
                let once = Once()
                var convErr: NSError?
                converter.convert(to: outBuf, error: &convErr) { _, status in
                    if once.done { status.pointee = .noDataNow; return nil }
                    once.done = true; status.pointee = .haveData; return buf
                }
                guard convErr == nil, outBuf.frameLength > 0,
                      let data = outBuf.floatChannelData else { continue }
                continuation.yield(Array(UnsafeBufferPointer(start: data[0], count: Int(outBuf.frameLength))))
            }
        }
    }
    #endif

    // MARK: Shared mic implementation

    private func startAVEngine(_ engine: AVAudioEngine,
                               continuation: AsyncStream<[Float]>.Continuation) throws {
        let inputNode = engine.inputNode
        let nativeFmt = inputNode.inputFormat(forBus: 0)
        let outFmt    = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16_000, channels: 1, interleaved: false)!

        guard nativeFmt.sampleRate > 0, nativeFmt.channelCount > 0 else {
            throw AudioEngineError.invalidInputFormat(sampleRate: nativeFmt.sampleRate,
                                                      channels: Int(nativeFmt.channelCount))
        }
        guard let converter = AVAudioConverter(from: nativeFmt, to: outFmt) else {
            throw AudioEngineError.noConverter
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFmt) { buffer, _ in
            let ratio    = outFmt.sampleRate / nativeFmt.sampleRate
            let outCount = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCount) else { return }
            var err: NSError?
            converter.convert(to: outBuf, error: &err) { _, status in
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, let ptr = outBuf.floatChannelData else { return }
            continuation.yield(Array(UnsafeBufferPointer(start: ptr[0], count: Int(outBuf.frameLength))))
        }

        engine.prepare()
        try engine.start()
        self.avEngine = engine
    }

    // MARK: System audio (macOS only)

    #if os(macOS)
    func startSystemAudio(continuation: AsyncStream<[Float]>.Continuation) throws {
        let tapDesc = CATapDescription()
        tapDesc.isMono      = true
        tapDesc.isPrivate   = true
        tapDesc.muteBehavior = .unmuted
        tapDesc.isExclusive = true

        var localTapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &localTapID)
        guard tapStatus == noErr, localTapID != 0 else {
            throw AudioEngineError.tapFailed(tapStatus)
        }
        tapID = localTapID

        let agUID = UUID().uuidString
        let agDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String:          "JaSubTap",
            kAudioAggregateDeviceUIDKey as String:           agUID,
            kAudioAggregateDeviceIsPrivateKey as String:     true,
            kAudioAggregateDeviceTapAutoStartKey as String:  false,
            kAudioAggregateDeviceSubDeviceListKey as String: [] as [Any],
            kAudioAggregateDeviceTapListKey as String:       [["uid": tapDesc.uuid.uuidString]]
        ]

        var localAgDevID: AudioDeviceID = 0
        let agStatus = AudioHardwareCreateAggregateDevice(agDesc as CFDictionary, &localAgDevID)
        guard agStatus == noErr, localAgDevID != 0 else {
            AudioHardwareDestroyProcessTap(tapID); tapID = 0
            throw AudioEngineError.aggregateFailed(agStatus)
        }
        agDevID = localAgDevID

        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        var nativeRate = 48_000.0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(agDevID, &rateAddr, 0, nil, &rateSize, &nativeRate)

        let ctx    = SystemAudioContext(mainCont: continuation, nativeSampleRate: nativeRate)
        systemCtx  = ctx
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        systemCtxPtr = ctxPtr

        var localProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(agDevID, jasub_system_ioProc, ctxPtr, &localProcID)
        guard createStatus == noErr else {
            ctx.finish()
            Unmanaged<SystemAudioContext>.fromOpaque(ctxPtr).release()
            systemCtx = nil; systemCtxPtr = nil
            AudioHardwareDestroyAggregateDevice(agDevID); agDevID = 0
            AudioHardwareDestroyProcessTap(tapID); tapID = 0
            throw AudioEngineError.procFailed(createStatus)
        }
        ioProcID = localProcID

        let startStatus = AudioDeviceStart(agDevID, localProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(agDevID, localProcID!)
            ctx.finish()
            Unmanaged<SystemAudioContext>.fromOpaque(ctxPtr).release()
            systemCtx = nil; systemCtxPtr = nil
            AudioHardwareDestroyAggregateDevice(agDevID); agDevID = 0
            AudioHardwareDestroyProcessTap(tapID); tapID = 0
            throw AudioEngineError.startFailed(startStatus)
        }
    }
    #endif

    // MARK: Stop

    func stop() {
        avEngine?.inputNode.removeTap(onBus: 0)
        avEngine?.stop()
        avEngine = nil

        fileReadTask?.cancel()
        fileReadTask = nil

        #if os(macOS)
        if agDevID != 0 {
            if let procID = ioProcID {
                AudioDeviceStop(agDevID, procID)
                AudioDeviceDestroyIOProcID(agDevID, procID)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(agDevID)
            agDevID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        systemCtx?.finish()
        systemCtx = nil
        if let ptr = systemCtxPtr {
            Unmanaged<SystemAudioContext>.fromOpaque(ptr).release()
            systemCtxPtr = nil
        }
        #else
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }
}

// MARK: - Errors

enum AudioEngineError: Error {
    case deviceSetFailed(OSStatus)
    case invalidInputFormat(sampleRate: Double, channels: Int)
    case noConverter
    case tapFailed(OSStatus)
    case aggregateFailed(OSStatus)
    case procFailed(OSStatus)
    case startFailed(OSStatus)
}

extension AudioEngineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .deviceSetFailed(let s):
            return "無法設定音訊輸入裝置（OSStatus \(s)）。請嘗試選擇其他裝置。"
        case .invalidInputFormat(let sr, let ch):
            return "選取的裝置不支援音訊輸入（sampleRate=\(sr) channels=\(ch)）。請在設定中選擇其他輸入裝置。"
        case .noConverter:
            return "無法建立音訊格式轉換器。請嘗試選擇其他輸入裝置。"
        case .tapFailed(let s):
            return "系統音訊擷取失敗（tap OSStatus \(s)）。請確認螢幕錄製權限已開啟。"
        case .aggregateFailed(let s):
            return "系統音訊裝置建立失敗（OSStatus \(s)）。"
        case .procFailed(let s):
            return "音訊 IOProc 建立失敗（OSStatus \(s)）。"
        case .startFailed(let s):
            return "音訊裝置啟動失敗（OSStatus \(s)）。"
        }
    }
}
