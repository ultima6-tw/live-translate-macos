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

# 第二層：音源
echo "音源："
echo "  1) 麥克風"
echo "  2) Loopback Audio"
echo -n "選擇 [1]: "
read src_choice
case "${src_choice:-1}" in
  2) SRC_ARGS=(-l) ;;
  *) SRC_ARGS=() ;;
esac

python3 meeting.py "${SRC_ARGS[@]}" "${MODE_ARGS[@]}" "$@"
