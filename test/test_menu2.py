#!/usr/bin/env python3
"""
修改器菜单的回归测试。

    python test/test_menu2.py

退出码 0 = 全部断言通过。成功时还会出一张截图
    %APPDATA%\\LOVE\\krmirror\\_kr6_shot.png
"""
import io
import os
import re
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
# 双引号。harness 的 Lua 现在直接用 Python 单引号字符串写（`w('... "..." ...')`），
# 只有一处动态拼接还要它（F 键那行）。留着是因为它也让 Lua 里的引号一眼可辨。
Q = chr(34)
# 整排功能键：一个都不能当热键（F1–F3 是玩家的物品热键）。
FKEYS = tuple("f%d" % i for i in range(1, 13))
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
RT = os.path.join(ROOT, "_scratch", "rt")
MIRROR = os.path.join(os.environ["APPDATA"], "krmirror")
LOVE_SAVE = os.path.join(os.environ["APPDATA"], "LOVE", "krmirror")

FAILURES = []


def check(cond, label, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + label + (("   " + detail) if detail else ""))
    if not cond:
        FAILURES.append(label)


def num(kv, key, default=0.0):
    """KV 日志里的数值；缺项/不是数字时给 default（用于「大于 0」这类断言）。"""
    try:
        return float(kv.get(key, ""))
    except (TypeError, ValueError):
        return default


def near(kv, key, want, tol=1e-9):
    """KV 日志里的数值近似比较。

    倍率来回乘除一趟会有末位误差（600 x 1/3 得 199.99999999999997），所以倍率类断言
    一律走这里，别拿字符串比 —— 那样会报一堆看着像 bug 的假失败。
    """
    try:
        return abs(float(kv.get(key, "")) - want) <= tol
    except (TypeError, ValueError):
        return False


def build_harness():
    """把 src/ 镜像到假存档目录，再生成驱动用的 .love。

    存档目录里的文件优先于游戏本体，所以 payload 会从这里被读出来。"""
    shutil.rmtree(MIRROR, ignore_errors=True)
    os.makedirs(os.path.join(MIRROR, "all"), exist_ok=True)
    os.makedirs(os.path.join(MIRROR, "_orig"), exist_ok=True)

    payload = io.open(os.path.join(ROOT, "src", "_kr6trainer.lua"), encoding="utf-8").read()
    # payload 从 APPDATA + "kingdom_rush_genesis" 读自己的目录，这里改指向镜像目录
    payload = payload.replace("kingdom_rush_genesis", "krmirror")
    io.open(os.path.join(MIRROR, "_kr6trainer.lua"), "w", encoding="utf-8",
            newline=NL).write(payload)

    L = []
    w = L.append
    w('local frames, log, fake = 0, {}, nil')
    w('local M = os.getenv("APPDATA") .. "/krmirror/"')
    w('local function flush()')
    w('  local f = io.open(M .. "_selftest_log.txt", "w")')
    w('  f:write(table.concat(log, string.char(10)) .. string.char(10)) f:close()')
    w('end')
    w('local function say(k, v) log[#log+1] = k .. "=" .. tostring(v) end')
    w('function love.load()')
    # 整段测试台包在 xpcall 里：报错时**落进日志**（否则 LÖVE 弹错误屏、进程不退，
    # 测试只会在 60 秒超时后死掉，什么线索都不给）。
    w('  local ok, err = xpcall(function()')
    # 英雄**同时**进 entities 与 hero_team（真游戏里就是这样：英雄是关卡实体，hero_team 只是
    # 队伍列表）。遍历必须走 entities —— 剧情英雄走 LU.insert_hero，不写 hero_team。
    # 英雄技能冷却是实体上的 timed_attacks 容器（探针实测：实体上没有 *_cd 字段）；
    # hero.skills 里也有一份。实体自己的 attack_cd 是基础攻击节奏，不许动。
    w('  local fake_hero = { hero = { level = 3, skills = { { cooldown = 3 } } },')
    w('                      template_name = "hero_gerald", attack_cd = 2,')
    w('                      timed_attacks = { { cd = 4, ts = 12 } } }')
    # 只在 entities、不在 hero_team —— 3 个剧情英雄的哨兵。
    w('  local fake_stage_hero = { hero = { level = 1, stage_hero = true },')
    w('                            template_name = "hero_stage_alleria",')
    w('                            timed_attacks = { { cd = 30 } } }')
    # 带 fn_level_up 的英雄，专测「解锁满级成就」：回调照游戏那份写（纯赋值 + hp 跟着上限）。
    # level_stats.hp_max 是 10 级满表，用值本身当"有没有真的应用那一级"的凭据。
    w('  local fake_hero2 = { hero = { level = 3, xp = 10500,')
    w('                             level_stats = { hp_max = { 100, 200, 300, 400, 500,')
    w('                                                          600, 700, 800, 900, 1000 } },')
    w('                             fn_level_up = function(this, st, initial)')
    w('                               local hl = this.hero.level')
    w('                               this.health.hp_max = this.hero.level_stats.hp_max[hl]')
    w('                               this.health.hp = this.health.hp_max')
    w('                             end },')
    w('                        health = { hp_max = 300, hp = 300 },')
    w('                        template_name = "hero_test_unlock" }')
    w('  local store = { player_gold = 700, lives = 30, gems_collected = 3,')
    w('                  gems_per_wave = 5, level_name = "level05", force_next_wave = false,')
    # ★ 故意做成**稀疏**表：没有 [1]，只有 [2] 和 [7]。实机上的 store.entities 就长这样
    #   （下标从 2 起、中间有洞）。别改成连续表 —— 这份数据是那条 bug 的回归哨兵。
    w('                  entities = {')
    # health 必须同时给 hp 和 hp_max：只缩上限没用（当前血量不变，敌人照样按原血量死掉）。
    w('                    [2] = { id = 2, health = { hp_max = 200, hp = 200 },')
    w('                            motion = { max_speed = 40 },')
    # 敌人也有 attacks/timed_attacks：技能无CD 那三个开关**不许**碰它的冷却（清了就是加强敌人）
    w('                            attacks = { { cooldown = 6 } },')
    w('                            timed_attacks = { { cd = 6 } } },')
    # [9] 防御塔：实体名是 tower_<名>_lvl<N>（探针实测），冷却在 attacks 容器里；
    # 实体自己身上的 attack_cd 是**基础攻击节奏**，不许动。
    # [9] 建成的塔：**库存在 .tower 子表里**（探针实测），实体自己那层也可能有一份
    w('                    [9] = { id = 9, template_name = "tower_forger_lvl4", attack_cd = 9,')
    w('                            attacks = { { cd = 7 } },')
    w('                            tower = { attacks = { { cd = 2, cooldown = 5 } } } },')
    # [11] 法术控制对象：store.entities 里 template_name = power_<id>_control，cooldown 是它的直接字段
    w('                    [11] = { id = 11, template_name = "power_rain_of_fire_control", cooldown = 9 },')
    # [7] 故意不连续，用来证明遍历真的走的是 pairs 而不是 1..#
    w('                    [7] = { id = 7, health = { hp_max = 100, hp = 100 },')
    w('                            motion = { max_speed = 20 } },')
    w('                    [13] = fake_hero, [17] = fake_stage_hero,')
    w('                  },')
    w('                  hero_team = { fake_hero, fake_hero2 },')
    w('                  }')
    w('  _G.game = { store = store }')
    # 金币 2 倍用的两个假模块。形状照抄 all/systems.lua：**倍率在函数开头读一次**，
    # 这样才测得出「钩子只在 health 那一趟把表改成 ×2」——读第二次就不准了。
    # goal_line 是漏怪系统，它读同一张表，用来证明漏怪**没**被带上。
    # 英雄 XP 阈值用游戏里的**真值**（kr6/game_settings.lua:148），「几乎满级」那条按它算。
    w('  local GS = { gold_enemy_factor_per_mode = { 1, 0, 1, 0, 1, 1.5, 2.5, 1 },')
    w('                 hero_xp_thresholds = { 1000, 4500, 10500, 19000, 30000, 45000,')
    w('                                         64000, 88000, 120000 } }')
    w('  package.loaded.game_settings = GS')
    w('  local seen_health, seen_goal, seen_idx6, seen_idx2 = nil, nil, nil, nil')
    w('  local fake_systems = {}')
    # 三个下标都在**函数内部**读：×2 只存在于这一趟调用期间，出了函数表就还原了。
    w('  fake_systems.health = { on_update = function(self, dt, ts, st)')
    w('    seen_health = GS.gold_enemy_factor_per_mode[1]')
    w('    seen_idx6 = GS.gold_enemy_factor_per_mode[6]')
    w('    seen_idx2 = GS.gold_enemy_factor_per_mode[2]')
    w('  end }')
    w('  fake_systems.goal_line = { on_update = function(self, dt, ts, st)')
    w('    seen_goal = GS.gold_enemy_factor_per_mode[1]')
    w('  end }')
    w('  package.loaded.systems = fake_systems')
    # 模板倍率的假数据。形状照抄真实模板（源码：tt.health.hp_max = b.hp、
    # tt.motion.max_speed = b.speed）—— 值都在**子表**里，不在顶层。
    w('  local tpl_enemy = { template_name = "enemy_bandit", health = { hp_max = 100 }, motion = { max_speed = 50 } }')
    w('  local tpl_tower = { template_name = "tower_forger_lvl4", health = { hp_max = 999 }, motion = { max_speed = 77 } }')
    # 子弹模板：英雄远程伤害按 use_unit_damage_factor 分流 —— 带的走 unit.damage_factor，
    # 不带的必须改模板。两支都要有，才能证明"只碰该碰的那一支"。
    w('  local tpl_bullet_plain = { template_name = "bullet_bolin",')
    w('                            bullet = { damage_min = 10, damage_max = 20 } }')
    w('  local tpl_bullet_unit = { template_name = "bullet_zefira",')
    w('                           bullet = { damage_min = 10, damage_max = 20,')
    w('                                      use_unit_damage_factor = true } }')
    w('  package.loaded.entity_db = { entities = {')
    w('    enemy_x = tpl_enemy, tower_x = tpl_tower,')
    w('    bullet_bolin = tpl_bullet_plain, bullet_zefira = tpl_bullet_unit } }')
    # 「直接发满级信号」那条路：假的 hump.signal + achievements。emit 顺便**模拟游戏那两个
    # 处理器**（满级英雄 → TIME_SAVIOUR；法术 new_level>=6 → PLAYING_WITH_POWER），
    # 这样才测得到"本次新解锁了哪几个"那段播报逻辑。
    w('  local sig_log, ach_got = {}, {}')
    w('  package.loaded["hump.signal"] = {')
    w('    emit = function(name, a, b)')
    w('      sig_log[#sig_log+1] = tostring(name)')
    w('      if name == "hero-level-increased" and type(a) == "table" then')
    w('        local lv = a.hero and a.hero.level')
    w('        sig_log[#sig_log+1] = "hero_lv=" .. tostring(lv)')
    w('        if lv == 10 then ach_got.TIME_SAVIOUR = true end')
    w('      elseif name == "power-level-increased" and type(b) == "number" then')
    w('        sig_log[#sig_log+1] = "power_lv=" .. tostring(b)')
    w('        if b >= 6 then ach_got.PLAYING_WITH_POWER = true end')
    w('      end end }')
    w('  package.loaded.achievements = {')
    w('    have = function(self, id) return ach_got[id] == true end,')
    w('    got = function(self, id) ach_got[id] = true end }')
    # 假 balance：**必须一个数都不被碰**。模板每关开头从它重建（E:load），
    # 两边都写会让下一关拿到已乘过一次的值，直接平方。
    w('  local bal_unit = { hp = { 100, 100, 100, 100 }, speed = 50 }')
    w('  package.loaded["data.balance.balance"] = { enemies = { grp = { unit = bal_unit } } }')
    w('  local src = io.open(M .. "_kr6trainer.lua"):read("*a")')
    w('  local payload = loadstring(src, "_kr6trainer")')
    w('  fake = { calls = { keypressed = 0, mousepressed = 0, draw = 0, update = 0 } }')
    w('  fake.keypressed = function(...) fake.calls.keypressed = fake.calls.keypressed + 1 end')
    w('  fake.mousepressed = function(...) fake.calls.mousepressed = fake.calls.mousepressed + 1 end')
    w('  fake.draw = function(...) fake.calls.draw = fake.calls.draw + 1 end')
    w('  fake.update = function(...) fake.calls.update = fake.calls.update + 1 end')
    w('  local ok, err = pcall(payload, "all/director.lua", fake)')
    w('  say("payload_ok", ok)')
    w('  say("wrap_error", err)')
    w('  local S = _G.__kr6trainer')
    w('  if type(S) ~= "table" then say("installed", false) flush() return end')
    w('  say("installed", true)')
    w('  say("route2_keys", S.wrap_src.director_keypressed)')
    w('  say("route2_mouse", S.wrap_src.director_mousepressed)')
    # ---- 菜单基础行为
    w('  local function key(k) S.last_key = nil fake.keypressed(k) end')
    w('  local function idx_of(id)')
    w('    for i, it in ipairs(S.items or {}) do if it.id == id then return i end end')
    w('    return nil')
    w('  end')
    w('  local function pick(id)')
    w('    local i = idx_of(id)')
    w('    if not i then error("no such menu item: " .. tostring(id)) end')
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
    # 整排 F1–F12 都必须什么都不做、且原样透传：F1–F3 是玩家的物品热键（游戏
    # all/constants.lua 的 key_item_1/2/3），游戏的调试键（F5/F8/F9/F10/F12）也在这段
    # —— 谁想拿 F 键当菜单键都会先撞上这条。菜单键只能用 Home / Tab。
    w('  local kc_f = fake.calls.keypressed')
    w('  for _, fk in ipairs({ ' + (', ').join(Q + k + Q for k in FKEYS) + ' }) do key(fk) end')
    w('  say("menu_after_fkeys", S.menu_open)')
    # 差值，不是绝对次数：这 12 个键必须一个不漏地透传给游戏。
    w('  say("passthrough_after_fkeys", fake.calls.keypressed - kc_f)')
    w('  local kc0 = fake.calls.keypressed')
    w('  key("home")')
    w('  say("after_home_open", S.menu_open)')
    # 差值，不是绝对次数：热键被吃掉时游戏**一次都不该收到**。
    w('  say("home_swallowed", fake.calls.keypressed - kc0)')
    # ---- Tab 也是开关（有些键盘没有 Home 键）。它必须和 Home 一样**被吃掉**，
    # 不能漏给游戏。用差值判，别写绝对次数。
    w('  S.menu_open = false')
    w('  local kc = fake.calls.keypressed')
    w('  key("tab")')
    w('  say("tab_opens_menu", S.menu_open)')
    w('  key("tab")')
    w('  say("tab_toggles_closed", S.menu_open == false)')
    w('  say("tab_leaked_to_game", fake.calls.keypressed - kc)')
    w('  S.menu_open = true')
    w('  key("down")      -- 顺带触发 S.items 构建')
    w('  say("after_down_id", S.items and S.items[S.sel] and S.items[S.sel].id)')
    w('  say("after_down_is_header", S.items and S.items[S.sel] and S.items[S.sel].header or false)')
    w('  say("item1_id", nth_action(1))')
    w('  say("item2_id", nth_action(2))')
    w('  say("item_count", S.items and #S.items or -1)')
    # 分组标题必须真的存在，否则下面「↓ 不会停在标题上」的断言会空转
    w('  local hdr = 0')
    w('  for _, it in ipairs(S.items or {}) do if it.header then hdr = hdr + 1 end end')
    w('  say("header_count", hdr)')
    w('  pick("gold_add") key("return")')
    w('  say("gold_after_add", store.player_gold)')
    w('  say("swallowed_orig_calls", fake.calls.keypressed)')
    w('  key("escape")')
    w('  say("after_escape_open", S.menu_open)')
    w('  key("x")')
    w('  say("passthrough_calls", fake.calls.keypressed)')
    # ---- 左右键微调
    w('  key("home") pick("lives_add") key("right")')
    w('  say("lives_after_right", store.lives)')
    w('  pick("lives_sub") key("return")')
    w('  say("lives_after_sub", store.lives)')
    # ---- 无限金钱
    w('  pick("hold") key("return")')
    w('  say("hold_on", S.hold)')
    w('  store.player_gold = 5  pcall(fake.update)')
    w('  say("gold_after_hold", store.player_gold)')
    w('  pick("hold") key("return")      -- 关掉')
    # ---- 击杀金币倍率（可调行，下限 x1；只该影响击杀，不该影响漏怪）
    # x1 时钩子短路：表一个数都不该被动
    w('  fake_systems.health:on_update(0, 0, store)')
    w('  say("gold_at1", seen_health)')
    # → 两下 = x2（步长 0.5）
    w('  pick("gold_mult") key("right") key("right")')
    w('  say("gold_mult_val", S.gold.mult)')
    w('  fake_systems.health:on_update(0, 0, store)')
    w('  say("gold_kill_seen", seen_health)')
    w('  say("gold_idx6", seen_idx6)')
    w('  say("gold_idx2", seen_idx2)')
    w('  fake_systems.goal_line:on_update(0, 0, store)')
    w('  say("gold_goal_seen", seen_goal)')
    w('  say("gold_outside", GS.gold_enemy_factor_per_mode[1])')
    # 下限与上限都要夹住
    w('  pick("gold_mult")')
    w('  for _ = 1, 12 do key("left") end')
    w('  say("gold_floor", S.gold.mult)')
    w('  for _ = 1, 40 do key("right") end')
    w('  say("gold_ceil", S.gold.mult)')
    w('  for _ = 1, 40 do key("left") end')
    w('  say("gold_back", S.gold.mult)')
    w('  fake_systems.health:on_update(0, 0, store)')
    w('  say("gold_kill_off", seen_health)')
    w('  say("gold_restored", GS.gold_enemy_factor_per_mode[1])')
    # ---- 防御塔射程 / 攻速。
    # 用**独立的假 store**：主 store 里那座塔是为了无CD 测试造的（attacks 是个数组，
    # 不是真形状），往里加实体还会改掉「tower 3/3」那条自检断言。
    w('  local tstore = { entities = {')
    w('    [1] = { id = 1, template_name = "tower_archers_lvl2",')
    w('            attacks = { range = 200, list = {')
    w('              { cooldown = 1, basic_attack = true },')
    w('              { cooldown = 2 } } } },')
    w('    [2] = { id = 2, template_name = "tower_holder_1", attacks = { range = 50 } },')
    w('  } }')
    w('  local kept_store = _G.game.store')
    w('  _G.game.store = tstore')
    w('  S.tower.range, S.tower.rate = 1, 1')
    w('  S.tower_seen = setmetatable({}, { __mode = "k" })')
    w('  S.tower_apply_fn()')
    w('  say("tw_at1_range", tstore.entities[1].attacks.range)')
    w('  S.tower.range, S.tower.rate = 2, 2')
    w('  S.tower_apply_fn()')
    w('  say("tw_range", tstore.entities[1].attacks.range)')
    w('  say("tw_cd1", tstore.entities[1].attacks.list[1].cooldown)')
    w('  say("tw_cd2", tstore.entities[1].attacks.list[2].cooldown)')
    # 幂等：再跑一遍不能复合
    w('  S.tower_apply_fn()')
    w('  say("tw_range_twice", tstore.entities[1].attacks.range)')
    # 空建造位（holder）没有真的 attacks，一个数都不许碰
    w('  say("tw_holder", tstore.entities[2].attacks.range)')
    # 调回 x1 要还原（冷却也要还原，它乘的是倒数）
    w('  S.tower.range, S.tower.rate = 1, 1')
    w('  S.tower_apply_fn()')
    w('  say("tw_range_back", tstore.entities[1].attacks.range)')
    w('  say("tw_cd_back", tstore.entities[1].attacks.list[1].cooldown)')
    # 塔升级会**重建实体** → 新表没记录 → 按完整倍率乘一次（不是只乘差值）
    w('  S.tower.range = 3')
    w('  tstore.entities[3] = { id = 3, template_name = "tower_archers_lvl3",')
    w('                          attacks = { range = 220, list = { { cooldown = 0.7 } } } }')
    w('  S.tower_apply_fn()')
    w('  say("tw_upgraded", tstore.entities[3].attacks.range)')
    w('  S.tower.range = 1  S.tower_apply_fn()')
    w('  _G.game.store = kept_store')
    # ---- 新增的塔伤害 / 塔技能CD / 英雄四项。同样用独立假 store（理由同上），
    # 全部靠 S.*_apply_fn 直接驱动，不走菜单。断言一律"值 + 幂等 + 还原"三段式。
    w('  local cstore = { entities = {')
    w('    [1] = { id = 1, template_name = "tower_sniper_lvl4",')
    w('            tower = { damage_factor = 2 },')
    w('            attacks = { range = 300, min_cooldown = 3, list = {')
    w('              [1] = { cooldown = 0.6, shoot_time = 0.4, animation = "shoot", basic_attack = true },')
    w('              [2] = { cooldown = 9, shoot_time = 0.4, animation = "shoot" } } },')
    # 攻击动画 fps 那一层要用的假 sprite：
    #   [2] 名字就是组名（angles 里有它）；[3] 是 angles 展开出来的另一个名；[1] 是待机
    w('            render = { sprites = {')
    w('              [1] = { name = "idle" },')
    w('              [2] = { name = "shoot", angles = { shoot = { "shootback", "shoot" } } },')
    w('              [3] = { name = "shootback", angles = { shoot = { "shootback", "shoot" } } } } },')
    w('            timed_attacks = { list = {')
    w('              [1] = { cooldown = 15 },')
    w('              [2] = { cooldown = 4, static_cooldown = true } } },')
    w('            powers = { skill_a = { cooldown = { 5, 4, 3 } }, skill_b = { cooldown = 6 } } },')
    w('    [2] = { id = 2, template_name = "hero_gerald",')
    w('            hero = { level = 1, level_stats = { hp_max = { 100, 200, 300 } } },')
    w('            health = { hp_max = 200, hp = 200 },')
    w('            unit = { damage_factor = 1 },')
    w('            melee = { cooldown = 1.5, attacks = {')
    w('              { cooldown = 1.5, hit_time = 0.5, animation = "attack", basic_attack = true } } },')
    # [1] 名字直接就是动画名（英雄的 angles 里常常没有攻击组，游戏就用组名播）；
    #     **预设了非 nil 的 fps** —— 还原时必须回到 12，不是 nil。
    w('            render = { sprites = {')
    w('              [1] = { name = "attack", fps = 12 },')
    w('              [2] = { name = "idle" },')
    # 一次性、非待机的名字：**英雄**身上这类动画不许被碰（放宽那条只给塔）
    w('              [3] = { name = "death", loop = false } } },')
    w('            timed_attacks = { list = { [1] = { cooldown = 12 }, [4] = { cooldown = 60 } } } },')
    # [3]/[4] 专测远程子弹分流：一支的子弹**不认** unit.damage_factor（要改模板），
    # 另一支认（只能缩 unit，碰模板就是平方）。两边都带 level_stats 的远程伤害数组。
    w('    [3] = { id = 3, template_name = "hero_bolin",')
    w('            hero = { level = 1, level_stats = {')
    w('              ranged_damage_min = { 10, 20 }, ranged_damage_max = { 20, 40 } } },')
    w('            unit = { damage_factor = 1 },')
    w('            ranged = { attacks = { { bullet = "bullet_bolin" } } } },')
    w('    [4] = { id = 4, template_name = "hero_zefira",')
    w('            hero = { level = 1, level_stats = {')
    w('              ranged_damage_min = { 10, 20 }, ranged_damage_max = { 20, 40 } } },')
    w('            unit = { damage_factor = 1 },')
    w('            ranged = { attacks = { { bullet = "bullet_zefira" } } } },')
    # [5] 敌方/机关的塔：名字也是 tower_ 开头，但模板里 can_be_mod = false —— 塔倍率必须绕开它
    w('    [5] = { id = 5, template_name = "tower_stage_08_catapult",')
    w('            tower = { can_be_mod = false, damage_factor = 1 },')
    w('            attacks = { range = 100, list = {')
    w('              { cooldown = 2, basic_attack = true } } } },')
    # [6] 真普攻在 list[2] 的塔（culverine 那种）：普攻判据必须按**标记**而不是下标
    w('    [6] = { id = 6, template_name = "tower_culverine_lvl4",')
    w('            tower = { damage_factor = 1 },')
    w('            attacks = { range = 100, list = {')
    w('              { cooldown = 5 },')
    w('              { cooldown = 2, basic_attack = true } } } },')
    # [7] 「分段射击」的塔（炮塔那种）：模板只声明 animation="attack"，
    # 实际播的是 attack_2 / rotation_1（瞄准收招），还有 loop=false 起的 idle_2。
    w('    [7] = { id = 7, template_name = "tower_catapult_lvl1",')
    w('            tower = { damage_factor = 1 },')
    # 门控读的是**容器级** cooldown（不是 list[1]）—— 炮塔/树人/炼金/三管炮这 4 座都这样
    w('            attacks = { range = 100, cooldown = 3, list = {')
    w('              { cooldown = 3, basic_attack = true, animation = "attack" } } },')
    w('            render = { sprites = {')
    w('              [1] = { name = "idle", loop = true },')
    w('              [2] = { name = "idle_2", loop = false },')
    w('              [3] = { name = "attack_2", loop = false },')
    w('              [4] = { name = "rotation_1", loop = false } } } },')
    w('  } }')
    w('  local kept2 = _G.game.store')
    w('  _G.game.store = cstore')
    w('  local D1, D2 = cstore.entities[1], cstore.entities[2]')
    w('  local function drive() S.tower_apply_fn() S.tower_cd_apply_fn() S.hero_apply_fn() end')
    # 靠相对法自己乘回 x1（**不能**清 seen：清了就不知道已经乘过，还原不出来）
    w('  local function back_to_one()')
    w('    S.tower.range, S.tower.rate, S.tower.damage, S.tower.cd = 1, 1, 1, 1')
    w('    S.hero.hp, S.hero.damage, S.hero.rate, S.hero.cd = 1, 1, 1, 1')
    w('    S.nocd.tower, S.nocd.hero = false, false')
    w('    drive()')
    w('  end')
    w('  S.nocd.tower, S.nocd.hero = false, false')
    # x1：一个数都不许动（damage_factor=2 是**游戏自己**设的，不该被我们碰）
    w('  drive()')
    w('  say("n1_dmg", D1.tower.damage_factor)')
    w('  say("n1_st", D1.attacks.list[1].shoot_time)')
    w('  say("n1_skillcd", D1.attacks.list[2].cooldown)')
    w('  say("n1_hp", D2.health.hp_max)')
    w('  say("n1_df", D2.unit.damage_factor)')
    # 塔：伤害 x3、攻速 x2、技能CD x0.5
    w('  S.tower.damage, S.tower.rate, S.tower.cd = 3, 2, 0.5')
    w('  drive()')
    w('  say("n2_dmg", D1.tower.damage_factor)')
    w('  say("n2_st", D1.attacks.list[1].shoot_time)')
    w('  say("n2_basic", D1.attacks.list[1].cooldown)')
    w('  say("n2_skill", D1.attacks.list[2].cooldown)')
    w('  say("n2_mincd", D1.attacks.min_cooldown)')
    w('  say("n2_ta", D1.timed_attacks.list[1].cooldown)')
    w('  say("n2_static", D1.timed_attacks.list[2].cooldown)')
    w('  say("n2_arr", D1.powers.skill_a.cooldown[1])')
    w('  say("n2_num", D1.powers.skill_b.cooldown)')
    # 幂等：再跑一遍不复合
    w('  drive()')
    w('  say("n3_dmg", D1.tower.damage_factor)')
    w('  say("n3_skill", D1.attacks.list[2].cooldown)')
    # 英雄：血量 x3、伤害 x2、攻速 x2、技能CD x0.5
    w('  S.hero.hp, S.hero.damage, S.hero.rate, S.hero.cd = 3, 2, 2, 0.5')
    w('  drive()')
    w('  say("n4_hp", D2.health.hp_max)')
    w('  say("n4_hpcur", D2.health.hp)')
    w('  say("n4_ls", D2.hero.level_stats.hp_max[2])')
    w('  say("n4_df", D2.unit.damage_factor)')
    w('  say("n4_mc", D2.melee.cooldown)')
    w('  say("n4_hit", D2.melee.attacks[1].hit_time)')
    w('  say("n4_cd1", D2.timed_attacks.list[1].cooldown)')
    w('  say("n4_cd4", D2.timed_attacks.list[4].cooldown)')
    # 升级模拟：fn_level_up 会从 level_stats 重写活体血量 —— 数组缩过了，写出来就是缩过的
    w('  D2.health.hp_max = D2.hero.level_stats.hp_max[2]')
    w('  D2.health.hp = D2.health.hp_max')
    w('  drive()')
    w('  say("n5_hp", D2.health.hp_max)')
    # 全部回 x1 要还原到原值
    w('  back_to_one()')
    w('  say("n6_dmg", D1.tower.damage_factor)')
    w('  say("n6_skill", D1.attacks.list[2].cooldown)')
    w('  say("n6_st", D1.attacks.list[1].shoot_time)')
    w('  say("n6_hp", D2.health.hp_max)')
    w('  say("n6_ls", D2.hero.level_stats.hp_max[2])')
    w('  say("n6_df", D2.unit.damage_factor)')
    w('  say("n6_mc", D2.melee.cooldown)')
    # 「无CD」开关与技能CD倍率：**开关开着时倍率那一趟整个跳过**（不清零也不记），
    # 开关关掉、原值写回后按完整倍率补缩一次。顺序反过来也必须收敛 —— 这是最容易写错的地方。
    w('  S.tower.cd = 0.5  drive()')
    w('  S.nocd.tower = true')
    w('  S.nocd_clear_entity(D1, { seen = 0, cleared = 0 })')
    w('  S.tower.cd = 1  drive()')
    w('  say("n7_zero", D1.attacks.list[2].cooldown)')
    w('  S.nocd_restore()')
    w('  S.nocd.tower = false')
    w('  drive()')
    w('  say("n7_back", D1.attacks.list[2].cooldown)')
    w('  back_to_one()')
    w('  S.hero.cd = 0.5  drive()')
    w('  S.nocd.hero = true')
    w('  S.nocd_clear_entity(D2, { seen = 0, cleared = 0 })')
    w('  S.hero.cd = 1  drive()')
    w('  say("n8_zero", D2.timed_attacks.list[1].cooldown)')
    w('  S.nocd_restore()')
    w('  S.nocd.hero = false')
    w('  drive()')
    w('  say("n8_back", D2.timed_attacks.list[1].cooldown)')
    w('  back_to_one()')
    # ---- 远程子弹分流：不认 use_unit_damage_factor 的才改模板，认的连碰都不许碰
    #（碰了就是平方：模板 x2 之后再乘 unit 的 x2）
    w('  local EB = package.loaded.entity_db.entities')
    w('  local BP, BU = EB.bullet_bolin.bullet, EB.bullet_zefira.bullet')
    w('  local D3, D4 = cstore.entities[3], cstore.entities[4]')
    w('  S.hero.damage = 2  drive()')
    w('  say("b1_plain_min", BP.damage_min)')
    w('  say("b1_plain_max", BP.damage_max)')
    w('  say("b1_unit_min", BU.damage_min)')
    w('  say("b1_ls_plain", D3.hero.level_stats.ranged_damage_min[1])')
    w('  say("b1_ls_unit", D4.hero.level_stats.ranged_damage_min[1])')
    w('  drive()')
    w('  say("b2_plain_min", BP.damage_min)')
    w('  back_to_one()')
    w('  say("b3_plain_min", BP.damage_min)')
    w('  say("b3_ls_plain", D3.hero.level_stats.ranged_damage_min[1])')
    # ---- 攻速第三层：攻击动画的 fps。只碰攻击动画那条 sprite，其余一个数不动；
    # 还原要写回**原值**（英雄那个本来是 12，不是 nil）。
    w('  local R1, R2 = D1.render.sprites, D2.render.sprites')
    w('  S.tower.rate, S.hero.rate = 1, 1')
    w('  S.anim_apply_fn()')
    w('  say("a1_shoot", tostring(R1[2].fps))')
    w('  say("a1_hero", tostring(R2[1].fps))')
    w('  S.tower.rate, S.hero.rate = 2, 3')
    w('  S.anim_apply_fn()')
    w('  say("a2_shoot", tostring(R1[2].fps))')
    w('  say("a2_shootback", tostring(R1[3].fps))')
    w('  say("a2_idle", tostring(R1[1].fps))')
    w('  say("a2_hero", tostring(R2[1].fps))')
    w('  say("a2_heroidle", tostring(R2[2].fps))')
    w('  S.anim_apply_fn()')
    w('  say("a3_shoot", tostring(R1[2].fps))')
    w('  S.tower.rate, S.hero.rate = 1, 1')
    w('  S.anim_apply_fn()')
    w('  say("a4_shoot", tostring(R1[2].fps))')
    w('  say("a4_shootback", tostring(R1[3].fps))')
    w('  say("a4_hero", tostring(R2[1].fps))')
    # ---- 「分段射击」的塔（炮塔那种）：模板只声明 "attack"，实际播 attack_2 / rotation_1。
    # 塔要放宽（一次性且不像待机就算攻击动画），英雄不放宽。
    w('  local D7 = cstore.entities[7]')
    w('  local R7 = D7.render.sprites')
    w('  S.tower.rate, S.hero.rate = 2, 2')
    w('  S.tower_apply_fn()')
    w('  S.anim_apply_fn()')
    w('  say("r1_container", D7.attacks.cooldown)')
    w('  say("r1_idle", tostring(R7[1].fps))')
    w('  say("r1_idle2", tostring(R7[2].fps))')
    w('  say("r1_attack2", tostring(R7[3].fps))')
    w('  say("r1_rot", tostring(R7[4].fps))')
    w('  say("r1_hero_atk", tostring(R2[1].fps))')
    w('  say("r1_hero_death", tostring(R2[3].fps))')
    # ⚠️ 塔字段也要还原（不能只还原动画那层）：上面的 tower_apply_fn 把 cstore 里的塔
    # 冷却都缩过了，不还原的话后面每个用例都是在已缩过的值上再缩一次，双重缩放。
    w('  S.tower.rate, S.hero.rate = 1, 1')
    w('  S.tower_apply_fn()  S.anim_apply_fn()')
    # ---- 普攻判据按**标记**、敌方塔要排除
    w('  local D5, D6 = cstore.entities[5], cstore.entities[6]')
    w('  S.tower.range, S.tower.rate, S.tower.damage, S.tower.cd = 1, 1, 1, 1')
    w('  S.tower_seen = setmetatable({}, { __mode = "k" })')
    w('  S.tower_cd_seen = setmetatable({}, { __mode = "k" })')
    w('  S.tower.damage, S.tower.rate, S.tower.cd = 2, 2, 0.5')
    w('  S.tower_apply_fn()  S.tower_cd_apply_fn()')
    w('  say("s1_stage_dmg", D5.tower.damage_factor)')
    w('  say("s1_stage_cd", D5.attacks.list[1].cooldown)')
    w('  say("s1_culv_basic", D6.attacks.list[2].cooldown)')
    w('  say("s1_culv_skill", D6.attacks.list[1].cooldown)')
    w('  S.tower.range, S.tower.rate, S.tower.damage, S.tower.cd = 1, 1, 1, 1')
    w('  S.tower_apply_fn()  S.tower_cd_apply_fn()')
    # ---- 「无CD」与倍率：**必须走 tick**（直接调 apply_fn 会绕过 S.tower_cd_active 的门禁，
    # 而那正是漏掉 bug 的那条路）
    w('  _G.game.store = cstore')
    w('  S.nocd_report = false')
    w('  S.nocd.tower, S.nocd.hero = false, false')
    w('  pcall(fake.update)')
    w('  say("f1_base", D1.attacks.list[2].cooldown)')
    w('  S.tower.cd = 0.5  pcall(fake.update)')
    w('  say("f1_half", D1.attacks.list[2].cooldown)')
    w('  S.nocd.tower = true  pcall(fake.update)')
    w('  S.tower.cd = 1  pcall(fake.update)')
    w('  say("f1_zeroed", D1.attacks.list[2].cooldown)')
    w('  S.nocd_restore()  S.nocd.tower = false')
    w('  pcall(fake.update)')
    w('  say("f1_back", D1.attacks.list[2].cooldown)')
    # 无CD 不许碰**基础攻击**（它归攻速那一项管），技能那条该清还是要清
    w('  S.nocd.tower = true  pcall(fake.update)')
    w('  say("f3_basic", D1.attacks.list[1].cooldown)')
    w('  say("f3_skill", D1.attacks.list[2].cooldown)')
    w('  S.nocd_restore()  S.nocd.tower = false')
    w('  pcall(fake.update)')
    w('  _G.game.store = kept2')
    # ---- 每个菜单项都必须有可用标签（标签为 nil 会让整个面板静默消失）
    # 标签 == id 是 menu_items() 里 L(id) 回退的特征（MENU_TEXT 漏了这条文案，cn/en 任一边），
    # 所以只能这么查：光查「非空字符串」永远为真，等于没测。
    w('  local bad = {}')
    w('  for i, it in ipairs(S.items or {}) do')
    w('    if type(it.label) ~= "string" or it.label == "" or it.label == it.id then')
    w('      bad[#bad+1] = tostring(it.id)')
    w('    end')
    w('  end')
    w('  say("labelless_items", table.concat(bad, ","))')
    # ---- 倍率行走 S.mult，**不走 store**（tweak 的第二种目标）
    w('  S.menu_open = true')
    w('  pick("enemy_hp") key("right")')
    w('  say("mult_after_right", S.mult.enemy_hp)')
    # tick 只认第一个到达的源（假 director 的 update），所以这里必须显式推一帧
    w('  pcall(fake.update)')
    # 倍率非 x1 时必须进入"每帧重放"状态
    w('  say("mult_active_after_raise", S.mult_active)')
    w('  pick("enemy_hp") key("left")')
    w('  say("mult_after_left", S.mult.enemy_hp)')
    w('  pcall(fake.update)')
    # 调回 x1 后必须**再跑一趟收尾重放**才停手：守卫条件此刻已经变假，
    # 不补跑的话模板会永远停在放大后的值上。
    w('  say("mult_active_after_reset", S.mult_active)')
    # 下调到下限要停住，且**不能**返回 FAIL（冒烟测试把 FAIL 当失败）。
    # enemy_hp 的下限是 0.1（不是 1），所以先摆到下限再按左键。
    w('  S.mult.enemy_hp = 0.1')
    w('  pick("enemy_hp") key("left")')
    w('  say("mult_at_floor", S.mult.enemy_hp)')
    # ---- 倍率只在本关生效：换关就归 1。同一关内**不许**动它，
    # 否则功能会在中途自己失效（静默）。
    w('  S.mult.enemy_hp = 2')
    w('  S.last_level_check = 0  pcall(fake.update)')
    w('  say("mult_tag_set", S.mult_tag ~= nil)')
    w('  S.last_level_check = 0  pcall(fake.update)')
    w('  say("mult_same_level", S.mult.enemy_hp)')
    # 换一关：关卡标识变了（真实存档里 store.level_name 就是关卡名）。
    # ⚠️ 别在这里换成另一张 store 表 —— 场上的实体挂在原表上，换表会让"场上的单位"
    # 那一趟无从下手，倍率残留在实体上污染后面的用例。
    w('  store.level_name = "level06"')
    w('  S.last_level_check = 0  pcall(fake.update)')
    w('  say("mult_after_level_change", S.mult.enemy_hp)')
    w('  store.level_name = "level05"')
    w('  S.last_level_check = 0  pcall(fake.update)')
    # ---- 技能无CD：三个开关各自定位目标，且一个字都不许误伤
    w('  S.nocd.power, S.nocd.hero, S.nocd.tower = true, true, true')
    w('  S.nocd_report, S.nocd_since = true, os.time() - 5')
    w('  S.last_level_check = 0  pcall(fake.update)')
    w('  local ht = store.hero_team[1]')
    w('  say("nocd_hero_ta_cd", ht.timed_attacks[1].cd)')
    w('  say("nocd_hero_ta_ts", ht.timed_attacks[1].ts)')
    w('  say("nocd_hero_skill_cd", ht.hero.skills[1].cooldown)')
    w('  say("nocd_hero_attack_kept", ht.attack_cd)')
    w('  say("nocd_tower_cd", store.entities[9].tower.attacks[1].cd)')
    w('  say("nocd_tower_cd2", store.entities[9].tower.attacks[1].cooldown)')
    w('  say("nocd_tower_own", store.entities[9].attacks[1].cd)')
    w('  say("nocd_tower_attack_kept", store.entities[9].attack_cd)')
    w('  say("nocd_enemy_kept", store.entities[2].attacks[1].cooldown)')
    w('  say("nocd_enemy_kept2", store.entities[2].timed_attacks[1].cd)')
    w('  say("nocd_power_entity_kept", store.entities[11].cooldown)')
    # 剧情英雄只在 entities、不在 hero_team（真游戏里 alleria / blackburn / denas 就是这种形态，
    # 走 LU.insert_hero 不写 hero_team）—— 旧的「只遍历 hero_team」实现会静默漏掉它。
    w('  say("nocd_stage_in_team", store.hero_team[1] == store.entities[17])')
    w('  say("nocd_stage_hero_cd", store.entities[17].timed_attacks[1].cd)')
    # 法术：冷却**时长**在按钮自己身上（探针数字 diff 实测）—— 清 cooldown_time 一类；
    # tm 里那份按英雄/塔同一套规则一起清。测试台没有 game_gui，直接喂几个假按钮。
    w('  local kids = { { cooldown_time = 20, cooldown_max = 20, cooldown_min = 2,')
    w('                    tm = { phase = 0.3, ts = 5 }, other = 7 } }')
    w('  local acc2 = { seen = 0, cleared = 0 }')
    w('  S.nocd_clear_buttons(kids, acc2)')
    w('  say("nocd_btn_cleared", acc2.cleared)')
    w('  say("nocd_btn_time", kids[1].cooldown_time)')
    w('  say("nocd_btn_max", kids[1].cooldown_max)')
    w('  say("nocd_btn_other_kept", kids[1].other)')
    # 可逆性：清掉的是**冷却时长**，游戏不会自己重写，所以关掉开关时必须把原值写回去。
    w('  local ent2 = { timed_attacks = { { cd = 8, ts = 0 } } }')
    w('  local acc4 = { seen = 0, cleared = 0 }')
    w('  S.nocd_clear_entity(ent2, acc4)')
    w('  say("nocd_rev_zeroed", ent2.timed_attacks[1].cd)')
    w('  S.nocd_restore()')
    w('  say("nocd_rev_restored", ent2.timed_attacks[1].cd)')
    w('  local kids2 = { { cooldown_time = 20 } }')
    w('  local acc5 = { seen = 0, cleared = 0 }')
    w('  S.nocd_clear_buttons(kids2, acc5)')
    w('  say("nocd_rev_btn_zeroed", kids2[1].cooldown_time)')
    w('  S.nocd_restore()')
    w('  say("nocd_rev_btn_restored", kids2[1].cooldown_time)')
    w('  say("nocd_report_msg", S.msg)')
    # 关掉就停手（游戏自己的冷却接着走）
    w('  S.nocd.power, S.nocd.hero, S.nocd.tower = false, false, false')
    w('  store.hero_team[1].timed_attacks[1].cd = 5')
    w('  pcall(fake.update)')
    w('  say("nocd_off_kept", store.hero_team[1].timed_attacks[1].cd)')
    w('  say("last_err", S.last_err)')
    # ---- 存档改写逻辑（S.slot_apply / S.slot_like 是刻意暴露给测试的）。
    # 测试环境没有 storage 模块、钩子装不上，所以直接调这两个函数。
    w('  local function mk_slot()')
    w('    return { gems = 100, last_stars = 0,')
    w('             levels = { [1] = { stars = 2 }, [2] = { stars = 1 } },')
    # 存档里升级树是**数组**（{ "l1" }），不是字典 —— 写成 { l1 = "l1" } 就不是存档的形状，
    # 测试会假过。
    # ⚠️ 三类树的节点名**各不相同**（塔 7 / 法术 8 / 英雄 17），**跨类写就是坏档**（见
    # ENGINE_NOTES「升级树」）。这里故意三种混着放（含两个错写的节点），钉住"只碰自己那类"。
    w('             upgrades_trees = {')
    w('               archers = { "l1" },')                          # 塔树：补成 7 个
    w('               power_rain_of_fire = { "l2b", "l1" },')         # 法术树：留 l2b、删错写的 l1
    w('               hero_gerald = {},')                             # 空英雄树：补满
    w('               hero_zefira = { "skill_a", "talent_2", "l2" },')  # 留 talent_2、删错写的 l2
    w('               tower_wizard = {} },')                          # 游戏从不写的槽位：谁也不许碰
    w('             towers = { status = { archers = true, wizard = true },')
    w('                        selected = { "archers" } },')
    # heroes.status 的每个英雄是**表**（{ skills, xp }），不是布尔 —— 写成 true 的话
    # 英雄升级 op 会抛错被 pcall 吞掉，测试照样通过（假过）。selected 是「出战英雄」。
    w('             heroes = { status = { hero_a = { xp = 2865 }, hero_b = { xp = 0 } },')
    w('                        selected = "hero_a", team = { "hero_a" } },')
    w('             powers = { status = { rain_of_fire = { xp = 300 },')
    w('                                  musketeers = { xp = 0 } },')
    w('                        selected = { "rain_of_fire" } },')
    w('             progression = { last_stars = 0 } }')
    w('  end')
    # 指纹：不满足 gems/levels/upgrades_trees 的表一律不认（否则会误改别的表）
    w('  say("slot_like_ok", S.slot_like(mk_slot()))')
    w('  say("slot_like_rejects", S.slot_like({ gems = 1, foo = 2 }))')
    w('  say("slot_like_rejects_str", S.slot_like({ gems = "x", levels = {}, upgrades_trees = {} }))')
    # 待办是**一次性**的：应用完就清空，否则会变成"每帧覆盖存档"，
    # 宝石就再也涨不上去。
    w('  S.slot_ops = {}')
    w('  local function queue_op(o) S.slot_ops[#S.slot_ops+1] = o end')
    # 星星：补到够拿完轨道，且**故意不动 last_stars**（那是游戏发现新星星的机制）
    w('  queue_op({ op = "stars" })')
    w('  local t2 = mk_slot()  S.slot_apply(t2)')
    w('  local total = 0')
    w('  for _, e in pairs(t2.levels) do total = total + (e.stars or 0) end')
    w('  say("stars_total", total)')
    w('  say("last_stars_untouched", t2.progression.last_stars)')
    w('  say("ops_cleared", #S.slot_ops)')
    # ---- 三类升级树各走各的节点名，**只能按树种类分别填**（塔的节点名写进法术树/英雄树
    # 是坏档）。每个 op 都断言：自己那类补对 + 另外两类一个字没动。
    w('  local function nodes_of(arr)')
    w('    local t = {}')
    w('    for _, v in pairs(arr or {}) do t[#t+1] = tostring(v) end')
    w('    table.sort(t)')
    w('    return table.concat(t, ",")')
    w('  end')
    w('  S.slot_ops = {}')
    w('  queue_op({ op = "tree" })')
    w('  local t3 = mk_slot()  S.slot_apply(t3)')
    w('  say("tree_tower", nodes_of(t3.upgrades_trees.archers))')
    w('  say("tree_tower_power", nodes_of(t3.upgrades_trees.power_rain_of_fire))')
    w('  say("tree_tower_hero", nodes_of(t3.upgrades_trees.hero_zefira))')
    w('  say("tree_tower_slot", nodes_of(t3.upgrades_trees.tower_wizard))')
    # 法术升满：**经验先拉满**（点数按等级发，只填树会变负数），再填一条完整路径。
    w('  S.slot_ops = {}')
    w('  queue_op({ op = "power_max" })')
    w('  local t4 = mk_slot()  S.slot_apply(t4)')
    w('  say("power_xp_raised", t4.powers.status.rain_of_fire.xp)')
    w('  say("power_xp_other", t4.powers.status.musketeers.xp)')
    w('  say("power_tree", nodes_of(t4.upgrades_trees.power_rain_of_fire))')
    w('  say("power_tower_untouched", nodes_of(t4.upgrades_trees.archers))')
    w('  say("power_hero_untouched", nodes_of(t4.upgrades_trees.hero_zefira))')
    # 读不到经验表就**整条不做**（宁可不填树，也不造负点数）
    w('  S.slot_ops = {}')
    w('  local np = mk_slot()')
    w('  np.powers = nil')
    w('  queue_op({ op = "power_max" })')
    w('  say("power_nostatus_applied", S.slot_apply(np))')
    w('  say("power_nostatus_tree", nodes_of(np.upgrades_trees.power_rain_of_fire))')

    # 英雄升级：只动**出战英雄**（heroes.selected），别的英雄一个字段都不许变。
    # 这里测 max 模式 —— 它不依赖任何未验证的东西（next 模式要读 game_settings 里那张
    # 阈值表，测试台没有那个模块，所以那条路只能在实机验）。
    w('  S.slot_ops = {}')
    w('  queue_op({ op = "hero_level", mode = "max" })')
    w('  local t4 = mk_slot()  S.slot_apply(t4)')
    w('  say("hero_xp_raised", t4.heroes.status.hero_a.xp)')
    w('  say("hero_other_untouched", t4.heroes.status.hero_b.xp)')
    # 形状不对（条目是布尔）→ 失败**且什么都不改**，绝不新建条目（新建等于替玩家伪造一个
    # 他没拥有的英雄）。这条同时钉住 apply_slot_ops：结构化失败不能被算成应用成功。
    w('  S.slot_ops = {}')
    w('  S.slot_ops_done = 0')
    w('  local bad = mk_slot()')
    w('  bad.heroes.status.hero_a = true')
    w('  queue_op({ op = "hero_level", mode = "max" })')
    w('  local applied = S.slot_apply(bad)')
    w('  say("hero_bad_applied", applied)')
    w('  say("hero_bad_done", S.slot_ops_done)')
    w('  say("hero_bad_untouched", tostring(bad.heroes.status.hero_a))')
    w('  say("hero_bad_no_new_key", bad.heroes.status.hero_c == nil)')
    # 没出息英雄可用时（status 缺失）同样失败、不抛错
    w('  S.slot_ops = {}')
    w('  local ns = mk_slot()')
    w('  ns.heroes.status = {}')
    w('  queue_op({ op = "hero_level", mode = "max" })')
    w('  say("hero_none_applied", S.slot_apply(ns))')

    # ---- 稀疏 entities 的回归：假 store 故意只放 [2] 和 [7]、没有 [1] —— 遍历写成
    # `for i = 1, #s.entities` 会一次都不进（# 返回 0），倍率整个静默失效。
    # ⚠️ 活单位走相对缩放（按新旧倍率之比乘一次），这里必须把"上一次"钉成 1，
    # 否则结果取决于前面用例留下的状态（顺序一变就假失败）。
    w('  S.mult_applied.enemy_hp, S.mult_applied.enemy_speed = 1, 1')
    w('  S.mult.enemy_hp = 5')
    # 直接调活单位缩放那条（tick 的接线由 mult_active_after_raise 那条断言覆盖）；
    # 走 tick 的话结果依赖前面用例留下的 prev，顺序一变就假失败。
    w('  pcall(S.mult_live)')
    w('  say("hp_max_after", store.entities[2].health.hp_max)')
    w('  say("hp_after", store.entities[2].health.hp)')
    w('  say("hp_max_after_7", store.entities[7].health.hp_max)')
    w('  S.mult.enemy_speed = 2')
    w('  pcall(S.mult_live)')
    w('  say("speed_after", store.entities[2].motion.max_speed)')
    w('  say("speed_after_7", store.entities[7].motion.max_speed)')
    w('  S.mult.enemy_speed = 1')
    w('  pcall(S.mult_live)')
    w('  S.mult.enemy_hp = 1')
    w('  pcall(S.mult_live)')
    w('  say("hp_max_back", store.entities[2].health.hp_max)')
    # ---- 模板倍率：**只写模板、且写对子表**（这条路径以前完全没被测过）
    w('  S.mult.enemy_hp, S.mult.enemy_speed = 2, 2')
    w('  pcall(S.mult_apply)')
    w('  say("tpl_hp", tpl_enemy.health.hp_max)')
    w('  say("tpl_speed", tpl_enemy.motion.max_speed)')
    w('  say("tpl_tower_hp", tpl_tower.health.hp_max)')
    w('  say("tpl_tower_speed", tpl_tower.motion.max_speed)')
    # 再跑一遍不能复合（基线只记一次）
    w('  pcall(S.mult_apply)')
    w('  say("tpl_hp_twice", tpl_enemy.health.hp_max)')
    # balance 一个数都不能动
    w('  say("tpl_bal_hp", bal_unit.hp[1])')
    w('  say("tpl_bal_speed", bal_unit.speed)')
    # 调回 x1 要还原
    w('  S.mult.enemy_hp, S.mult.enemy_speed = 1, 1')
    w('  pcall(S.mult_apply)')
    w('  say("tpl_hp_back", tpl_enemy.health.hp_max)')
    w('  say("tpl_speed_back", tpl_enemy.motion.max_speed)')
    # ---- 冒烟测试：把每个动作都从**菜单**跑一遍。
    # 专门抓「调用了声明在它上面的函数」—— 名字会静默解析成 nil 全局，只有那一个动作挂掉。
    w('  local smoke = {}')
    w('  for _, it in ipairs(S.items or {}) do')
    # 跳过两类：tweak「按设计必须有参数，不给参数必然失败」；分组标题
    # 「不是动作，跑出来必然是 unknown action hdr_xxx」。
    w('    if not it.header and it.id ~= "tweak" then')
    # 菜单里有一项是「关闭菜单」，跑到它菜单就关了 —— 每项之前重新打开，
    # 否则它后面的条目全部落空、静默没被测。
    w('      S.menu_open = true')
    w('      S.msg = ""')
    w('      pick(it.id) key("return")')
    # 失败信号：run_action 出错会 note("出错 <id>: …")，未知 id 回 "unknown action"。
    w('      local reply = tostring(S.msg)')
    w('      if reply:find("\x129]\x0186\x9b\x0c8k")')
    w('         or reply:find("FAIL", 1, true)')
    w('         or reply:find("unknown action", 1, true) then')
    w('        smoke[#smoke+1] = it.id .. "<" .. reply:sub(1, 40)')
    w('      end')
    w('    end')
    w('  end')
    w('  say("smoke_failures", table.concat(smoke, " ;; "))')
    # 遍历的最后一项是「关闭菜单」——后面还有绘制用例，这里必须再打开
    w('  S.menu_open = true')
    w('  say("smoke_ran", #(S.items or {}))')
    # 全部条目 id（含标题）。门控靠它做集合断言，别写回「项数必须等于 N」的硬编码 ——
    # 那样每加一个菜单项就得手改一次。
    # 三个开关**各按两次**（开→关）：关那一路才是"还原"路径 —— 冒烟只按一次抓不到
    # （nocd_restore 曾被解析成 nil：开的时候没事、关的时候报错。）
    w('  S.last_err = nil')
    w('  S.nocd.power, S.nocd.hero, S.nocd.tower = false, false, false   -- 冒烟把它们留在开了')
    w('  S.menu_open = true')
    w('  for _, id2 in ipairs({ "nocd_power", "nocd_hero", "nocd_tower" }) do')
    w('    pick(id2) key("return")   -- 开')
    w('    pick(id2) key("return")   -- 关（走还原）')
    w('  end')
    w('  say("nocd_toggle_err", S.last_err)')
    w('  say("nocd_toggle_off", tostring(S.nocd.power) .. "," .. tostring(S.nocd.hero) .. "," .. tostring(S.nocd.tower))')
    w('  local ids = {}')
    w('  for _, it in ipairs(S.items or {}) do ids[#ids+1] = tostring(it.id) end')
    w('  say("all_item_ids", table.concat(ids, ","))')
    # ---- 表头必须反映实际状态，且绝不能打印 "nil"
    w('  S.menu_open = true')
    w('  S.drew = false  pcall(fake.draw)')
    w('  say("header_in_level", S.header)')
    # 分组标题的命中框（S.rects 是 draw 时建的，所以这条必须在 draw 之后）。
    # 标题行没有命中框的话，点在标题上会被当成「没点中」漏给游戏。
    w('  local badrect = {}')
    w('  for i, it in ipairs(S.items or {}) do')
    w('    local r = S.rects and S.rects[i]')
    w('    if type(r) ~= "table" then')
    w('      badrect[#badrect+1] = tostring(it.id) .. "=norc"')
    w('    elseif it.header and not r.header then')
    w('      badrect[#badrect+1] = tostring(it.id) .. "=nomark"')
    w('    end')
    w('  end')
    w('  say("rect_mismatch", table.concat(badrect, ","))')
    # 提示行宽度必须装得下面板（S.rects[1].w 就是 MENU_W）。
    # 提示行宽度：**最终选定的字号**量出来的值，得装得下面板（S.rects[1].w 就是 MENU_W）。
    # ⚠️ 测试台跑英文、且提示只有 359px，够不到换字号的阈值 —— 所以这条钉的是「提示不会
    # 超出面板」这个**结果**，换字号那条路本身只能靠真机确认（中文提示在大窗口下才会撞上）。
    w('  say("hint_w", S.hint_w or -1)')
    w('  say("panel_w", (S.rects and S.rects[1] and S.rects[1].w) or -1)')
    # ---- 档位表：**不会漂** —— 加法步进 + 下限夹取之后，
    # 从 x1 往下走再走回来，永远回不到 1.0（0.1 不在 0.25 的格子上）。
    w('  S.menu_open = true')
    w('  pick("enemy_hp")')
    w('  S.mult.enemy_hp = 1')
    w('  for _ = 1, 5 do key("left") end')
    w('  say("lad_down5", S.mult.enemy_hp)')
    w('  for _ = 1, 5 do key("right") end')
    w('  say("lad_back", S.mult.enemy_hp)')
    w('  for _ = 1, 30 do key("left") end')
    w('  say("lad_floor", S.mult.enemy_hp)')
    w('  for _ = 1, 9 do key("right") end')
    w('  say("lad_to_one", S.mult.enemy_hp)')
    w('  for _ = 1, 10 do key("right") end')
    w('  say("lad_ten", S.mult.enemy_hp)')
    # 技能CD 是"越小越快"，所以范围收在 0.1–1，往右按到底也该停在 1
    w('  pick("tower_skill_cd")')
    w('  S.tower.cd = 0.1')
    w('  for _ = 1, 30 do key("right") end')
    w('  say("lad_cd_max", S.tower.cd)')
    # ---- 滑条：点轨道设值；点**文字区**不改值
    w('  S.mult.enemy_hp = 1')
    w('  S.tower.cd = 1')
    w('  S.last_click = nil')
    w('  S.drew = false  pcall(fake.draw)')
    w('  local rowr, tr = nil, nil')
    w('  for i = 1, #S.rects do')
    w('    if S.rects[i].id == "enemy_hp" then rowr = S.rects[i] tr = S.rects[i].track end')
    w('  end')
    w('  say("sld_has", tr ~= nil)')
    w('  say("sld_trackw", tr and tr.w or -1)')
    w('  local ty = rowr.y + 2')
    w('  S.last_click = nil')
    w('  fake.mousepressed(tr.x + tr.w - 1, ty, 1)')
    w('  say("sld_right", S.mult.enemy_hp)')
    w('  S.last_click = nil')
    w('  fake.mousepressed(tr.x, ty, 1)')
    w('  say("sld_left", S.mult.enemy_hp)')
    w('  S.mult.enemy_hp = 2')
    w('  S.last_click = nil')
    w('  fake.mousepressed(rowr.x + 5, ty, 1)')
    w('  say("sld_label_kept", S.mult.enemy_hp)')
    w('  S.mult.enemy_hp = 1')
    # ---- 直接发满级信号：不要求回关卡里打死敌人
    # 就地清空：闭包捕获的是这张表本身，重新赋值一个 {} 不会影响闭包看到的内容
    w('  for i = #sig_log, 1, -1 do sig_log[i] = nil end')
    w('  ach_got.TIME_SAVIOUR, ach_got.PLAYING_WITH_POWER = nil, nil')
    w('  fake_hero2.hero.level, fake_hero2.hero.xp = 4, 19000')
    w('  S.msg = ""')
    w('  pick("ach_unlock")')
    w('  key("return")')
    w('  say("ach_log", table.concat(sig_log, "|"))')
    w('  say("ach_hero_lv", fake_hero2.hero.level)')
    w('  say("ach_msg", S.msg)')
    # 再点一次：成就已解锁，播报该说"此前已解锁"而不是又解一遍
    w('  for i = #sig_log, 1, -1 do sig_log[i] = nil end')
    w('  S.msg = ""')
    w('  pick("ach_unlock")')
    w('  key("return")')
    w('  say("ach_msg2", S.msg)')
    w('  _G.game.store = nil')
    w('  S.drew = false  pcall(fake.draw)')
    w('  say("header_no_level", S.header)')
    w('  _G.game.store = store')
    w('  S.menu_open = true')
    w('  end, function(e)')
    w('    return tostring(e) .. string.char(10) .. debug.traceback("", 2)')
    w('  end)')
    w('  if not ok then say("harness_error", err) end')
    w('  flush()')
    w('end')
    w('function love.draw()')
    w('  love.graphics.setColor(45, 75, 110)')
    w('  love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())')
    w('  love.graphics.setColor(235, 235, 235)')
    w('  love.graphics.print("SELFTEST fake game screen", 20, 30)')
    w('  if fake then pcall(fake.draw) end      -- 游戏先画，director.draw 后画')
    # 截图在测试台这边做**，不在 payload 里 —— 截屏是开发期诊断，
    # 精简版不该为它多带一段代码。这一趟是最后一帧，菜单已经画好了。
    w('  if frames > 25 and not shot_done then')
    w('    shot_done = true')
    w('    pcall(function()')
    w('      local sid = love.graphics.newScreenshot()')
    w('      sid:encode("png", "_kr6_shot.png")')
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
    # 发行版不许有轮询/心跳：命令文件通道、每秒写的诊断文件都不该出现。
    for gone in ("_kr6_cmd", "_kr6_beat", "_kr6_font.txt", "CMD_MAP"):
        check(gone not in src, "精简版里没有 " + gone)


def check_footer_text():
    """署名与声明：cn / en 两边都要有且非空。

    运行时测不到 —— 测试台没有 CJK 字体，只会走 en 那一支；而且文案缺失时 draw_menu
    里的类型守卫会静默跳过、不报错。所以只能查源码。
    """
    src = io.open(os.path.join(ROOT, "src", "_kr6trainer.lua"), encoding="utf-8").read()
    for key in ("credit", "warn"):
        hits = [ln.split("=", 1)[1].strip().rstrip(",").strip('"')
                for ln in src.splitlines() if ln.strip().startswith(key + " = ")]
        check(len(hits) == 2 and all(h for h in hits),
              "MENU_TEXT 的 cn / en 都有非空的 " + key, "hits=%d" % len(hits))


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
    build_harness()
    kv = run_and_read()
    if kv is None:
        print("没有产出日志 —— 测试台没跑起来")
        return 1
    if kv.get("harness_error"):
        print("测试台自己报错了（下面所有断言都不可信）：")
        print(kv["harness_error"])
        return 1

    print("\n断言:")
    check(kv.get("payload_ok") == "true", "payload 能加载并正常返回", kv.get("wrap_error", ""))
    check(kv.get("installed") == "true", "状态表已创建")
    check(kv.get("route2_keys") == "true", "已钩住 director.keypressed（路径 2）")
    check(kv.get("route2_mouse") == "true", "已钩住 director.mousepressed（路径 2）")
    # 功能键必须完全不触发（F 键容易误触，游戏自己也在用）
    check(kv.get("menu_after_fkeys") == "false", "F1–F12 一个都不会打开菜单")
    check(kv.get("passthrough_after_fkeys") == str(len(FKEYS)),
          "F1–F12 原样透传给游戏（F1–F3 是玩家的物品热键，一个都不能吃）",
          "calls=" + kv.get("passthrough_after_fkeys", "?"))
    check(kv.get("after_home_open") == "true", "Home 打开菜单")
    check(kv.get("home_swallowed") == "0", "Home 被吃掉，一次都没透传给游戏",
          "leak=" + kv.get("home_swallowed", "?"))
    check(kv.get("tab_opens_menu") == "true", "Tab 打开菜单（没有 Home 键的键盘）",
          "menu=" + kv.get("tab_opens_menu", "?"))
    check(kv.get("tab_toggles_closed") == "true", "Tab 再按一次关闭（和 Home 一样是开关）",
          kv.get("tab_toggles_closed", "?"))
    check(kv.get("tab_leaked_to_game") == "0", "Tab 被吃掉，没透传给游戏",
          "leak=" + kv.get("tab_leaked_to_game", "?"))
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
    # ---- 击杀金币倍率：**只**放大击杀。击杀与漏怪共用同一个倍率表达式，靠「只在
    # sys.health:on_update 这一趟把表 × 倍率」区分开，所以这几条要一起看。
    check(kv.get("gold_at1") == "1", "倍率 x1 时钩子短路，倍率表一个数都不动",
          "seen=" + kv.get("gold_at1", "?"))
    check(kv.get("gold_mult_val") == "2", "→ 按两下到 x2（步长 0.5，是**可调**不是开关）",
          "mult=" + kv.get("gold_mult_val", "?"))
    check(kv.get("gold_kill_seen") == "2", "击杀系统读到的是放大后的值",
          "seen=" + kv.get("gold_kill_seen", "?"))
    check(kv.get("gold_idx6") == "3", "整张倍率表都按基线放大（1.5 -> 3），不是只改当前模式",
          "idx6=" + kv.get("gold_idx6", "?"))
    check(kv.get("gold_idx2") == "0",
          "基线是 0 的格子不会被弄成非 0（HEROIC/ENDLESS 击杀本来就不给钱）",
          "idx2=" + kv.get("gold_idx2", "?"))
    check(kv.get("gold_goal_seen") == "1", "漏怪系统读到的仍是原值（没被带上）",
          "seen=" + kv.get("gold_goal_seen", "?"))
    check(kv.get("gold_outside") == "1", "钩子跑完表就还原，不会留在放大后的值上",
          "tbl=" + kv.get("gold_outside", "?"))
    check(kv.get("gold_floor") == "1", "← 按到底夹在下限 x1，不会更低",
          "mult=" + kv.get("gold_floor", "?"))
    check(kv.get("gold_ceil") == "10", "→ 按到底夹在上限 x10",
          "mult=" + kv.get("gold_ceil", "?"))
    check(kv.get("gold_back") == "1", "再按回 x1", "mult=" + kv.get("gold_back", "?"))
    check(kv.get("gold_kill_off") == "1", "回到 x1 后击杀读回原值",
          "seen=" + kv.get("gold_kill_off", "?"))
    check(kv.get("gold_restored") == "1", "回到 x1 后倍率表已还原",
          "tbl=" + kv.get("gold_restored", "?"))
    # ---- 防御塔射程 / 攻速：字段在**活塔实体的 attacks 上**（attacks.range /
    # attacks.list[].cooldown）。改 balance.towers.*.stats.* 是没用的 —— 那个只喂 UI 数字。
    check(kv.get("tw_at1_range") == "200", "倍率 x1 时塔射程一个数都不动",
          "range=" + kv.get("tw_at1_range", "?"))
    check(kv.get("tw_range") == "400", "射程 x2 落在 attacks.range 上",
          "range=" + kv.get("tw_range", "?"))
    check(kv.get("tw_cd1") == "0.5" and kv.get("tw_cd2") == "2",
          "攻速 x2 只缩**基础攻击**的冷却（1->0.5，乘倒数是故意的）；没标记的那条（技能）一个数都不动",
          "%s / %s" % (kv.get("tw_cd1", "?"), kv.get("tw_cd2", "?")))
    check(kv.get("tw_range_twice") == "400", "重放不复合（记的是「已乘上去的倍率」）",
          "range=" + kv.get("tw_range_twice", "?"))
    check(kv.get("tw_holder") == "50", "空建造位（tower_holder_*）一个数都不碰",
          "range=" + kv.get("tw_holder", "?"))
    check(kv.get("tw_range_back") == "200" and kv.get("tw_cd_back") == "1",
          "调回 x1 后射程与冷却都还原",
          "%s / %s" % (kv.get("tw_range_back", "?"), kv.get("tw_cd_back", "?")))
    check(kv.get("tw_upgraded") == "660",
          "塔升级换实体后按**完整**倍率乘一次（220 x3 = 660，不是只乘差值）",
          "range=" + kv.get("tw_upgraded", "?"))
    # ---- 新增：塔伤害 / 塔技能CD / 英雄四项（独立假 store，直接驱动 S.*_apply_fn）
    check(near(kv, "n1_dmg", 2) and near(kv, "n1_st", 0.4) and near(kv, "n1_skillcd", 9),
          "倍率全 x1 时塔一个数都不动（damage_factor=2 是**游戏自己**设的，不能被我们碰）",
          "%s / %s / %s" % (kv.get("n1_dmg"), kv.get("n1_st"), kv.get("n1_skillcd")))
    check(near(kv, "n1_hp", 200) and near(kv, "n1_df", 1),
          "倍率全 x1 时英雄一个数都不动", kv.get("n1_hp", "?"))
    check(near(kv, "n2_dmg", 6), "塔伤害 x3 落在 .tower.damage_factor 上（2 -> 6）",
          kv.get("n2_dmg", "?"))
    check(near(kv, "n2_st", 0.2), "塔攻速 x2 也缩 shoot_time（绝对秒数，0.4 -> 0.2）",
          kv.get("n2_st", "?"))
    check(near(kv, "n2_basic", 0.3),
          "塔攻速 x2 缩基础攻击冷却（0.6 -> 0.3，乘倒数是故意的）",
          kv.get("n2_basic", "?"))
    check(near(kv, "n2_skill", 4.5),
          "塔技能CD x0.5 落在技能条目上（9 -> 4.5，**不是**被攻速管的）",
          kv.get("n2_skill", "?"))
    check(near(kv, "n2_mincd", 1.5),
          "塔技能CD 也缩 min_cooldown（第二层地板，法师塔共享）", kv.get("n2_mincd", "?"))
    check(near(kv, "n2_ta", 7.5), "塔技能CD 落在 timed_attacks 上（15 -> 7.5）",
          kv.get("n2_ta", "?"))
    check(near(kv, "n2_static", 4),
          "static_cooldown 的条目跳过（游戏自己的重置逻辑也排除它们）",
          kv.get("n2_static", "?"))
    check(near(kv, "n2_arr", 2.5), "塔技能CD 缩 powers 里**按等级索引的数组**（5 -> 2.5）",
          kv.get("n2_arr", "?"))
    check(near(kv, "n2_num", 3), "塔技能CD 也缩 powers 里的**数字**形式（6 -> 3）",
          kv.get("n2_num", "?"))
    check(near(kv, "n3_dmg", 6) and near(kv, "n3_skill", 4.5),
          "重放不复合（记的是「已经乘上去的倍率」）",
          "%s / %s" % (kv.get("n3_dmg"), kv.get("n3_skill")))
    check(near(kv, "n4_hp", 600) and near(kv, "n4_hpcur", 600),
          "英雄血量 x3 **成对**缩（hp_max 与 hp 都动，只缩上限等于没缩）",
          "%s / %s" % (kv.get("n4_hp"), kv.get("n4_hpcur")))
    check(near(kv, "n4_ls", 600),
          "英雄血量也缩 level_stats.hp_max[]（升级是从这张数组重写的，不缩它升级即失效）",
          kv.get("n4_ls", "?"))
    check(near(kv, "n4_df", 2), "英雄伤害 x2 落在 unit.damage_factor 上",
          kv.get("n4_df", "?"))
    check(near(kv, "n4_mc", 0.75) and near(kv, "n4_hit", 0.25),
          "英雄攻速 x2 同时缩容器级 cooldown 与**前摇** hit_time",
          "%s / %s" % (kv.get("n4_mc"), kv.get("n4_hit")))
    check(near(kv, "n4_cd1", 6) and near(kv, "n4_cd4", 30),
          "英雄技能CD 覆盖 timed_attacks.list 的**每一条**（下标不固定，不能按固定位置写）",
          "%s / %s" % (kv.get("n4_cd1"), kv.get("n4_cd4")))
    check(near(kv, "n5_hp", 600),
          "升级模拟：游戏从 level_stats 重写活体血量后，倍率仍然在（数组已被缩过）",
          kv.get("n5_hp", "?"))
    check(near(kv, "n6_dmg", 2) and near(kv, "n6_skill", 9) and near(kv, "n6_st", 0.4),
          "调回 x1 塔三项都还原到原值",
          "%s / %s / %s" % (kv.get("n6_dmg"), kv.get("n6_skill"), kv.get("n6_st")))
    check(near(kv, "n6_hp", 200) and near(kv, "n6_ls", 200) and near(kv, "n6_df", 1)
          and near(kv, "n6_mc", 1.5),
          "调回 x1 英雄四项都还原到原值",
          "%s / %s / %s / %s" % (kv.get("n6_hp"), kv.get("n6_ls"), kv.get("n6_df"),
                                 kv.get("n6_mc")))
    check(near(kv, "n7_zero", 0),
          "塔技能CD 倍率不会把「无CD」清掉的 0 再当成自己的成果", kv.get("n7_zero", "?"))
    check(near(kv, "n7_back", 9),
          "无CD 关掉、原值写回后，技能CD 倍率补缩一次并收敛到 9（顺序反过来也要对）",
          kv.get("n7_back", "?"))
    check(near(kv, "n8_zero", 0), "英雄技能CD 与「英雄技能无CD」同款共存",
          kv.get("n8_zero", "?"))
    check(near(kv, "n8_back", 12),
          "英雄那边关掉无CD 后同样收敛到 12", kv.get("n8_back", "?"))
    check(near(kv, "b1_plain_min", 20) and near(kv, "b1_plain_max", 40),
          "英雄伤害 x2 落在**不认** use_unit_damage_factor 的子弹模板上（10/20 -> 20/40）",
          "%s / %s" % (kv.get("b1_plain_min"), kv.get("b1_plain_max")))
    check(near(kv, "b1_unit_min", 10),
          "认 use_unit_damage_factor 的子弹模板**一个数都不碰**（碰了就是平方）",
          kv.get("b1_unit_min", "?"))
    check(near(kv, "b1_ls_plain", 20),
          "同一支英雄的 level_stats 远程伤害数组也跟着缩（升级回调是从它重写模板的）",
          kv.get("b1_ls_plain", "?"))
    check(near(kv, "b1_ls_unit", 10),
          "认标志那支的 level_stats **不许缩** —— 缩了升级时会把模板也带偏",
          kv.get("b1_ls_unit", "?"))
    check(near(kv, "b2_plain_min", 20), "子弹模板重放不复合", kv.get("b2_plain_min", "?"))
    check(near(kv, "b3_plain_min", 10) and near(kv, "b3_ls_plain", 10),
          "调回 x1 后子弹模板与 level_stats 都还原",
          "%s / %s" % (kv.get("b3_plain_min"), kv.get("b3_ls_plain")))
    # ---- 攻速第三层：动画 fps
    check(kv.get("a1_shoot") == "nil" and kv.get("a1_hero") == "12",
          "倍率 x1 时不动任何 sprite 的 fps", "%s / %s" % (kv.get("a1_shoot"), kv.get("a1_hero")))
    check(near(kv, "a2_shoot", 60) and near(kv, "a2_shootback", 60),
          "攻速 x2 把攻击动画的 fps 抬到 30x2（名字来自 angles 展开的那条也认）",
          "%s / %s" % (kv.get("a2_shoot"), kv.get("a2_shootback")))
    check(kv.get("a2_idle") == "nil",
          "**非攻击**动画的 fps 一个数都不动（idle 快了玩家一眼能看出来）",
          kv.get("a2_idle", "?"))
    check(near(kv, "a2_hero", 36),
          "英雄攻速 x3 抬到 12x3 —— 原值非 nil 时按**原值**乘，不是按 30",
          kv.get("a2_hero", "?"))
    check(kv.get("a2_heroidle") == "nil", "英雄的 idle 也不动", kv.get("a2_heroidle", "?"))
    check(near(kv, "a3_shoot", 60), "重放不复合", kv.get("a3_shoot", "?"))
    check(kv.get("a4_shoot") == "nil" and kv.get("a4_shootback") == "nil",
          "回 x1 后攻击 sprite 的 fps 还原成 nil（原值就是 nil）",
          "%s / %s" % (kv.get("a4_shoot"), kv.get("a4_shootback")))
    check(near(kv, "a4_hero", 12),
          "原值非 nil 的还原成 **12 而不是 nil** —— 模板里有两处带 fps，写 nil 会改掉它们",
          kv.get("a4_hero", "?"))
    # ---- 分段射击的塔（炮塔那种）
    check(near(kv, "r1_container", 1.5),
          "**容器级** attacks.cooldown 也要缩（3 -> 1.5）—— 炮塔/树人/炼金/三管炮的门控读它，"
          "不缩就是「有变快但明显有上限」",
          kv.get("r1_container", "?"))
    check(kv.get("r1_idle") == "nil" and kv.get("r1_idle2") == "nil",
          "待机动画不动 —— 包括用 loop=false 起的 idle_2（有 7 处塔是这么起的）",
          "%s / %s" % (kv.get("r1_idle"), kv.get("r1_idle2")))
    check(near(kv, "r1_attack2", 60),
          "模板写 \"attack\"、实际播 attack_2：前缀要认（30 x2）", kv.get("r1_attack2", "?"))
    check(near(kv, "r1_rot", 60),
          "瞄准/收招的 rotation_1 也要加速 —— 不加速它炮塔周期等于没改（炮塔就卡在这）",
          kv.get("r1_rot", "?"))
    check(near(kv, "r1_hero_atk", 24), "英雄那边照常（12 x2）", kv.get("r1_hero_atk", "?"))
    check(kv.get("r1_hero_death") == "nil",
          "**英雄不放宽**：一次性但非攻击的动画（death）不许被碰",
          kv.get("r1_hero_death", "?"))
    # ---- 直接发满级信号
    _log = kv.get("ach_log", "")
    check("hero-level-increased" in _log and "hero_lv=10" in _log,
          "给满级英雄发了 hero-level-increased（且发信号那一刻正好 10 级 —— 处理器就这么要求的）",
          _log)
    check("power-level-increased" in _log and "power_lv=6" in _log,
          "也发了 power-level-increased（处理器只看 new_level>=6）",
          _log)
    check(near(kv, "ach_hero_lv", 10), "没满级的英雄会先补到 10 级再发",
          kv.get("ach_hero_lv", "?"))
    _m = kv.get("ach_msg", "")
    check("TIME_SAVIOUR" in _m and "PLAYING_WITH_POWER" in _m,
          "播报里如实列出本次新解锁的成就（动之前记状态、动之后对比）", _m)
    _m2 = kv.get("ach_msg2", "")
    check("TIME_SAVIOUR" not in _m2,
          "已经解锁过的**不再重复报成「新解锁」**", _m2)
    # ---- 敌方塔 / 普攻判据
    check(near(kv, "s1_stage_dmg", 1) and near(kv, "s1_stage_cd", 2),
          "`tower_stage_*`（敌人/机关的塔）一个数都不动 —— 否则玩家是在给敌人上 buff",
          "%s / %s" % (kv.get("s1_stage_dmg"), kv.get("s1_stage_cd")))
    check(near(kv, "s1_culv_basic", 1),
          "真普攻在 list[2] 的塔：攻速按**标记**缩那条（2 -> 1），不是按下标",
          kv.get("s1_culv_basic", "?"))
    check(near(kv, "s1_culv_skill", 2.5),
          "同一条 list 里没标记的那条归技能CD 管（5 -> 2.5）；两边判据互补，谁都不重复缩",
          kv.get("s1_culv_skill", "?"))
    # ---- 「无CD」与倍率的 tick 门禁（review 找出的残留路径）
    check(near(kv, "f1_base", 9) and near(kv, "f1_half", 4.5),
          "tick 路径：塔技能CD x0.5 生效（9 -> 4.5）",
          "%s / %s" % (kv.get("f1_base"), kv.get("f1_half")))
    check(near(kv, "f1_zeroed", 0), "无CD 开着时冷却被清成 0", kv.get("f1_zeroed", "?"))
    check(near(kv, "f1_back", 9),
          "开关**开着时**把倍率调回 x1，关掉开关后仍要收敛到 9（旧代码这里会残留在 4.5）",
          kv.get("f1_back", "?"))
    check(near(kv, "f3_basic", 0.6), "无CD **不碰基础攻击**的冷却（它归攻速管）",
          kv.get("f3_basic", "?"))
    check(near(kv, "f3_skill", 0), "无CD 该清的技能冷却还是清", kv.get("f3_skill", "?"))
    check(kv.get("labelless_items") == "", "每个菜单项都有标签", kv.get("labelless_items", "?"))
    # （命令文件通道已移除，对应的断言一并删掉）
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
    check(kv.get("mult_tag_set") == "true", "记下了本关的标识（换关检测的前提）",
          "tag=" + kv.get("mult_tag_set", "?"))
    check(kv.get("mult_same_level") == "2", "同一关内倍率**不**被复位",
          "val=" + kv.get("mult_same_level", "?"))
    check(kv.get("mult_after_level_change") == "1", "换关后倍率自动归 1",
          "val=" + kv.get("mult_after_level_change", "?"))
    # ---- 技能无CD（三个分开的开关；目标结构是探针实测的，不是猜的）
    check(kv.get("nocd_hero_ta_cd") == "0" and kv.get("nocd_hero_ta_ts") == "0",
          "英雄：timed_attacks 容器里的 cd / ts 清零",
          "cd=%s ts=%s" % (kv.get("nocd_hero_ta_cd"), kv.get("nocd_hero_ta_ts")))
    check(kv.get("nocd_hero_skill_cd") == "0", "英雄：hero.skills 里的 cooldown 也清",
          kv.get("nocd_hero_skill_cd", "?"))
    check(kv.get("nocd_hero_attack_kept") == "2",
          "英雄实体自己的 attack_cd 不动（那是基础攻击节奏）",
          kv.get("nocd_hero_attack_kept", "?"))
    check(kv.get("nocd_tower_cd") == "0" and kv.get("nocd_tower_cd2") == "0",
          "塔：**.tower 子表**里的 attacks 容器清零（探针实测：库存在那里）",
          "cd=%s cooldown=%s" % (kv.get("nocd_tower_cd"), kv.get("nocd_tower_cd2")))
    check(kv.get("nocd_tower_own") == "0", "塔实体自己那层的 attacks 也清",
          kv.get("nocd_tower_own", "?"))
    check(kv.get("nocd_tower_attack_kept") == "9",
          "塔实体自己的 attack_cd 不动", kv.get("nocd_tower_attack_kept", "?"))
    check(kv.get("nocd_enemy_kept") == "6" and kv.get("nocd_enemy_kept2") == "6",
          "敌人的冷却**不许**被清（清了是加强敌人）",
          "atk=%s ta=%s" % (kv.get("nocd_enemy_kept"), kv.get("nocd_enemy_kept2")))
    check(kv.get("nocd_power_entity_kept") == "9",
          "法术：不再乱清实体字段（控制对象不是关卡实体）", kv.get("nocd_power_entity_kept", "?"))
    check(kv.get("nocd_btn_cleared") == "4",
          "法术：按钮上的冷却时长（cooldown_time/max/min）+ tm.ts 共清 4 个",
          "cleared=" + kv.get("nocd_btn_cleared", "?"))
    check(kv.get("nocd_btn_time") == "0" and kv.get("nocd_btn_max") == "0",
          "法术：cooldown_time / cooldown_max 归零",
          "%s / %s" % (kv.get("nocd_btn_time"), kv.get("nocd_btn_max")))
    check(kv.get("nocd_btn_other_kept") == "7", "法术：按钮上别的字段不动",
          kv.get("nocd_btn_other_kept", "?"))
    check(kv.get("nocd_stage_in_team") == "false",
          "哨兵前提：剧情英雄确实不在 hero_team（不成立的话下面那条就是假断言）",
          kv.get("nocd_stage_in_team", "?"))
    check(kv.get("nocd_stage_hero_cd") == "0",
          "剧情英雄（只在 entities）的技能 CD 也被清 —— 旧实现只遍历 hero_team，会漏掉",
          kv.get("nocd_stage_hero_cd", "?"))
    check(kv.get("nocd_rev_zeroed") == "0" and kv.get("nocd_rev_restored") == "8",
          "可逆性：英雄技能的 cd 被清零后，关掉开关能写回原值（8）",
          "%s -> %s" % (kv.get("nocd_rev_zeroed"), kv.get("nocd_rev_restored")))
    check(kv.get("nocd_toggle_err") == "nil" and kv.get("nocd_toggle_off") == "false,false,false",
          "三个开关「开→关」各走一遍都无错，且关完确实是关（还原路径可达）",
          "err=%s off=%s" % (kv.get("nocd_toggle_err"), kv.get("nocd_toggle_off")))
    check(kv.get("nocd_rev_btn_zeroed") == "0" and kv.get("nocd_rev_btn_restored") == "20",
          "可逆性：法术按钮的 cooldown_time 清掉后能写回原值（20）",
          "%s -> %s" % (kv.get("nocd_rev_btn_zeroed"), kv.get("nocd_rev_btn_restored")))
    _msg = kv.get("nocd_report_msg") or ""
    # 不写死 "hero 3/3" 这类计数：夹具一改数量就假报警。只断言「按类报了、且每类都真清到了」。
    def _cleared(kind):
        m = re.search(kind + r" (\d+)/(\d+)", _msg)
        return int(m.group(2)) if m else -1
    check(_cleared("hero") > 0 and _cleared("tower") > 0,
          "自检回执按类报 seen/cleared，hero 与 tower 都真的清到了", _msg)
    check(kv.get("nocd_off_kept") == "5", "关掉后停手，冷却不再被清",
          kv.get("nocd_off_kept", "?"))
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
    # ---- 模板倍率：值在**子表**里（t.health.hp_max / t.motion.max_speed），
    # 改顶层 hp_max/speed 是永远匹配不上的（那就是修之前"一直空转"的原因）。
    check(kv.get("tpl_hp") == "200", "模板血量：写的是 t.health.hp_max（不是顶层 hp_max）",
          "hp_max=" + kv.get("tpl_hp", "?"))
    check(kv.get("tpl_speed") == "100", "模板移速：写的是 t.motion.max_speed",
          "speed=" + kv.get("tpl_speed", "?"))
    check(kv.get("tpl_tower_hp") == "999" and kv.get("tpl_tower_speed") == "77",
          "只动 enemy_* 模板，塔/英雄一个都不碰",
          "%s / %s" % (kv.get("tpl_tower_hp", "?"), kv.get("tpl_tower_speed", "?")))
    check(kv.get("tpl_hp_twice") == "200", "重放两次不复合（基线只记一次）",
          "hp_max=" + kv.get("tpl_hp_twice", "?"))
    check(kv.get("tpl_bal_hp") == "100" and kv.get("tpl_bal_speed") == "50",
          "balance **一个数都不动**（模板每关开头从它重建，写它会变成平方）",
          "%s / %s" % (kv.get("tpl_bal_hp", "?"), kv.get("tpl_bal_speed", "?")))
    check(kv.get("tpl_hp_back") == "100" and kv.get("tpl_speed_back") == "50",
          "模板倍率调回 x1 能还原",
          "%s / %s" % (kv.get("tpl_hp_back", "?"), kv.get("tpl_speed_back", "?")))
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
    # ---- 升级树：三类树的节点名**各不相同**，每个 op 只能碰自己那一类。
    # 集合断言，不是计数断言 —— 差一个名字就该红。
    TOWER_T = {"l1", "l2", "l3a", "l3b", "l4a", "l4b", "ulti"}
    # 英雄树现在是**禁区**：技能点由等级给（skill_points_for_hero_level），树上的节点不是
    # 解锁技能的路子 —— 填了不生效，所以不做。这条钉住"两个 op 都不许碰它"。
    HERO_TOUCH = {"skill_a", "talent_2", "l2"}

    def nodes(key):
        return set(x for x in (kv.get(key) or "").split(",") if x)

    check(nodes("tree_tower") == TOWER_T, "塔树升满：补成 7 个真实节点",
          kv.get("tree_tower", "?"))
    check(nodes("tree_tower_power") == {"l2b", "l1"},
          "塔树升满**不碰法术树**（塔的节点名写进法术树就是坏档）",
          kv.get("tree_tower_power", "?"))
    check(nodes("tree_tower_hero") == HERO_TOUCH, "塔树升满不碰英雄树",
          kv.get("tree_tower_hero", "?"))
    check(nodes("tree_tower_slot") == set(),
          "tower_* 槽位游戏自己从不写（那是另一套机制），一个字都不碰",
          kv.get("tree_tower_slot", "?"))
    # 法术升满：经验先拉满（点数按等级发），再填一条完整路径，清掉错写的 l1
    check(int(kv.get("power_xp_raised", "0")) > 300,
          "法术升满：把经验抬到阈值之上（点数靠等级发，不能只填树）",
          "xp=" + kv.get("power_xp_raised", "?"))
    check(int(kv.get("power_xp_other", "0")) > 0, "法术升满是所有法术，不只出战的",
          "xp=" + kv.get("power_xp_other", "?"))
    check(nodes("power_tree") == {"l2b", "l3", "l4a", "l5a", "l6"},
          "法术升满：保住已有的 l2b，补成一条完整路径，错写的 l1 被清掉",
          kv.get("power_tree", "?"))
    check(nodes("power_tower_untouched") == {"l1"}, "法术升满不碰塔树",
          kv.get("power_tower_untouched", "?"))
    check(nodes("power_hero_untouched") == HERO_TOUCH, "法术升满不碰英雄树",
          kv.get("power_hero_untouched", "?"))
    check(kv.get("power_nostatus_applied") == "0" and nodes("power_nostatus_tree") == {"l1", "l2b"},
          "读不到法术经验表时**整条不做**（宁可不填树，也不造负点数）",
          kv.get("power_nostatus_tree", "?"))
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
    _pw = num(kv, "panel_w", -1)
    check(_pw > 0 and 0 < num(kv, "hint_w", -1) <= _pw - 10,
          "提示行宽度装得下面板（底部的操作提示不许超出面板，实机报过这条）",
          "hint=%s panel=%s" % (kv.get("hint_w", "?"), kv.get("panel_w", "?")))
    # ---- 档位表
    check(near(kv, "lad_down5", 0.5),
          "档位表：从 x1 往左 5 格到 x0.5", kv.get("lad_down5", "?"))
    check(near(kv, "lad_back", 1),
          "**往回 5 格精确回到 x1** —— 加法步进在这里回不到（用户实机报的 bug）",
          kv.get("lad_back", "?"))
    check(near(kv, "lad_floor", 0.1),
          "一路按到底停在下限 x0.1（不是被夹成一个表外的值）", kv.get("lad_floor", "?"))
    check(near(kv, "lad_to_one", 1),
          "从下限往右 9 格**精确**落在 x1", kv.get("lad_to_one", "?"))
    check(near(kv, "lad_ten", 10),
          "x1 → x10 只要 10 下（原来加法步长 0.25 要 36 下）", kv.get("lad_ten", "?"))
    check(near(kv, "lad_cd_max", 1),
          "技能CD 封顶在 x1（越小越快，调到 10 没意义）", kv.get("lad_cd_max", "?"))
    # ---- 滑条
    check(kv.get("sld_has") == "true", "倍率行有滑条轨道")
    check(num(kv, "sld_trackw", -1) > 0, "轨道宽度为正",
          "w=" + kv.get("sld_trackw", "?"))
    check(near(kv, "sld_right", 10), "点轨道最右端 → 最后一档 x10", kv.get("sld_right", "?"))
    check(near(kv, "sld_left", 0.1), "点轨道最左端 → 第一档 x0.1", kv.get("sld_left", "?"))
    check(near(kv, "sld_label_kept", 2),
          "点行左侧**文字区**不改值（那是「执行 / 只读回执」语义，误触不该改数值）",
          kv.get("sld_label_kept", "?"))
    ids = kv.get("all_item_ids", "").split(",")
    # 精简版**应该**有的（金币/生命/无限金钱 + 敌人血量/移速 + 星星/升级树）
    for want in ("gold_add", "gold_sub", "lives_add", "lives_sub", "hold",
                 "hold_lives", "gold_mult", "next_wave", "enemy_hp", "enemy_speed",
                 "tower_range",
                 "tower_damage", "tower_atkspd", "tower_skill_cd",
                 "hero_hp", "hero_damage", "hero_atkspd", "hero_skill_cd",
                 "stars_max", "unlock_tree", "power_max",
                 "nocd_power", "nocd_hero", "nocd_tower",
                 "hero_now_up", "hero_now_max", "ach_unlock", "close"):
        check(want in ids, "菜单含 " + want)
    # **不该**有的：删掉的那些必须真的不在。
    # ⚠️ tower_dmg 仍然禁止：塔伤害走 tower.damage_factor，不碰子弹模板（改模板会被法师
    # brilliance 覆盖）。tower_rate 也仍在清单里：底层做通了，但受射击动画时长限制、
    # 调快很快失效，所以不摆上菜单 —— 机器由下面 tw_cd* 那几条断言钉着。
    # tower_range 已从清单移出：它现在缩的是活塔实体的 attacks.range（选敌时现读的真字段）。
    for gone in ("tower_dmg", "tower_rate", "free_towers",
                 "all_towers", "kill_all", "hide_ui", "gems_add", "unlock_all",
                 "probe", "store", "api", "report", "snap", "diff", "shot",
                 "level_gems_add",
                 # 英雄升级只留「英雄」组那份即时的，存档组不许再有同名项（两条路名字几乎一样）
                 "hero_level_up", "hero_level_max"):
        check(gone not in ids, "精简版菜单里没有 " + gone)

    # 源码层面的硬约束（没有 DEV 开关、没有诊断项、没有轮询/心跳）
    check_slim_payload()
    check_footer_text()

    print()
    if FAILURES:
        print("%d 项失败: %s" % (len(FAILURES), ", ".join(FAILURES)))
        return 1
    print("全部通过。")
    print("菜单渲染截图: %s" % shot)
    return 0


if __name__ == "__main__":
    sys.exit(main())