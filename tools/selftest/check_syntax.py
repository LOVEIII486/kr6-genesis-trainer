#!/usr/bin/env python3
"""
用游戏自己的 Lua 运行时给源码做编译检查。

    python tools/selftest/check_syntax.py
    python tools/selftest/check_syntax.py --game-dir "D:\\...\\Kingdom Rush Genesis"
"""
import argparse
import io
import os
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
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RT = os.path.join(ROOT, "_scratch", "rt")
# _kr6trainer_lab.lua 是功能全开那一版的**冻结快照**，不发布、不部署，
# 但仍要能 loadstring —— 它躺在 src/ 里是给人回头继续开发的，
# 语法烂掉就白留了。这一条几乎零成本（同一趟运行时顺便编译）。
SOURCES = ["src/_kr6trainer.lua", "src/shadow_director.lua", "src/_kr6trainer_lab.lua"]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--game-dir")
    args = ap.parse_args()

    if not os.path.isfile(os.path.join(RT, "love.exe")):
        print("runtime missing, building it first...")
        cmd = [sys.executable, os.path.join(HERE, "make_runtime.py")]
        if args.game_dir:
            cmd += ["--game-dir", args.game_dir]
        subprocess.run(cmd, check=True)
        print()

    syn = os.path.join(RT, "syn")
    os.makedirs(syn, exist_ok=True)

    # 把源码作为 Lua 长字符串嵌进去而不是当文件附带：
    # 这样测试台不依赖 love.filesystem 的存档目录查找路径。
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

    love = os.path.join(RT, "syntax.love")
    with zipfile.ZipFile(love, "w", zipfile.ZIP_DEFLATED) as z:
        for fn in ("conf.lua", "main.lua"):
            z.write(os.path.join(syn, fn), fn)

    # 非 fused 的 .love，存档目录是 %APPDATA%\LOVE\<identity>
    save = os.path.join(os.environ["APPDATA"], "LOVE", "krsyntax")
    os.makedirs(save, exist_ok=True)
    result = os.path.join(save, "syntax_result.txt")
    if os.path.isfile(result):
        os.remove(result)

    subprocess.run([os.path.join(RT, "love.exe"), love], cwd=RT, timeout=60)

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
