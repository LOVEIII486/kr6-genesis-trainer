#!/usr/bin/env python3
"""
改写 payload 的发布开关（DEV）—— **精简版已经不需要它了**。

历史：以前 `src/_kr6trainer.lua` 顶部有一个 `local DEV`，关掉它就没了诊断菜单项、
接口图、状态报告。构建链靠改那一行来出发布版，找不到就抛错，绝不静默发出带诊断的包。

现在分流成了两个文件：

  * `src/_kr6trainer.lua`     —— 精简版，**一个诊断项都没有**，两种版本完全一样，
                                 所以没有任何开关要改
  * `src/_kr6trainer_lab.lua` —— 功能全开的冻结快照，不发布，构建链不碰它

于是这个模块退化成一个**兼容垫片**：源码里没有开关就原样返回。保留它是因为
`install.py --release` 和 `tools/make_dist.py` 仍然会调它，删了要动三处调用方，
而留着的成本只是一个 no-op。

如果哪天精简版又要加回开关，把 DEV_ON/DEV_OFF 那套逻辑从 git 历史里捡回来即可
（本次提交之前的那一版就是）。
"""


class FlagNotFound(Exception):
    pass


def release_flags(src):
    """返回适合发布的 `src`。

    精简版没有开关，所以**原样返回**。保留这个签名是为了不动调用方。
    """
    return src


if __name__ == "__main__":
    import io
    import sys
    if len(sys.argv) != 3:
        sys.exit("usage: release_flags.py <src.lua> <dst.lua>")
    io.open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(
        release_flags(io.open(sys.argv[1], encoding="utf-8").read()))
    print("wrote %s (slim build: no release flag to rewrite)" % sys.argv[2])
