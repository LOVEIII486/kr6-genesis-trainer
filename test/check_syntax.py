#!/usr/bin/env python3
"""
用游戏自己的 Lua 运行时给源码做编译检查。

    python test/check_syntax.py
    python test/check_syntax.py --game-dir "D:\\...\\Kingdom Rush Genesis"
"""
import argparse
import io
import os
import shutil
import subprocess
import sys
import zipfile

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

NL = chr(10)
Q = chr(34)
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
RT = os.path.join(ROOT, "_scratch", "rt")
SOURCES = ["src/_kr6trainer.lua", "src/shadow_director.lua"]

# macOS 用 love_path.txt（make_runtime 只搭假 bundle 不拷贝游戏本体）。
def love_binary():
    p = os.path.join(RT, "love_path.txt")
    if os.path.isfile(p):
        return open(p).read().strip()
    return os.path.join(RT, "love.exe")


# 存档目录：Windows 非 bundle 是 %APPDATA%\LOVE\<id>；macOS 的假 bundle 是
# ~/Library/Application Support\<id>（bundle 形态不带 LOVE 段）。
def love_save_dir(identity):
    if sys.platform == "darwin":
        base = os.path.join(os.environ["HOME"], "Library", "Application Support")
        return os.path.join(base, identity)
    return os.path.join(os.environ["APPDATA"], "LOVE", identity)


def deploy_game_love(love_file):
    """macOS bundle 形态：把自己的 .love 复制成假 bundle 的 Contents/Resources/game.love。
    Windows 直接传 .love 参数即可。"""
    if sys.platform != "darwin":
        return love_file
    love = love_binary()
    # love = <...>/bundle.app/Contents/MacOS/love → bundle 根在往上剥三层
    dst = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(love))),
                       "Contents", "Resources", "game.love")
    shutil.copyfile(love_file, dst)
    return dst


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--game-dir")
    args = ap.parse_args()

    love = love_binary()
    if not os.path.isfile(love):
        print("runtime missing, building it first...")
        cmd = [sys.executable, os.path.join(HERE, "make_runtime.py")]
        if args.game_dir:
            cmd += ["--game-dir", args.game_dir]
        subprocess.run(cmd, check=True)
        love = love_binary()
        print()

    syn = os.path.join(RT, "syn")
    os.makedirs(syn, exist_ok=True)

    # 源码作为 Lua 长字符串嵌进去，不当文件附带：这样测试台不依赖
    # love.filesystem 的存档目录查找路径。
    L = ["local SRC = {}"]
    for i, rel in enumerate(SOURCES):
        txt = io.open(os.path.join(ROOT, rel), encoding="utf-8").read()
        while "]==]" in txt:
            txt = txt.replace("]==]", "]=] ]")
        L.append("SRC[%d] = {name = %s%s%s, text = [==[%s]==]}" % (i + 1, Q, rel, Q, txt))
    L += [
        "function love.load()",
        "  local out = {}",
        "  for _, s in ipairs(SRC) do",
        "    local chunk, err = loadstring(s.text, s.name)",
        "    out[#out+1] = (chunk and 'OK   ' or 'FAIL ') .. s.name .. (err and ('  ' .. tostring(err)) or '')",
        "  end",
        "  love.filesystem.write('syntax_result.txt', table.concat(out, string.char(10)) .. string.char(10))",
        "  love.event.quit(0)",
        "end",
    ]
    io.open(os.path.join(syn, "main.lua"), "w", encoding="utf-8", newline=NL).write(NL.join(L) + NL)
    io.open(os.path.join(syn, "conf.lua"), "w", encoding="utf-8", newline=NL).write(
        "function love.conf(t)" + NL +
        "  t.identity = " + Q + "krsyntax" + Q + NL +
        "  t.modules.audio = false" + NL +
        "  t.modules.graphics = false" + NL +
        "  t.modules.window = false" + NL +
        "end" + NL)

    game_love = os.path.join(RT, "syntax.love")
    with zipfile.ZipFile(game_love, "w", zipfile.ZIP_DEFLATED) as z:
        for fn in ("conf.lua", "main.lua"):
            z.write(os.path.join(syn, fn), fn)

    # 非 fused 的 .love，存档目录在 <LOVE>\<identity>（截图落在这里）。
    save = love_save_dir("krsyntax")
    os.makedirs(save, exist_ok=True)
    result = os.path.join(save, "syntax_result.txt")
    if os.path.isfile(result):
        os.remove(result)

    if sys.platform == "darwin":
        # 假 bundle：love 自己会读 Contents/Resources/game.love，不能把 .love 当参数传
        # （会跟 bundle 路径互相打架）
        deploy_game_love(game_love)
        subprocess.run([love], cwd=RT, timeout=60)
    else:
        subprocess.run([love, game_love], cwd=RT, timeout=60)

    if not os.path.isfile(result):
        print("no result produced -- the runtime did not start")
        return 1
    txt = io.open(result, encoding="utf-8", errors="replace").read()
    print(txt.strip())
    bad = [ln for ln in txt.splitlines() if ln.startswith("FAIL")]
    if bad:
        print()
        print("%d file(s) failed to compile" % len(bad))
        return 1
    print()
    print("all sources compile.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
