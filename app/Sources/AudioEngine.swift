@preconcurrency import AVFoundation
import CoreAudio

// MARK: - System audio IOProc (top-level C-compatible function)

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

// MARK: - System audio context

// Bridges between the real-time IOProc thread and the async pipeline.
// feed() is called from the IOProc; the processing Task resamples to 16 kHz.
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
        let chunkSize = Int(nativeSampleRate / 10) // 100 ms per chunk

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

                    // Use a class to avoid @Sendable captured-var warning (callback is synchronous)
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

    func feed(_ samples: [Float]) {
        rawCont.yield(samples)
    }

    func finish() {
        task.cancel()
        rawCont.finish()
    }
}

// MARK: - AudioEngine

final class AudioEngine {
    // Microphone mode
    private var avEngine: AVAudioEngine?

    // System audio mode
    private var tapID: AudioObjectID = 0
    private var agDevID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var systemCtx: SystemAudioContext?
    private var systemCtxPtr: UnsafeMutableRawPointer?

    // MARK: Microphone

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
                throw NSError(domain: "AudioEngine", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "Cannot set input device (\(status))"])
            }
        }

        let inputNode   = engine.inputNode
        let nativeFmt   = inputNode.inputFormat(forBus: 0)
        let outFmt      = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 16_000, channels: 1, interleaved: false)!

        guard let converter = AVAudioConverter(from: nativeFmt, to: outFmt) else {
            throw NSError(domain: "AudioEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
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
            let samples = Array(UnsafeBufferPointer(start: ptr[0], count: Int(outBuf.frameLength)))
            continuation.yield(samples)
        }

        engine.prepare()
        try engine.start()
        self.avEngine = engine
    }

    // MARK: System audio (CATapDescription + IOProc)

    func startSystemAudio(continuation: AsyncStream<[Float]>.Continuation) throws {
        // 1. Create global process tap (captures all system audio)
        let tapDesc = CATapDescription()
        tapDesc.isMono = true
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted
        tapDesc.isExclusive = true

        var localTapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &localTapID)
        guard tapStatus == noErr, localTapID != 0 else {
            throw AudioEngineError.tapFailed(tapStatus)
        }
        tapID = localTapID

        // 2. Wrap tap in private aggregate device
        let agUID = UUID().uuidString
        let agDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String:     "JaSubTap",
            kAudioAggregateDeviceUIDKey as String:      agUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: false,
            kAudioAggregateDeviceSubDeviceListKey as String: [] as [Any],
            kAudioAggregateDeviceTapListKey as String:  [["uid": tapDesc.uuid.uuidString]]
        ]

        var localAgDevID: AudioDeviceID = 0
        let agStatus = AudioHardwareCreateAggregateDevice(agDesc as CFDictionary, &localAgDevID)
        guard agStatus == noErr, localAgDevID != 0 else {
            AudioHardwareDestroyProcessTap(tapID); tapID = 0
            throw AudioEngineError.aggregateFailed(agStatus)
        }
        agDevID = localAgDevID

        // 3. Query native sample rate
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nativeRate = 48_000.0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(agDevID, &rateAddr, 0, nil, &rateSize, &nativeRate)

        // 4. Create context (handles resampling to 16 kHz asynchronously)
        let ctx = SystemAudioContext(mainCont: continuation, nativeSampleRate: nativeRate)
        systemCtx = ctx
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        systemCtxPtr = ctxPtr

        // 5. Create and start IOProc
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

    // MARK: Stop

    func stop() {
        // Microphone
        avEngine?.inputNode.removeTap(onBus: 0)
        avEngine?.stop()
        avEngine = nil

        // System audio — stop before releasing context (no more IOProc callbacks after Stop)
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
    }
}

// MARK: - Errors

enum AudioEngineError: Error {
    case tapFailed(OSStatus)
    case aggregateFailed(OSStatus)
    case procFailed(OSStatus)
    case startFailed(OSStatus)
}
