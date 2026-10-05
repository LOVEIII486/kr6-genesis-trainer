#!/usr/bin/env python3
"""
kr6-trainer 安装器（Windows + macOS）。

不修改游戏目录里的任何文件：把 3 个文件写进 LÖVE 的存档目录，
靠「存档目录优先于游戏本体」顶掉游戏的一个模块（all/director.lua）。
被顶掉模块的原始字节码在安装时从玩家自己的游戏里现提取，因此不分发任何游戏代码。

两个平台只差「游戏在哪、代码从哪取、存档在哪」：
  Windows  游戏 = fused 主程序（尾部追加 .love zip），存档在 %APPDATA%\\<identity>
  macOS    游戏 = .app bundle 里的 Contents/Resources/game.love（普通 zip），
           存档在 ~/Library/Application Support/<identity>
取字节码的打开方式不同，顶替逻辑完全一样。

    python install.py                   # 自动找游戏
    python install.py --game-dir "D:\\...\\Kingdom Rush Genesis"
    python install.py --dry-run         # 只看会做什么，不写文件
    python install.py --save-dir "C:\\tmp\\test"    # 测试用
"""
import argparse
import os
import re
import struct
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))

# ── 平台各自的游戏定位 / 代码来源 / 存档目录 ──────────────────────────────
IS_MAC = sys.platform == "darwin"
EXE_NAME = "Kingdom Rush Genesis.exe"   # Windows：游戏根目录里的 fused 主程序
GAME_FOLDER = "Kingdom Rush Genesis"    # Steam 库里的文件夹名（两个平台同名）
MAC_APP = "Kingdom Rush Genesis.app"    # macOS：普通 LÖVE app bundle
MAC_LOVE = ("Contents", "Resources", "game.love")   # bundle 里的 .love（普通 zip）

TARGET_MODULE = "all/director.lua"          # the module we shadow
DEFAULT_IDENTITY = "kingdom_rush_genesis"   # the game's LOVE identity
LUAC_NAME = "all_director.luac"             # what we call the extracted blob
PAYLOAD_NAME = "_kr6trainer.lua"
SHADOW_PATH = "all/director.lua"

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")

# Windows 猜路径兜底。⚠️ 刻意**不做** Steam 库发现（读注册表键 + 解析库配置文件）：那组特征与
# Steam 盗号木马逐字重合，会被杀软启发式误报 —— 详见 docs/HANDOFF.md。猜不中时由 --game-dir 兜底。
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


def _game_present(d):
    """目录 d 是不是「装着游戏的那个目录」（平台各自的判定）。"""
    if IS_MAC:
        return os.path.isdir(os.path.join(d, MAC_APP))
    return os.path.isfile(os.path.join(d, EXE_NAME))


def _upward_from_here(levels=3):
    """从脚本自己所在目录逐级向上找：发行包解压出来脚本在游戏根的下一层，
    只看本层的话这个快路径永远命中不了。"""
    d = HERE
    for _ in range(levels):
        if _game_present(d):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def _mac_steam_common_roots():
    """macOS 的 Steam 库根：默认库 + 解析 libraryfolders.vdf 里的自定义库。
    ⚠️ 这里刻意做库发现 —— macOS 没有 Windows 那组杀软启发式误报顾虑
    （见 GAME_CANDIDATES 上方的注释）。"""
    out = []
    vdf = os.path.expanduser(
        "~/Library/Application Support/Steam/steamapps/libraryfolders.vdf")
    try:
        txt = open(vdf, encoding="utf-8", errors="replace").read()
    except OSError:
        txt = ""
    for m in re.finditer(r'"path"\s+"([^"]+)"', txt):
        out.append(os.path.join(m.group(1), "steamapps", "common"))
    out.append(os.path.expanduser(
        "~/Library/Application Support/Steam/steamapps/common"))
    return out


def find_game_dir(explicit):
    if explicit:
        if _game_present(explicit):
            return explicit
        # 传的是 .app bundle 本身时，退回它的父目录
        if IS_MAC and os.path.basename(explicit) == MAC_APP and os.path.isdir(explicit):
            return os.path.dirname(explicit)
        sys.exit("error: %s not found in %s"
                 % (MAC_APP if IS_MAC else EXE_NAME, explicit))
    # 1) 从脚本所在目录向上找（发行包解压成子文件夹时最常命中）
    up = _upward_from_here()
    if up:
        return up
    # 2) 猜路径兜底。Windows 侧刻意不做 Steam 库发现，理由见 GAME_CANDIDATES。
    if IS_MAC:
        for root in _mac_steam_common_roots():
            if _game_present(os.path.join(root, GAME_FOLDER)):
                return os.path.join(root, GAME_FOLDER)
    else:
        for d in GAME_CANDIDATES:
            if _game_present(d):
                return d
    # 3) 兜底：浅扫几个可能的地方（慢，但装在哪都能翻出来）
    if IS_MAC:
        for root in (os.path.expanduser("~/Library/Application Support/Steam"),
                     os.path.expanduser("~/Applications"), "/Applications"):
            for dirpath, dirs, files in os.walk(root):
                if dirpath.count(os.sep) - root.count(os.sep) > 4:
                    dirs[:] = []
                    continue
                if _game_present(dirpath):
                    return dirpath
    else:
        for drive in ("C:\\", "D:\\", "E:\\", "F:\\"):
            for root, dirs, files in os.walk(drive):
                if root.count(os.sep) > 4:
                    dirs[:] = []
                    continue
                if EXE_NAME in files:
                    return root
    sys.exit("error: could not find the game; if Steam sits in a custom folder, "
             "pass --game-dir explicitly")


def default_save_dir(identity):
    if IS_MAC:
        home = os.environ.get("HOME")
        if not home:
            sys.exit("error: HOME is not set; pass --save-dir explicitly")
        return os.path.join(home, "Library", "Application Support", identity)
    appdata = os.environ.get("APPDATA")
    if not appdata:
        sys.exit("error: APPDATA is not set; pass --save-dir explicitly")
    return os.path.join(appdata, identity)


def load_target_module(game_dir):
    """从游戏里取出 TARGET_MODULE 的原始字节码（平台各自的来源）。"""
    if IS_MAC:
        love = os.path.join(game_dir, MAC_APP, *MAC_LOVE)
        if not os.path.isfile(love):
            sys.exit("error: %s not found" % love)
        with zipfile.ZipFile(love) as z:
            blob = z.read(TARGET_MODULE)
        return blob, love
    exe = os.path.join(game_dir, EXE_NAME)
    ar = FusedArchive(exe)
    try:
        blob = ar.read(TARGET_MODULE)
    finally:
        ar.close()
    return blob, exe


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def main():
    ap = argparse.ArgumentParser(description="Install the KR6 trainer mod.")
    ap.add_argument("--game-dir", help="folder containing the game")
    ap.add_argument("--save-dir", help="override the deploy target (testing)")
    ap.add_argument("--identity", default=DEFAULT_IDENTITY,
                    help="LOVE identity == save folder name (default: %(default)s)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--payload",
                    help="要部署哪个 payload（默认 src/_kr6trainer.lua）。")
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    save_dir = args.save_dir or default_save_dir(args.identity)

    print("game     : %s" % game_dir)
    print("save dir : %s" % save_dir)

    print("reading  : %s" % TARGET_MODULE)
    blob, src = load_target_module(game_dir)
    print("source   : %s" % src)

    if blob[:3] != b"\x1bLJ":
        sys.exit("error: %s is not LuaJIT bytecode; unexpected build" % TARGET_MODULE)
    print("extracted: %s -> %s (%d bytes)"
          % (TARGET_MODULE, LUAC_NAME, len(blob)))

    # release 包里没有 src/（只带了 mod/），仓库里则是 src/ —— 两个都认。
    # 顺序：仓库路径优先（开发时改的是它）；发行包解开后只剩 mod/，走兜底。
    for rel in ("src/shadow_director.lua", "mod/director.lua"):
        p = os.path.join(HERE, rel.replace("/", os.sep))
        if os.path.isfile(p):
            shadow_path = p
            break
    else:
        shadow_path = None
    if not shadow_path:
        sys.exit("error: 找不到遮蔽桩 shadow_director.lua（release 包缺 mod/director.lua？）")
    shadow = open(shadow_path, "rb").read()

    for rel in ("src/_kr6trainer.lua", "mod/_kr6trainer.lua"):
        p = os.path.join(HERE, rel.replace("/", os.sep))
        if os.path.isfile(p):
            payload_path = p
            break
    else:
        payload_path = None
    payload_path = args.payload or payload_path
    if not payload_path or not os.path.isfile(payload_path):
        sys.exit("error: payload 不存在（release 包缺 mod/_kr6trainer.lua？）")
    payload = open(payload_path, "rb").read()
    print("payload  : %s" % payload_path)

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
  2. press Home or Tab in game to open the trainer menu
     (up/down select, left/right adjust, enter run, esc close; mouse works too)
     NOTE: not an F-key - F1-F3 are the player's item keys, and on laptops the
     F-row is usually claimed by firmware (media keys).

to remove it again:  python uninstall.py --save-dir "%s"
""" % save_dir)


if __name__ == "__main__":
    main()