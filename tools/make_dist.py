#!/usr/bin/env python3
"""
打包。默认出**玩家版**（只收玩家需要的文件，payload 里 DEV 关掉），--dev 出全源码快照。

三种包是三种完全不同的东西，别混。`docs/` 不属于任何一种：它是本地资料，已被
.gitignore 排除。

    python tools/make_dist.py                 # 玩家版 -> dist/kr6-trainer-v<N>.zip
    python tools/make_dist.py --dev           # 全源码快照（含开发工具，含诊断项）
    python tools/make_dist.py --release       # 发行版：解压到游戏根目录，双击 install.bat
"""
import argparse
import io
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)

from release_flags import FlagNotFound, release_flags  # noqa: E402

# docs/ 一并排除：那是本地逆向资料（笔记 + 逆向工具），三种包都不该带。
EXCLUDE_DIRS = {"_scratch", "__pycache__", ".git", "dist", "docs"}
EXCLUDE_EXT = {".pyc", ".love"}
PAYLOAD = "src/_kr6trainer.lua"
# 玩家版**显式白名单**：必须逐个列出 —— 用排除法的话，新加的文件（尤其不发布的
# src/_kr6trainer_lab.lua）会悄悄进包。kr6_slot_edit.py 也要收：游戏内改不了存档进度。
PLAYER_FILES = [
    "README.md",
    "LICENSE",
    "install.py",
    "uninstall.py",
    "src/shadow_director.lua",
    "tools/release_flags.py",
    "tools/kr6_slot_edit.py",
]

# 发行版：给不装 Python 的玩家，只带安装所需的东西
# （不含 install.py / tools/ / docs/）。解压到游戏根目录，双击 install.bat。
RELEASE_ROOT_FILES = [
    "使用说明.txt",
    "LICENSE",
    "install.bat",
    "uninstall.bat",
    "install.ps1",
    "uninstall.ps1",
]
# 发行版里 mod\ 的文件名 -> 仓库里的来源。mod\ 里的 lua 不是"待编译的源码"，
# 它们就是模组本身，安装脚本原样复制进存档目录。
RELEASE_MOD_FILES = [
    ("mod/director.lua", "src/shadow_director.lua"),
]

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def player_build(z, n):
    for rel in PLAYER_FILES:
        full = os.path.join(ROOT, rel.replace("/", os.sep))
        if not os.path.isfile(full):
            sys.exit("error: %s is missing" % rel)
        z.write(full, os.path.join("kr6-trainer", rel))
        n += 1
    src = io.open(os.path.join(ROOT, PAYLOAD.replace("/", os.sep)), encoding="utf-8").read()
    try:
        out = release_flags(src)
    except FlagNotFound as e:
        sys.exit("error: %s" % e)
    z.writestr(os.path.join("kr6-trainer", PAYLOAD), out)
    n += 1
    return n


def dev_build(z, n):
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDE_DIRS]
        for fn in sorted(filenames):
            if os.path.splitext(fn)[1] in EXCLUDE_EXT:
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, ROOT)
            z.write(full, os.path.join("kr6-trainer", rel))
            n += 1
    return n


def release_build(z, n):
    for rel in RELEASE_ROOT_FILES:
        full = os.path.join(ROOT, rel)
        if not os.path.isfile(full):
            sys.exit("error: %s is missing" % rel)
        z.write(full, os.path.join("kr6-trainer", rel))
        n += 1
    for dest, src_rel in RELEASE_MOD_FILES:
        full = os.path.join(ROOT, src_rel.replace("/", os.sep))
        if not os.path.isfile(full):
            sys.exit("error: %s is missing" % src_rel)
        z.write(full, os.path.join("kr6-trainer", dest.replace("/", os.sep)))
        n += 1
    # payload 不能直接拷源文件：必须和 install.py 走同一条 release_flags 处理路径
    src = io.open(os.path.join(ROOT, PAYLOAD.replace("/", os.sep)), encoding="utf-8").read()
    try:
        out = release_flags(src)
    except FlagNotFound as e:
        sys.exit("error: %s" % e)
    z.writestr(os.path.join("kr6-trainer", "mod", "_kr6trainer.lua"), out)
    n += 1
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--version", default="1")
    ap.add_argument("--dev", action="store_true",
                    help="full source snapshot instead of the player build")
    ap.add_argument("--release", action="store_true",
                    help="发行版：解压到游戏根目录，双击 install.bat（不需要 Python）")
    args = ap.parse_args()

    dist = os.path.join(ROOT, "dist")
    os.makedirs(dist, exist_ok=True)
    kind = "dev" if args.dev else ("release" if args.release else "player")
    suffix = "-dev" if args.dev else ("-release" if args.release else "")
    out = os.path.join(dist, "kr6-trainer-v%s%s.zip" % (args.version, suffix))

    n = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        if args.dev:
            n = dev_build(z, n)
        elif args.release:
            n = release_build(z, n)
        else:
            n = player_build(z, n)

    print("wrote %s (%s build)" % (out, kind))
    print("  %d files, %.1f KB" % (n, os.path.getsize(out) / 1024.0))
    print("  docs/ 未包含（本地逆向资料，要备份请另行打包）")
    if args.release:
        print("  整包解压到游戏根目录，双击 install.bat —— 不需要 Python、不需要 7-Zip")
    elif not args.dev:
        print("  payload 里 DEV = false：无诊断菜单项，也不写自动报告")


if __name__ == "__main__":
    main()
