# JaSub — Real-Time Meeting Transcription & Translation

> Also available on iPhone & iPad: **[LiveSub →](https://apps.apple.com/tw/app/livesub/id6771318855)**

Real-time speech transcription and translation for macOS 26.4+. No API keys, no subscription. Fully on-device by default; optional high-fidelity mode routes translation through Apple servers via Private Cloud Compute.

Uses Apple's native stack exclusively:

- **ASR**: SpeechAnalyzer + SpeechTranscriber (Speech.framework, macOS 26+)
- **Translation**: Translation.framework `.highFidelity` (Apple servers, optional) or `.lowLatency` (on-device, < 100ms, default) → FoundationModels / Apple Intelligence (fallback, ~500ms)
- **System audio**: CATapDescription + IOProc — captures browser or any app audio without a virtual audio driver

## Download

**[→ JaSub 0.3.9 (DMG)](https://github.com/ultima6-tw/livesub-macos/releases/latest)**

> Requires macOS 26.4+ (Tahoe) + Apple Intelligence + Apple Silicon.  
> First launch: right-click the app → **Open** to bypass Gatekeeper.

### Upgrading from a previous version

When replacing an existing installation, TCC (privacy permissions) must be reset manually — the ad-hoc signature changes with each build, and macOS does not transfer permissions automatically.

1. Open **System Settings → Privacy & Security → Screen Recording** → remove JaSub
2. Open **System Settings → Privacy & Security → Microphone** → remove JaSub
3. Drag the new version into Applications (overwrite)
4. Launch JaSub — macOS will prompt for permissions again → grant them
5. **Quit and relaunch JaSub** — TCC changes don't take effect in the same process session

![JaSub subtitle overlay windows](app/docs/screenshot-overview.png)

---

## Menu Bar App

A native SwiftUI menu bar app with floating subtitle overlay windows.

### Requirements

- macOS 26.4+ (Tahoe) with Apple Intelligence enabled
- Apple Silicon Mac
- Xcode 26+ (`xcode-select --install` or full Xcode)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Install translation language packs (required)

**System Settings → General → Language & Region → Translation Languages**

Install the language pairs you need (e.g. English ↔ Chinese, Japanese ↔ Chinese). Required for < 100ms translation. Without this the app uses FoundationModels (~500ms), which is still fully on-device.

### Build and install

```bash
cd app
./setup.sh        # install xcodegen and generate .xcodeproj (first time only)
./package.sh      # Release build → dist/JaSub-0.3.9.dmg
```

Open the DMG, drag JaSub to Applications, then right-click → **Open** on first launch (bypasses Gatekeeper — the app is ad-hoc signed, not notarised).

### Usage

| Action | Result |
|--------|--------|
| Left-click menu bar icon | Open settings popover (language, audio source, font size) |
| Right-click menu bar icon | Quick menu: Start / Stop / Quit |
| Icon turns red | App is running — click to access Stop |

![Settings popover](app/docs/screenshot-popover.png)

### Features

| Feature | Details |
|---------|---------|
| Source language | Dynamically queried from `SFSpeechRecognizer.supportedLocales()`; frequent languages shown first |
| Target language | Dynamically queried from `Translation.framework`, installed packs listed first; frequent languages shown first |
| Frequent languages | Top-3 most-used source and target languages float to the top of each picker automatically |
| High Quality Translation | Optional toggle — routes translation through Apple servers (`.highFidelity`); falls back to on-device silently if no network |
| Language names | Localised to system display language |
| Audio source | Microphone (CoreAudio device list) or Browser / System Audio (CATapDescription + IOProc) |
| Font size | 12–40pt stepper, persisted across launches — subtitle windows are freely resizable |
| Show original | Toggle original-language subtitle window |
| Session log | Auto-creates `~/Documents/JaSub/YYYY-MM-DD HH-mm.txt` on start, appends each sentence in real time |
| Log folder | Opens `~/Documents/JaSub` in Finder |

![Subtitle windows — resizable, font size 12–40pt](app/docs/screenshot-subtitles.png)

> Both subtitle windows can be freely resized by dragging any edge or corner. Font size (12–40pt) is controlled from the settings popover and persisted across launches.

### Localisation

The UI adapts to the system language automatically. Supported languages:

English · 繁體中文 · 简体中文 · 日本語 · 한국어 · Français · Deutsch · Español · Português (BR) · Italiano · العربية · Русский · Nederlands · Polski · ภาษาไทย · Türkçe · Українська · Tiếng Việt · Bahasa Indonesia

### Upgrading from a previous version

Because JaSub is ad-hoc signed, macOS treats each new binary as a different app and revokes the old permissions. Follow these steps to avoid "Screen Recording denied" errors after upgrading:

1. **Remove old permissions** — System Settings → Privacy & Security:
   - Screen Recording → select JaSub → click **–** to remove
   - Microphone → select JaSub → click **–** to remove
2. **Install the new version** — drag the new `JaSub.app` into Applications (overwrite)
3. **Launch JaSub** — macOS will ask for Screen Recording and Microphone access again → grant both
4. **Relaunch when prompted** — macOS will say the app needs to be restarted for the permission to take effect → quit JaSub completely and reopen it
5. JaSub should now work normally

> **Why this is needed**: TCC (macOS's permission database) records permissions by binary path + code signature. An ad-hoc re-signed binary is treated as a new app, so the old entry must be removed before macOS will prompt again.

### Permissions

- **Speech Recognition** — prompted on first start
- **Microphone** — prompted on first start (microphone mode)
- **Screen & System Audio Recording** — required for browser audio capture (System Settings → Privacy & Security → Screen Recording)

---

## Architecture

```
Microphone
    ↓ AVAudioEngine (16kHz mono float32)
    ↓ AsyncStream<[Float]>

Browser / System Audio
    ↓ CATapDescription + IOProc (48kHz → resample → 16kHz)
    ↓ AsyncStream<[Float]>

SpeechAnalyzer + SpeechTranscriber  [ASRManager]
    partial → live subtitle update
    final   → hallucination filter → translation queue

Translation.framework  [TranslatorManager]
    ① Translation.framework  .highFidelity  (Apple servers, optional)
       or .lowLatency  (on-device, < 100ms, default)
       .highFidelity failure → auto-fallback to .lowLatency
    ② FoundationModels fallback  (Apple Intelligence 3B, ~500ms)
       guardrail → completion-style retry → ⚠ original text

@MainActor TranslationEngine → SwiftUI floating NSPanel windows
```

---

## Why SpeechAnalyzer?

`SpeechAnalyzer` (macOS 26+) is Apple's API for continuous live transcription. No session time limit, progressive partial results, fully Neural Engine, automatic model download.

**Evolution**: mlx-whisper → WhisperKit → SFSpeechRecognizer → **SpeechAnalyzer**. WhisperKit with `--use-prefill-prompt` invalidated the Neural Engine cache (7–10s/segment). SFSpeechRecognizer was superseded when SpeechAnalyzer shipped in macOS 26.

---

## Known Limitations

**Music / singing**: SpeechAnalyzer is speech-optimised. Some lyrics are recognised but gaps are expected.

**Proper nouns**: No hot-words API — character names and technical terms may be phonetically substituted.

---

## CLI version (legacy, no longer actively developed)

A Python + Swift CLI version is available in `server/` for headless or terminal use. No further development planned — the Menu Bar App is the primary version.

```bash
./run.sh    # auto-setup + interactive menu (language pair + audio source)
```

Requires Python 3.13+ and Xcode Command Line Tools. See `NOTES.md` for architecture details and known issues.
