# JaSub 踩坑紀錄

> 給未來自己或 Claude 看的。記錄開發過程中踩過的每一個坑，避免重蹈覆轍。

---

## 一、為什麼最後選 SFSpeechRecognizer 而不是 WhisperKit

一開始用 WhisperKit（Apple CoreML + Neural Engine），理論上很快，實際上踩了一堆坑：

### 坑 1：WhisperKit POST body 不支援 `task` 參數
加了 `"task": "transcribe"` 之後，所有辨識結果全部回傳空字串，沒有任何錯誤訊息。
**解法**：移除 POST body 的 `task`，改用 `--task transcribe` 在啟動 CLI 時指定。

### 坑 2：語言漂移（日文輸入卻輸出英文）
不加任何 hint 時，Whisper 自動偵測語言，日文輸入常輸出英文。
嘗試加 `--use-prefill-prompt`，語言固定了，但帶來坑 3。

### 坑 3：`--use-prefill-prompt` 讓 Neural Engine 快取失效
每次請求都重新初始化 decoder，Neural Engine 的 KV cache 無效，延遲從 < 1s 變成 7-10s/段。
繞過方式：移除 `--use-prefill-prompt`，改用 per-request `"prompt": "。"` 暗示語言。
但即使如此，延遲仍然 4-10s，遠不如 SFSpeechRecognizer 的即時體感。

### 坑 4：積壓問題
WhisperKit 每段需 5-10s，但 VAD 每 0.3s 就會切出一段。queue 積壓速度 > 消化速度，
導致影片看到的內容要幾分鐘後才出現在字幕上。

### 根本原因
WhisperKit 是批次推理模型，設計上不適合「低延遲即時串流」情境。
SFSpeechRecognizer 是 Apple 專為即時語音辨識設計的 API，在這個情境完勝。
**下次遇到 macOS-only 即時語音辨識，先用 SFSpeechRecognizer，不要碰 Whisper 系列。**

---

## 二、macOS Translation.framework 的坑

### 坑 5：macOS 26 的 API 不同於網路範例
網路上的範例多用 `TranslationSession(configuration:)`，在 macOS 26 會編譯錯誤：
`extra argument 'configuration' in call`

**正確 API（macOS 26）**：
```swift
TranslationSession(installedSource: Locale.Language(identifier: src),
                   target: Locale.Language(identifier: tgt))
```

---

## 三、SFSpeechRecognizer 音訊捕捉的坑（macOS 26）

### 坑 6：AVAudioEngine + CoreAudio 對虛擬設備無效
用 `kAudioOutputUnitProperty_CurrentDevice` 設定 Loopback Audio，
API 回傳成功（`setInputDevice` 回傳 true），但 tap callback 從未被呼叫。
引擎有啟動，格式也正確（44100Hz ch=1），就是沒有音訊流過來。

### 坑 7：AVCaptureSession 也一樣無效
換成 `AVCaptureSession` + `AVCaptureAudioDataOutput`，
`captureOutput` delegate 方法從未被呼叫。
推測是 macOS 26 beta 改變了 AVFoundation 對虛擬音訊設備的行為。

**解法**：Python sounddevice（PortAudio）負責設備選擇與音訊捕捉，
resample 到 16kHz float32 後透過 subprocess stdin pipe 傳給 Swift。
Swift 只做辨識，不碰音訊硬體。

---

## 四、SFSpeechRecognizer 辨識的坑

### 坑 8：shouldReportPartialResults = false 在串流模式完全沒有輸出
以為設 false 讓辨識器「等到完整一句才輸出」，
實際上在 Loopback Audio 連續音訊的情境，辨識器永遠等不到「完整靜音」，
callback 從不觸發，完全沒有輸出。

**解法**：設 `shouldReportPartialResults = true`，callback 會在每個自然停頓點
以 `isFinal = false` 觸發，收到後重設靜音計時器，停頓 0.5s 後呼叫 `req.endAudio()`
強制產生 `isFinal = true`。

### 坑 9：串流模式需要手動呼叫 endAudio()
`SFSpeechAudioBufferRecognitionRequest` 在持續餵入音訊時，
辨識器永遠不會自動產生 `isFinal = true`，需要主動呼叫 `req.endAudio()`。
**文字穩定偵測**：partial result 文字 1.0s 沒有變化 → endAudio。這比音訊靜音偵測更準確——讓辨識器的語言模型決定句子何時結束，而不是我們自己看波形。最長 20s 強制結束（fallback）。isFinal 後立即 startRequest()，不加 delay，否則這段空白期間的音訊會流失。

**串流顯示設計**：asr.swift 輸出 `~text\n`（partial）和 `text\n`（final）兩種訊息。meeting.py 收到 partial 直接更新最後一行（in-place），收到 final 才觸發翻譯。這樣文字會在辨識過程中即時出現、持續更新，只有穩定後才送翻譯，避免翻到一半的句子。

### 坑 10：ARC 生命週期——ASRManager 被提早釋放
```swift
SFSpeechRecognizer.requestAuthorization { status in
    let mgr = try ASRManager(...)   // ← local variable
    mgr.start()
}
// callback 結束 → mgr 被 ARC 釋放
// [weak self] 變 nil → readStdin guard 提前 return
// RunLoop 失去 source → process 退出 → stdin pipe 斷掉
// Python 收到 Broken pipe [Errno 32]
```

**症狀**：log 看到 `audio_writer chunk #1`（音訊有流入），但幾秒後出現 `Broken pipe`，
Swift process 悄悄退出。

**解法**：全域宣告 `var globalMgr: ASRManager?`，在 callback 裡賦值，持住強引用。

### 坑 11：靜音觸發太快產生單字輸出
靜音偵測 0.5s 有時觸發得太快，切出「遅」「赤」這類單字，顯示怪異。
**解法**：`text.count >= 2` 過濾。

---

## 五、已知限制與工具邊界

### 歌曲辨識
片頭片尾等音樂場景，SpeechAnalyzer 在音樂背景下信心閾值偏高，部分歌詞可辨識、部分直接跳過（不會輸出亂碼）。這是合理行為——寧可漏字也不亂猜。

**根本原因**：SpeechAnalyzer 是針對語音訓練的，歌聲聲學特性（拉長音、顫音、音調變化）與自然語音差異大。要真正改善需要：① 人聲分離（Demucs）→ ② 歌聲專用 ASR（如 Whisper large），兩者都大幅增加延遲與複雜度，不在這個工具的定位內。

### 人名 / 專有名詞
動畫角色名（如フリーレン、ストレク）等專有名詞常被替換成音近的普通詞。

**根本原因**：SpeechAnalyzer 沒有 hot words / biasing API，無法預先給定名單偏向特定詞彙。Apple 目前未開放此功能。事後可做字典替換 post-processing，但動畫每部名稱不同，維護成本高，目前不實作。

---

## 六、架構選型教訓（歷史）

1. **先找 native API**：macOS-only 工具優先考慮 macOS 原生 API
   （SFSpeechRecognizer、Translation.framework）。這些 API 有硬體加速、
   不需模型下載、有系統級授權流程。

2. **批次推理模型 ≠ 即時串流**：Whisper 系列是批次模型，不適合即時字幕。
   SFSpeechRecognizer 是串流 API，天生適合這個情境。

3. **照著 PROJECT.md 走不一定對**：這次花了很多時間修 WhisperKit，
   才換 SFSpeechRecognizer。如果一開始評估「這個工具根本性地不適合這個情境」，
   可以省很多時間。

---

## 七、快速參考

### 啟動

```bash
# JaSub 根目錄執行
./run.sh
# 選單：語言（英文→中文 / 日文→中文 / 中文→英文）→ 音源（麥克風 / Loopback Audio）
```

### 翻譯語言包安裝（必做，首次使用）

**System Settings → General → Language & Region → Translation Languages**

選擇需要的語言對（如 Japanese ↔ Chinese），安裝完成後重啟 JaSub 即可使用 Translation.framework（< 100ms）。未安裝時自動 fallback 到 FoundationModels（~500ms）。

> macOS 26 移除了 Translate.app，語言包改由 System Settings 管理。

### 版面

```
┌──────────────────────────┐
│  English / Japanese      │  ← 原文（即時串流）
└──────────────────────────┘
┌──────────────────────────┐
│  中文                     │  ← 翻譯（Translation.framework < 100ms）
└──────────────────────────┘
```

### on-device 驗證
關 Wi-Fi，跑 `./run.sh` 選日文→中文，ASR 仍正常 → 完全 on-device 確認。

### Loopback Audio 裝置名稱
各機器可能不同，設定在 `config.json` 的 `loopback_device` 欄位。
啟動後 log 裡 `audio : [名稱]` 那行可確認實際使用的裝置。

### 手動停止殘留 process
```bash
pkill -f "asr"
pkill -f "translator"
```

---

## 七、macOS Menu Bar App（app/）

### 安裝

```bash
cd app
./package.sh          # 輸出 dist/JaSub-0.1.0.dmg
```

1. 開啟 DMG → 將 JaSub.app 拖入 Applications
2. 首次啟動：右鍵 → **打開**（繞過 GateKeeper）
3. 若提示「無法開啟」：系統設定 → 隱私與安全性 → 點「仍要打開」

### 使用方式

- **左鍵點選**選單列圖示 → 開啟設定 popover（語言、音源、字型大小）
- **右鍵點選**選單列圖示 → 快速選單（開始 / 停止 / 結束 JaSub）
- 執行中時圖示變**紅色**，提示可點擊停止

### 功能

| 功能 | 說明 |
|------|------|
| 來源語言 | 動態從 SFSpeechRecognizer 查詢支援語言，依系統語言顯示名稱 |
| 翻譯目標 | 動態查詢 Translation.framework 支援語言對，已安裝優先顯示 |
| 音源 | 麥克風（CoreAudio 動態列舉）或瀏覽器 / 系統音訊（CATapDescription + IOProc） |
| 字型大小 | 12–40pt Stepper，持久化到 UserDefaults |
| 顯示原文 | 可開關原文浮動視窗 |
| 自動記錄 | 開始時自動建立 `~/Documents/JaSub/YYYY-MM-DD HH-mm.txt`，每句即時寫入 |
| 記錄資料夾 | 開啟 `~/Documents/JaSub`（Finder） |

### 系統音訊（瀏覽器 / YouTube 等）

選「瀏覽器 / 系統音訊」需要**螢幕錄製**權限：  
系統設定 → 隱私與安全性 → 螢幕錄製 → 勾選 JaSub

### 翻譯語言包安裝（必做）

**系統設定 → 一般 → 語言與地區 → 翻譯語言** → 安裝需要的語言
