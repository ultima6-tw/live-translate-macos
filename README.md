# JaSub — Real-Time Meeting Transcription & Translation

Fully on-device, real-time speech transcription and translation for macOS 26+. No cloud, no API keys, no external models.

Uses the complete Apple-native stack:

- **ASR**: SpeechAnalyzer + SpeechTranscriber (Speech.framework, macOS 26+)
- **Translation**: Translation.framework (primary, < 100ms) → FoundationModels / Apple Intelligence (fallback, ~500ms)
- **System audio**: CATapDescription + IOProc global tap — captures browser or any app audio without a virtual audio driver
- **Display**: rich Live terminal — split panels, sliding window, in-place partial updates

Designed for watching foreign-language video, attending online meetings in a second language, or any scenario where you need low-latency subtitles without leaving your terminal.

## Requirements

- macOS 26+ (Tahoe) with Apple Intelligence enabled
- Apple Silicon Mac
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3.13+ (`brew install python@3.13`)

## Setup

**1. Install translation language packs**

Open **System Settings → General → Language & Region → Translation Languages** and install the language pairs you need (e.g. English ↔ Chinese, Japanese ↔ Chinese).

> Required for low-latency translation via Translation.framework (< 100ms). Without it the app falls back to FoundationModels (~500ms), which is still fully on-device.

**2. Run**

```bash
./run.sh
```

On first run, `run.sh` automatically:
- Creates a Python virtual environment
- Installs all Python dependencies
- Compiles the Swift components (`asr.swift`, `translator.swift`, `screencap.swift`)

macOS will prompt for **Speech Recognition** permission on first use — click Allow.

## Usage

```bash
./run.sh
```

Interactive menu — select language pair and audio source:

**Language:**

| Option | Description |
|--------|-------------|
| English → Chinese | Transcribe English, display Chinese translation |
| Japanese → Chinese | Transcribe Japanese, display Chinese translation |
| Chinese → English | Transcribe Chinese, display English translation |

**Audio source:**

| Option | Description |
|--------|-------------|
| Microphone (default) | System default input device or any listed device |
| Browser audio (Chrome) | System audio tap via CATapDescription — no virtual audio driver needed |

> For browser audio, macOS will prompt for **Screen & System Audio Recording** permission — grant it in System Settings → Privacy & Security.

## Display

The terminal is split into two panels:

- **Top**: original transcript (English / Japanese / Chinese)
- **Bottom**: translated output

Transcription shows partial results in-place as speech is recognised, then finalises each segment when ASR is confident. Both panels use a sliding window that reserves a bottom margin so incoming text is always visible — not clipped at the edge. The margin logic accounts for text wrapping, so long English sentences and compact CJK text both behave correctly.

## Architecture

```
Microphone / Loopback Audio
    ↓ sounddevice (Python, native sample rate)
    ↓ resample → 16kHz float32 mono (scipy)
    ↓ stdin pipe → asr.swift

Browser / System Audio
    ↓ screencap.swift — CATapDescription + IOProc (48kHz float32 mono, no virtual driver)
    ↓ resample → 16kHz float32 mono

asr.swift  [SpeechAnalyzer + SpeechTranscriber, macOS 26+]
    partial: ~text\n  →  in-place display update
    final:    text\n  →  enqueue for translation

meeting.py  [main loop]
    hallucination filter (non-target chars > 30%, char/phrase repeats)
    cross-segment dedup (last 5 results)
    sliding window display with bottom margin (visual-line-aware, handles wrapping)

translator.swift  [daemon]
    ① Translation.framework  (< 100ms, installed language pack required)
    ② FoundationModels fallback  (Apple Intelligence 3B, ~500ms)
       guardrail → completion-style fallback → ⚠ original text
    → OpenCC s2twp (Simplified → Taiwan Traditional Chinese)

rich Live: 2-panel split, partial in-place updates, sliding window
```

## Files

| File | Description |
|------|-------------|
| `run.sh` | Launch script — auto-setup + interactive menu |
| `server/meeting.py` | Main loop: audio → ASR → translate → display |
| `server/asr.swift` | SpeechAnalyzer daemon (auto-compiled on first run) |
| `server/translator.swift` | Translation daemon: Translation.framework + FoundationModels fallback (auto-compiled) |
| `server/screencap.swift` | System audio capture via CATapDescription + IOProc (auto-compiled) |
| `server/config.json` | Device name overrides |
| `server/requirements.txt` | Python dependencies |

## Why SpeechAnalyzer?

`SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+) is Apple's API for continuous, long-form live transcription.

- No session time limit (SFSpeechRecognizer had a ~1-minute limit)
- Progressive transcription: stable partial results that update in-place
- Fully Neural Engine — minimal CPU load
- Automatic language model download via `AssetInventory`

**Evolution**: this project tried mlx-whisper → WhisperKit → SFSpeechRecognizer before landing on SpeechAnalyzer. WhisperKit with `--use-prefill-prompt` invalidated the Neural Engine cache, causing 7–10s latency per segment. SFSpeechRecognizer was replaced when SpeechAnalyzer became available in macOS 26.

## Translation Strategy

**Translation.framework** (primary):
< 100ms if the language pack is installed. Purely on-device, no model download at runtime. Install packs via **System Settings → General → Language & Region → Translation Languages**.

> Note: macOS 26 removed the Translate app. Language packs are now managed entirely from System Settings. CLI apps and third-party frameworks access the same installed packs.

**FoundationModels** (fallback):
Apple Intelligence on-device 3B model. Always available if Apple Intelligence is set up. ~500ms latency.

The fallback uses a two-stage prompt to reduce guardrail false positives on dramatic or emotionally charged content (common in subtitles). A session reset fires automatically when the 4096-token context window fills — the current request is retried on the fresh session transparently.

## Browser Audio Capture

`screencap.swift` captures system audio using `CATapDescription` + a low-level `AudioDeviceCreateIOProcID` / `AudioDeviceStart` loop — no Loopback or other virtual audio driver required.

- `AudioHardwareCreateProcessTap` with `isExclusive=false, processes=[]` creates a global tap on all playing audio
- An aggregate device is built from the tap
- An IOProc callback delivers 48kHz mono float32 PCM directly

This approach was chosen after `ScreenCaptureKit` `.audio` callbacks returned 0 bytes on macOS 26.4.1 (video worked, audio did not — likely a system extension conflict) and both `AVAudioEngine` and `AudioQueue` failed to produce audio from the aggregate device.

## Known Limitations

**Music / singing**: SpeechAnalyzer is speech-optimised. Some lyrics are recognised but gaps are expected. Vocal separation (e.g. Demucs) + singing-specific ASR would improve results but add significant latency and complexity — not currently implemented.

**Proper nouns / names**: SpeechAnalyzer has no hot-words API. Character names and technical terms may be replaced with phonetically similar common words. Apple has not opened this API.

## Latency (MacBook Air M2)

| Component | Latency |
|-----------|---------|
| SpeechAnalyzer (ASR) | < 500ms, on-device |
| Translation.framework | < 100ms (language pack required) |
| FoundationModels | ~500ms |
| **Total (Translation.framework path)** | ~500ms |
| **Total (FoundationModels path)** | ~1s |
