@preconcurrency import AVFoundation
import Speech

/// Wraps SpeechAnalyzer + SpeechTranscriber.
/// Feed 16 kHz mono float32 samples via the sampleStream; receive
/// transcription results through onPartial / onFinal callbacks.
@available(macOS 26.0, iOS 26.0, *)
actor ASRManager {

    var onPartial: @Sendable (String) -> Void = { _ in }
    var onFinal:   @Sendable (String) -> Void = { _ in }

    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerTask: Task<Void, Error>?
    private var resultsTask:  Task<Void, Error>?
    private var forwardTask:  Task<Void, Never>?

    // Converter from 16 kHz → analyzerFormat (nil if same)
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    private let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!

    func setOnPartial(_ cb: @escaping @Sendable (String) -> Void) { onPartial = cb }
    func setOnFinal(_ cb: @escaping @Sendable (String) -> Void)   { onFinal   = cb }

    func start(sampleStream: AsyncStream<[Float]>, locale: Locale,
               onStatus: (@Sendable (String) -> Void)? = nil) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        // Download ASR model if not installed
        if !(await SpeechTranscriber.installedLocales).contains(locale) {
            onStatus?(NSLocalizedString("startup.downloadingASR", value: "Downloading speech recognition model, please wait…", comment: ""))
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await req.downloadAndInstall()
            }
        }
        onStatus?(NSLocalizedString("startup.initializingASR", value: "Initializing speech recognition engine…", comment: ""))

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let aFmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "ASR", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No compatible audio format"])
        }
        analyzerFormat = aFmt
        converter = aFmt == inputFormat ? nil : AVAudioConverter(from: inputFormat, to: aFmt)

        let (analyzerStream, analyzerContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = analyzerContinuation

        let onPartial = self.onPartial
        let onFinal   = self.onFinal

        // 1. Results reader
        resultsTask = Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count >= 2 else { continue }
                if result.isFinal { onFinal(text) } else { onPartial(text) }
            }
        }

        // 2. Analyzer (blocks until analyzerStream ends)
        analyzerTask = Task {
            try await analyzer.start(inputSequence: analyzerStream)
        }

        // 3. Forward 16 kHz samples → AnalyzerInput
        let conv     = converter
        let aFmtCopy = aFmt
        let ifmt     = inputFormat

        forwardTask = Task {
            for await samples in sampleStream {
                let frames = samples.count
                guard let pcm = AVAudioPCMBuffer(pcmFormat: ifmt,
                                                  frameCapacity: AVAudioFrameCount(frames)) else { continue }
                pcm.frameLength = AVAudioFrameCount(frames)
                samples.withUnsafeBufferPointer { src in
                    if let dst = pcm.floatChannelData?[0], let base = src.baseAddress {
                        memcpy(dst, base, frames * MemoryLayout<Float>.size)
                    }
                }

                let bufferToYield: AVAudioPCMBuffer
                if let conv {
                    let ratio    = aFmtCopy.sampleRate / 16_000.0
                    let outCount = AVAudioFrameCount((Double(frames) * ratio).rounded(.up))
                    guard let out = AVAudioPCMBuffer(pcmFormat: aFmtCopy, frameCapacity: outCount) else { continue }
                    var convErr: NSError?
                    conv.convert(to: out, error: &convErr) { _, status in
                        status.pointee = .haveData
                        return pcm
                    }
                    guard convErr == nil else { continue }
                    bufferToYield = out
                } else {
                    bufferToYield = pcm
                }

                analyzerContinuation.yield(AnalyzerInput(buffer: bufferToYield))
            }
            analyzerContinuation.finish()
        }
    }

    func stop() async {
        forwardTask?.cancel()
        inputContinuation?.finish()
        analyzerTask?.cancel()
        resultsTask?.cancel()
        forwardTask = nil
        inputContinuation = nil
        analyzerTask = nil
        resultsTask = nil
        converter = nil
        analyzerFormat = nil
    }
}
