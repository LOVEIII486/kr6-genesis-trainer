#!/usr/bin/env python3
"""
发布开关（DEV）—— **现在什么都不做**，是个兼容垫片。

精简版 `src/_kr6trainer.lua` 里已经没有开关了（两种版本完全一样），全开版是
不发布的冻结快照 `src/_kr6trainer_lab.lua`。保留这个 no-op 只是因为
`install.py --release` 和 `tools/make_dist.py` 还在调它，删掉要动三处调用方。
"""


class FlagNotFound(Exception):
    pass


def release_flags(src):
    """原样返回 `src`（精简版没有开关）。签名保留是为了不动调用方。"""
    return src


if __name__ == "__main__":
    import io
    import sys
    if len(sys.argv) != 3:
        sys.exit("usage: release_flags.py <src.lua> <dst.lua>")
    io.open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(
        release_flags(io.open(sys.argv[1], encoding="utf-8").read()))
    print("wrote %s (slim build: no release flag to rewrite)" % sys.argv[2])
