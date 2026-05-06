import Foundation
import Speech
import AVFAudio
import Darwin

@discardableResult
func readExact(fd: Int32, into buffer: UnsafeMutableRawPointer, count: Int) -> Bool {
    var remaining = count
    var offset = 0
    while remaining > 0 {
        let n = Darwin.read(fd, buffer.advanced(by: offset), remaining)
        if n <= 0 { return false }
        remaining -= n
        offset += n
    }
    return true
}

@available(macOS 26.0, *)
func runASR(lang: String) async throws {
    let locale = Locale(identifier: lang)

    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

    // Download language model if not installed
    if !(await SpeechTranscriber.installedLocales).contains(locale) {
        fputs("Downloading speech model for \(lang)…\n", stderr)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])

    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        fputs("No compatible audio format\n", stderr)
        exit(1)
    }

    let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: 16000, channels: 1, interleaved: false)!
    let needsConversion = analyzerFormat != inputFormat
    let converter = needsConversion ? AVAudioConverter(from: inputFormat, to: analyzerFormat) : nil

    let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

    // Read transcription results (partial + final)
    let resultsTask = Task {
        for try await result in transcriber.results {
            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { continue }
            let line = result.isFinal ? (text + "\n") : ("~" + text + "\n")
            FileHandle.standardOutput.write(line.data(using: .utf8)!)
        }
    }

    // analyzer.start() internally awaits input from the stream.
    // Run it in a separate Task so the stdin reader below can feed data concurrently.
    let analyzerTask = Task {
        try await analyzer.start(inputSequence: inputSequence)
    }

    fputs("ASR started (SpeechAnalyzer)\n", stderr)

    // Blocking stdin reader → yield AnalyzerInput on background thread
    let framesPerChunk = 1600  // 100ms at 16kHz
    let bytesPerChunk  = framesPerChunk * 4

    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInteractive).async {
            var chunkData = Data(count: bytesPerChunk)
            var chunkCount = 0

            while true {
                let ok = chunkData.withUnsafeMutableBytes {
                    readExact(fd: STDIN_FILENO, into: $0.baseAddress!, count: bytesPerChunk)
                }
                if !ok { break }

                chunkCount += 1
                if chunkCount == 1 || chunkCount % 200 == 0 {
                    fputs("DBG stdin chunk #\(chunkCount)\n", stderr)
                }

                guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                                       frameCapacity: AVAudioFrameCount(framesPerChunk)) else { continue }
                pcmBuffer.frameLength = AVAudioFrameCount(framesPerChunk)
                chunkData.withUnsafeBytes { src in
                    if let dst = pcmBuffer.floatChannelData?[0], let srcPtr = src.baseAddress {
                        memcpy(dst, srcPtr, bytesPerChunk)
                    }
                }

                let bufferToYield: AVAudioPCMBuffer
                if let conv = converter {
                    let ratio    = analyzerFormat.sampleRate / 16000.0
                    let outCount = AVAudioFrameCount((Double(framesPerChunk) * ratio).rounded(.up))
                    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat,
                                                           frameCapacity: outCount) else { continue }
                    var convError: NSError?
                    conv.convert(to: outBuffer, error: &convError) { _, outStatus in
                        outStatus.pointee = .haveData
                        return pcmBuffer
                    }
                    if convError != nil { continue }
                    bufferToYield = outBuffer
                } else {
                    bufferToYield = pcmBuffer
                }

                inputBuilder.yield(AnalyzerInput(buffer: bufferToYield))
            }

            continuation.resume()
        }
    }

    inputBuilder.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    try await analyzerTask.value
    try await resultsTask.value
}

// MARK: - Entry point

var langArg = "ja-JP"
var argIt = CommandLine.arguments.dropFirst().makeIterator()
while let a = argIt.next() {
    if a == "--lang", let v = argIt.next() { langArg = v }
}

guard #available(macOS 26.0, *) else {
    fputs("SpeechAnalyzer requires macOS 26.0+\n", stderr)
    exit(1)
}

Task {
    if #available(macOS 26.0, *) {
        do {
            try await runASR(lang: langArg)
        } catch {
            fputs("ASR error: \(error)\n", stderr)
            exit(1)
        }
        exit(0)
    }
}

RunLoop.main.run()
