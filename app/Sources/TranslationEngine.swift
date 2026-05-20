import AVFoundation
import Foundation
#if os(macOS)
import CoreAudio
import CoreGraphics
#endif
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

@available(macOS 26.0, iOS 26.0, *)
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

    // MARK: Audio state (macOS only)

    #if os(macOS)
    static let systemAudioID = "__system_audio__"

    @Published var selectedDevice: String = ""
    @Published var inputDevices: [AudioDevice] = []
    #endif

    // MARK: Subtitle content

    @Published var isRunning: Bool = false
    @Published var isImporting: Bool = false
    @Published var importProgress: Double = 0
    @Published var startError: String? = nil
    @Published var startupStatus: String? = nil
    @Published var isASRSilent: Bool = false
    @Published var showOriginal: Bool = true
    @Published var saveTranscript: Bool = false {
        didSet { UserDefaults.standard.set(saveTranscript, forKey: "jasub.saveTranscript") }
    }
    @Published var diagnosticLogging: Bool = false {
        didSet {
            UserDefaults.standard.set(diagnosticLogging, forKey: "jasub.diagnosticLogging")
            DiagnosticLog.shared.isEnabled = diagnosticLogging
        }
    }
    @Published var translationFontSize: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "jasub.translationFontSize")
        return saved >= 12 ? CGFloat(saved) : 20
    }()
    @Published var originalPartial: String = ""
    @Published var originalHistory: [String] = []
    @Published var translatedHistory: [String] = []

    // MARK: Private

    private static let allTargetIDs: [String] = [
        "zh-TW", "zh-HK", "zh-CN", "en-US", "ja-JP", "ko-KR",
        "fr-FR", "de-DE", "es-ES", "pt-BR", "it-IT",
        "ar-AE", "ru-RU", "nl-NL", "pl-PL", "th-TH", "tr-TR", "uk-UA", "vi-VN", "id-ID",
    ]

    private var importFileURL: URL?
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
        #if os(macOS)
        refreshDevices()
        #endif

        saveTranscript = UserDefaults.standard.bool(forKey: "jasub.saveTranscript")

        let savedDiagnostic = UserDefaults.standard.bool(forKey: "jasub.diagnosticLogging")
        diagnosticLogging = savedDiagnostic
        DiagnosticLog.shared.isEnabled = savedDiagnostic

        $translationFontSize
            .dropFirst()
            .sink { size in UserDefaults.standard.set(Double(size), forKey: "jasub.translationFontSize") }
            .store(in: &cancellables)

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
            if srcID == tgtID { continue }

            let tgtLang = Locale.Language(identifier: tgtID)
            let status = await availability.status(from: srcLang, to: tgtLang)
            guard status != .unsupported else { continue }

            let name = display.localizedString(forIdentifier: tgtID) ?? tgtID
            targets.append(TargetLanguage(
                id: tgtID, name: name,
                isInstalled: status == .installed
            ))
        }

        // Simulator / no-model fallback: LanguageAvailability returns .unsupported for everything
        if targets.isEmpty {
            for tgtID in Self.allTargetIDs {
                let tgtBase = String(tgtID.prefix(2))
                if srcBase == tgtBase && srcBase != "zh" { continue }
                if srcID == tgtID { continue }
                let name = display.localizedString(forIdentifier: tgtID) ?? tgtID
                targets.append(TargetLanguage(id: tgtID, name: name, isInstalled: false))
            }
        }

        targetLanguages = targets.sorted {
            if $0.isInstalled != $1.isInstalled { return $0.isInstalled }
            return $0.name < $1.name
        }

        if !targets.contains(where: { $0.id == selectedTgtID }) {
            selectedTgtID = targets.first(where: { $0.isInstalled })?.id ?? targets.first?.id ?? ""
        }
    }

    // MARK: Audio device enumeration (macOS only)

    #if os(macOS)
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
    #endif

    // MARK: Start / Stop

    func importFromFile(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        importFileURL = url
        start(fileURL: url)
    }

    func start(fileURL: URL? = nil) {
        guard !isRunning else { return }
        startError = nil

        // Check 1: macOS 26+
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        guard osVer.majorVersion >= 26 else {
            DiagnosticLog.shared.log("[FAIL] macOS version \(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion) — requires 26+")
            startError = "JaSub 需要 macOS 26（Tahoe）或更新版本（目前：\(osVer.majorVersion).\(osVer.minorVersion)）。"
            return
        }

        isRunning = true
        isImporting = fileURL != nil
        importProgress = 0
        isASRSilent = false
        lastASRActivity = .now
        originalPartial = ""
        originalHistory = []
        translatedHistory = []
        hallucinationFilter = HallucinationFilter()
        if saveTranscript { startSessionLog() }
        #if os(macOS)
        let deviceLabel = selectedDevice == Self.systemAudioID ? "system-audio" : (selectedDevice.isEmpty ? "default" : selectedDevice)
        #else
        let deviceLabel = "mic"
        #endif
        DiagnosticLog.shared.sessionHeader(
            osVersion: "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)",
            src: selectedSrcID, tgt: selectedTgtID, device: deviceLabel
        )
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.isASRSilent = Date.now.timeIntervalSince(self.lastASRActivity) > 4.0
            }
        }

        let srcLocaleID = selectedSrcID
        let tgtID       = selectedTgtID
        let translSrc   = translationSrcCode(for: srcLocaleID)

        #if os(macOS)
        let isSystemAudio = selectedDevice == Self.systemAudioID
        let deviceID = isSystemAudio ? nil : inputDevices.first(where: { $0.name == selectedDevice })?.id

        if isSystemAudio && !CGPreflightScreenCaptureAccess() {
            DiagnosticLog.shared.log("[FAIL] screen recording permission not granted")
            CGRequestScreenCaptureAccess()
            isRunning = false
            startError = NSLocalizedString("error.screenCapture",
                value: "JaSub requires Screen Recording permission to capture system audio. Please grant it in System Settings → Privacy & Security → Screen Recording, then try again.",
                comment: "")
            return
        }
        #endif

        let (sampleStream, continuation) = AsyncStream<[Float]>.makeStream()
        sampleStreamContinuation = continuation

        let engine     = AudioEngine()
        audioEngine    = engine
        let asr        = ASRManager()
        asrManager     = asr
        let translator = TranslatorManager()
        translatorManager = translator

        let capturedFileURL = fileURL
        pipelineTask = Task { [weak self] in

            // Check 2: Microphone permission (macOS, mic input only)
            #if os(macOS)
            if !isSystemAudio {
                let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                switch micStatus {
                case .notDetermined:
                    let granted = await AVCaptureDevice.requestAccess(for: .audio)
                    if !granted {
                        DiagnosticLog.shared.log("[FAIL] mic permission denied by user")
                        Task { @MainActor [weak self] in
                            self?.isRunning = false
                            self?.startupStatus = nil
                            self?.startError = "JaSub 需要麥克風存取權限。請至「系統設定 → 隱私權與安全性 → 麥克風」開啟後重試。"
                        }
                        return
                    }
                    DiagnosticLog.shared.log("[OK] mic permission granted")
                case .denied, .restricted:
                    DiagnosticLog.shared.log("[FAIL] mic permission denied/restricted (status=\(micStatus.rawValue))")
                    Task { @MainActor [weak self] in
                        self?.isRunning = false
                        self?.startupStatus = nil
                        self?.startError = "麥克風存取被拒絕。請至「系統設定 → 隱私權與安全性 → 麥克風」允許 JaSub 後重試。"
                    }
                    return
                default:
                    DiagnosticLog.shared.log("[OK] mic permission already authorized")
                }
            }
            #endif

            // Check 3: Translation language pack
            // Check 4: ASR model
            let tgtInstalled = await MainActor.run { self?.selectedTgt?.isInstalled ?? true }
            let srcLocale = Locale(identifier: srcLocaleID)
            let asrInstalled = await SpeechTranscriber.installedLocales.contains(srcLocale)
            DiagnosticLog.shared.log("[CHECK] tgtInstalled=\(tgtInstalled) asrInstalled=\(asrInstalled)")

            var statusParts: [String] = []
            if !asrInstalled {
                statusParts.append(NSLocalizedString("startup.asrModelMissing",
                    value: "Speech model will download on first use",
                    comment: ""))
            }
            if !tgtInstalled {
                statusParts.append(NSLocalizedString("startup.translationPackMissing",
                    value: "Translation pack not installed — Apple Intelligence will be used (slower)",
                    comment: ""))
            }
            let initialStatus = statusParts.isEmpty
                ? NSLocalizedString("startup.preparingTranslation", value: "Preparing translation engine…", comment: "")
                : statusParts.joined(separator: " · ") + "…"
            await MainActor.run { self?.startupStatus = initialStatus }

            await translator.prepare()

            await asr.setOnPartial { [weak self] text in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastASRActivity = .now
                    self.isASRSilent = false
                    self.originalPartial = text
                }
            }

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
                    self.logFileHandle?.seekToEndOfFile()
                    if let data = (text + "\n").data(using: .utf8) {
                        self.logFileHandle?.write(data)
                    }
                }
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

            await MainActor.run { self?.startupStatus = NSLocalizedString("startup.startingAudio", value: "Starting audio capture…", comment: "") }
            do {
                #if os(macOS)
                if isSystemAudio {
                    try engine.startSystemAudio(continuation: continuation)
                } else {
                    try engine.start(deviceID: deviceID, continuation: continuation)
                }
                #else
                if let url = capturedFileURL {
                    try engine.startFromFile(url, onProgress: { [weak self] p in
                        Task { @MainActor [weak self] in self?.importProgress = p }
                    }, continuation: continuation)
                } else {
                    try engine.start(continuation: continuation)
                }
                #endif
            } catch {
                DiagnosticLog.shared.log("[FAIL] audio engine: \(error)")
                Task { @MainActor [weak self] in
                    self?.isRunning = false
                    self?.startupStatus = nil
                    self?.startError = error.localizedDescription
                }
                return
            }
            DiagnosticLog.shared.log("[OK] audio engine started")

            do {
                try await asr.start(
                    sampleStream: sampleStream,
                    locale: Locale(identifier: srcLocaleID),
                    onStatus: { [weak self] msg in
                        Task { @MainActor [weak self] in self?.startupStatus = msg }
                    }
                )
            } catch {
                DiagnosticLog.shared.log("[FAIL] ASR: \(error)")
                Task { @MainActor [weak self] in
                    self?.isRunning = false
                    self?.startupStatus = nil
                    self?.startError = error.localizedDescription
                }
                return
            }
            DiagnosticLog.shared.log("[OK] ASR started — pipeline running")
            await MainActor.run { self?.startupStatus = nil }

            // File import finished — auto-stop and save transcript
            if capturedFileURL != nil {
                await MainActor.run { self?.stop() }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        DiagnosticLog.shared.log("[STOP] session ended by user")
        isRunning = false
        startupStatus = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        isASRSilent = false

        audioEngine?.stop()
        audioEngine = nil

        sampleStreamContinuation?.finish()
        sampleStreamContinuation = nil

        pipelineTask?.cancel()
        pipelineTask = nil

        let asr = asrManager
        asrManager        = nil
        translatorManager = nil
        Task { await asr?.stop() }

        logFileHandle?.closeFile()
        logFileHandle = nil
        currentLogURL = nil

        importFileURL?.stopAccessingSecurityScopedResource()
        importFileURL = nil
        isImporting = false
        importProgress = 0
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
        asrLocaleID  // ASR locales (e.g. "en-US", "ja-JP") are already valid Translation identifiers
    }
}
