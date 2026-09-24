#!/usr/bin/env python3
"""
修改器菜单的回归测试。

构造一个临时 .love：给 payload 一个假的 `director` 模块和一张假的关卡 store，
用合成按键驱动菜单，断言可观察的行为。走的是「路径 2」—— 游戏把输入直接从
director.keypressed 转发出去，真实情况就是这样 —— 外加基于文件的命令通道。

**菜单项一律按 id 查找，不用下标**：菜单已经被重排过多次，
硬编码的下标会安静地按在错误的行上。

    python tools/selftest/test_menu2.py

退出码 0 = 全部断言通过。成功时还会出一张截图，可以打开肉眼确认菜单布局：
    %APPDATA%\\LOVE\\krmirror\\_kr6_shot.png
"""
import io
import os
import shutil
import subprocess
import sys
import zipfile

# Windows 控制台常是 cp936/cp1252；别让一次 print() 把整个测试弄挂。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

NL = chr(10)
Q = chr(34)
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RT = os.path.join(ROOT, "_scratch", "rt")
MIRROR = os.path.join(os.environ["APPDATA"], "krmirror")
LOVE_SAVE = os.path.join(os.environ["APPDATA"], "LOVE", "krmirror")

FAILURES = []


def check(cond, label, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + label + (("   " + detail) if detail else ""))
    if not cond:
        FAILURES.append(label)


def build_harness(release=False):
    """把 src/ 镜像到假存档目录，再生成驱动用的 .love。

    存档目录里的文件优先于游戏本体，所以 payload 会从这里被读出来。
    """
    shutil.rmtree(MIRROR, ignore_errors=True)
    os.makedirs(os.path.join(MIRROR, "all"), exist_ok=True)
    os.makedirs(os.path.join(MIRROR, "_orig"), exist_ok=True)

    payload = io.open(os.path.join(ROOT, "src", "_kr6trainer.lua"), encoding="utf-8").read()
    # payload 从 APPDATA + "kingdom_rush_genesis" 读自己的目录，这里改指向镜像目录
    payload = payload.replace("kingdom_rush_genesis", "krmirror")
    if release:
        sys.path.insert(0, os.path.join(ROOT, "tools"))
        from release_flags import release_flags
        payload = release_flags(payload)
    io.open(os.path.join(MIRROR, "_kr6trainer.lua"), "w", encoding="utf-8",
            newline=NL).write(payload)

    L = []
    w = L.append
    w('local frames, log, fake = 0, {}, nil')
    w('local M = os.getenv(' + Q + 'APPDATA' + Q + ') .. ' + Q + '/krmirror/' + Q)
    w('local function flush()')
    w('  local f = io.open(M .. ' + Q + '_selftest_log.txt' + Q + ', ' + Q + 'w' + Q + ')')
    w('  f:write(table.concat(log, string.char(10)) .. string.char(10)) f:close()')
    w('end')
    w('local function say(k, v) log[#log+1] = k .. ' + Q + '=' + Q + ' .. tostring(v) end')
    w('function love.load()')
    w('  local store = { player_gold = 700, lives = 30, gems_collected = 3,')
    w('                  gems_per_wave = 5, level_name = ' + Q + 'level05' + Q +
      ', force_next_wave = false }')
    w('  _G.game = { store = store }')
    w('  local src = io.open(M .. ' + Q + '_kr6trainer.lua' + Q + '):read(' + Q + '*a' + Q + ')')
    w('  local payload = loadstring(src, ' + Q + '_kr6trainer' + Q + ')')
    w('  fake = { calls = { keypressed = 0, mousepressed = 0, draw = 0, update = 0 } }')
    w('  fake.keypressed = function(...) fake.calls.keypressed = fake.calls.keypressed + 1 end')
    w('  fake.mousepressed = function(...) fake.calls.mousepressed = fake.calls.mousepressed + 1 end')
    w('  fake.draw = function(...) fake.calls.draw = fake.calls.draw + 1 end')
    w('  fake.update = function(...) fake.calls.update = fake.calls.update + 1 end')
    w('  local ok, err = pcall(payload, ' + Q + 'all/director.lua' + Q + ', fake)')
    w('  say(' + Q + 'payload_ok' + Q + ', ok)')
    w('  say(' + Q + 'wrap_error' + Q + ', err)')
    w('  local S = _G.__kr6trainer')
    w('  if type(S) ~= ' + Q + 'table' + Q + ' then say(' + Q + 'installed' + Q + ', false) flush() return end')
    w('  say(' + Q + 'installed' + Q + ', true)')
    w('  say(' + Q + 'route2_keys' + Q + ', S.wrap_src.director_keypressed)')
    w('  say(' + Q + 'route2_mouse' + Q + ', S.wrap_src.director_mousepressed)')
    # ---- 菜单基础行为
    w('  local function key(k) S.last_key = nil fake.keypressed(k) end')
    w('  local function idx_of(id)')
    w('    for i, it in ipairs(S.items or {}) do if it.id == id then return i end end')
    w('    return nil')
    w('  end')
    w('  local function pick(id)')
    w('    local i = idx_of(id)')
    w('    if not i then error(' + Q + 'no such menu item: ' + Q + ' .. tostring(id)) end')
    w('    S.sel = i')
    w('    return i')
    w('  end')
    w('  -- 功能键必须什么都不做（误触问题就是它们带来的）')
    w('  for _, fk in ipairs({ ' + Q + 'f1' + Q + ', ' + Q + 'f2' + Q + ', ' + Q + 'f3' + Q +
      ', ' + Q + 'f4' + Q + ', ' + Q + 'f5' + Q + ', ' + Q + 'f6' + Q + ' }) do key(fk) end')
    w('  say(' + Q + 'menu_after_fkeys' + Q + ', S.menu_open)')
    w('  say(' + Q + 'passthrough_after_fkeys' + Q + ', fake.calls.keypressed)')
    w('  key(' + Q + 'home' + Q + ')')
    w('  say(' + Q + 'after_home_open' + Q + ', S.menu_open)')
    w('  say(' + Q + 'home_swallowed' + Q + ', fake.calls.keypressed)')
    w('  key(' + Q + 'down' + Q + ')      -- 顺带触发 S.items 构建')
    w('  say(' + Q + 'after_down_sel' + Q + ', S.sel)')
    w('  say(' + Q + 'item1_id' + Q + ', S.items and S.items[1] and S.items[1].id)')
    w('  say(' + Q + 'item2_id' + Q + ', S.items and S.items[S.sel] and S.items[S.sel].id)')
    w('  say(' + Q + 'item_count' + Q + ', S.items and #S.items or -1)')
    w('  pick(' + Q + 'gold_add' + Q + ') key(' + Q + 'return' + Q + ')')
    w('  say(' + Q + 'gold_after_add' + Q + ', store.player_gold)')
    w('  say(' + Q + 'swallowed_orig_calls' + Q + ', fake.calls.keypressed)')
    w('  key(' + Q + 'escape' + Q + ')')
    w('  say(' + Q + 'after_escape_open' + Q + ', S.menu_open)')
    w('  key(' + Q + 'x' + Q + ')')
    w('  say(' + Q + 'passthrough_calls' + Q + ', fake.calls.keypressed)')
    # ---- 左右键微调
    w('  key(' + Q + 'home' + Q + ') pick(' + Q + 'lives_add' + Q + ') key(' + Q + 'right' + Q + ')')
    w('  say(' + Q + 'lives_after_right' + Q + ', store.lives)')
    w('  pick(' + Q + 'lives_sub' + Q + ') key(' + Q + 'return' + Q + ')')
    w('  say(' + Q + 'lives_after_sub' + Q + ', store.lives)')
    # ---- 无限金钱
    w('  pick(' + Q + 'hold' + Q + ') key(' + Q + 'return' + Q + ')')
    w('  say(' + Q + 'hold_on' + Q + ', S.hold)')
    w('  store.player_gold = 5  pcall(fake.update)')
    w('  say(' + Q + 'gold_after_hold' + Q + ', store.player_gold)')
    w('  pick(' + Q + 'hold' + Q + ') key(' + Q + 'return' + Q + ')      -- 关掉')
    # ---- 每个菜单项都必须有可用标签（标签为 nil 会让整个面板静默消失）
    w('  local bad = {}')
    w('  for i, it in ipairs(S.items or {}) do')
    w('    if type(it.label) ~= ' + Q + 'string' + Q + ' or it.label == ' + Q + '' + Q + ' then')
    w('      bad[#bad+1] = tostring(it.id)')
    w('    end')
    w('  end')
    w('  say(' + Q + 'labelless_items' + Q + ', table.concat(bad, ' + Q + ',' + Q + '))')
    # ---- 命令通道
    w('  local function runcmd(text)')
    w('    local f = io.open(M .. ' + Q + '_kr6_cmd.txt' + Q + ', ' + Q + 'w' + Q + ')')
    w('    f:write(text) f:close()')
    w('    S.last_cmd_check = 0')
    w('    pcall(fake.update)')
    w('    local g = io.open(M .. ' + Q + '_kr6_cmd_out.txt' + Q + ')')
    w('    local t = g and g:read(' + Q + '*a' + Q + ') or ' + Q + '' + Q + '')
    w('    if g then g:close() end')
    w('    return (t:gsub(string.char(10), ' + Q + '|' + Q + '))')
    w('  end')
    w('  say(' + Q + 'cmd_gold' + Q + ', runcmd(' + Q + 'gold 5000' + Q + '))')
    w('  say(' + Q + 'gold_after_cmd' + Q + ', store.player_gold)')
    w('  say(' + Q + 'cmd_lives' + Q + ', runcmd(' + Q + 'lives- 5' + Q + '))')
    w('  say(' + Q + 'cmd_bogus' + Q + ', runcmd(' + Q + 'cmd no_such_action' + Q + '))')
    # 回归：snap / diff / report / api 以前在 action() 里调用 nil 全局，
    # 于是菜单和命令文件这两条路静默死掉，只有心跳那条正常。
    w('  say(' + Q + 'cmd_snap' + Q + ', runcmd(' + Q + 'snap' + Q + '))')
    w('  say(' + Q + 'cmd_diff' + Q + ', runcmd(' + Q + 'diff' + Q + '))')
    w('  say(' + Q + 'cmd_report' + Q + ', runcmd(' + Q + 'report' + Q + '))')
    w('  say(' + Q + 'cmd_api' + Q + ', runcmd(' + Q + 'api' + Q + '))')
    w('  say(' + Q + 'cmd_store' + Q + ', runcmd(' + Q + 'store' + Q + '))')
    w('  say(' + Q + 'last_err' + Q + ', S.last_err)')
    # ---- 冒烟测试：把每个动作都从命令通道跑一遍。
    # 这条专门抓「调用了声明在它上面的函数」—— 名字会静默解析成 nil 全局，
    # 而且只有那一个动作挂掉，snap/diff/report/api 当初就是这么坏的。
    w('  local smoke = {}')
    w('  for _, it in ipairs(S.items or {}) do')
    # 跳过 tweak：它按设计必须有参数，不给参数必然失败
    w('    if it.id ~= ' + Q + 'tweak' + Q + ' then')
    w('      local reply = runcmd(' + Q + 'cmd ' + Q + ' .. it.id)')
    w('      if reply:find(' + Q + 'FAIL' + Q + ', 1, true)')
    w('         or reply:find(' + Q + 'unknown action' + Q + ', 1, true) then')
    w('        smoke[#smoke+1] = it.id .. ' + Q + '<' + Q + ' .. reply:sub(1, 40)')
    w('      end')
    w('    end')
    w('  end')
    w('  say(' + Q + 'smoke_failures' + Q + ', table.concat(smoke, ' + Q + ' ;; ' + Q + '))')
    w('  say(' + Q + 'smoke_ran' + Q + ', #(S.items or {}))')
    # ---- 表头必须反映实际状态，且绝不能打印 "nil"
    w('  S.menu_open = true')
    w('  S.drew = false  pcall(fake.draw)')
    w('  say(' + Q + 'header_in_level' + Q + ', S.header)')
    w('  _G.game.store = nil')
    w('  S.drew = false  pcall(fake.draw)')
    w('  say(' + Q + 'header_no_level' + Q + ', S.header)')
    w('  _G.game.store = store')
    w('  say(' + Q + 'release' + Q + ', ' + ('true' if release else 'false') + ')')
    # ---- 截图（走 director.draw 那条路）。shot 是开发版专有，
    # 发布版里不存在 —— 直接 pick 会抛错、卡在 LÖVE 的错误屏上。
    w('  S.menu_open = true')
    w('  if idx_of(' + Q + 'shot' + Q + ') then')
    w('    pick(' + Q + 'shot' + Q + ') key(' + Q + 'return' + Q + ')')
    w('  end')
    w('  say(' + Q + 'shot_queued' + Q + ', S.want_shot)')
    w('  flush()')
    w('end')
    w('function love.draw()')
    w('  love.graphics.setColor(45, 75, 110)')
    w('  love.graphics.rectangle(' + Q + 'fill' + Q + ', 0, 0, love.graphics.getWidth(), love.graphics.getHeight())')
    w('  love.graphics.setColor(235, 235, 235)')
    w('  love.graphics.print(' + Q + 'SELFTEST fake game screen' + Q + ', 20, 30)')
    w('  if fake then pcall(fake.draw) end      -- 游戏先画，director.draw 后画')
    w('end')
    w('function love.update(dt)')
    w('  frames = frames + 1')
    w('  if fake then pcall(fake.update) end')
    w('  if frames > 30 then flush() love.event.quit(0) end')
    w('end')
    io.open(os.path.join(RT, "syn", "main.lua"), "w", encoding="utf-8",
            newline=NL).write(NL.join(L) + NL)

    conf = ('function love.conf(t)' + NL + '  t.identity = ' + Q + 'krmirror' + Q + NL +
            '  t.window.width, t.window.height = 1280, 720' + NL +
            '  t.window.vsync = 0' + NL + '  t.modules.audio = false' + NL +
            '  t.modules.physics = false' + NL + 'end' + NL)
    io.open(os.path.join(RT, "syn", "conf.lua"), "w", encoding="utf-8", newline=NL).write(conf)

    with zipfile.ZipFile(os.path.join(RT, "selftest.love"), "w", zipfile.ZIP_DEFLATED) as z:
        for fn in ("conf.lua", "main.lua"):
            z.write(os.path.join(RT, "syn", fn), fn)


def run_and_read():
    subprocess.run([os.path.join(RT, "love.exe"), os.path.join(RT, "selftest.love")],
                   cwd=RT, timeout=60)
    logpath = os.path.join(MIRROR, "_selftest_log.txt")
    if not os.path.isfile(logpath):
        return None
    kv = {}
    for line in io.open(logpath, encoding="utf-8"):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            kv[k] = v
    return kv


def check_release_flag():
    """发布版必须真的把诊断去掉。"""
    src = io.open(os.path.join(ROOT, "src", "_kr6trainer.lua"), encoding="utf-8").read()
    check("local DEV = true" in src, "开发版默认 DEV = true")
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    from release_flags import release_flags
    out = release_flags(src)
    check("local DEV = false" in out, "release_flags() 关掉 DEV")
    check(out.count("local DEV = false") == 1, "只改写一处开关")
    # 幂等：发布包里 src/ 本来就是关的，在其上跑 --release 必须成功而不是报错
    check(release_flags(out) == out, "release_flags() 对发布版幂等")
    # 开关真的搬走时必须拒绝，而不是发出带诊断的包
    try:
        release_flags("-- no flag here")
        check(False, "开关缺失时 release_flags() 拒绝执行")
    except Exception:
        check(True, "开关缺失时 release_flags() 拒绝执行")


def main():
    if not os.path.isfile(os.path.join(RT, "love.exe")):
        print("运行时缺失，先裁一个...")
        subprocess.run([sys.executable, os.path.join(HERE, "make_runtime.py")], check=True)
        print()

    os.makedirs(os.path.join(RT, "syn"), exist_ok=True)
    os.makedirs(LOVE_SAVE, exist_ok=True)
    for stale in ("_selftest_log.txt", "_kr6_cmd.txt", "_kr6_cmd_out.txt", "_kr6_err.txt"):
        f = os.path.join(MIRROR, stale)
        if os.path.isfile(f):
            os.remove(f)
    shot = os.path.join(LOVE_SAVE, "_kr6_shot.png")
    if os.path.isfile(shot):
        os.remove(shot)

    print("=== 开发版 ===")
    build_harness(release=False)
    kv = run_and_read()
    if kv is None:
        print("没有产出日志 —— 测试台没跑起来")
        return 1

    print("\n断言:")
    check(kv.get("payload_ok") == "true", "payload 能加载并正常返回", kv.get("wrap_error", ""))
    check(kv.get("installed") == "true", "状态表已创建")
    check(kv.get("route2_keys") == "true", "已钩住 director.keypressed（路径 2）")
    check(kv.get("route2_mouse") == "true", "已钩住 director.mousepressed（路径 2）")
    # 功能键必须完全不触发（这是玩家要求的：容易误触）
    check(kv.get("menu_after_fkeys") == "false", "F1–F6 不会打开菜单")
    check(kv.get("passthrough_after_fkeys") == "6", "F1–F6 原样透传给游戏",
          "calls=" + kv.get("passthrough_after_fkeys", "?"))
    check(kv.get("after_home_open") == "true", "Home 打开菜单")
    check(kv.get("home_swallowed") == "6", "Home 被吃掉，没透传",
          "calls=" + kv.get("home_swallowed", "?"))
    check(kv.get("after_down_sel") == "2", "↓ 移动选择")
    check(kv.get("item1_id") == "gold_add" and kv.get("item2_id") == "gold_sub",
          "前两行仍是金币加减（布局约定）",
          "%s / %s" % (kv.get("item1_id", "?"), kv.get("item2_id", "?")))
    check(kv.get("gold_after_add") == "1700", "Enter 执行「金币 +1000」",
          "gold=" + kv.get("gold_after_add", "?"))
    check(kv.get("swallowed_orig_calls") == "6", "菜单开着时吞键（游戏处理器未被调用）",
          "calls=" + kv.get("swallowed_orig_calls", "?"))
    check(kv.get("after_escape_open") == "false", "Esc 关闭菜单")
    check(kv.get("passthrough_calls") == "7", "菜单关闭后按键正常透传",
          "calls=" + kv.get("passthrough_calls", "?"))
    check(kv.get("lives_after_right") == "40", "→ 微调生命 +10",
          "lives=" + kv.get("lives_after_right", "?"))
    check(kv.get("lives_after_sub") == "30", "生命 -10",
          "lives=" + kv.get("lives_after_sub", "?"))
    check(kv.get("hold_on") == "true", "无限金钱可开关")
    check(kv.get("gold_after_hold") == "999999", "无限金钱花掉后自动补满",
          "gold=" + kv.get("gold_after_hold", "?"))
    check(kv.get("labelless_items") == "", "每个菜单项都有标签", kv.get("labelless_items", "?"))
    # 命令通道
    check("gold 5000" in kv.get("cmd_gold", ""), "命令通道 gold 动词", kv.get("cmd_gold", "?")[:50])
    check(kv.get("gold_after_cmd") == "5000", "命令通道真的改了金币",
          kv.get("gold_after_cmd", "?"))
    check("lives" in kv.get("cmd_lives", ""), "命令通道 lives- 动词", kv.get("cmd_lives", "?")[:50])
    check("unknown action" in kv.get("cmd_bogus", ""), "坏命令会如实报错",
          kv.get("cmd_bogus", "?")[:60])
    # 回归：这四个曾经在菜单/命令文件两条路上静默失效
    check("snap " in kv.get("cmd_snap", ""), "snap 能跑并回复", kv.get("cmd_snap", "?")[:50])
    check("int +" in kv.get("cmd_diff", "") or "no snapshot" in kv.get("cmd_diff", ""),
          "diff 能跑并回复", kv.get("cmd_diff", "?")[:50])
    check("report(menu)" in kv.get("cmd_report", ""), "report 能跑并回复",
          kv.get("cmd_report", "?")[:50])
    check("api:" in kv.get("cmd_api", ""), "api 能跑并回复", kv.get("cmd_api", "?")[:50])
    check("store dumped" in kv.get("cmd_store", ""), "store 能跑并回复",
          kv.get("cmd_store", "?")[:50])
    check(os.path.isfile(os.path.join(MIRROR, "_kr6_report_menu.txt")), "report 写出了文件")
    check(kv.get("last_err") == "nil", "全程未记录任何错误", kv.get("last_err", "?"))
    # 冒烟测试
    check(kv.get("smoke_failures") == "", "每个菜单动作都能跑通不报错",
          kv.get("smoke_failures", "?")[:150])
    check(kv.get("smoke_ran") not in ("", "0", None), "冒烟测试跑遍了整个菜单",
          "items=" + kv.get("smoke_ran", "?"))
    # 表头
    h1, h2 = kv.get("header_in_level", ""), kv.get("header_no_level", "")
    check("nil" not in h1 and "nil" not in h2, "表头从不打印 nil", "%s / %s" % (h1[:40], h2[:40]))
    check(all(k in h1 for k in ("gold", "lives", "level05")),
          "关卡内表头显示金币/生命/关卡", h1[:50])
    check(kv.get("header_no_level") == "(not in a level)" or "金币" not in h2,
          "关卡外表头说明不在关卡内", h2[:50])
    check(kv.get("item_count") == "15", "开发版 15 项", "count=" + kv.get("item_count", "?"))
    check(kv.get("shot_queued") == "true", "能从菜单排队截图")
    check(os.path.isfile(shot), "截图已写出", shot)

    # ---- 发布版：开关改写 + 玩家实际看到什么
    print("\n=== 发布版 ===")
    check_release_flag()
    build_harness(release=True)
    rkv = run_and_read()
    if rkv is None:
        check(False, "发布版 payload 能跑")
        rkv = {}
    check(rkv.get("payload_ok") == "true", "发布版 payload 能加载")
    check(rkv.get("item_count") == "8", "发布版 8 项", "count=" + rkv.get("item_count", "?"))
    check(rkv.get("item1_id") == "gold_add", "发布版首行仍是金币加")
    # 逐个确认诊断项不在菜单里
    check(rkv.get("labelless_items") == "", "发布版每个菜单项都有标签")
    check(rkv.get("smoke_failures") == "", "发布版每个动作都能跑通",
          rkv.get("smoke_failures", "?")[:120])
    check(rkv.get("cmd_store", "").find("unknown action") >= 0,
          "发布版里 store 已不存在（被 DEV 关掉）", rkv.get("cmd_store", "?")[:60])

    print()
    if FAILURES:
        print("%d 项失败: %s" % (len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("全部通过。")
    print("菜单渲染截图: %s" % shot)
    return 0


if __name__ == "__main__":
    sys.exit(main())
