#!/usr/bin/env python3
"""
kr6-trainer 卸载器。

只删自己写进存档目录的文件，别的一律不动 ——
游戏自己的存档（settings.lua / global.lua / cache.lua / slot_*.lua /
steam_autocloud.vdf）永不触碰，编辑器留下的存档备份也**保留**（那是用户数据）。

    python uninstall.py
    python uninstall.py --dry-run
    python uninstall.py --save-dir "C:\\tmp\\test"
"""
import argparse
import os
import shutil
import sys

DEFAULT_IDENTITY = "kingdom_rush_genesis"

# 自己的文件（相对存档目录）
OUR_FILES = [
    "all/director.lua",
    "_kr6trainer.lua",
    "_kr6trainer_loaded.txt",
    "_kr6_beat.txt",
    "_kr6_font.txt",
    "_kr6_money.txt",
    "_kr6_money_api.txt",
    "_kr6_snap.txt",
    "_kr6_diff.txt",
    "_kr6_store.txt",
    "_kr6_cmd.txt",
    "_kr6_cmd_out.txt",
    "_kr6_shot.txt",
    "_kr6_shot.png",
    "_kr6_api.txt",
    "_kr6_fatal.txt",
    "_kr6_err.txt",
]
# 自己的整个目录
OUR_DIRS = ["_orig"]
# 可以放心清扫的前缀（报告、诊断文件等）
OUR_PREFIXES = ("_kr6_", "_probe_")
# 例外：这些也匹配上面的前缀，但它们是**用户数据**不是垃圾 ——
# 是编辑器改动存档前的备份，而卸载恰恰是最需要它的时刻。
KEEP_PREFIXES = ("_kr6_slot_backup", "_kr6_global_backup")

# 无论如何都不删
PROTECTED = ("cache.lua", "global.lua", "settings.lua", "steam_autocloud.vdf")


def default_save_dir(identity):
    appdata = os.environ.get("APPDATA")
    if not appdata:
        sys.exit("error: APPDATA is not set; pass --save-dir explicitly")
    return os.path.join(appdata, identity)


def looks_like_save_dir(path):
    if not os.path.isdir(path):
        return False
    for name in os.listdir(path):
        if name in ("settings.lua", "global.lua", "cache.lua", "steam_autocloud.vdf"):
            return True
        if name.startswith("slot_") and name.endswith(".lua"):
            return True
    return False


def main():
    ap = argparse.ArgumentParser(description="Remove the KR6 trainer mod.")
    ap.add_argument("--save-dir")
    ap.add_argument("--identity", default=DEFAULT_IDENTITY)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true",
                    help="skip the 'does this look like the save dir' check")
    args = ap.parse_args()

    save_dir = args.save_dir or default_save_dir(args.identity)
    if not os.path.isdir(save_dir):
        sys.exit("nothing to do: %s does not exist" % save_dir)
    if not args.force and not looks_like_save_dir(save_dir):
        sys.exit("refusing to touch %s: it does not look like the game's save "
                 "directory (use --force to override)" % save_dir)

    victims = []
    kept = []
    for rel in OUR_FILES:
        p = os.path.join(save_dir, rel)
        if os.path.isfile(p):
            victims.append(p)
    for rel in OUR_DIRS:
        p = os.path.join(save_dir, rel)
        if os.path.isdir(p):
            victims.append(p)
    for name in sorted(os.listdir(save_dir)):
        if name in PROTECTED:
            continue
        if name.startswith(KEEP_PREFIXES):
            kept.append(name)
            continue
        if name.startswith(OUR_PREFIXES):
            p = os.path.join(save_dir, name)
            if p not in victims:
                victims.append(p)

    if not victims and not kept:
        print("nothing to remove - the mod does not appear to be installed here")
        print("(save dir: %s)" % save_dir)
        return

    print("save dir: %s" % save_dir)
    for p in victims:
        kind = "dir " if os.path.isdir(p) else "file"
        print("  %s %s" % (kind, os.path.relpath(p, save_dir)))
    if kept:
        print("\nkeeping (these are YOUR save backups, not the mod's files):")
        for name in kept:
            print("  file %s" % name)
    if args.dry_run:
        print("\ndry run: nothing deleted")
        return

    for p in victims:
        if os.path.isdir(p):
            shutil.rmtree(p)
        else:
            os.remove(p)
    # 覆盖桩的父目录如果空了就一并删掉
    all_dir = os.path.join(save_dir, "all")
    if os.path.isdir(all_dir) and not os.listdir(all_dir):
        os.rmdir(all_dir)
    print("\nremoved %d item(s). The game is back to stock." % len(victims))
    if kept:
        print("left %d save backup(s) in place." % len(kept))


if __name__ == "__main__":
    main()
