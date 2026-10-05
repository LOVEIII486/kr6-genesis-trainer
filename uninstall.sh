#!/bin/bash
# kr6-trainer 卸载器（macOS）。终端里直接跑本脚本，或双击 Uninstall.command。
cd "$(dirname "$0")" || exit 1

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
  echo "错误：找不到 Python 3。"
  echo "可以直接手动删除存档目录里的：all/director.lua、_kr6trainer.lua、_orig/、_kr6_*.txt"
  exit 1
fi

"$PY" uninstall.py "$@"