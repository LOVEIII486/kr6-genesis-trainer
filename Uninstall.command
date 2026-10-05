#!/bin/bash
# uninstall.command —— macOS 双击卸载入口。
cd "$(dirname "$0")" || exit 1
bash uninstall.sh
echo
read -r -p "按回车键退出..." _