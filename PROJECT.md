# JaSub — 即時會議翻譯

## 開發機器
MacBook Air M2（16GB）、Mac Studio M1 Max（主力）

## 目前狀態
**完整運作中。** 全程 on-device，macOS 26 專屬。

- **ASR**：SpeechAnalyzer + SpeechTranscriber（Speech.framework，macOS 26+）
- **翻譯**：Translation.framework（主路徑，< 100ms）→ FoundationModels（Apple Intelligence 3B，fallback）
- **語言包**：System Settings → General → Language & Region → Translation Languages 安裝後生效
- **模式**：翻譯模式（2 panel）；對話模式（4 panel）程式碼保留，選單暫時隱藏
- **音源**：麥克風、Loopback Audio（Rogue Amoeba）、或 CATapDescription + IOProc（瀏覽器音訊，免虛擬設備）

WhisperKit、SFSpeechRecognizer、Ollama、silero-vad、torch 已全部移除。
server.py（瀏覽器字幕版）不維護，目前無需求。

## 使用方式

```bash
./run.sh   # 互動選單（語言 / 音源）
```

**選單結構：**
1. **語言**（預設 1）：1) 英文→中文 / 2) 日文→中文 / 3) 中文→英文
2. **音源**：動態列出所有輸入裝置，系統預設裝置標記 `(預設)` 並作為預設選項

## 架構

```
麥克風 / Loopback Audio / CATapDescription（全系統音訊 tap）
    ↓ sounddevice（Python，native rate）或 screencap.swift（48kHz float32 mono IOProc）
    ↓ resample → 16kHz float32 mono（scipy）
    ↓ stdin pipe → asr.swift × N（1 個或 2 個）

asr.swift：SpeechAnalyzer + SpeechTranscriber（macOS 26+）
    ↓ stdout：~text = partial，text = final

meeting.py 主迴圈：
    [pair 模式] 跨 ASR 雜訊過濾 + mutual suppression（2.5s）
    → is_hallucination() + 跨 segment 重複過濾
    → partial：直接更新最後一行（in-place）
    → final：放入 _translate_q（single worker）

translator.swift daemon：
    ① Translation.framework（installedSource，< 100ms，若語言包已裝）
    ② FoundationModels fallback（Apple Intelligence 3B，~500ms）
       - primary prompt → guardrail 觸發 → completion-style fallback → 仍觸發 → ⚠ 原文
    → OpenCC s2twp（簡→臺灣繁體）→ 顯示

rich Live 顯示：
    對話模式（--pair）：p1 EN/JA 原文 | p2 →中文 | p3 中文原文 | p4 →EN/JA
    翻譯模式（--lang）：p1 原文 | p3 翻譯
    sliding window：最近 n 行（n = max(3, height/4-2) 或 height/2-2）
```

## 目錄結構

```
JaSub/
├── run.sh                  # 啟動腳本（三層選單 + 啟動 venv）
├── server/
│   ├── meeting.py          # 主程式
│   ├── asr.swift           # SpeechAnalyzer daemon（swiftc 自動編譯）
│   ├── translator.swift    # Translation + FoundationModels daemon（swiftc 自動編譯）
│   ├── screencap.swift     # CATapDescription + IOProc 音訊 daemon（swiftc 自動編譯，--screencap 模式）
│   ├── config.json         # 裝置設定
│   ├── requirements.txt
│   ├── server.py           # 瀏覽器字幕版（不維護）
│   └── ...
└── extension/              # 備用
```

## config.json

```json
{
  "device": "",                          // 預設輸入裝置（空 = 系統預設麥克風）
  "loopback_device": "Loopback Audio"    // -l flag 使用的裝置名稱
}
```

## 首次啟動

```bash
# 各機器各建一次 venv
python3.13 -m venv .venv.nosync
.venv.nosync/bin/pip install -r server/requirements.txt

# 執行（首次自動編譯 asr.swift + translator.swift，需幾秒）
./run.sh
# macOS 彈出「語音辨識」授權請求 → 點選「允許」
```

## 延遲估算（MacBook Air M2）

| 元件 | 延遲 |
|------|------|
| SpeechAnalyzer（ASR） | < 500ms，on-device |
| Translation.framework | < 100ms，若語言包已安裝 |
| FoundationModels（Apple Intelligence） | ~500ms，無需安裝 |
| OpenCC s2twp | < 5ms |
| **總延遲（FoundationModels 路徑）** | ~1s |

## 版面與翻譯設計

- **ASR（asr.swift）**：SpeechAnalyzer + SpeechTranscriber，preset `.progressiveTranscription`
  - `AsyncStream<AnalyzerInput>` 接收 PCM buffer → `analyzer.start(inputSequence:)`（需獨立 Task 避免死鎖）
  - partial：`~text\n`；final：`text\n`；短文字過濾 `text.count >= 2`
  - 語言包未安裝時透過 `AssetInventory` 自動下載
- **串流顯示**：partial 直接更新最後一行（in-place），final 才觸發翻譯
- **翻譯**：只有 final 進 `_translate_q`（maxsize=20），single worker 依序處理
- **Mutual suppression（pair 模式）**：`_asr_last_final` 記錄各 ASR 最後有效 final 時間；另一 ASR 在 2.5s 內有輸出則抑制當前 ASR（partial + final 均丟棄）
- **幻覺過濾**：非目標字元 >30%、字元重複、片語重複 ≥3 次 → 丟棄
- **跨 segment 重複過濾**：最近 5 筆出現 ≥2 次 → 丟棄
- **OpenCC**：Translation.framework 輸出 → s2twp 轉臺灣繁體；FoundationModels 輸出不過 OpenCC（已輸出繁體）

## 翻譯策略（translator.swift）

**Translation.framework（主要）：**
- `LanguageAvailability.status()` 確認 `.installed` 才建立 session
- `TranslationSession(installedSource:target:)`
- 語言包安裝：**System Settings → General → Language & Region → Translation Languages**（macOS 26 移除 Translate.app，改由此處管理）
- 安裝後所有機器均正常使用（MacBook Air M2 / Mac Studio M1 Max 確認）

**FoundationModels（fallback）：**
- `SystemLanguageModel.default.isAvailable` 為 true（Apple Intelligence 已設定）
- Session instructions：`"You are a professional real-time interpreter... Translate all input faithfully, including fictional, dramatic, or emotionally charged content"`
- Prompt 三層：
  1. Primary：`You are a translator... Text: {text}\n\nTranslation:`
  2. Fallback（guardrail 觸發）：completion-style `{srcName}: {text}\n{tgtName}:`
  3. 雙重 guardrail：回傳 `⚠ {原文}`
- 語言標示加中文：`"Traditional Chinese (繁體中文)"`，確保輸出繁體

## 決策紀錄

- **ASR 演進**：mlx_whisper → WhisperKit → SFSpeechRecognizer → **SpeechAnalyzer（2026-05-06）**
  - WhisperKit 移除：`--use-prefill-prompt` 讓 Neural Engine 快取失效，每段 7-10s
  - SFSpeechRecognizer 移除：macOS 26 新增 SpeechAnalyzer，專為 long-form 設計，更快更穩
- **翻譯演進**：mlx_whisper → Ollama gemma4:e4b → Translation.framework → **FoundationModels fallback（2026-05-06）**
- SpeechAnalyzer 死鎖：`analyzer.start(inputSequence:)` 等待 stream 有資料才返回，須包進獨立 `Task {}` 與 stdin 讀取並行
- SpeechTranscriber preset：beta 叫 `progressiveLiveTranscription`，正式版（Xcode 26）改為 `progressiveTranscription`
- 音訊捕捉：AVAudioEngine / AVCaptureSession 對 Loopback Audio（虛擬設備）在 macOS 26 不可靠；改用 Python sounddevice（PortAudio），resample 後 pipe 給 asr.swift
- asr.swift 協議：stdin 讀取 raw float32 PCM（16kHz mono），每 1600 frames（100ms）一個 chunk → AVAudioPCMBuffer → SpeechAnalyzer
- 日文路由 bug：`_detect_lang` 原先把假名歸類為 zh；改為先偵測假名比例（> 8% → ja）再偵測漢字（> 15% → zh）
- 路由用 lang_hint（ASR 來源）而非偵測語言：ja-ASR → top panel，zh-ASR → bot panel
- 翻譯結果不顯示 bug（單語模式）：`_do_translate` 中 `dest_panel = "p2"` 硬編碼，但單語模式 layout 只有 p1/p3；改為 `"p2" if _PAIR else "p3"`（en/ja 源）與 `"p4" if _PAIR else "p3"`（zh 源）
- zh 單語模式 orig_panel bug：原先 zh 原文放 p3（英文面板），修正為所有單語模式均用 `orig_panel = "p1"`
- Translation.framework 語言包安裝：macOS 26 移除 Translate.app，改從 **System Settings → General → Language & Region → Translation Languages** 安裝；安裝後 CLI app 即可正常使用 Translation.framework（< 100ms）
- FoundationModels guardrail：奇幻/負面情緒內容觸發 `guardrailViolation`（如「魔力を消して」），無法關閉，用 completion-style fallback + instructions 降低誤觸
- FoundationModels context overflow：session 累積所有對話歷史，長時間使用後 4096 token 爆掉 → 翻譯 EMPTY；偵測 `exceededContextWindowSize` 錯誤字串，自動重建 session 並重試當前請求
- 原文最後一行視覺問題：面板滿時新 partial 貼在底部邊緣，難以看到文字出現；解法：`_render_lines()` 在 `len >= n-1` 時改顯示 `n-2` 行並補 2 行空白，新文字出現在倒數第三行
- 音源選單動態化：原先固定 2 選項（麥克風 / Loopback Audio），改為 `run.sh` 用 Python 列出所有 sounddevice 輸入裝置，系統預設裝置標記 `(預設)` 並設為預設選項，以 `--device "name"` 傳給 `meeting.py`；`-l` flag 保留做 backward compat
- 瀏覽器音訊擷取演進（2026-05-14）：
  - ScreenCaptureKit 嘗試：SCStream `.audio` callback 在 macOS 26.4.1 上始終 0 bytes（video=OK、audio=0），原因不明（Loopback system extension 干擾或 API 行為改變）
  - CATapDescription（CoreAudio）：`AudioHardwareCreateProcessTap`（isExclusive=true, processes=[]）→ 全局 tap；aggregate device → 成功
  - AVAudioEngine / AudioQueue 均無 callback（分別返回成功但 0 bytes / -66628 錯誤）
  - **解法**：最低層 `AudioDeviceCreateIOProcID` + `AudioDeviceStart` 直接從 aggregate device 讀，確認有 callback（~186/2s，48kHz mono float32）
  - `screencap.swift` 完全改用 CATapDescription + IOProc（移除 ScreenCaptureKit 依賴），輸出 48kHz mono float32 PCM，stderr 輸出 `SAMPLERATE:48000`
  - `meeting.py._start_screencap`：等待 `SAMPLERATE:` 行確定 native rate，不再硬碼 16000；`_screencap_reader` chunk 改為 `native_rate/10 * 4` bytes（100ms），`_audio_writer` 統一處理 resample
- 英文原文底部 margin 失效（2026-05-17）：`_render_lines` 原本用 deque 項目數判斷是否留 margin，但英文句子較長會 wrap 成多行，導致面板已滿但條件未觸發，新文字貼底看不到。改為計算**實際視覺行數**（`vlen`，CJK 雙寬字元各算 2 cols），並將 `panel_width` 從 `render()` 傳入（`console.size.width - 4`）。日文句短幾乎不 wrap，所以此問題只在英文明顯。
- iCloud 會刪 .venv symlink，一律直接用 `.venv.nosync`，不建 symlink
- macOS 26 + Python 3.14 + sounddevice 多進程同時用麥克風會 SIGSEGV crash，確保只有一個進程

## 已知限制（工具邊界）

- **歌曲辨識**：SpeechAnalyzer 針對語音設計，音樂背景下信心閾值自然偏高，部分歌詞可辨識但會有漏失。人聲分離（Demucs）+ 歌聲 ASR 理論上可改善，但延遲與複雜度大幅上升，目前不實作。片頭片尾非主要使用情境，接受此限制。
- **人名 / 專有名詞**：SpeechAnalyzer 無 hot words API，無法預先指定名單；動畫角色名、人名容易被替換成音近普通詞。Apple 目前未開放此功能，無解法。

## 使用的工具

| 工具 | 說明 |
|------|------|
| sounddevice（PortAudio） | 音訊輸入，支援虛擬設備；Python 層處理 |
| scipy.signal.resample_poly | 重採樣到 16kHz |
| SpeechAnalyzer + SpeechTranscriber | ASR（macOS 26+），asr.swift daemon，自動編譯 |
| Translation.framework | on-device 翻譯（< 100ms），需語言包預裝 |
| FoundationModels.framework | Apple Intelligence 本地 3B LLM，翻譯 fallback |
| opencc（s2twp） | 簡→臺灣繁體後處理 |
| rich（Live + Layout + Panel） | 終端機分割視窗，sliding window 顯示 |

## app/ — macOS Menu Bar App（進行中）

原始 CLI 版本（`server/`）維持不動，`app/` 是獨立的 SwiftUI menu bar app 版本。

### 架構

```
app/
├── setup.sh                  ← brew install xcodegen && xcodegen generate
├── project.yml               ← xcodegen 設定
├── Sources/
│   ├── JaSubApp.swift        ← @main，Settings scene
│   ├── AppDelegate.swift     ← @MainActor，NSStatusItem + NSPopover + SubtitleOverlayWindow
│   ├── TranslationEngine.swift ← @MainActor ObservableObject 共享狀態，CoreAudio 裝置列舉
│   ├── MenuBarView.swift     ← 語言 / 音源選擇 + 開始停止
│   └── SubtitleOverlayWindow.swift ← NSPanel floating，isMovableByWindowBackground，SubtitleView
├── Resources/
│   ├── Info.plist            ← LSUIElement=YES，Usage description
│   └── JaSub.entitlements   ← microphone + audio-input
```

### 技術決策

- **Swift 6 strict concurrency**：AppDelegate 標 `@MainActor`，解決 `@objc` method 存取 AppKit UI 的 race
- **裝置列舉**：CoreAudio `AudioObjectGetPropertyData`，比 `AVCaptureDevice` 更完整，可正確過濾 input-only 裝置
- **字幕視窗**：`NSPanel` + `isMovableByWindowBackground = true`，`level = .floating`，`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
- **SourceKit 誤報**：xcodegen 生成前 SourceKit 看不到 module scope，實際 `xcodebuild` BUILD SUCCEEDED
- **xcodegen**：`project.yml` 管理，`setup.sh` 自動安裝並生成 `.xcodeproj`；`.xcodeproj` 不進 git

### 技術細節補充

- **Idle 時的可見性**：SubtitleView 原先在無文字時 opacity=0.3，貼著深色背景看不到。改為顯示佔位文字（`engine.isRunning ? "聆聽中…" : "JaSub · 點選選單列圖示開始"`）並加淡白色 border，讓使用者看得到視窗位置並可拖移。
- **多螢幕座標**：外接 ASUS（1920pt wide）放在 MacBook 左側，built-in 的 `visibleFrame.minX ≈ 1920`。字幕視窗正確出現在 built-in 螢幕底部。
- **NSPanel 高度收縮**：SwiftUI `NSHostingView` 會根據內容自動調整 window 大小；加 `minHeight: 50` 並移除 idle opacity 折疊，確保視窗有固定最小高度。

### 目前狀態（Phase 2 完成，待實機測試）

- [x] Menu bar icon（captions.bubble.fill）
- [x] Popover：語言選擇、音源選擇（CoreAudio 動態列舉 + 系統音訊 toggle）、開始/停止、結束
- [x] 浮動字幕視窗（NSPanel，底部置中，可拖移，半透明黑底）
- [x] Idle 佔位文字：「JaSub · 點選選單列圖示開始」，有淡邊框，讓視窗可見可拖
- [x] AudioEngine.swift：AVAudioEngine 麥克風捕捉，16kHz mono float32，AsyncStream 輸出
- [x] ASRManager.swift：SpeechAnalyzer + SpeechTranscriber，三個 Task 並行（防死鎖），自動下載語言模型
- [x] TranslatorManager.swift：Translation.framework 主路徑 + FoundationModels fallback，guardrail 雙 prompt 策略，context overflow 自動 reset
- [x] HallucinationFilter.swift：從 meeting.py 移植，非目標字元過濾 + 重複過濾
- [x] TranslationEngine.start()/stop()：完整 pipeline 接線（AudioEngine → ASRManager → TranslatorManager → UI）
- [x] 捲動歷史顯示：`originalHistory`/`translatedHistory`（各 max 20 筆）+ `originalPartial`（live ASR），ScrollViewReader 自動捲到底部
- [x] BUILD SUCCEEDED（Swift 6，macOS 26 target，0 error / 0 warning）

### 語言選擇設計（Phase 1 補充）

- **UI 結構**：來源語言（SpeechAnalyzer）和翻譯目標（Translation.framework）分成兩個獨立 Picker，不合併成語言對
- **音源 Picker**：輸入裝置（CoreAudio 動態列舉）與「瀏覽器 / 系統音訊」合併為單一 Picker，分兩個 Section；移除原 Toggle checkbox 設計（checkbox 語意不直覺）；系統音訊選項標記「即將推出」，選取時 Start 按鈕 disabled；sentinel `TranslationEngine.systemAudioID = "__system_audio__"`
- **兩個獨立浮動視窗**：原文（可開關）與翻譯（固定顯示）分離，皆可拖移 + 可調大小；AppDelegate 用 Combine sink 觀察 `engine.showOriginal` 控制原文視窗；MenuBarView 加「顯示原文」checkbox；初始位置：翻譯在螢幕底部，原文在翻譯上方 8pt
- **resize 實作**：`.titled` + `titlebarAppearsTransparent = true` + `titleVisibility = .hidden` + 隱藏 traffic lights → macOS 原生邊緣/角落 resize；`NSHostingView.sizingOptions = []` 解除 SwiftUI ideal height 鎖定（否則只能左右 resize）；SwiftUI view 用 `maxHeight: .infinity` 填滿調整後的視窗；factory functions 標 `@MainActor` 避免 Swift 6 data race error
- **捲動歷史**：`originalHistory: [String]`（completed）+ `originalPartial: String`（live partial）+ `translatedHistory: [String]`；各 max 20 筆（FIFO）；`ScrollViewReader` + `onChange` 自動捲到底；partial 白色全亮，history 白色 70% 透明；翻譯最新一筆 yellow 全亮，舊句 55% 透明
- **來源語言**：12 個固定選項（SpeechAnalyzer 已知支援語言），靜態清單不需查詢
- **翻譯目標**：19 個候選，選定來源後動態查詢 `LanguageAvailability.status(from:to:)`，`.unsupported` 過濾，`.installed` 排前面，`.supported` 顯示「↓」並提示安裝路徑
- **來源切換觸發**：Combine `$selectedSrcID.dropFirst().sink` → `Task { await refreshTargets(for:) }`，目標清單自動更新且保留原選擇（若仍有效）
- **資料模型**：`SourceLanguage`（id + name）、`TargetLanguage`（id + name + isInstalled），locale 字串直接存，只在 `LanguageAvailability` 呼叫時建 `Locale.Language`
- **編譯問題**：`Locale.Language` 沒有 `.identifier` 直接屬性，改為 struct 內只存字串

### Phase 2 技術決策

- **Pipeline 架構**：`AudioEngine`（sync）→ `AsyncStream<[Float]>`（16kHz）→ `ASRManager`（actor）→ `onPartial`/`onFinal` callback → `TranslatorManager`（actor）→ `@MainActor` UI 更新
- **[Float] 跨 actor 邊界**：AudioEngine tap callback 內直接萃取 `[Float]`（Sendable），避免傳遞 `AVAudioPCMBuffer`（non-Sendable）
- **ASRManager callback setter**：actor 的 stored property 不可從外部直接賦值，改為 `setOnPartial(_:)` / `setOnFinal(_:)` 方法，Swift 6 strict concurrency 相容
- **Translation.framework Swift 6 修正**：`LanguageAvailability`、`TranslationSession` 均為 non-Sendable，加 `@preconcurrency import Translation` 抑制 actor isolation data race error
- **翻譯來源碼映射**：ASR locale（`"zh-TW"`）→ Translation source（`"zh-Hant"`）透過 `translationSrcCode(for:)` helper；其餘語言取前 2 字元
- **stop() 清理順序**：先停 AudioEngine tap → finish sampleStream continuation → cancel pipelineTask → 非同步 await asr.stop()（防 ASRManager 殘留 Task 仍在消耗資源）

### 系統音訊技術細節

`AudioEngine.startSystemAudio()` 實作：
1. `CATapDescription()`（isMono / isPrivate / isExclusive）→ `AudioHardwareCreateProcessTap` → tapID
2. `AudioHardwareCreateAggregateDevice`（private、tap list = tapDesc.uuid）→ agDevID
3. 查詢 `kAudioDevicePropertyNominalSampleRate`（通常 48 kHz）
4. 建立 `SystemAudioContext`（持有 AVAudioConverter、Task.detached 背景 resample）
5. `AudioDeviceCreateIOProcID` + `AudioDeviceStart`，clientData = Unmanaged-retained context pointer
6. IOProc（C-compatible top-level func）：raw float32 → context.feed() → rawContinuation.yield()
7. 背景 Task：每 100ms 一個 chunk → AVAudioConverter → 16 kHz → mainCont.yield()
8. stop()：DeviceStop → DestroyIOProcID → DestroyAggregateDevice → DestroyProcessTap → context.finish()

注意事項：
- 需要 Screen Recording 系統權限
- `TranslationEngine.start()` 在 @MainActor 上先呼叫 `CGPreflightScreenCaptureAccess()` + `CGRequestScreenCaptureAccess()`（需在 main thread），若未授權則設 `startError` 並 return
- `startError: String?` @Published，MenuBarView 在開始按鈕上方顯示橘色提示
- Ad-hoc 簽名（`CODE_SIGNING_IDENTITY: "-"`）：讓 TCC 能用 bundle ID 識別 app，permission dialog 才能正常出現；每次 rebuild 不需重新授權
- `@unchecked Sendable` class `Once` 解決 AVAudioConverter inputBlock @Sendable 的 captured var warning
- AVAudioEngine + aggregate device 在 macOS 26 不可靠（0 bytes），確認用 IOProc 直接讀
- `@preconcurrency import AVFoundation` 抑制 AVAudioPCMBuffer non-Sendable 警告
- `NSScreenCaptureUsageDescription` 已加入 Info.plist（TCC dialog 用）

### DMG 打包

```bash
cd app && ./package.sh   # 輸出 dist/JaSub-<version>.dmg
```

流程：
1. Release build（CODE_SIGNING_REQUIRED=NO，繞過 iCloud xattr 問題）
2. `xattr -cr` 清 extended attributes（iCloud 同步資料夾的檔案帶有 xattrs，codesign 會拒絕）
3. `codesign -s - --force --deep --entitlements` 手動 ad-hoc 簽名
4. `hdiutil create -format UDZO` 建立壓縮 DMG（含 Applications symlink）

收件人安裝方式：開啟 DMG → 拖 app 到 Applications → 右鍵 → 打開（繞過 GateKeeper）

### Phase 3（下一步）

- [ ] 實機測試：開啟 app → 選語言 → 按開始 → 說話確認字幕
- [ ] 系統音訊實機測試：選「瀏覽器 / 系統音訊」→ 播 Chrome YouTube → 確認辨識翻譯
- [ ] OpenCC：s2twp 簡→臺灣繁體（Translation.framework 輸出後處理）

---

## 待辦事項

- [x] ASR 換 SpeechAnalyzer（macOS 26+，2026-05-06）
- [x] 雙語對話模式（--pair en-zh / ja-zh，2026-05-06）
- [x] Mutual suppression（pair 模式，2.5s 視窗，2026-05-06）
- [x] 翻譯修復：FoundationModels fallback（2026-05-06）
- [x] run.sh 三層選單（模式 / 語言 / 音源，預設翻譯模式英文→中文，2026-05-06）
- [x] 翻譯結果不顯示修正（單語模式 panel 路由，2026-05-06）
- [x] Dead code 清理 + run.sh 隱藏對話模式 + README / .gitignore 建立（2026-05-06）
- [x] GitHub 發布（ultima6-tw/live-translate-macos，2026-05-06）
- [x] FoundationModels context overflow 自動 reset session（2026-05-06）
- [x] Translation.framework 語言包安裝路徑確認（System Settings，2026-05-06）
- [ ] FoundationModels guardrail 誤觸率觀察：長期使用後是否影響體驗
- [x] 瀏覽器音訊捕捉：CATapDescription + IOProc（取代 ScreenCaptureKit，2026-05-14）
- [x] 實機測試：`./run.sh` 選「瀏覽器音訊」，確認 Chrome YouTube 音訊正常辨識翻譯（2026-05-14，Loopback 開著兩個音源都可選）
- [x] app/ Phase 2：AudioEngine + ASRManager + TranslatorManager + HallucinationFilter 接線完成，BUILD SUCCEEDED（2026-05-17）
- [x] app/ 捲動歷史字幕：originalHistory + translatedHistory（各 max 20），ScrollView 自動捲底（2026-05-17）
- [x] app/ 系統音訊：CATapDescription + IOProc，背景 resample，AudioEngine.startSystemAudio() 完成，BUILD 0 error 0 warning（2026-05-17）
- [x] app/ Screen Recording 權限流程：CGRequestScreenCaptureAccess() + startError UI 提示 + ad-hoc 簽名（2026-05-17）
- [x] app/ DMG 打包：package.sh 一鍵 Release build + xattr 清除 + ad-hoc 簽名 + 壓縮 DMG，376K（2026-05-17）
- [x] app/ 字型大小調整：translationFontSize（12–40pt，step 2），UserDefaults 持久化，原文 × 0.7 等比縮放，MenuBarView Stepper（2026-05-17）
- [x] app/ 自動記錄：start() 建立 ~/Documents/JaSub/YYYY-MM-DD HH-mm.txt，每句 final 即時 append，stop() 關閉；currentLogURL @Published（2026-05-17）
- [x] app/ 記錄 UI：MenuBarView 顯示錄製中紅點 + 檔名 + 資料夾按鈕；「記錄資料夾」按鈕開啟 ~/Documents/JaSub（取代舊版「匯出原文」）（2026-05-17）
- [x] app/ 執行中 icon 變色：isRunning 時選單列圖示變紅色（bubble.fill + tintColor = .systemRed），讓使用者知道可以點擊停止（2026-05-17）
- [x] app/ 右鍵選單：icon 右鍵顯示「停止/開始」+「結束 JaSub」，不需開 popover 即可停止（2026-05-17）
- [x] app/ 來源語言動態查詢：改用 SFSpeechRecognizer.supportedLocales()，移除硬編碼清單（2026-05-17）
- [x] app/ 語言名稱跟隨系統語言：來源與目標語言名稱改用 Locale.current.localizedString(forIdentifier:)，自動顯示繁中/英文等（2026-05-17）
- [ ] app/ 實機測試：說話 → 字幕顯示 → 記錄檔確認
- [ ] app/ 系統音訊實機測試：選瀏覽器音訊 → Chrome YouTube → 辨識翻譯確認
- [ ] app/ re-run package.sh 打包含新功能的 DMG
