#!/usr/bin/env python3
"""
从游戏自己的 exe 里裁出一个独立的 LÖVE 运行时（离线测试台）。

游戏是 fused LÖVE 应用：exe 前 `delta` 字节就是普通的 love.exe（LÖVE 是 MIT 许可），
后面追加的是游戏的 .love 负载。按 `delta` 截断就得到一个不含任何游戏内容的 love.exe，
配上游戏的 DLL 就能离线跑测试 .love。

本项目的所有验证都是这么做的。

    python tools/selftest/make_runtime.py
    python tools/selftest/make_runtime.py --game-dir "D:\\...\\Kingdom Rush Genesis"
    python tools/selftest/make_runtime.py --out ./_scratch/rt
"""
import argparse
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, ROOT)

from install import EXE_NAME, FusedArchive, find_game_dir  # noqa: E402

DLLS = ["love.dll", "lua51.dll", "SDL2.dll", "OpenAL32.dll", "mpg123.dll",
        "msvcp120.dll", "msvcr120.dll", "libcurl-x64.dll"]

# 测试用的 .love 不是 fused 的，存档目录在 %APPDATA%\LOVE\<identity>（截图落在这里）。
DEFAULT_OUT = os.path.join(ROOT, "_scratch", "rt")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--game-dir")
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    exe = os.path.join(game_dir, EXE_NAME)
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)

    ar = FusedArchive(exe)
    try:
        delta = ar.delta
        entries = len(ar.entries)
    finally:
        ar.close()

    # 1. 在负载边界截断 exe -> 独立的 love.exe
    dest_exe = os.path.join(out, "love.exe")
    with open(exe, "rb") as src, open(dest_exe, "wb") as dst:
        remaining = delta
        while remaining > 0:
            chunk = src.read(min(1 << 20, remaining))
            if not chunk:
                break
            dst.write(chunk)
            remaining -= len(chunk)

    # 2. 把运行时 DLL 拷到旁边
    copied, missing = [], []
    for d in DLLS:
        s = os.path.join(game_dir, d)
        if os.path.isfile(s):
            shutil.copy2(s, os.path.join(out, d))
            copied.append(d)
        else:
            missing.append(d)

    print("game dir : %s" % game_dir)
    print("payload  : %d entries, exe portion = %d bytes" % (entries, delta))
    print("love.exe : %s (%d bytes)" % (dest_exe, os.path.getsize(dest_exe)))
    print("dlls     : %d copied%s" % (len(copied), (" (missing: %s)" % ", ".join(missing)) if missing else ""))
    print("\nrun a .love with:  %s <file.love>" % dest_exe)


if __name__ == "__main__":
    main()
