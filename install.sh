#!/bin/bash
# kr6-trainer 安装器（macOS）。终端里直接跑本脚本，或双击 Install.command。
# 纯标准库，macOS 自带 python3；找不到就报错并停在这里。
cd "$(dirname "$0")" || exit 1

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
  echo "错误：找不到 Python 3（macOS 自带 python3，正常情况下不会走到这）。"
  exit 1
fi

"$PY" install.py "$@"