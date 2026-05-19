import Foundation
import CoreAudio
import CoreGraphics
import Combine
import Translation
import Speech

// MARK: - Language models

struct SourceLanguage: Identifiable, Hashable, Sendable {
    let id: String    // SpeechAnalyzer locale, e.g. "en-US"
    let name: String
}

struct TargetLanguage: Identifiable, Hashable, Sendable {
    let id: String    // Translation.framework locale, e.g. "zh-Hant"
    let name: String
    var isInstalled: Bool
    var needsDownload: Bool { !isInstalled }
}

// MARK: - Engine

@available(macOS 26.0, *)
@MainActor
final class TranslationEngine: ObservableObject {
    static let shared = TranslationEngine()

    // MARK: Language state

    let sourceLanguages: [SourceLanguage] = {
        let display = Locale.current
        return SFSpeechRecognizer.supportedLocales()
            .compactMap { locale -> SourceLanguage? in
                guard let name = display.localizedString(forIdentifier: locale.identifier) else { return nil }
                return SourceLanguage(id: locale.identifier, name: name)
            }
            .sorted { $0.name < $1.name }
    }()

    @Published var selectedSrcID: String = "en-US"
    @Published var targetLanguages: [TargetLanguage] = []
    @Published var selectedTgtID: String = "zh-Hant"
    @Published var isLoadingTargets: Bool = true

    var selectedSrc: SourceLanguage? { sourceLanguages.first(where: { $0.id == selectedSrcID }) }
    var selectedTgt: TargetLanguage? { targetLanguages.first(where: { $0.id == selectedTgtID }) }

    // MARK: Audio state

    static let systemAudioID = "__system_audio__"

    @Published var selectedDevice: String = ""
    @Published var inputDevices: [AudioDevice] = []

    // MARK: Subtitle content

    @Published var isRunning: Bool = false
    @Published var startError: String? = nil
    @Published var isASRSilent: Bool = false
    @Published var showOriginal: Bool = true
    @Published var translationFontSize: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "jasub.translationFontSize")
        return saved >= 12 ? CGFloat(saved) : 20
    }()
    @Published var originalPartial: String = ""      // live partial from ASR
    @Published var originalHistory: [String] = []    // completed sentences
    @Published var translatedHistory: [String] = []  // completed translations

    // MARK: Private

    private static let allTargetIDs: [String] = [
        "zh-Hant", "zh-Hans", "en", "ja", "ko", "fr", "de", "es", "pt", "it",
        "ar", "ru", "nl", "pl", "th", "tr", "uk", "vi", "id",
    ]

    private var cancellables = Set<AnyCancellable>()
    private var lastASRActivity: Date = .distantPast
    private var silenceTimer: Timer?

    // MARK: Pipeline

    private var audioEngine: AudioEngine?
    private var asrManager: ASRManager?
    private var translatorManager: TranslatorManager?
    private var sampleStreamContinuation: AsyncStream<[Float]>.Continuation?
    private var pipelineTask: Task<Void, Never>?
    private var hallucinationFilter = HallucinationFilter()

    // MARK: Logging

    @Published var currentLogURL: URL? = nil
    private var logFileHandle: FileHandle?

    // MARK: Init

    private init() {
        refreshDevices()

        // Persist font size changes
        $translationFontSize
            .dropFirst()
            .sink { size in UserDefaults.standard.set(Double(size), forKey: "jasub.translationFontSize") }
            .store(in: &cancellables)

        // Re-query targets whenever source changes
        $selectedSrcID
            .dropFirst()
            .sink { [weak self] srcID in
                guard let self else { return }
                Task { await self.refreshTargets(for: srcID) }
            }
            .store(in: &cancellables)

        Task { await refreshTargets(for: selectedSrcID) }
    }

    // MARK: Target language refresh

    func refreshTargets(for srcID: String) async {
        isLoadingTargets = true
        defer { isLoadingTargets = false }

        let availability = LanguageAvailability()
        let srcLang = Locale.Language(identifier: srcID)
        let srcBase = String(srcID.prefix(2))

        let display = Locale.current
        var targets: [TargetLanguage] = []
        for tgtID in Self.allTargetIDs {
            let tgtBase = String(tgtID.prefix(2))
            if srcBase == tgtBase && srcBase != "zh" { continue }
            if srcID.hasPrefix("zh-TW") && tgtID == "zh-Hant" { continue }
            if srcID.hasPrefix("zh-CN") && tgtID == "zh-Hans" { continue }

            let tgtLang = Locale.Language(identifier: tgtID)
            let status = await availability.status(from: srcLang, to: tgtLang)
            guard status != .unsupported else { continue }

            let name = display.localizedString(forIdentifier: tgtID) ?? tgtID
            targets.append(TargetLanguage(
                id: tgtID, name: name,
                isInstalled: status == .installed
            ))
        }

        // Installed first, then alphabetical
        targetLanguages = targets.sorted {
            if $0.isInstalled != $1.isInstalled { return $0.isInstalled }
            return $0.name < $1.name
        }

        // Keep current selection if still valid, else pick best default
        if !targets.contains(where: { $0.id == selectedTgtID }) {
            selectedTgtID = targets.first(where: { $0.isInstalled })?.id ?? targets.first?.id ?? ""
        }
    }

    // MARK: Audio device enumeration

    struct AudioDevice: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        var isDefault: Bool = false
    }

    func refreshDevices() {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize
        ) == noErr else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return }

        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultID: AudioDeviceID = 0
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &defaultSize, &defaultID
        )

        var result: [AudioDevice] = []
        for id in deviceIDs {
            var channelAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var channelSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &channelAddr, 0, nil, &channelSize) == noErr,
                  channelSize > 0 else { continue }

            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: Unmanaged<CFString>? = nil
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            guard AudioObjectGetPropertyData(
                id, &nameAddr, 0, nil, &nameSize, &nameRef
            ) == noErr, let name = nameRef?.takeRetainedValue() as String? else { continue }

            result.append(AudioDevice(id: id, name: name, isDefault: id == defaultID))
        }

        inputDevices = result.sorted { $0.isDefault && !$1.isDefault }
        if selectedDevice.isEmpty {
            selectedDevice = result.first(where: { $0.isDefault })?.name ?? result.first?.name ?? ""
        }
    }

    // MARK: Start / Stop

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startError = nil
        isASRSilent = false
        lastASRActivity = .now
        originalPartial = ""
        originalHistory = []
        translatedHistory = []
        hallucinationFilter = HallucinationFilter()
        startSessionLog()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.isASRSilent = Date.now.timeIntervalSince(self.lastASRActivity) > 4.0
            }
        }

        // Snapshot selections on MainActor before entering Task
        let srcLocaleID = selectedSrcID
        let tgtID       = selectedTgtID
        let translSrc   = translationSrcCode(for: srcLocaleID)
        let isSystemAudio = selectedDevice == Self.systemAudioID
        let deviceID = isSystemAudio ? nil : inputDevices.first(where: { $0.name == selectedDevice })?.id

        // Request Screen Recording permission before spawning the pipeline Task
        if isSystemAudio && !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            isRunning = false
            startError = "JaSub 需要「螢幕錄製」權限才能擷取系統音訊。請在系統設定 → 隱私與安全性 → 螢幕錄製中授予權限，然後重新開始。"
            return
        }

        let (sampleStream, continuation) = AsyncStream<[Float]>.makeStream()
        sampleStreamContinuation = continuation

        let engine     = AudioEngine()
        audioEngine    = engine
        let asr        = ASRManager()
        asrManager     = asr
        let translator = TranslatorManager()
        translatorManager = translator

        pipelineTask = Task { [weak self] in
            // Warm up Foundation Models session
            await translator.prepare()

            // Wire partial → show live transcription immediately
            await asr.setOnPartial { [weak self] text in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastASRActivity = .now
                    self.isASRSilent = false
                    self.originalPartial = text
                }
            }

            // Wire final → filter + append to history + translate
            await asr.setOnFinal { [weak self] text in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastASRActivity = .now
                    self.isASRSilent = false
                    guard !self.hallucinationFilter.isHallucination(text) else { return }
                    if self.hallucinationFilter.isDuplicateAndRecord(text) { return }
                    self.originalPartial = ""
                    self.originalHistory.append(text)
                    if self.originalHistory.count > 20 { self.originalHistory.removeFirst() }
                    // Append to session log (no cap)
                    self.logFileHandle?.seekToEndOfFile()
                    if let data = (text + "\n").data(using: .utf8) {
                        self.logFileHandle?.write(data)
                    }
                }
                // Translate concurrently
                Task {
                    let translated = await translator.translate(text, from: translSrc, to: tgtID)
                    guard !translated.isEmpty else { return }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.translatedHistory.append(translated)
                        if self.translatedHistory.count > 20 { self.translatedHistory.removeFirst() }
                    }
                }
            }

            // Start audio capture
            do {
                if isSystemAudio {
                    try engine.startSystemAudio(continuation: continuation)
                } else {
                    try engine.start(deviceID: deviceID, continuation: continuation)
                }
            } catch {
                Task { @MainActor [weak self] in self?.isRunning = false }
                return
            }

            // Start ASR pipeline (returns quickly; keeps running via internal Tasks)
            do {
                try await asr.start(sampleStream: sampleStream,
                                    locale: Locale(identifier: srcLocaleID))
            } catch {
                Task { @MainActor [weak self] in self?.isRunning = false }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        isASRSilent = false

        // Stop mic tap first so no more samples arrive
        audioEngine?.stop()
        audioEngine = nil

        // Signal end-of-stream → ASRManager's forwardTask exits naturally
        sampleStreamContinuation?.finish()
        sampleStreamContinuation = nil

        pipelineTask?.cancel()
        pipelineTask = nil

        // Clean up ASR (cancels internal tasks)
        let asr = asrManager
        asrManager        = nil
        translatorManager = nil
        Task { await asr?.stop() }

        // Close session log
        logFileHandle?.closeFile()
        logFileHandle = nil
        currentLogURL = nil
    }

    // MARK: Logging

    private func startSessionLog() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("JaSub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH-mm"
        let url = dir.appendingPathComponent("\(fmt.string(from: .now)).txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logFileHandle = try? FileHandle(forWritingTo: url)
        currentLogURL = url
    }

    // MARK: Helpers

    private func translationSrcCode(for asrLocaleID: String) -> String {
        switch asrLocaleID {
        case "zh-TW": return "zh-Hant"
        case "zh-CN": return "zh-Hans"
        default:      return String(asrLocaleID.prefix(2))
        }
    }
}
