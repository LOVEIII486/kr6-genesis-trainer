#!/usr/bin/env python3
"""
改写 payload 的发布开关（DEV）。

发布版包含什么，唯一的事实来源是 src/_kr6trainer.lua 顶部的 `local DEV`：
关掉它，诊断菜单项、接口图、状态报告、以及定时写进 Steam 云同步目录的报告全部消失。
文件里别处一个字都不改。改不动就抛错，绝不静默发出带诊断的包。

    from release_flags import release_flags
    open(dst, "wb").write(release_flags(src_text).encode("utf-8"))
"""
DEV_ON = "local DEV = true"
DEV_OFF = "local DEV = false"


class FlagNotFound(Exception):
    pass


def release_flags(src):
    """返回 DEV 关掉的 `src`。

    幂等：发布包里的 src/ 本来就是关的，玩家在那种包里跑 `install.py --release`
    应该正常装上而不是报错。两种写法都找不到时才抛错 —— 那说明开关搬走了，
    我们无法保证诊断已被去掉。
    """
    if DEV_OFF in src and DEV_ON not in src:
        return src
    if DEV_ON not in src:
        raise FlagNotFound(
            "found neither %r nor %r -- the DEV flag moved, so the release build "
            "cannot be verified as free of the diagnostics" % (DEV_ON, DEV_OFF))
    # 只有 DEV = true 时才会走到这里：替换并复查
    out = src.replace(DEV_ON, DEV_OFF)
    if DEV_OFF not in out or DEV_ON in out:
        raise FlagNotFound("DEV flag rewrite did not take")
    return out


if __name__ == "__main__":
    import io
    import sys
    if len(sys.argv) != 3:
        sys.exit("usage: release_flags.py <src.lua> <dst.lua>")
    try:
        io.open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(
            release_flags(io.open(sys.argv[1], encoding="utf-8").read()))
    except FlagNotFound as e:
        sys.exit("error: %s" % e)
    print("wrote %s with DEV off" % sys.argv[2])
