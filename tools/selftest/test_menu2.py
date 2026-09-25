#!/usr/bin/env python3
"""
修改器菜单的回归测试。

    python tools/selftest/test_menu2.py

退出码 0 = 全部断言通过。成功时还会出一张截图
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

    存档目录里的文件优先于游戏本体，所以 payload 会从这里被读出来。"""
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
      ', force_next_wave = false,')
    # ★ 故意做成**稀疏**表：没有 [1]，只有 [2] 和 [7]。实机上的 store.entities 就长这样
    #   （下标从 2 起、中间有洞）。别改成连续表 —— 这份数据是那条 bug 的回归哨兵。
    w('                  entities = {')
    # health 必须同时给 hp 和 hp_max：只缩上限没用（当前血量不变，敌人照样按原血量死掉）。
    w('                    [2] = { id = 2, health = { hp_max = 200, hp = 200 },')
    w('                            motion = { max_speed = 40 } },')
    # [7] 故意不连续，用来证明遍历真的走的是 pairs 而不是 1..#
    w('                    [7] = { id = 7, health = { hp_max = 100, hp = 100 },')
    w('                            motion = { max_speed = 20 } },')
    w('                  } }')
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
    # 按「第 n 个可执行条目」取 id，跳过分组标题 —— 这样断言布局约定时
    # 不必关心菜单里插了几个标题，加分组不会碰坏它。
    w('  local function nth_action(n)')
    w('    local c = 0')
    w('    for _, it in ipairs(S.items or {}) do')
    w('      if not it.header then')
    w('        c = c + 1')
    w('        if c == n then return it.id end')
    w('      end')
    w('    end')
    w('    return nil')
    w('  end')
    # 整排 F1–F12 都必须什么都不做：F1–F3 是玩家的物品热键，游戏的调试键
    # （F5/F8/F9/F10/F12）也在这段 —— 谁想用 F 键当菜单键都会先撞上这条。
    fkeys = (', ').join(Q + ('f%d' % i) + Q for i in range(1, 13))
    w('  -- 功能键必须什么都不做（误触问题就是它们带来的）')
    w('  for _, fk in ipairs({ ' + fkeys + ' }) do key(fk) end')
    w('  say(' + Q + 'menu_after_fkeys' + Q + ', S.menu_open)')
    w('  say(' + Q + 'passthrough_after_fkeys' + Q + ', fake.calls.keypressed)')
    w('  key(' + Q + 'home' + Q + ')')
    w('  say(' + Q + 'after_home_open' + Q + ', S.menu_open)')
    w('  say(' + Q + 'home_swallowed' + Q + ', fake.calls.keypressed)')
    w('  key(' + Q + 'down' + Q + ')      -- 顺带触发 S.items 构建')
    w('  say(' + Q + 'after_down_id' + Q + ', S.items and S.items[S.sel] and S.items[S.sel].id)')
    w('  say(' + Q + 'after_down_is_header' + Q + ', S.items and S.items[S.sel] and S.items[S.sel].header or false)')
    w('  say(' + Q + 'item1_id' + Q + ', nth_action(1))')
    w('  say(' + Q + 'item2_id' + Q + ', nth_action(2))')
    w('  say(' + Q + 'item_count' + Q + ', S.items and #S.items or -1)')
    # 分组标题必须真的存在，否则下面「↓ 不会停在标题上」的断言会空转
    w('  local hdr = 0')
    w('  for _, it in ipairs(S.items or {}) do if it.header then hdr = hdr + 1 end end')
    w('  say(' + Q + 'header_count' + Q + ', hdr)')
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
    # 标签 == id 是 menu_items() 里 L(id) 回退的特征（MENU_TEXT 漏了这条文案，cn/en 任一边），
    # 所以只能这么查：光查「非空字符串」永远为真，等于没测。
    w('  local bad = {}')
    w('  for i, it in ipairs(S.items or {}) do')
    w('    if type(it.label) ~= ' + Q + 'string' + Q + ' or it.label == ' + Q + '' + Q +
      ' or it.label == it.id then')
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
    # ---- 倍率行走 S.mult，**不走 store**（tweak 的第二种目标）
    w('  S.menu_open = true')
    w('  pick(' + Q + 'enemy_hp' + Q + ') key(' + Q + 'right' + Q + ')')
    w('  say(' + Q + 'mult_after_right' + Q + ', S.mult.enemy_hp)')
    # tick 只认第一个到达的源（假 director 的 update），所以这里必须显式推一帧
    w('  pcall(fake.update)')
    # 倍率非 x1 时必须进入"每帧重放"状态
    w('  say(' + Q + 'mult_active_after_raise' + Q + ', S.mult_active)')
    w('  pick(' + Q + 'enemy_hp' + Q + ') key(' + Q + 'left' + Q + ')')
    w('  say(' + Q + 'mult_after_left' + Q + ', S.mult.enemy_hp)')
    w('  pcall(fake.update)')
    # 调回 x1 后必须**再跑一趟收尾重放**才停手：守卫条件此刻已经变假，
    # 不补跑的话模板会永远停在放大后的值上。
    w('  say(' + Q + 'mult_active_after_reset' + Q + ', S.mult_active)')
    # 下调到下限要停住，且**不能**返回 FAIL（冒烟测试把 FAIL 当失败）。
    # enemy_hp 的下限是 0.1（不是 1），所以先摆到下限再按左键。
    w('  S.mult.enemy_hp = 0.1')
    w('  pick(' + Q + 'enemy_hp' + Q + ') key(' + Q + 'left' + Q + ')')
    w('  say(' + Q + 'mult_at_floor' + Q + ', S.mult.enemy_hp)')
    w('  say(' + Q + 'last_err' + Q + ', S.last_err)')
    # ---- 存档改写逻辑（S.slot_apply / S.slot_like 是刻意暴露给测试的）。
    # 测试环境没有 storage 模块、钩子装不上，所以直接调这两个函数。
    w('  local function mk_slot()')
    w('    return { gems = 100, last_stars = 0,')
    w('             levels = { [1] = { stars = 2 }, [2] = { stars = 1 } },')
    # 存档里升级树是**数组**（{ "l1" }），不是字典 —— 写成 { l1 = "l1" } 就不是
    # 存档的形状了，测试会假过。
    # ⚠️ 节点名按**真实存档**来：防御塔树和英雄树用的是同一套短 id（l1..ulti），
    # 而且英雄树可能整个是空的。曾经 fixture 造了个 hero_x = { "skill_a" } 的假形状，
    # 把"英雄风格"那条错误分支养活了 —— 而游戏里没有 skill_a/upg_a 这些名字，
    # 写进存档会坏档（实际发生过）。别再写回来。
    w('             upgrades_trees = { archers = { "l1" }, hero_gerald = {} },')
    w('             towers = { status = { archers = true, wizard = true },')
    w('                        selected = { "archers" } },')
    # heroes.status 的每个英雄是**表**（{ skills, xp }），不是布尔 —— 写成 true 的话
    # 英雄升级 op 会抛错被 pcall 吞掉，测试照样通过（假过）。selected 是「出战英雄」。
    w('             heroes = { status = { hero_a = { xp = 2865 }, hero_b = { xp = 0 } },')
    w('                        selected = "hero_a", team = { "hero_a" } },')
    w('             progression = { last_stars = 0 } }')
    w('  end')
    # 指纹：不满足 gems/levels/upgrades_trees 的表一律不认（否则会误改别的表）
    w('  say(' + Q + 'slot_like_ok' + Q + ', S.slot_like(mk_slot()))')
    w('  say(' + Q + 'slot_like_rejects' + Q + ', S.slot_like({ gems = 1, foo = 2 }))')
    w('  say(' + Q + 'slot_like_rejects_str' + Q + ', S.slot_like({ gems = ' + Q + 'x' + Q +
      ', levels = {}, upgrades_trees = {} }))')
    # 待办是**一次性**的：应用完就清空，否则会变成"每帧覆盖存档"，
    # 玩家自己赚的宝石再也涨不上去。
    w('  S.slot_ops = {}')
    w('  local function queue_op(o) S.slot_ops[#S.slot_ops+1] = o end')
    # 星星：补到够拿完轨道，且**故意不动 last_stars**（那是游戏发现新星星的机制）
    w('  queue_op({ op = ' + Q + 'stars' + Q + ' })')
    w('  local t2 = mk_slot()  S.slot_apply(t2)')
    w('  local total = 0')
    w('  for _, e in pairs(t2.levels) do total = total + (e.stars or 0) end')
    w('  say(' + Q + 'stars_total' + Q + ', total)')
    w('  say(' + Q + 'last_stars_untouched' + Q + ', t2.progression.last_stars)')
    w('  say(' + Q + 'ops_cleared' + Q + ', #S.slot_ops)')
    # 升级树：补全但**沿用该表已有的风格**（短 id 命名空间不能混）
    w('  S.slot_ops = {}')
    w('  queue_op({ op = ' + Q + 'tree' + Q + ' })')
    w('  local t3 = mk_slot()  S.slot_apply(t3)')
    # 升级树在存档里是**数组**，节点名是「值」不是「键」—— 要点名检查不能写 arr.ulti。
    w('  local function has_val(arr, v)')
    w('    for _, x in pairs(arr) do if tostring(x) == v then return true end end')
    w('    return false')
    w('  end')
    w('  say(' + Q + 'tree_filled' + Q + ',')
    w('    has_val(t3.upgrades_trees.archers, ' + Q + 'ulti' + Q + ') and')
    w('    has_val(t3.upgrades_trees.hero_gerald, ' + Q + 'ulti' + Q + '))')
    # ★ 绝不能写入游戏里不存在的节点名（skill_* / talent_* / upg_* / ultimate）——
    # 那是曾经坏过档的原因，也是这份断言存在的唯一理由。
    w('  local bogus = { "skill_a", "skill_b", "skill_c", "talent_1", "talent_2",')
    w('                  "upg_a", "upg_b", "ultimate" }')
    w('  local nbad = 0')
    w('  for _, k in ipairs({ "archers", "hero_gerald" }) do')
    w('    for _, v in ipairs(bogus) do')
    w('      if has_val(t3.upgrades_trees[k], v) then nbad = nbad + 1 end')
    w('    end')
    w('  end')
    w('  say(' + Q + 'tree_no_bogus' + Q + ', nbad)')

    # 英雄升级：只动**出战英雄**（heroes.selected），别的英雄一个字段都不许变。
    # 这里测 max 模式 —— 它不依赖任何未验证的东西（next 模式要读 game_settings 里那张
    # 阈值表，测试台没有那个模块，所以那条路只能在实机验）。
    w('  S.slot_ops = {}')
    w('  queue_op({ op = ' + Q + 'hero_level' + Q + ', mode = ' + Q + 'max' + Q + ' })')
    w('  local t4 = mk_slot()  S.slot_apply(t4)')
    w('  say(' + Q + 'hero_xp_raised' + Q + ', t4.heroes.status.hero_a.xp)')
    w('  say(' + Q + 'hero_other_untouched' + Q + ', t4.heroes.status.hero_b.xp)')
    # 形状不对（条目是布尔）→ 失败**且什么都不改**，绝不新建条目（新建等于替玩家伪造一个
    # 他没拥有的英雄）。这条同时钉住 apply_slot_ops：结构化失败不能被算成应用成功。
    w('  S.slot_ops = {}')
    w('  S.slot_ops_done = 0')
    w('  local bad = mk_slot()')
    w('  bad.heroes.status.hero_a = true')
    w('  queue_op({ op = ' + Q + 'hero_level' + Q + ', mode = ' + Q + 'max' + Q + ' })')
    w('  local applied = S.slot_apply(bad)')
    w('  say(' + Q + 'hero_bad_applied' + Q + ', applied)')
    w('  say(' + Q + 'hero_bad_done' + Q + ', S.slot_ops_done)')
    w('  say(' + Q + 'hero_bad_untouched' + Q + ', tostring(bad.heroes.status.hero_a))')
    w('  say(' + Q + 'hero_bad_no_new_key' + Q + ', bad.heroes.status.hero_c == nil)')
    # 没出息英雄可用时（status 缺失）同样失败、不抛错
    w('  S.slot_ops = {}')
    w('  local ns = mk_slot()')
    w('  ns.heroes.status = {}')
    w('  queue_op({ op = ' + Q + 'hero_level' + Q + ', mode = ' + Q + 'max' + Q + ' })')
    w('  say(' + Q + 'hero_none_applied' + Q + ', S.slot_apply(ns))')

    # ---- 稀疏 entities 的回归：假 store 故意只放 [2] 和 [7]、没有 [1] —— 遍历写成
    # `for i = 1, #s.entities` 会一次都不进（# 返回 0），倍率整个静默失效。
    w('  S.mult.enemy_hp = 5')
    w('  pcall(fake.update)')
    w('  say(' + Q + 'hp_max_after' + Q + ', store.entities[2].health.hp_max)')
    w('  say(' + Q + 'hp_after' + Q + ', store.entities[2].health.hp)')
    w('  say(' + Q + 'hp_max_after_7' + Q + ', store.entities[7].health.hp_max)')
    w('  S.mult.enemy_speed = 2')
    w('  pcall(fake.update)')
    w('  say(' + Q + 'speed_after' + Q + ', store.entities[2].motion.max_speed)')
    w('  say(' + Q + 'speed_after_7' + Q + ', store.entities[7].motion.max_speed)')
    w('  S.mult.enemy_speed = 1')
    w('  pcall(fake.update)')
    w('  S.mult.enemy_hp = 1')
    w('  pcall(fake.update)')
    w('  say(' + Q + 'hp_max_back' + Q + ', store.entities[2].health.hp_max)')
    # ---- 冒烟测试：把每个动作都从命令通道跑一遍。
    # 专门抓「调用了声明在它上面的函数」—— 名字会静默解析成 nil 全局，只有那一个动作挂掉。
    w('  local smoke = {}')
    w('  for _, it in ipairs(S.items or {}) do')
    # 跳过两类：tweak「按设计必须有参数，不给参数必然失败」；分组标题
    # 「不是动作，跑出来必然是 unknown action hdr_xxx」。
    w('    if not it.header and it.id ~= ' + Q + 'tweak' + Q + ' then')
    w('      local reply = runcmd(' + Q + 'cmd ' + Q + ' .. it.id)')
    w('      if reply:find(' + Q + 'FAIL' + Q + ', 1, true)')
    w('         or reply:find(' + Q + 'unknown action' + Q + ', 1, true) then')
    w('        smoke[#smoke+1] = it.id .. ' + Q + '<' + Q + ' .. reply:sub(1, 40)')
    w('      end')
    w('    end')
    w('  end')
    w('  say(' + Q + 'smoke_failures' + Q + ', table.concat(smoke, ' + Q + ' ;; ' + Q + '))')
    w('  say(' + Q + 'smoke_ran' + Q + ', #(S.items or {}))')
    # 全部条目 id（含标题）。门控靠它做集合断言，别写回「项数必须等于 N」的硬编码 ——
    # 那样每加一个菜单项就得手改一次。
    w('  local ids = {}')
    w('  for _, it in ipairs(S.items or {}) do ids[#ids+1] = tostring(it.id) end')
    w('  say(' + Q + 'all_item_ids' + Q + ', table.concat(ids, ' + Q + ',' + Q + '))')
    # ---- 表头必须反映实际状态，且绝不能打印 "nil"
    w('  S.menu_open = true')
    w('  S.drew = false  pcall(fake.draw)')
    w('  say(' + Q + 'header_in_level' + Q + ', S.header)')
    # 分组标题的命中框（S.rects 是 draw 时建的，所以这条必须在 draw 之后）。
    # 标题行没有命中框的话，点在标题上会被当成「没点中」漏给游戏。
    w('  local badrect = {}')
    w('  for i, it in ipairs(S.items or {}) do')
    w('    local r = S.rects and S.rects[i]')
    w('    if type(r) ~= ' + Q + 'table' + Q + ' then')
    w('      badrect[#badrect+1] = tostring(it.id) .. ' + Q + '=norc' + Q)
    w('    elseif it.header and not r.header then')
    w('      badrect[#badrect+1] = tostring(it.id) .. ' + Q + '=nomark' + Q)
    w('    end')
    w('  end')
    w('  say(' + Q + 'rect_mismatch' + Q + ', table.concat(badrect, ' + Q + ',' + Q + '))')
    w('  _G.game.store = nil')
    w('  S.drew = false  pcall(fake.draw)')
    w('  say(' + Q + 'header_no_level' + Q + ', S.header)')
    w('  _G.game.store = store')
    w('  say(' + Q + 'release' + Q + ', ' + ('true' if release else 'false') + ')')
    w('  S.menu_open = true')
    w('  flush()')
    w('end')
    w('function love.draw()')
    w('  love.graphics.setColor(45, 75, 110)')
    w('  love.graphics.rectangle(' + Q + 'fill' + Q + ', 0, 0, love.graphics.getWidth(), love.graphics.getHeight())')
    w('  love.graphics.setColor(235, 235, 235)')
    w('  love.graphics.print(' + Q + 'SELFTEST fake game screen' + Q + ', 20, 30)')
    w('  if fake then pcall(fake.draw) end      -- 游戏先画，director.draw 后画')
    # 截图**在测试台这边做**，不在 payload 里 —— 截屏是开发期诊断，
    # 精简版不该为它多带一段代码。这一趟是最后一帧，菜单已经画好了。
    w('  if frames > 25 and not shot_done then')
    w('    shot_done = true')
    w('    pcall(function()')
    w('      local sid = love.graphics.newScreenshot()')
    w('      sid:encode(' + Q + 'png' + Q + ', ' + Q + '_kr6_shot.png' + Q + ')')
    w('    end)')
    w('  end')
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


def check_slim_payload():
    """精简版的硬约束：**一个诊断项都不许有**，构建链也不该再依赖已删掉的 DEV 开关。

    直接检查源码：既不该出现开关，也不该出现那批诊断动作 id。
    """
    src = io.open(os.path.join(ROOT, "src", "_kr6trainer.lua"), encoding="utf-8").read()
    check("local DEV = " not in src, "精简版里没有 DEV 开关")
    check("AUTO_REPORT" not in src, "精简版里没有自动报告开关")
    # 只查函数名/动作 id，不查裸词 —— 注释里提一句「探针」是合理的，
    # 不该被当成"精简版里还有 probe"。
    for gone in ("probe_dump", '"probe"', "api_sweep", "dump_store", "kill_all",
                 "free_towers", "all_towers", "hide_ui", "tower_dmg",
                 "gems_add", "unlock_all"):
        check(gone not in src, "精简版里没有 " + gone)
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    from release_flags import release_flags
    check(release_flags(src) == src, "release_flags() 对精简版是 no-op（不该再改任何东西）")


def main():
    if not os.path.isfile(os.path.join(RT, "love.exe")):
        print("运行时缺失，先裁一个...")
        subprocess.run([sys.executable, os.path.join(HERE, "make_runtime.py")], check=True)
        print()

    os.makedirs(os.path.join(RT, "syn"), exist_ok=True)
    os.makedirs(LOVE_SAVE, exist_ok=True)
    for stale in ("_selftest_log.txt", "_kr6_cmd.txt", "_kr6_cmd_out.txt",
                  "_kr6_err.txt", "_kr6_probe.txt"):
        f = os.path.join(MIRROR, stale)
        if os.path.isfile(f):
            os.remove(f)
    shot = os.path.join(LOVE_SAVE, "_kr6_shot.png")
    if os.path.isfile(shot):
        os.remove(shot)

    print("=== 精简版 ===")
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
    check(kv.get("passthrough_after_fkeys") == "12", "F1–F12 原样透传给游戏",
          "calls=" + kv.get("passthrough_after_fkeys", "?"))
    check(kv.get("after_home_open") == "true", "Home 打开菜单")
    check(kv.get("home_swallowed") == "12", "Home 被吃掉，没透传",
          "calls=" + kv.get("home_swallowed", "?"))
    # ↓ 的语义断言：只关心「确实动了」+「不会停在分组标题上」，
    # 不写死落到第几项（那样每加一个条目就会假报警）。
    check(kv.get("after_down_is_header") == "false",
          "↓ 不会停在分组标题上", kv.get("after_down_id", "?"))
    check(kv.get("after_down_id") != "gold_add",
          "↓ 真的移动了选择", kv.get("after_down_id", "?"))
    check(kv.get("item1_id") == "gold_add" and kv.get("item2_id") == "gold_sub",
          "前两行仍是金币加减（布局约定）",
          "%s / %s" % (kv.get("item1_id", "?"), kv.get("item2_id", "?")))
    check(kv.get("gold_after_add") == "1700", "Enter 执行「金币 +1000」",
          "gold=" + kv.get("gold_after_add", "?"))
    check(kv.get("swallowed_orig_calls") == "12", "菜单开着时吞键（游戏处理器未被调用）",
          "calls=" + kv.get("swallowed_orig_calls", "?"))
    check(kv.get("after_escape_open") == "false", "Esc 关闭菜单")
    check(kv.get("passthrough_calls") == "13", "菜单关闭后按键正常透传",
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
    check(kv.get("last_err") == "nil", "全程未记录任何错误", kv.get("last_err", "?"))
    # 冒烟测试
    check(kv.get("smoke_failures") == "", "每个菜单动作都能跑通不报错",
          kv.get("smoke_failures", "?")[:150])
    check(kv.get("smoke_ran") not in ("", "0", None), "冒烟测试跑遍了整个菜单",
          "items=" + kv.get("smoke_ran", "?"))
    # 倍率：走 S.mult，**不碰 store**（tweak 的第二个目标）
    check(kv.get("mult_after_right") == "1.5", "→ 调高倍率（落在 S.mult 上）",
          "val=" + kv.get("mult_after_right", "?"))
    check(kv.get("mult_after_left") == "1", "← 调回倍率",
          "val=" + kv.get("mult_after_left", "?"))
    check(kv.get("mult_active_after_raise") == "true", "倍率非 1 时进入每帧重放",
          "val=" + kv.get("mult_active_after_raise", "?"))
    check(kv.get("mult_active_after_reset") == "false",
          "倍率调回 1 后跑完收尾重放才停手（否则模板回不去）",
          "val=" + kv.get("mult_active_after_reset", "?"))
    check(kv.get("mult_at_floor") == "0.1", "倍率到下限（0.1）就停住，不越界",
          "val=" + kv.get("mult_at_floor", "?"))
    # 回归：**store.entities 是稀疏表**，必须用 pairs 而不是 1..#（细节见上面的假 store）。
    check(kv.get("hp_max_after") == "1000", "敌人血量倍率够得到稀疏实体表（不是 1..#）",
          "hp_max=" + kv.get("hp_max_after", "?"))
    check(kv.get("hp_after") == "1000", "血量成对缩放：当前血量也缩了（只缩上限等于没缩）",
          "hp=" + kv.get("hp_after", "?"))
    check(kv.get("hp_max_after_7") == "500", "也够得到下标 7 那个实体",
          "hp_max[7]=" + kv.get("hp_max_after_7", "?"))
    check(kv.get("speed_after") == "80", "敌人移速倍率缩的是 motion.max_speed",
          "speed=" + kv.get("speed_after", "?"))
    check(kv.get("speed_after_7") == "40", "移速也够得到下标 7",
          "speed[7]=" + kv.get("speed_after_7", "?"))
    check(kv.get("hp_max_back") == "200", "调回 x1 血量能还原",
          "hp_max=" + kv.get("hp_max_back", "?"))
    # ---- 存档改写（会动玩家数据，单独测）
    check(kv.get("slot_like_ok") == "true", "存档指纹认得真存档表",
          kv.get("slot_like_ok", "?"))
    check(kv.get("slot_like_rejects") == "false", "存档指纹拒绝不完整的表",
          kv.get("slot_like_rejects", "?"))
    check(kv.get("slot_like_rejects_str") == "false", "gems 不是数字时不认（防误改别的表）",
          kv.get("slot_like_rejects_str", "?"))
    check(kv.get("ops_cleared") == "0", "应用完就清空待办（否则会变成每帧覆盖存档）",
          "pending=" + kv.get("ops_cleared", "?"))
    try:
        st = int(kv.get("stars_total", "0"))
    except ValueError:
        st = 0
    check(st >= 84, "星星补到够拿完奖励轨道", "total=" + kv.get("stars_total", "?"))
    check(kv.get("last_stars_untouched") == "0",
          "故意不动 progression.last_stars（游戏靠它发现新星星并发放内容）",
          "last_stars=" + kv.get("last_stars_untouched", "?"))
    check(kv.get("tree_filled") == "true",
          "升级树补全：防御塔树和英雄树都用同一套真实节点名补全（含空英雄树）",
          kv.get("tree_filled", "?"))
    check(kv.get("tree_no_bogus") == "0",
          "没有写入游戏里不存在的节点名（skill_*/talent_*/upg_*/ultimate）",
          "bogus=" + kv.get("tree_no_bogus", "?"))
    # 英雄升级
    check(int(kv.get("hero_xp_raised", "0")) > 2865, "英雄拉满把出战英雄的经验抬高",
          "xp=" + kv.get("hero_xp_raised", "?"))
    check(kv.get("hero_other_untouched") == "0", "只动出战英雄，其他英雄的经验一个都不变",
          "hero_b xp=" + kv.get("hero_other_untouched", "?"))
    check(kv.get("hero_bad_applied") == "0",
          "存档形状不对时英雄 op 不算应用成功（结构化失败不能被当成成功）",
          "applied=" + kv.get("hero_bad_applied", "?"))
    check(kv.get("hero_bad_done") == "0", "失败的 op 不计入 slot_ops_done",
          "done=" + kv.get("hero_bad_done", "?"))
    check(kv.get("hero_bad_untouched") == "true", "失败时连碰都不碰那个条目",
          kv.get("hero_bad_untouched", "?"))
    check(kv.get("hero_bad_no_new_key") == "true", "失败时不新建英雄条目（不伪造拥有权）",
          kv.get("hero_bad_no_new_key", "?"))
    check(kv.get("hero_none_applied") == "0", "没有出战英雄可解析时失败且不抛错",
          "applied=" + kv.get("hero_none_applied", "?"))
    # 表头
    h1, h2 = kv.get("header_in_level", ""), kv.get("header_no_level", "")
    check("nil" not in h1 and "nil" not in h2, "表头从不打印 nil", "%s / %s" % (h1[:40], h2[:40]))
    check(all(k in h1 for k in ("gold", "lives", "level05")),
          "关卡内表头显示金币/生命/关卡", h1[:50])
    check(kv.get("header_no_level") == "(not in a level)" or "金币" not in h2,
          "关卡外表头说明不在关卡内", h2[:50])
    check(int(kv.get("header_count", "0")) >= 4, "菜单里有分组标题",
          "headers=" + kv.get("header_count", "?"))
    check(kv.get("rect_mismatch") == "", "每个条目（含标题）都有命中框，标题带标记",
          kv.get("rect_mismatch", "?"))
    ids = kv.get("all_item_ids", "").split(",")
    # 精简版**应该**有的（金币/生命/无限金钱 + 敌人血量/移速 + 星星/升级树）
    for want in ("gold_add", "gold_sub", "lives_add", "lives_sub", "hold",
                 "hold_lives", "next_wave", "enemy_hp", "enemy_speed",
                 "stars_max", "unlock_tree",
                 "hero_now_up", "hero_now_max", "close"):
        check(want in ids, "菜单含 " + want)
    # **不该**有的：删掉的那些必须真的不在 —— 免得哪天又把未验证的东西混回来
    for gone in ("tower_dmg", "tower_range", "tower_rate", "free_towers",
                 "all_towers", "kill_all", "hide_ui", "gems_add", "unlock_all",
                 "probe", "store", "api", "report", "snap", "diff", "shot",
                 "level_gems_add",
                 # 曾经在「存档」组里和「塔与单位」组的即时项**同名并存**，
                 # 结果玩家按错、以为功能坏了。英雄升级只留即时那一份。
                 "hero_level_up", "hero_level_max"):
        check(gone not in ids, "精简版菜单里没有 " + gone)

    # 源码层面的硬约束（没有 DEV 开关、没有诊断、release_flags 已是 no-op）
    check_slim_payload()

    print()
    if FAILURES:
        print("%d 项失败: %s" % (len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("全部通过。")
    print("菜单渲染截图: %s" % shot)
    return 0


if __name__ == "__main__":
    sys.exit(main())
