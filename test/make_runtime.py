#!/usr/bin/env python3
"""
从游戏自己那里裁出一个独立的 LÖVE 运行时（离线测试台）。

    python test/make_runtime.py
    python test/make_runtime.py --game-dir "D:\\...\\Kingdom Rush Genesis"
    python test/make_runtime.py --out ./_scratch/rt

Windows：截出 fused exe 的 love.exe 部分 + 拷运行时 DLL。
macOS  ：不拷贝——直接记录 .app 里的 love 二进制路径到 <out>/love_path.txt，
        测试脚本原地运行它（dylib 靠 @rpath 从 bundle 内解析，拷走才麻烦）。
"""
import argparse
import os
import shutil
import subprocess
import sys

# 平台依赖：macOS 不用截 exe、不用 DLL，只需定位 .app 里的 love 二进制
IS_MAC = sys.platform == "darwin"

# Windows 控制台常是 cp936/cp1252；别让一次 print() 把整个脚本弄挂
# （--help 里的中文就会）。其他脚本都有这一句，这里之前漏了。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, ROOT)

from install import EXE_NAME, FusedArchive, find_game_dir  # noqa: E402
if IS_MAC:
    from install import MAC_APP  # noqa: E402

DLLS = ["love.dll", "lua51.dll", "SDL2.dll", "OpenAL32.dll", "mpg123.dll",
        "msvcp120.dll", "msvcr120.dll", "libcurl-x64.dll"]

# 测试用的 .love 不是 fused 的，存档目录在 %APPDATA%\LOVE\<identity>（截图落在这里）。
DEFAULT_OUT = os.path.join(ROOT, "_scratch", "rt")


def mac_love_binary(app):
    """.app/Contents/MacOS 里的主二进制（优先叫 love 的那个）。"""
    macos_dir = os.path.join(app, "Contents", "MacOS")
    pref = os.path.join(macos_dir, "love")
    if os.path.isfile(pref):
        return pref
    for name in sorted(os.listdir(macos_dir)):
        if name in (".", ".."):
            continue
        p = os.path.join(macos_dir, name)
        if os.path.isfile(p):
            return p
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--game-dir")
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)

    if IS_MAC:
        app = os.path.join(game_dir, MAC_APP)
        src_love = mac_love_binary(app)
        if not src_love:
            print("error: no executable found in %s" % os.path.join(app, "Contents", "MacOS"))
            return 1

        # 不能用 bundle 里的二进制直接跑测试台 .love：LÖVE 检测到「可执行文件在 .app 里」
        # 就去读 Contents/Resources/game.love，CLI 传的 .love 会被忽略；反过来不放在 .app
        # 里又会被当成「非 bundle 启动」而静默退出（进带 .love 参数的设备路径走不通）。
        # 所以搭一个假 bundle：可执行文件路径带 .app、Resources 里放 game.love，
        # Frameworks 软链到真 app 的 —— 二进制靠 @loader_path/../Frameworks 找所有 framework。
        bdl = os.path.join(out, "bundle.app")
        macos_dir = os.path.join(bdl, "Contents", "MacOS")
        res_dir = os.path.join(bdl, "Contents", "Resources")
        os.makedirs(macos_dir, exist_ok=True)
        os.makedirs(res_dir, exist_ok=True)
        rt_love = os.path.join(macos_dir, "love")
        if not os.path.exists(rt_love):
            try:
                os.link(src_love, rt_love)          # 同一卷上硬链，秒成
            except OSError:
                shutil.copy2(src_love, rt_love)     # 跨卷就退化成拷贝
            # ⚠️ 游戏这个二进制带 **hardened runtime**（codesign flags=runtime）。
            # 硬化运行时默认禁止 LuaJIT 分配可写/可执行内存（mcode），一分配就 SIGKILL ——
            # 游戏自己靠 main.lua 里 `jit.status:false` 规避，测试台 JIT 默认开着必死。
            # 这里把副本 **ad-hoc 重签**（去掉 hardened runtime）：
            # arm64 上未签名二进制无法执行，ad-hoc 签名没有 hardening 行为。
            try:
                subprocess.run(["codesign", "--force", "--sign", "-", rt_love],
                               check=True, capture_output=True)
            except (OSError, subprocess.CalledProcessError) as e:
                print("warning: ad-hoc re-sign failed (%s); the test runtime may "
                      "be SIGKILLed by hardened runtime" % e)
        fw = os.path.join(bdl, "Contents", "Frameworks")
        if not os.path.exists(fw):
            os.symlink(os.path.join(app, "Contents", "Frameworks"), fw)
        # 每个测试把自己打包的 .love 复制成 bundle 的 game.love 再跑（见 check_syntax.py /
        # test_menu2.py 的 deploy）。
        with open(os.path.join(out, "love_path.txt"), "w") as f:
            f.write(rt_love + "\n")
        print("game dir : %s" % game_dir)
        print("love     : %s (fake bundle; Frameworks symlinked)" % rt_love)
        print("           run: <love> ; game.love is picked from Contents/Resources")
        return 0

    exe = os.path.join(game_dir, EXE_NAME)

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
