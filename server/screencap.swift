import Foundation
import CoreAudio

// CLI args (--app is accepted but ignored; global tap captures all system audio)
var ai = 1
while ai < CommandLine.arguments.count {
    switch CommandLine.arguments[ai] {
    case "--app", "--system": break
    default: break
    }
    ai += 1
}

// ─── CATapDescription (global tap: exclusive=true, processes=[]) ─────────────

let tapDesc = CATapDescription()
tapDesc.isMono = true
tapDesc.isPrivate = true
tapDesc.muteBehavior = .unmuted
tapDesc.isExclusive = true

var tapID: AudioObjectID = 0
let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)
fputs("CreateProcessTap: status=\(tapStatus) tapID=\(tapID)\n", stderr)
guard tapStatus == noErr, tapID != 0 else {
    fputs("CreateProcessTap 失敗\n", stderr); exit(1)
}

// ─── Aggregate device ────────────────────────────────────────────────────────

let agUID = UUID().uuidString
let agDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: "JaSubTap",
    kAudioAggregateDeviceUIDKey as String: agUID,
    kAudioAggregateDeviceIsPrivateKey as String: true,
    kAudioAggregateDeviceTapAutoStartKey as String: false,
    kAudioAggregateDeviceSubDeviceListKey as String: [] as [Any],
    kAudioAggregateDeviceTapListKey as String: [["uid": tapDesc.uuid.uuidString]]
]

var agDevID: AudioDeviceID = 0
let agStatus = AudioHardwareCreateAggregateDevice(agDesc as CFDictionary, &agDevID)
fputs("CreateAggregateDevice: status=\(agStatus) devID=\(agDevID)\n", stderr)
guard agStatus == noErr, agDevID != 0 else {
    fputs("CreateAggregateDevice 失敗\n", stderr)
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

// ─── Query native sample rate ────────────────────────────────────────────────

func getDeviceSampleRate(_ devID: AudioDeviceID) -> Double {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var rate = 48000.0
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, &rate)
    return rate
}

let sampleRate = Int(getDeviceSampleRate(agDevID))
// Print to stderr so meeting.py can parse it
fputs("SAMPLERATE:\(sampleRate)\n", stderr)

// ─── Stats ───────────────────────────────────────────────────────────────────

var gCount = 0
var gBytes = 0
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    fputs("callbacks=\(gCount) bytes=\(gBytes)\n", stderr)
}

// ─── AudioDeviceIOProc ───────────────────────────────────────────────────────

func ioProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    gCount += 1
    let n = Int(inputData.pointee.mBuffers.mDataByteSize)
    gBytes += n
    if n > 0, let ptr = inputData.pointee.mBuffers.mData {
        FileHandle.standardOutput.write(Data(bytes: ptr, count: n))
    }
    return noErr
}

var procID: AudioDeviceIOProcID?
let createStatus = AudioDeviceCreateIOProcID(agDevID, ioProc, nil, &procID)
fputs("CreateIOProcID: \(createStatus)\n", stderr)
guard createStatus == noErr else {
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

let startStatus = AudioDeviceStart(agDevID, procID)
fputs("DeviceStart: \(startStatus)\n", stderr)
guard startStatus == noErr else {
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

fputs("就緒\n", stderr)
RunLoop.main.run()
