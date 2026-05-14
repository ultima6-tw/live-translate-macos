#!/bin/zsh
cd "$(dirname "$0")/server"

# Python 環境檢查與自動建立 venv
if command -v python3.13 &>/dev/null; then
    PYTHON_CMD=python3.13
elif command -v python3 &>/dev/null; then
    PYTHON_CMD=python3
else
    echo "錯誤：找不到 python3，請先安裝 Python 3.13+"
    echo "  brew install python@3.13"
    exit 1
fi

if [[ ! -f ../.venv.nosync/bin/activate ]]; then
    echo "首次執行：建立虛擬環境（需要一點時間）..."
    $PYTHON_CMD -m venv ../.venv.nosync || { echo "錯誤：venv 建立失敗"; exit 1; }
    echo "安裝 Python 套件..."
    ../.venv.nosync/bin/pip install -q -r requirements.txt || { echo "錯誤：套件安裝失敗"; exit 1; }
    echo "完成。"
    echo ""
fi
source ../.venv.nosync/bin/activate

# 環境偵測
MACOS_VER=$(sw_vers -productVersion)
XCODE_VER=$(xcodebuild -version 2>/dev/null | head -1)
SWIFT_VER=$(swiftc --version 2>/dev/null | grep -oE 'Swift version [0-9.]+')
echo "環境：macOS $MACOS_VER | ${XCODE_VER:-Xcode 未安裝} | ${SWIFT_VER:-swiftc 未找到}"
if [[ -z "$SWIFT_VER" ]]; then
  echo "錯誤：找不到 swiftc，請安裝 Xcode 或 Command Line Tools"
  exit 1
fi
echo ""

# 語言
echo "語言："
echo "  1) 英文 → 中文"
echo "  2) 日文 → 中文"
echo "  3) 中文 → 英文"
echo -n "選擇 [1]: "
read lang_choice
case "${lang_choice:-1}" in
  2) MODE_ARGS=(--lang ja) ;;
  3) MODE_ARGS=(--lang zh) ;;
  *) MODE_ARGS=(--lang en) ;;
esac

# 音源（動態列出）
echo "音源："
AUDIO_RESULT=$(python3 -c "
import sounddevice as sd, sys

devs = [d for d in sd.query_devices() if d['max_input_channels'] > 0]
if not devs:
    sys.exit(1)

try:
    default_name = sd.query_devices(sd.default.device[0])['name']
except Exception:
    default_name = ''

default_choice = 1
print('  0) 瀏覽器音訊 (Chrome)', file=sys.stderr)
for i, d in enumerate(devs, 1):
    marker = ' (預設)' if d['name'] == default_name else ''
    print(f'  {i}) {d[\"name\"]}{marker}', file=sys.stderr)
    if d['name'] == default_name:
        default_choice = i

sys.stderr.write(f'選擇 [0=瀏覽器, {default_choice}]: ')
sys.stderr.flush()

try:
    inp = input().strip()
    if inp == '0':
        print('SCREENCAP')
        sys.exit(0)
    choice = int(inp) - 1 if inp else default_choice - 1
except Exception:
    choice = default_choice - 1

idx = max(0, min(choice, len(devs) - 1))
print('DEVICE:' + devs[idx]['name'])
")

if [[ "$AUDIO_RESULT" == "SCREENCAP" ]]; then
    # CATapDescription + AudioDeviceIOProc requires macOS 14.2+ (Sonoma)
    _mac_major=${MACOS_VER%%.*}
    _mac_minor=${${MACOS_VER#*.}%%.*}
    if (( _mac_major < 14 || (_mac_major == 14 && _mac_minor < 2) )); then
        echo "錯誤：瀏覽器音訊需要 macOS 14.2+（Sonoma），目前 $MACOS_VER"
        exit 1
    fi
    if [[ -z "$XCODE_VER" ]]; then
        echo "警告：未偵測到 Xcode，若編譯失敗請安裝 Xcode 15.2+"
    else
        _xcode_num=$(echo "$XCODE_VER" | grep -oE '[0-9]+\.[0-9]+' | head -1)
        _xcode_major=${_xcode_num%%.*}
        _xcode_minor=${_xcode_num#*.}
        if (( _xcode_major < 15 || (_xcode_major == 15 && _xcode_minor < 2) )); then
            echo "警告：建議 Xcode 15.2+（目前 $_xcode_num），CATapDescription SDK 支援較完整"
        fi
    fi
    python3 meeting.py --screencap "Google Chrome" "${MODE_ARGS[@]}" "$@"
else
    DEVICE_NAME="${AUDIO_RESULT#DEVICE:}"
    python3 meeting.py --device "$DEVICE_NAME" "${MODE_ARGS[@]}" "$@"
fi
