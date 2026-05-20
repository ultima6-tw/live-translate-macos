# JaSub — 即時會議翻譯（macOS）

## 開發機器
MacBook Air M2（16GB）、Mac Studio M1 Max（主力）

## 目前狀態
**完整運作中。** 全程 on-device，macOS 26 專屬。

兩個版本：
- **CLI 版本**（`server/`）：Python + Swift daemon，終端機運行
- **Menu Bar App**（`app/`）：SwiftUI，背景執行，浮動字幕視窗

GitHub repo：`ultima6-tw/livesub-macos`

## CLI 版本

### 使用方式

```bash
./run.sh   # 互動選單（語言 / 音源）
```

選單：
1. 語言（預設英文→中文）：英文→中文 / 日文→中文 / 中文→英文
2. 音源：動態列出所有輸入裝置，系統預設裝置標記 `(預設)`

### 架構

```
麥克風 / Loopback Audio / CATapDescription（全系統音訊 tap）
    ↓ sounddevice（Python）或 screencap.swift（IOProc）
    ↓ resample → 16kHz float32 mono（scipy）
    ↓ stdin pipe → asr.swift

asr.swift：SpeechAnalyzer + SpeechTranscriber（macOS 26+）
    ↓ ~text = partial，text = final

meeting.py 主迴圈：
    → is_hallucination() + 跨 segment 重複過濾
    → final 放入 _translate_q（single worker）

translator.swift daemon：
    ① Translation.framework（< 100ms，若語言包已裝）
    ② FoundationModels fallback（Apple Intelligence 3B，~500ms）
    → OpenCC s2twp（簡→臺灣繁體）→ rich Live 顯示
```

### 目錄結構

```
livesub-macos/
├── run.sh                  # 啟動腳本（互動選單 + venv）
├── server/
│   ├── meeting.py          # 主程式
│   ├── asr.swift           # SpeechAnalyzer daemon（swiftc 自動編譯）
│   ├── translator.swift    # Translation + FoundationModels daemon
│   ├── screencap.swift     # CATapDescription + IOProc 音訊 daemon
│   ├── config.json         # 裝置設定
│   └── requirements.txt
└── extension/              # 備用（瀏覽器字幕版，不維護）
```

### 首次啟動

```bash
python3.13 -m venv .venv.nosync
.venv.nosync/bin/pip install -r server/requirements.txt
./run.sh   # 首次自動編譯 asr.swift + translator.swift
```

### 技術決策

- **ASR 演進**：mlx_whisper → WhisperKit → SFSpeechRecognizer → **SpeechAnalyzer（macOS 26+）**
- **翻譯演進**：Ollama → Translation.framework + **FoundationModels fallback**
- **音訊捕捉**：AVAudioEngine / ScreenCaptureKit 在 macOS 26 不可靠 → **CATapDescription + IOProc**
- **瀏覽器音訊**：`screencap.swift` CATapDescription + IOProc（移除 ScreenCaptureKit 依賴）
- **FoundationModels guardrail**：三層 prompt 策略降低誤觸；context overflow 自動 reset session
- **iCloud**：`.venv.nosync` 直接用，不建 symlink（iCloud 會刪 broken symlink）

---

## Menu Bar App（app/）

### 架構

```
app/
├── project.yml             # xcodegen 設定（macOS only）
├── package.sh              # DMG 打包腳本
├── Sources/                # macOS 核心（含共用邏輯，iOS 用 #if os(macOS) 隔離）
│   ├── JaSubApp.swift      # macOS @main
│   ├── AppDelegate.swift   # NSApplicationDelegate
│   ├── MenuBarView.swift   # 選單列 popover UI
│   ├── SubtitleOverlayWindow.swift  # 浮動字幕 NSPanel
│   ├── AudioEngine.swift   # 麥克風 + CATapDescription 系統音訊
│   ├── ASRManager.swift    # SpeechAnalyzer + SpeechTranscriber
│   ├── TranslatorManager.swift      # Translation.framework + FoundationModels
│   ├── TranslationEngine.swift      # Pipeline 狀態管理
│   └── HallucinationFilter.swift
├── Resources/
│   ├── Info.plist          # LSUIElement=YES（無 Dock icon）
│   ├── JaSub.entitlements  # microphone + audio-input
│   └── zh-Hant.lproj/Localizable.strings
└── docs/                   # README 截圖
```

### 使用方式（DMG）

```bash
cd app && ./package.sh   # 輸出 dist/JaSub-<version>.dmg
```

安裝：DMG → 拖 JaSub.app 到 Applications → **退出 DMG** → 從 Applications 啟動 → 右鍵 → 打開

⚠️ **絕對不要從 DMG 或 build/ 直接啟動**：TCC 會記錄錯誤路徑，系統音訊授權失效。

### 技術細節

- **Pipeline**：AudioEngine → AsyncStream<[Float]> → ASRManager → onPartial/onFinal → TranslatorManager → @MainActor UI
- **字幕視窗**：NSPanel + `.floating` level + `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
- **系統音訊**：CATapDescription + AudioDeviceCreateIOProcID（IOProc）+ AVAudioConverter resample
- **語言包**：System Settings → General → Language & Region → Translation Languages
- **DMG 打包**：Release build（CODE_SIGNING_REQUIRED=NO）→ xattr -cr → ad-hoc codesign → hdiutil UDZO

### GitHub Release

- Repo：`ultima6-tw/livesub-macos`
- 最新：v0.2.0，`JaSub-0.2.0.dmg`（2026-05-20）

---

## 待辦事項

- [ ] FoundationModels guardrail 誤觸率觀察：長期使用後是否影響體驗
- [ ] app/ 系統音訊實機測試：選瀏覽器音訊 → Chrome YouTube → 辨識翻譯確認
- [ ] 推廣：讓更多人找到這個專案
