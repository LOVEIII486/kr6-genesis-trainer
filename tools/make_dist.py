#!/usr/bin/env python3
"""
打包。

    python tools/make_dist.py                 # 发行版 -> dist/kr6-trainer-v<N>-release.zip
    python tools/make_dist.py --dev           # 全源码快照（自用备份，不发布）
"""
import argparse
import io
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))

# docs/ 是本地逆向资料，任何包都不带。
EXCLUDE_DIRS = {"_scratch", "__pycache__", ".git", "dist", "docs"}
EXCLUDE_EXT = {".pyc", ".love"}
PAYLOAD = "src/_kr6trainer.lua"

# 发行版只带安装所需的东西（不含 install.py / tools/ / test/ / docs/）。
RELEASE_ROOT_FILES = [
    "使用说明.txt",
    "LICENSE",
    "install.bat",
    "uninstall.bat",
    "install.ps1",
    "uninstall.ps1",
]
# 发行包里 mod\ 的文件名 -> 仓库里的来源。这些 lua 就是模组本身，原样复制进存档目录，
# 没有编译步骤。
RELEASE_MOD_FILES = [
    ("mod/director.lua", "src/shadow_director.lua"),
]

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


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
    # ⚠️ **二进制读、原样写**：文本模式会把 CRLF 翻成 LF，包里的 payload 就和仓库里/
    # 测试过的**不是同一份字节**（指纹对不上，排查「装的是哪版」时白绕一圈）。
    src = io.open(os.path.join(ROOT, PAYLOAD.replace("/", os.sep)), "rb").read()
    z.writestr(os.path.join("kr6-trainer", "mod", "_kr6trainer.lua"), src)
    n += 1
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--version", default="11", help="发版号（**发新版时记得改这里**，"
                    "否则会静默覆盖上一版的同名文件）")
    ap.add_argument("--dev", action="store_true",
                    help="full source snapshot instead of the release build")
    args = ap.parse_args()

    dist = os.path.join(ROOT, "dist")
    os.makedirs(dist, exist_ok=True)
    kind = "dev" if args.dev else "release"
    suffix = "-dev" if args.dev else "-release"
    out = os.path.join(dist, "kr6-trainer-v%s%s.zip" % (args.version, suffix))

    n = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        if args.dev:
            n = dev_build(z, n)
        else:
            n = release_build(z, n)

    print("wrote %s (%s build)" % (out, kind))
    print("  %d files, %.1f KB" % (n, os.path.getsize(out) / 1024.0))
    print("  docs/ 未包含（本地逆向资料，要备份请另行打包）")
    if not args.dev:
        print("  整包解压到游戏根目录，双击 install.bat —— 不需要 Python、不需要 7-Zip")


if __name__ == "__main__":
    main()
