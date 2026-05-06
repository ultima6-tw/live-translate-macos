# JaSub — Real-Time Meeting Transcription & Translation

Fully on-device, real-time speech transcription and translation for macOS 26+.

Uses Apple's brand-new **SpeechAnalyzer** (Speech.framework, macOS 26+) for ASR and **FoundationModels** (Apple Intelligence) for translation — no cloud, no API keys, no external models.

## Requirements

- macOS 26+ (Tahoe)
- Apple Silicon Mac with Apple Intelligence enabled
- [Loopback](https://rogueamoeba.com/loopback/) (optional, for system audio capture)
- Python 3.13+
- Xcode Command Line Tools (`xcode-select --install`)

## Setup

```bash
# Create virtualenv (once per machine)
python3.13 -m venv .venv.nosync
.venv.nosync/bin/pip install -r server/requirements.txt

# Run
./run.sh
```

On first run, `asr.swift` and `translator.swift` are compiled automatically (takes a few seconds). macOS will prompt for Speech Recognition permission — click Allow.

## Usage

```
./run.sh
```

Menu:
1. **Language**: English → Chinese / Japanese → Chinese / Chinese → English
2. **Audio source**: Microphone / Loopback Audio (system audio)

## Architecture

```
Microphone / Loopback Audio
    ↓ sounddevice (Python, native rate)
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

## Why SpeechAnalyzer?

`SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+) is Apple's new API designed for long-form, progressive live transcription. It replaces `SFSpeechRecognizer` for this use case and runs entirely on-device via the Neural Engine.

Key differences from `SFSpeechRecognizer`:
- Designed for continuous, long-form audio (no 1-minute limit)
- Progressive transcription with stable partials
- Automatic language model download via `AssetInventory`

## Translation Strategy

**Translation.framework** (primary): < 100ms if language pack is installed. On macOS 26, language packs must be pre-installed via system settings — the CLI cannot trigger downloads.

**FoundationModels** (fallback): Apple Intelligence on-device 3B model. Always available if Apple Intelligence is set up. ~500ms latency. Handles guardrail violations with a 3-layer prompt strategy.

## Files

| File | Description |
|------|-------------|
| `run.sh` | Launch script with interactive menu |
| `server/meeting.py` | Main loop: audio → ASR → translate → display |
| `server/asr.swift` | SpeechAnalyzer daemon (auto-compiled on first run) |
| `server/translator.swift` | Translation daemon (auto-compiled on first run) |
| `server/config.json` | Device configuration |
| `server/requirements.txt` | Python dependencies |

## config.json

```json
{
  "device": "",
  "loopback_device": "Loopback Audio"
}
```

- `device`: input device name (empty = system default microphone)
- `loopback_device`: device name used with the Loopback option

## Latency (MacBook Air M2)

| Component | Latency |
|-----------|---------|
| SpeechAnalyzer (ASR) | < 500ms, on-device |
| Translation.framework | < 100ms (if pack installed) |
| FoundationModels | ~500ms |
| **Total (FoundationModels path)** | ~1s |
