# JaSub — 使用說明

## CLI 版本

```bash
./run.sh
```

首次使用需建立 venv：
```bash
python3.13 -m venv .venv.nosync
.venv.nosync/bin/pip install -r server/requirements.txt
```

語言包安裝：**System Settings → General → Language & Region → Translation Languages**

---

## Menu Bar App（DMG）

下載：https://github.com/ultima6-tw/livesub-macos/releases/latest

安裝：
1. 開啟 DMG → 拖 JaSub.app 到 **Applications** → 退出 DMG
2. 從 Applications 啟動
3. 首次啟動：右鍵 → **打開**（繞過 Gatekeeper）

⚠️ 不要從 DMG 直接啟動，否則系統音訊授權會記錯路徑。

重新打包：
```bash
cd app && ./package.sh
```

打包完後清理 build 資料夾（約 660MB，在 iCloud 同步範圍內）：
```bash
rm -rf app/build/
```
