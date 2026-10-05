#!/bin/bash
# install.command —— macOS 双击安装入口。
# 结束后保持窗口打开（直接执行的话窗口会立刻关闭，玩家看不到结果）。
cd "$(dirname "$0")" || exit 1
bash install.sh
echo
read -r -p "按回车键退出..." _