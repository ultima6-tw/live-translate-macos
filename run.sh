#!/bin/zsh
cd "$(dirname "$0")/server"
source ../.venv.nosync/bin/activate

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
DEVICE_NAME=$(python3 -c "
import sounddevice as sd, sys

devs = [d for d in sd.query_devices() if d['max_input_channels'] > 0]
if not devs:
    sys.exit(1)

try:
    default_name = sd.query_devices(sd.default.device[0])['name']
except Exception:
    default_name = ''

default_choice = 1
for i, d in enumerate(devs, 1):
    marker = ' (預設)' if d['name'] == default_name else ''
    print(f'  {i}) {d[\"name\"]}{marker}', file=sys.stderr)
    if d['name'] == default_name:
        default_choice = i

sys.stderr.write(f'選擇 [{default_choice}]: ')
sys.stderr.flush()

try:
    inp = input().strip()
    choice = int(inp) - 1 if inp else default_choice - 1
except Exception:
    choice = default_choice - 1

idx = max(0, min(choice, len(devs) - 1))
print(devs[idx]['name'])
")

python3 meeting.py --device "$DEVICE_NAME" "${MODE_ARGS[@]}" "$@"
