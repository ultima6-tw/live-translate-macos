# JaSub — Real-Time Meeting Transcription & Translation

Fully on-device, real-time speech transcription and translation for macOS 26+.

Uses Apple's **SpeechAnalyzer** (Speech.framework, macOS 26+) for ASR and **FoundationModels** (Apple Intelligence) for translation — no cloud, no API keys, no external models.

## Requirements

- macOS 26+ (Tahoe) with Apple Intelligence enabled
- Apple Silicon Mac
- Xcode or Command Line Tools (`xcode-select --install`)
- Python 3.13+ (`brew install python@3.13`)

## Setup

**1. Install translation language packs**

Open **System Settings → General → Language & Region → Translation Languages** and install the language pairs you need (e.g. English ↔ Chinese, Japanese ↔ Chinese).

> Required for low-latency translation via Translation.framework (< 100ms). Without it the app falls back to FoundationModels (~500ms).

**2. Run**

```bash
./run.sh
```

That's it. On first run, `run.sh` automatically:
- Creates a Python virtual environment
- Installs all Python dependencies
- Compiles the Swift components (`asr.swift`, `translator.swift`, `screencap.swift`)

macOS will prompt for **Speech Recognition** permission on first use — click Allow.

## Usage

```bash
./run.sh
```

Select language and audio source from the interactive menu:

| Option | Description |
|--------|-------------|
| English → Chinese | Transcribe English, display Chinese translation |
| Japanese → Chinese | Transcribe Japanese, display Chinese translation |
| Chinese → English | Transcribe Chinese, display English translation |

**Audio sources:**

| Option | Description |
|--------|-------------|
| Browser audio (Chrome) | Capture system audio via CATapDescription — no virtual driver needed |
| Microphone / other devices | Any input device listed by the OS |

> For browser audio, macOS will prompt for **Screen & System Audio Recording** permission — grant it in System Settings → Privacy & Security.

## Architecture

```
Microphone / System Audio (CATapDescription + IOProc)
    ↓ sounddevice (Python) or screencap.swift (48kHz float32 mono)
    ↓ resample → 16kHz float32 mono (scipy)
    ↓ stdin pipe → asr.swift

asr.swift  [SpeechAnalyzer + SpeechTranscriber, macOS 26+]
    ↓ stdout: ~text = partial,  text = final

meeting.py  [main loop]
    → hallucination filter + cross-segment dedup
    → partial: in-place update
    → final: enqueue for translation

translator.swift  [daemon]
    ① Translation.framework  (< 100ms, if language pack installed)
    ② FoundationModels fallback  (Apple Intelligence 3B, ~500ms)
       guardrail → completion-style fallback → ⚠ original text
    → OpenCC s2twp (Simplified → Taiwan Traditional Chinese)

rich Live display: 2-panel sliding window
    top: original  |  bottom: translation
```

## Files

| File | Description |
|------|-------------|
| `run.sh` | Launch script — auto-setup + interactive menu |
| `server/meeting.py` | Main loop: audio → ASR → translate → display |
| `server/asr.swift` | SpeechAnalyzer daemon (auto-compiled on first run) |
| `server/translator.swift` | Translation daemon (auto-compiled on first run) |
| `server/screencap.swift` | Browser audio capture daemon (CATapDescription + IOProc, auto-compiled) |
| `server/config.json` | Device configuration |
| `server/requirements.txt` | Python dependencies |

## Why SpeechAnalyzer?

`SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+) is Apple's API for long-form, progressive live transcription. It replaces `SFSpeechRecognizer` for this use case and runs entirely on-device via the Neural Engine.

- Designed for continuous, long-form audio (no 1-minute limit)
- Progressive transcription with stable partials
- Automatic language model download via `AssetInventory`

## Translation Strategy

**Translation.framework** (primary): < 100ms if language pack is installed. Install packs via **System Settings → General → Language & Region → Translation Languages**.

**FoundationModels** (fallback): Apple Intelligence on-device 3B model. Always available if Apple Intelligence is set up. ~500ms latency.

## Known Limitations

**Music / singing**: SpeechAnalyzer is trained on speech. During songs, some lyrics may be recognized but others skipped — improving this requires vocal separation + a singing-specific ASR model, which significantly increases latency.

**Proper nouns / names**: SpeechAnalyzer has no hot-words API. Character names and technical terms may be substituted with phonetically similar words.

## Latency (MacBook Air M2)

| Component | Latency |
|-----------|---------|
| SpeechAnalyzer (ASR) | < 500ms, on-device |
| Translation.framework | < 100ms (if pack installed) |
| FoundationModels | ~500ms |
| **Total (FoundationModels path)** | ~1s |
