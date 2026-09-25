#!/usr/bin/env python3
"""
kr6-trainer 安装器。

不修改游戏目录里的任何文件：把 3 个文件写进 LÖVE 的存档目录，
靠「存档目录优先于游戏本体」顶掉游戏的一个模块（all/director.lua）。
被顶掉模块的原始字节码在安装时从玩家自己的游戏里现提取，因此不分发任何游戏代码。

    python install.py                   # 自动找游戏
    python install.py --game-dir "D:\\...\\Kingdom Rush Genesis"
    python install.py --dry-run         # 只看会做什么，不写文件
    python install.py --release         # 玩家版：去掉诊断工具
    python install.py --save-dir "C:\\tmp\\test"    # 测试用

装完启动游戏，按 Home（**不是 F1** —— 这游戏没有也不该有 F 键热键，
F1–F3 是玩家的物品键）。
"""
import argparse
import os
import re
import shutil
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))


def _release_flags(src):
    """把 DEV 开关改成 false。延迟导入，这样只带 install.py / uninstall.py / src/
    的发布包里没有 tools/ 也能用。"""
    sys.path.insert(0, os.path.join(HERE, "tools"))
    from release_flags import FlagNotFound, release_flags
    try:
        return release_flags(src)
    except FlagNotFound as e:
        sys.exit("error: %s" % e)

# 游戏 exe = love.exe 的字节 + 追加在后面的 .love zip。
# 用中央目录结束记录（EOCD）定位 zip，所以不必知道 love.exe 那部分有多长。
EXE_NAME = "Kingdom Rush Genesis.exe"
GAME_FOLDER = "Kingdom Rush Genesis"   # Steam 库里就是这个文件夹名
TARGET_MODULE = "all/director.lua"          # the module we shadow
DEFAULT_IDENTITY = "kingdom_rush_genesis"   # the game's LOVE identity
LUAC_NAME = "all_director.luac"             # what we call the extracted blob
PAYLOAD_NAME = "_kr6trainer.lua"
SHADOW_PATH = "all/director.lua"

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")

GAME_CANDIDATES = [
    r"C:\Program Files (x86)\Steam\steamapps\common\Kingdom Rush Genesis",
    r"C:\Program Files\Steam\steamapps\common\Kingdom Rush Genesis",
    r"D:\Steam\steamapps\common\Kingdom Rush Genesis",
    r"D:\Game\Steam\steamapps\common\Kingdom Rush Genesis",
    r"E:\Steam\steamapps\common\Kingdom Rush Genesis",
]


class NotFusedError(Exception):
    pass


class FusedArchive:
    """Reads files out of the zip payload appended to a fused LOVE executable."""

    def __init__(self, path):
        self.path = path
        self.f = open(path, "rb")
        self.f.seek(0, os.SEEK_END)
        size = self.f.tell()
        self.size = size
        if size < 1024:
            raise NotFusedError("file too small to be a fused build")

        tail_len = min(65557, size)          # max comment + EOCD
        self.f.seek(size - tail_len)
        tail = self.f.read()
        i = tail.rfind(b"PK\x05\x06")
        if i < 0:
            raise NotFusedError("no zip end-of-central-directory record found")
        (_sig, _d1, _d2, _d3, count, cd_size, cd_off, comment_len) = struct.unpack(
            "<IHHHHIIH", tail[i:i + 22])
        cd_start = size - comment_len - 22 - cd_size
        # 中央目录里的偏移是相对 .love 起始的，所以要整体加上 love.exe 的长度。
        self.delta = cd_start - cd_off

        self.f.seek(cd_start)
        cd = self.f.read(cd_size)
        self.entries = {}
        p = 0
        for _ in range(count):
            if cd[p:p + 4] != b"PK\x01\x02":
                break
            (sig, _vmb, _vne, _flags, meth, _mt, _md, crc, csz, usz,
             nlen, elen, clen, _dsk, _ia, _ea, lho) = struct.unpack(
                "<IHHHHHHIIIHHHHHII", cd[p:p + 46])
            name = cd[p + 46:p + 46 + nlen].decode("utf-8", "replace")
            self.entries[name] = dict(meth=meth, csz=csz, usz=usz, crc=crc,
                                      lho=lho + self.delta)
            p += 46 + nlen + elen + clen

    def read(self, name):
        e = self.entries.get(name)
        if e is None:
            raise KeyError("no such entry in payload: %s" % name)
        self.f.seek(e["lho"])
        head = self.f.read(30)
        if head[:4] != b"PK\x03\x04":
            raise ValueError("bad local header for %s" % name)
        nlen, elen = struct.unpack("<HH", head[26:30])
        raw = self.f.read(nlen + elen + e["csz"])[nlen + elen:]
        out = zlib.decompress(raw, -15) if e["meth"] == 8 else raw
        if len(out) != e["usz"]:
            raise ValueError("size mismatch for %s" % name)
        if (zlib.crc32(out) & 0xffffffff) != e["crc"]:
            raise ValueError("CRC mismatch for %s" % name)
        return out

    def close(self):
        self.f.close()


def _upward_from_here(levels=3):
    """从脚本自己所在目录**逐级向上**找 exe。

    为什么要向上找：发行包解压出来是 kr6-trainer\\ 一层子文件夹，所以脚本所在的
    目录通常不是游戏根，而是它的下一层。只看本层的话这个快路径永远命中不了。
    """
    d = HERE
    for _ in range(levels):
        if os.path.isfile(os.path.join(d, EXE_NAME)):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def _steam_libraries():
    """问注册表 + Steam 自己的库清单，拿这台机器上所有的 Steam 库根目录。

    比硬编码猜路径靠谱得多 —— 实测有玩家的库根是 D:\\GAME，那几个猜测一个都不匹配。
    """
    libs = []
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as k:
            steam = winreg.QueryValueEx(k, "SteamPath")[0]
    except Exception:
        return libs
    if not steam:
        return libs
    steam = steam.replace("/", "\\")
    libs.append(steam)
    vdf = os.path.join(steam, "steamapps", "libraryfolders.vdf")
    try:
        with open(vdf, "r", encoding="utf-8", errors="replace") as f:
            txt = f.read()
    except OSError:
        return libs
    for m in re.finditer(r'"path"\s+"([^"]+)"', txt):
        p = m.group(1).replace("\\\\", "\\").rstrip("\\")
        if p:
            libs.append(p)
    return libs


def find_game_dir(explicit):
    if explicit:
        if not os.path.isfile(os.path.join(explicit, EXE_NAME)):
            sys.exit("error: %s not found in %s" % (EXE_NAME, explicit))
        return explicit
    # 1) 从脚本所在目录向上找（发行包解压成子文件夹时最常命中，也最快）
    up = _upward_from_here()
    if up:
        return up
    # 2) Steam 自己的库清单 + 硬编码猜测
    cands = [os.path.join(lib, "steamapps", "common", GAME_FOLDER)
             for lib in _steam_libraries()]
    cands += GAME_CANDIDATES
    for d in cands:
        if os.path.isfile(os.path.join(d, EXE_NAME)):
            return d
    # 3) 最后的兜底：在各盘根目录下浅扫几层找 exe（慢，但装在哪都能翻出来）
    for drive in ("C:\\", "D:\\", "E:\\", "F:\\"):
        for root, dirs, files in os.walk(drive):
            if root.count(os.sep) > 4:
                dirs[:] = []
                continue
            if EXE_NAME in files:
                return root
    sys.exit("error: could not find the game; pass --game-dir explicitly")


def default_save_dir(identity):
    appdata = os.environ.get("APPDATA")
    if not appdata:
        sys.exit("error: APPDATA is not set; pass --save-dir explicitly")
    return os.path.join(appdata, identity)


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def main():
    ap = argparse.ArgumentParser(description="Install the KR6 trainer mod.")
    ap.add_argument("--game-dir", help="folder containing " + EXE_NAME)
    ap.add_argument("--save-dir", help="override the deploy target (testing)")
    ap.add_argument("--identity", default=DEFAULT_IDENTITY,
                    help="LOVE identity == save folder name (default: %(default)s)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--release", action="store_true",
                    help="player build: drop the diagnostic menu items and the "
                         "periodic auto-report into the Steam-synced save dir")
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    exe = os.path.join(game_dir, EXE_NAME)
    save_dir = args.save_dir or default_save_dir(args.identity)

    print("game     : %s" % game_dir)
    print("save dir : %s" % save_dir)

    print("reading  : %s" % EXE_NAME)
    ar = FusedArchive(exe)
    try:
        print("payload  : starts at byte %d (love.exe portion)" % ar.delta)
        print("entries  : %d" % len(ar.entries))
        blob = ar.read(TARGET_MODULE)
    finally:
        ar.close()

    if blob[:3] != b"\x1bLJ":
        sys.exit("error: %s is not LuaJIT bytecode; unexpected build" % TARGET_MODULE)
    print("extracted: %s -> %s (%d bytes, CRC verified)"
          % (TARGET_MODULE, LUAC_NAME, len(blob)))

    shadow = open(os.path.join(SRC, "shadow_director.lua"), "rb").read()
    payload = open(os.path.join(SRC, PAYLOAD_NAME), "rb").read()

    if args.release:
        payload = _release_flags(payload.decode("utf-8")).encode("utf-8")
    # 按 payload 的实际情况报告，而不是按参数：发布包里 src/ 本来就是 DEV off，
    # 此时 --release 是空操作，照参数报会说错。
    if b"local DEV = false" in payload:
        print("build    : release (DEV off -- 只有关卡内数值，无诊断工具)")
    else:
        print("build    : dev (含存档进度项与诊断工具)")

    plan = [
        (os.path.join(save_dir, SHADOW_PATH), shadow),
        (os.path.join(save_dir, "_orig", LUAC_NAME), blob),
        (os.path.join(save_dir, PAYLOAD_NAME), payload),
    ]
    for path, data in plan:
        print("%s %s (%d bytes)" % ("would write" if args.dry_run else "writing    ",
                                    path, len(data)))
    if args.dry_run:
        print("\ndry run: nothing written")
        return

    for path, data in plan:
        write(path, data)

    print("""
done. Now:
  1. launch Kingdom Rush Genesis
  2. press Home in game to open the trainer menu
     (up/down select, left/right adjust, enter run, esc close; mouse works too)
     NOTE: it is Home, not F1 - this game has no F-key hotkeys on purpose
     (F1-F3 are the player's item keys).

to remove it again:  python uninstall.py --save-dir "%s"
""" % save_dir)


if __name__ == "__main__":
    main()
