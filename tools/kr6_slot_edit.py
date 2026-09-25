#!/usr/bin/env python3
"""
Kingdom Rush Genesis 离线存档编辑器。

    python tools/kr6_slot_edit.py show              # 看当前存档（只读，游戏开着也能跑）
    python tools/kr6_slot_edit.py gems 99999        # 宝石设为 99999（也支持 +500 / -500）
    python tools/kr6_slot_edit.py track             # 星星奖励轨道（解锁全部要 84 星）
    python tools/kr6_slot_edit.py stars-unlock      # 星数顶到阈值，让游戏自己发放内容
    python tools/kr6_slot_edit.py stars 3           # 每关 3 星
    python tools/kr6_slot_edit.py unlock-tree       # 免费补全升级树（不花宝石也不花星星）
    python tools/kr6_slot_edit.py unlock-towers     # 全部防御塔可造
    python tools/kr6_slot_edit.py unlock-heroes     # 全部英雄入队
    python tools/kr6_slot_edit.py hero-max hero_gerald
    python tools/kr6_slot_edit.py hero-xp hero_gerald +5000
    python tools/kr6_slot_edit.py backups / restore
    python tools/kr6_slot_edit.py selftest          # 往返自检，必须逐字节一致才允许写
"""
import argparse
import datetime
import glob
import os
import re
import shutil
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

DEFAULT_IDENTITY = "kingdom_rush_genesis"
EXE = "Kingdom Rush Genesis.exe"
BACKUP_PREFIX = "_kr6_slot_backup_"

# ---- Lua 表子集
# 存档就是一个 Lua 表字面量（local obj1 = {...}; return obj1）：键只有 ["名字"] 或
# [数字]，值只有数字/字符串/布尔/嵌套表，所以一个极小的解析器就能精确解析。

KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for",
            "function", "if", "in", "local", "nil", "not", "or", "repeat",
            "return", "then", "true", "until", "while"}


class LuaError(Exception):
    pass


class Parser:
    def __init__(self, text):
        self.s = text
        self.i = 0
        self.n = len(text)

    def fail(self, what):
        snippet = self.s[self.i:self.i + 40].replace("\n", " ")
        raise LuaError("%s at offset %d (near %r)" % (what, self.i, snippet))

    def skip(self):
        while self.i < self.n:
            c = self.s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif self.s.startswith("--", self.i):
                j = self.s.find("\n", self.i)
                self.i = self.n if j < 0 else j + 1
            else:
                return

    def expect(self, ch):
        self.skip()
        if self.i >= self.n or self.s[self.i] != ch:
            self.fail("expected %r" % ch)
        self.i += 1

    def name(self):
        self.skip()
        m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", self.s[self.i:])
        if not m:
            self.fail("expected a name")
        self.i += m.end()
        return m.group()

    def string(self):
        self.expect('"')
        out = []
        while True:
            if self.i >= self.n:
                self.fail("unterminated string")
            c = self.s[self.i]
            if c == '"':
                self.i += 1
                return "".join(out)
            if c == "\\":
                self.i += 1
                e = self.s[self.i] if self.i < self.n else ""
                out.append({"n": "\n", "t": "\t", "r": "\r"}.get(e, e))
                self.i += 1
            else:
                out.append(c)
                self.i += 1

    def number(self):
        self.skip()
        m = re.match(r"0[xX][0-9a-fA-F]+|-?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?",
                     self.s[self.i:])
        if not m:
            self.fail("expected a number")
        self.i += m.end()
        t = m.group()
        if t.lower().startswith(("0x", "-0x")):
            return int(t, 16)
        if "." in t or "e" in t.lower():
            return float(t)
        return int(t)

    def value(self):
        self.skip()
        if self.i >= self.n:
            self.fail("expected a value")
        c = self.s[self.i]
        if c == "{":
            return self.table()
        if c == '"':
            return self.string()
        for word, val in (("true", True), ("false", False), ("nil", None)):
            if self.s.startswith(word, self.i) and not re.match(
                    r"[A-Za-z0-9_]", self.s[self.i + len(word):self.i + len(word) + 1] or " "):
                self.i += len(word)
                return val
        if c in "-0123456789.":
            return self.number()
        self.fail("unexpected value")

    def table(self):
        self.expect("{")
        out = {}
        while True:
            self.skip()
            if self.i >= self.n:
                self.fail("unterminated table")
            if self.s[self.i] == "}":
                self.i += 1
                return out
            if self.s[self.i] == "[":
                self.i += 1
                key = self.value()
                self.expect("]")
            else:
                key = self.name()
            self.expect("=")
            out[key] = self.value()
            self.skip()
            if self.i < self.n and self.s[self.i] in ";,":
                self.i += 1


def parse_save(text):
    p = Parser(text)
    p.skip()
    kw = p.name()
    if kw != "local":
        raise LuaError("file does not start with `local <name> =` (got %r)" % kw)
    var = p.name()
    p.expect("=")
    obj = p.value()
    kw2 = p.name()
    if kw2 != "return":
        raise LuaError("expected `return`, got %r" % kw2)
    if p.name() != var:
        raise LuaError("returns a different variable than it declares")
    p.skip()
    if p.i != p.n:
        raise LuaError("trailing content after the return at offset %d" % p.i)
    if not isinstance(obj, dict):
        raise LuaError("the returned value is not a table")
    return var, obj


def render(var, obj):
    return "local %s = %s\nreturn %s\n" % (var, ser(obj, 0), var)


def ser(v, indent):
    pad = "\t" * indent
    if isinstance(v, dict):
        # 空表不特例化：游戏自己的序列化器也写 "{\n<制表符>}"，
        # 而往返检查要求逐字节一致。
        out = ["{"]
        for k, val in v.items():
            out.append("\t" * (indent + 1) + ske(k) + " = " + ser(val, indent + 1) + ";")
        out.append(pad + "}")
        return "\n".join(out)
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return str(int(v)) if v == int(v) else repr(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if v is None:
        return "nil"
    raise LuaError("cannot serialize a %s" % type(v).__name__)


def ske(k):
    if isinstance(k, bool):
        return "[%s]" % ("true" if k else "false")
    if isinstance(k, (int, float)):
        return "[%d]" % int(k)
    if isinstance(k, str):
        return '["%s"]' % k.replace("\\", "\\\\").replace('"', '\\"')
    raise LuaError("bad key type %s" % type(k).__name__)


# ---- 辅助

def default_slot_path(identity):
    appdata = os.environ.get("APPDATA")
    if not appdata:
        sys.exit("error: APPDATA is not set; pass --slot explicitly")
    return os.path.join(appdata, identity, "slot_1.lua")


def game_is_running():
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq " + EXE],
                             capture_output=True, timeout=20)
        return EXE.encode() in out.stdout
    except Exception:
        return None            # 未知：不要因此拦截操作


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    var, obj = parse_save(text)
    return text, var, obj


def save(path, var, obj, dry_run):
    new = render(var, obj)
    if dry_run:
        print("(dry run: %s not written)" % os.path.basename(path))
        return
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup = os.path.join(os.path.dirname(path), "%s%s.lua" % (BACKUP_PREFIX, stamp))
    shutil.copy2(path, backup)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(new)
    print("backed up -> %s" % os.path.basename(backup))
    print("wrote     -> %s (%d bytes)" % (os.path.basename(path), len(new)))


def stars_total(slot):
    lv = slot.get("levels")
    if not isinstance(lv, dict):
        return None
    return sum(e["stars"] for e in lv.values()
               if isinstance(e, dict) and isinstance(e.get("stars"), int))


# Lua 数组解析出来是以 1..n 为键的 dict（文件里写 [1] = ...），用不了 list 的操作。
def lua_array(d):
    if not isinstance(d, dict):
        return []
    out, n = [], 1
    while n in d:
        out.append(d[n])
        n += 1
    return out


def lua_array_append(d, v):
    if not isinstance(d, dict):
        raise LuaError("expected a table, got %s" % type(d).__name__)
    n = 1
    while n in d:
        n += 1
    d[n] = v
    return v


def show_list(d):
    return "{%s}" % ", ".join(repr(x) for x in lua_array(d))


# 星星奖励轨道，取自 kr6-desktop/data/map_data.lua 的 progression_rewards_premium。
REWARD_TRACK = [
    (1, "hero_zefira"), (3, "tower_wizard"), (5, "power_royal_edict"),
    (7, "tower_culverine"), (11, "hero_bolin"), (14, "tower_ranger"),
    (16, "tower_wildcat"), (18, "power_teleportation_sigil"), (20, "hero_connor"),
    (24, "modes_unlock"), (28, "hero_malik"), (30, "tower_miners"),
    (36, "tower_sunray_master"), (40, "hero_rhodes"), (42, "power_musketeers"),
    (44, "tower_crossbows"), (46, "tower_alchemist"), (48, "power_soaring_shop"),
    (50, "tower_tree"), (52, "tower_light_priestess"), (54, "hero_myriath"),
    (56, "tower_forger"), (58, "hero_ignus"), (60, "modes_impossible_unlock"),
    (62, "power_thunder_zapper"), (64, "tower_sniper"), (66, "hero_illiana"),
    (68, "power_wintersongs_wrath"), (70, "hero_oni"), (72, "power_aspect_of_sol"),
    (80, "hero_drakkan"), (84, "hero_ashbite"),
]

# 存档里的升级树节点是**短 id**（l1、skill_a），kr6/upgrades.lua 里是**带前缀的**
# （archers_l1）：两个命名空间绝不能混用，只能沿用该树里已有的风格去补。
TOWER_NODES = ["l1", "l2", "l3a", "l3b", "l4a", "l4b", "ulti"]
HERO_NODES = ["skill_a", "skill_b", "skill_c", "talent_1", "talent_2",
              "upg_a", "upg_b", "ultimate"]


def fill_tree(arr):
    """arr is a Lua array-as-dict. Returns how many nodes were appended."""
    vals = lua_array(arr)
    style = TOWER_NODES
    for n in vals:
        if any(t in str(n) for t in ("skill", "upg", "talent")):
            style = HERO_NODES
            break
    have = set(str(n) for n in vals)
    added = [n for n in style if n not in have]
    for n in added:
        lua_array_append(arr, n)
    return len(added)


# ---- commands

def cmd_show(slot):
    print("gems            : %s" % slot.get("gems"))
    lv = slot.get("levels")
    if isinstance(lv, dict):
        per = ",".join("%s=%s" % (k, (v or {}).get("stars"))
                       for k, v in sorted(lv.items(), key=lambda kv: str(kv[0])))
        total = stars_total(slot)
        stars = [(v or {}).get("stars") for v in lv.values()]
        if stars and len(set(stars)) == 1:
            print("stars per level : all %d level(s) at %s   (total %s)"
                  % (len(stars), stars[0], total))
        else:
            print("stars per level : %s   (total %s)" % (per, total))
    print("progression     : %s" % slot.get("progression"))
    heroes = slot.get("heroes") or {}
    st = heroes.get("status") or {}
    sel = heroes.get("selected")
    team = heroes.get("team")
    print("heroes.selected : %s" % sel)
    print("heroes.team     : %s" % show_list(team))
    for hid in sorted(st):
        mark = " *" if hid in (team or []) else "  "
        print("  %s %-16s xp=%s" % (mark, hid, (st[hid] or {}).get("xp")))
    towers = slot.get("towers") or {}
    print("towers.selected : %s" % show_list(towers.get("selected")))
    print("towers tracked  : %s" % sorted((towers.get("status") or {}).keys()))
    powers = ((slot.get("powers") or {}).get("status")) or {}
    print("powers xp       : %s" % ", ".join(
        "%s=%s" % (k, (v or {}).get("xp")) for k, v in sorted(powers.items())
        if (v or {}).get("xp")))
    tr = slot.get("upgrades_trees") or {}
    filled = {k: v for k, v in tr.items() if isinstance(v, dict) and v}
    print("upgrade trees with purchases (%d of %d):" % (len(filled), len(tr)))
    for k in sorted(filled):
        print("  %-26s %s" % (k, show_list(filled[k])))


def cmd_gems(slot, arg):
    cur = slot.get("gems")
    if not isinstance(cur, int):
        sys.exit("error: slot.gems is %s, refusing to guess" % type(cur).__name__)
    if arg[0] in "+-":
        new = cur + int(arg)
    else:
        new = int(arg)
    slot["gems"] = new
    print("gems %s -> %s" % (cur, new))


def cmd_stars(slot, n):
    lv = slot.setdefault("levels", {})
    if not isinstance(lv, dict):
        sys.exit("error: slot.levels is not a table")
    before = stars_total(slot)
    touched = 0
    for k in list(lv.keys()):
        if not isinstance(lv[k], dict):
            lv[k] = {}
        if lv[k].get("stars") != n:
            lv[k]["stars"] = n
            touched += 1
    print("stars on every level -> %d (%d level(s) touched, total %s -> %s)"
          % (n, touched, before, stars_total(slot)))


def cmd_stars_unlock(slot, target):
    lv = slot.setdefault("levels", {})
    if not isinstance(lv, dict):
        sys.exit("error: slot.levels is not a table")
    need = target or REWARD_TRACK[-1][0]
    before = stars_total(slot)
    invented, idx = 0, 1
    while (stars_total(slot) or 0) < need and idx <= 40:
        if not isinstance(lv.get(idx), dict):
            lv[idx] = {}
            invented += 1
        if lv[idx].get("stars") != 3:
            lv[idx]["stars"] = 3
        idx += 1
    after = stars_total(slot)
    print("stars %s -> %s (needed %d to reach the last reward)" % (before, after, need))
    if invented:
        print("  created %d level entr(ies) the save did not have -- the level "
              "select screen will show them as finished" % invented)
    print("  last_stars is left alone on purpose: keeping it below the total is "
          "what makes the game notice the new stars and grant the content")


def cmd_unlock_tree(slot):
    tr = slot.get("upgrades_trees")
    if not isinstance(tr, dict):
        sys.exit("error: slot.upgrades_trees is not a table")
    total, trees = 0, 0
    for k in sorted(tr):
        if isinstance(tr[k], dict):
            n = fill_tree(tr[k])
            if n:
                total += n
                trees += 1
                print("  %-26s +%d" % (k, n))
    print("added %d node(s) across %d tree(s)" % (total, trees) if total
          else "every tree already complete")


def cmd_unlock_towers(slot):
    towers = slot.setdefault("towers", {})
    status = towers.get("status") or {}
    sel = towers.setdefault("selected", {})
    have = set(str(x) for x in lua_array(sel))
    added = [str(k) for k in status if str(k) not in have]
    for name in added:
        lua_array_append(sel, name)
    print("towers.selected %d -> %d (+%d: %s)"
          % (len(have), len(have) + len(added), len(added), ", ".join(added) or "-"))
    print("  note: the game validates ownership on load (deselect_unowned_units)")
    print("  and may drop these; unlocking via stars is the path it cannot undo")


def cmd_unlock_heroes(slot):
    heroes = slot.setdefault("heroes", {})
    status = heroes.get("status") or {}
    team = heroes.setdefault("team", {})
    have = set(str(x) for x in lua_array(team))
    added = [str(k) for k in status if str(k) not in have]
    for name in added:
        lua_array_append(team, name)
    print("heroes.team %d -> %d (+%d: %s)"
          % (len(have), len(have) + len(added), len(added), ", ".join(added) or "-"))
    print("  same caveat as unlock-towers.")


def cmd_hero_xp(slot, hero, arg):
    st = (slot.get("heroes") or {}).get("status") or {}
    if hero not in st:
        sys.exit("error: no such hero in the slot: %s\n(slot has: %s)"
                 % (hero, ", ".join(sorted(st))))
    cur = st[hero].get("xp")
    if not isinstance(cur, int):
        sys.exit("error: %s.xp is %s" % (hero, type(cur).__name__))
    new = cur + int(arg) if arg[0] in "+-" else int(arg)
    st[hero]["xp"] = new
    print("%s xp %s -> %s" % (hero, cur, new))
    print("  the hero's LEVEL is not stored; the game derives it from xp against "
          "hero_xp_thresholds (in kr6/game_settings.lua as numeric constants).")


def cmd_hero_max(slot, hero):
    st = (slot.get("heroes") or {}).get("status") or {}
    targets = [hero] if hero else sorted(st)
    for h in targets:
        if h not in st:
            sys.exit("error: no such hero in the slot: %s" % h)
        st[h]["xp"] = 9999999
    print("set xp=9999999 on: %s" % ", ".join(targets))
    print("  the game clamps to the hero's max level.")


def cmd_backups(path):
    d = os.path.dirname(path)
    found = sorted(glob.glob(os.path.join(d, BACKUP_PREFIX + "*.lua")))
    if not found:
        print("no backups next to %s" % os.path.basename(path))
        return
    for f in found:
        print("  %s  (%d bytes)" % (os.path.basename(f), os.path.getsize(f)))


def cmd_restore(path, which):
    d = os.path.dirname(path)
    found = sorted(glob.glob(os.path.join(d, BACKUP_PREFIX + "*.lua")))
    if not found:
        sys.exit("no backups to restore from")
    src = which or found[-1]
    if not os.path.isfile(src):
        sys.exit("no such backup: %s" % src)
    shutil.copy2(path, path + ".pre-restore")
    shutil.copy2(src, path)
    print("restored %s -> %s" % (os.path.basename(src), os.path.basename(path)))
    print("(the file that was there is kept as %s)"
          % os.path.basename(path + ".pre-restore"))


def cmd_selftest(path):
    """Round-trip the real file: parse -> serialize -> must be byte-identical."""
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    var, obj = parse_save(text)
    out = render(var, obj)
    if out == text:
        print("round-trip is byte-identical (%d bytes, %d top-level keys)"
              % (len(text), len(obj)))
        return 0
    print("round-trip DIFFERS -- refusing to write anything until this is fixed")
    a, b = text.splitlines(), out.splitlines()
    for i in range(max(len(a), len(b))):
        x = a[i] if i < len(a) else "<eof>"
        y = b[i] if i < len(b) else "<eof>"
        if x != y:
            print("  line %d:\n    file: %r\n    ours: %r" % (i + 1, x, y))
            break
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", nargs="?", default="show")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--identity", default=DEFAULT_IDENTITY)
    ap.add_argument("--slot", help="path to the save file (default: %%APPDATA%%\\<identity>\\slot_1.lua)")
    ap.add_argument("--dry-run", action="store_true", help="show what would change, write nothing")
    ap.add_argument("--force", action="store_true", help="write even if the game looks like it is running")
    a = ap.parse_args()

    path = a.slot or default_slot_path(a.identity)
    if not os.path.isfile(path):
        sys.exit("error: %s not found" % path)

    if a.command == "selftest":
        return cmd_selftest(path)
    if a.command == "backups":
        cmd_backups(path)
        return 0
    if a.command == "restore":
        cmd_restore(path, a.args[0] if a.args else None)
        return 0

    text, var, slot = load(path)

    c = a.command
    if c == "show":
        print("slot: %s" % path)
        cmd_show(slot)
        return 0
    if c == "track":
        for s, name in REWARD_TRACK:
            print("  %3d stars  %s" % (s, name))
        print("total %d stars to unlock everything" % REWARD_TRACK[-1][0])
        return 0

    # 只有会写文件的命令需要游戏关闭：游戏存档时会重写整个文件，运行时改的直接作废。
    running = game_is_running()
    if running and not a.force and not a.dry_run:
        sys.exit("refusing to write: %s is running, and the game rewrites this file\n"
                 "when it saves. Close the game first (or pass --force)." % EXE)
    if running is None:
        print("warning: could not tell whether the game is running; be sure it is closed")

    print("slot: %s" % path)
    if c == "gems":
        if not a.args:
            sys.exit("usage: gems <N|+N|-N>")
        cmd_gems(slot, a.args[0])
    elif c == "stars":
        cmd_stars(slot, int(a.args[0]) if a.args else 3)
    elif c == "stars-unlock":
        cmd_stars_unlock(slot, int(a.args[0]) if a.args else None)
    elif c == "unlock-tree":
        cmd_unlock_tree(slot)
    elif c == "unlock-towers":
        cmd_unlock_towers(slot)
    elif c == "unlock-heroes":
        cmd_unlock_heroes(slot)
    elif c == "hero-xp":
        if len(a.args) != 2:
            sys.exit("usage: hero-xp <hero_id> <N|+N|-N>")
        cmd_hero_xp(slot, a.args[0], a.args[1])
    elif c == "hero-max":
        cmd_hero_max(slot, a.args[0] if a.args else None)
    else:
        sys.exit("unknown command %r -- see --help" % c)

    save(path, var, slot, a.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
