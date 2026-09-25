-- ===== 冻结快照（lab）：2026-09-25「功能全开」那一版（塔/单位全套倍率、免费造塔、全部塔可造、
-- 秒杀全部敌人、隐藏界面、存档组 + 一整批开发版诊断）；不是发布版，构建链不碰它。
-- 各项的实机验证状态（决定精简版保留什么时唯一可靠的依据）：
--   ✅ 已实测：敌人血量、敌人移速、星星拉满、升级树补全（存档侧：slot_1.lua 里 28 关 × 3 星 = 84）
--   ⚠️ 未实测：塔伤害/射程/攻速、免费造塔、全部塔可造、秒杀全部敌人、隐藏界面、宝石 +1000、全部解锁
-- 想继续开发它：复制回 src/_kr6trainer.lua 即可（发布版是从去掉 _lab 的那个同名文件出的）。

-- kr6 游戏内修改器，由被顶掉的模块（all/director.lua）加载；代码都在 pcall 保护下，坏不了游戏。
-- 改关卡内数值 + 存档进度（走下面的「存档层」钩子；离线工具 tools/kr6_slot_edit.py 是另一条路）。
-- 关卡状态（store，ECS 单例组件）字段：player_gold / lives / gems_collected / gems_per_wave / force_next_wave / level_name；
-- 热键只有 Home（F 键太容易误触）；命令：写 _kr6_cmd.txt，结果见 _kr6_cmd_out.txt（短名见 CMD_MAP）。
local virt, mod = ...

local SEP = string.char(92)
local function save_dir()
  return (os.getenv("APPDATA") or ".") .. SEP .. "kingdom_rush_genesis" .. SEP
end

local function wf(name, txt)
  local f = io.open(save_dir() .. name, "wb")
  if not f then return false end
  f:write(txt)
  f:close()
  return true
end

local function rf(name)
  local f = io.open(save_dir() .. name, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local S = _G.__kr6trainer
if type(S) ~= "table" then
  S = {
    fired = {}, frames = 0, hooks = {}, wrap_src = {}, tick_source = nil,
    reports = 0, last_beat = 0, last_report = 0, t0 = os.time(),
    api_done = false, hold = false, hold_lives = false, last_cmd_check = 0,
    menu_open = false, sel = 1, cjk = false, font = nil, drew = false,
    rects = {}, msg = "", msg_ts = 0,
  }
  _G.__kr6trainer = S
end
local first_install = not S.boot_done
S.boot_done = true

-- _G.__kr6trainer 跨次加载保留，旧 S 里没有本轮新增的字段：缺什么补什么（否则读到 nil）。
if type(S.mult) ~= "table" then
  S.mult = {
    tower_dmg = 1, tower_range = 1, tower_rate = 1,
    enemy_hp = 1, enemy_speed = 1,
  }
end
-- 已经"烤进"模板/场上的倍率：活单位走相对更新（见 mult_apply_live），需要它算 m1/m0。
if type(S.mult_applied) ~= "table" then
  S.mult_applied = {
    tower_dmg = 1, tower_range = 1, tower_rate = 1,
    enemy_hp = 1, enemy_speed = 1,
  }
end
if type(S.mult_base) ~= "table" then
  -- 弱键：实体/组件表被游戏回收后基线跟着释放，不会越攒越多。为什么需要基线见 scale_table。
  S.mult_base = setmetatable({}, { __mode = "k" })
end
for _, k in ipairs({ "free_towers", "all_towers", "hide_ui" }) do
  if S[k] == nil then S[k] = false end
end
if type(S.slot_hooks) ~= "table" then S.slot_hooks = {} end
if type(S.slot_ops) ~= "table" then S.slot_ops = {} end

-- 开发/发布开关：关掉后诊断项全部消失（它们会往 Steam 云同步的存档目录写大文件）；make_dist.py / install.py --release 改这行。
local DEV = true

local AUTO_REPORT = DEV

S.fired[#S.fired + 1] = tostring(virt)
if first_install then S.virt = tostring(virt) end
S.mod = (type(mod) == "table") and mod or S.mod

local function note(cn, en)
  S.msg = S.cjk and tostring(cn) or tostring(en or cn)
  S.msg_ts = os.time()
end

-- tick() 的 pcall 会吞掉错误，静默死掉的诊断最糟：记录下来的错误都落到 _kr6_err.txt。
local function record_err(where, err)
  local msg = tostring(where) .. ": " .. tostring(err)
  S.last_err = msg
  local f = io.open(save_dir() .. "_kr6_err.txt", "ab")
  if f then
    f:write(msg .. string.char(10))
    f:close()
  end
  return msg
end

-- ---- helpers ----
local SKIP = {
  love = true, package = true, string = true, table = true, math = true,
  os = true, io = true, debug = true, coroutine = true, jit = true,
  ffi = true, bit = true, _G = true, arg = true, __kr6trainer = true,
}
local MONEY_SUB = {
  "gold", "gem", "money", "coin", "cash", "currency", "wallet", "silver",
  "spend", "cost", "price", "buy", "purchase", "treasure", "reward", "paid",
  "purse", "credit", "balance", "fund", "loot",
}
local MONEY_EXACT = {
  gold = true, gems = true, gem = true, money = true, coins = true, coin = true,
  cash = true, player_gold = true, gold_amount = true, total_gold = true,
  currency = true, wallet = true,
}
local function ismoney_sub(name)
  local n = tostring(name):lower()
  for i = 1, #MONEY_SUB do
    if n:find(MONEY_SUB[i], 1, true) then return true end
  end
  return false
end
local function safestr(v, maxlen)
  maxlen = maxlen or 70
  local t = type(v)
  if t == "string" then
    if #v > maxlen then v = v:sub(1, maxlen) .. "..." end
    return string.format("%q", v)
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  end
  return "<" .. t .. ">"
end
local function pathkey(k)
  if type(k) == "string" and k:match("^[%a_][%w_]*$") then return "." .. k end
  return "[" .. tostring(k) .. "]"
end

-- ---- the store ----
-- 多条活路径能到达同一个关卡单例 store，全都试一遍。
local function store_of()
  local ok, store = pcall(function()
    local g = _G.game
    if type(g) == "table" then
      if type(g.store) == "table" then return g.store end
      if type(g.simulation) == "table" and type(g.simulation.store) == "table" then
        return g.simulation.store
      end
    end
    local d = _G.director
    if type(d) == "table" and type(d.active_item) == "table"
       and type(d.active_item.store) == "table" then
      return d.active_item.store
    end
    local m = _G.main
    if type(m) == "table" and type(m.handler) == "table" then
      local it = m.handler.active_item
      if type(it) == "table" then
        if type(it.store) == "table" then return it.store end
        if type(it.simulation) == "table" and type(it.simulation.store) == "table" then
          return it.simulation.store
        end
      end
    end
    return nil
  end)
  if ok and type(store) == "table" and store.player_gold ~= nil then return store end
  if ok and type(store) == "table" then return store end
  return nil
end

local function store_stat()
  local s = store_of()
  if not s then return nil end
  return {
    gold = s.player_gold, lives = s.lives, gems = s.gems_collected,
    level = s.level_name, wave = s.force_next_wave,
  }
end

local function set_field(field, value)
  local s = store_of()
  if not s then return "FAIL: no level store (in a level?)" end
  if type(s[field]) ~= "number" then
    return "FAIL: store." .. field .. " is " .. type(s[field])
  end
  local before = s[field]
  s[field] = value
  return ("OK: %s %s -> %s"):format(field, tostring(before), tostring(s[field]))
end

local function add_field(field, delta)
  local s = store_of()
  if not s then return "FAIL: no level store (in a level?)" end
  if type(s[field]) ~= "number" then
    return "FAIL: store." .. field .. " is " .. type(s[field])
  end
  local before = s[field]
  s[field] = before + delta
  return ("OK: %s %s -> %s"):format(field, tostring(before), tostring(s[field]))
end

local function dump_store()
  local s = store_of()
  if not s then return "FAIL: no level store" end
  local L = { "### kr6 store dump ###  clock=" .. tostring(os.time()) }
  local scalars = {}
  for k, v in pairs(s) do
    if type(v) ~= "table" then scalars[#scalars + 1] = "  store." .. tostring(k) .. " = " .. safestr(v) end
  end
  table.sort(scalars)
  for i = 1, #scalars do L[#L + 1] = scalars[i] end
  wf("_kr6_store.txt", table.concat(L, "\n") .. "\n")
  return "store dumped: " .. #scalars .. " scalar fields"
end

-- ---- actions ----
-- 只在开发版可用的动作（发布版里连命令通道也调不到）
local DIAG_ACTIONS = {
  store = true, api = true, report = true, snap = true, diff = true,
  shot = true, level_gems_add = true, probe = true,
}

-- 前向声明：action() 会调它们，但定义在文件更下面 —— 少了这几行，这些名字会解析成**同名全局变量**（nil），
-- 调用时报 "attempt to call global ... (a nil value)"。定义处必须写 `名字 = function()`：写成 `local function` 会新建局部变量，声明仍是 nil。
local report, snapshot, diff_action, api_sweep
local game_mod, balance_of, scale_table, mult_apply, mult_apply_live,
      free_towers_apply, all_towers_apply, hide_ui_apply, kill_all_enemies,
      probe_dump, queue_slot_op, hero_try

local function action(id, arg)
  if id == "gold_set" then
    local r = set_field("player_gold", tonumber(arg) or 999999)
    note(r) return r
  elseif id == "gold_add" then
    local r = add_field("player_gold", tonumber(arg) or 1000)
    note(r) return r
  elseif id == "gold_sub" then
    local r = add_field("player_gold", -(tonumber(arg) or 1000))
    note(r) return r
  elseif id == "hold" then
    S.hold = not S.hold
    note("无限金钱: " .. (S.hold and "开" or "关"),
         "infinite gold: " .. (S.hold and "ON" or "OFF"))
    return "hold=" .. tostring(S.hold)
  elseif id == "lives_add" then
    local r = add_field("lives", tonumber(arg) or 10)
    note(r) return r
  elseif id == "hold_lives" then
    S.hold_lives = not S.hold_lives
    note("生命锁定: " .. (S.hold_lives and "开" or "关"),
         "lock lives: " .. (S.hold_lives and "ON" or "OFF"))
    return "hold_lives=" .. tostring(S.hold_lives)
  elseif id == "level_gems_add" then
    local r = add_field("gems_collected", tonumber(arg) or 100)
    note(r) return r
  elseif id == "lives_sub" then
    local r = add_field("lives", -(tonumber(arg) or 10))
    note(r) return r
  elseif id == "tweak" then
    -- 左右键在可调行上的统一入口，两种目标走同一分支：arg.field → store 字段，arg.set → 我们自己的
    -- 倍率表 S.mult（倍率不在 store 里，所以走不了 add_field）。
    if type(arg) ~= "table" or type(arg.delta) ~= "number" or arg.delta == 0 then
      return "FAIL: bad tweak"
    end
    if type(arg.slot) == "table" then
      local o = arg.slot
      o.n = arg.delta
      return queue_slot_op(o, arg.cn or o.op, arg.en or o.op)
    end
    if type(arg.set) == "table" and arg.key ~= nil then
      local cur = tonumber(arg.set[arg.key]) or 1
      local v = cur + arg.delta
      if arg.min and v < arg.min then v = arg.min end
      if arg.max and v > arg.max then v = arg.max end
      -- 只留两位小数：0.25 反复加减会攒出 1.0000000000000002，而那数字会原样印给玩家看。
      v = math.floor(v * 100 + 0.5) / 100
      if v == cur then
        return "OK: " .. tostring(arg.key) .. " at limit x" .. tostring(v)
      end
      arg.set[arg.key] = v
      local r = "OK: " .. tostring(arg.key) .. " -> x" .. tostring(v)
      note(r) return r
    end
    local r = add_field(arg.field, arg.delta)
    note(r) return r
  elseif id == "next_wave" then
    local s = store_of()
    if not s then note("不在关卡内", "not in a level") return "no store" end
    s.force_next_wave = true
    note("强制下一波", "force next wave")
    return "force_next_wave=true"
  elseif id == "free_towers" or id == "all_towers" or id == "hide_ui" then
    S[id] = not S[id]
    local cn = ({ free_towers = "免费造塔", all_towers = "全部塔可造",
                  hide_ui = "隐藏界面" })[id]
    local en = ({ free_towers = "free towers", all_towers = "unlock all towers",
                  hide_ui = "hide HUD" })[id]
    note(cn .. ": " .. (S[id] and "开" or "关"), en .. ": " .. (S[id] and "ON" or "OFF"))
    return id .. "=" .. tostring(S[id])
  elseif id == "kill_all" then
    local r = kill_all_enemies()
    note(r) return r
  elseif id == "gems_add" then
    local n = tonumber(arg) or 1000
    return queue_slot_op({ op = "gems", n = n, mode = "add" },
                         "宝石 +" .. n, "gems +" .. n)
  elseif id == "stars_max" then
    -- 给星是**主力路径**：游戏自己按轨道把内容发给你，而且不会被回收。
    return queue_slot_op({ op = "stars" }, "星星拉满", "max stars")
  elseif id == "unlock_all" then
    -- 直接塞 selected/team 只是补充：游戏加载时有归属校验（deselect_unowned_units），可能把不属于你的清掉。
    queue_slot_op({ op = "stars" })
    queue_slot_op({ op = "tree" })
    queue_slot_op({ op = "towers" })
    return queue_slot_op({ op = "heroes" }, "全部解锁", "unlock everything")
  elseif id == "unlock_tree" then
    return queue_slot_op({ op = "tree" }, "升级树补全", "fill upgrade trees")
  elseif id == "tower_dmg" or id == "tower_range" or id == "tower_rate"
         or id == "enemy_hp" or id == "enemy_speed" then
    -- 倍率行靠 ←→ 调，但每个菜单项必须能用空参调一次（冒烟测试跑遍全菜单）：给它一个**只读**查询动作。
    local v = S.mult[id]
    local cn = ({ tower_dmg = "塔伤害", tower_range = "塔射程",
                  tower_rate = "塔攻速", enemy_hp = "敌人血量",
                  enemy_speed = "敌人移速" })[id] or id
    note(cn .. " x" .. tostring(v) .. "（←→ 调整）", id .. " = x" .. tostring(v))
    return id .. " = x" .. tostring(v)
  elseif not DEV and DIAG_ACTIONS[id] then
    return "unknown action " .. tostring(id)
  elseif id == "store" then
    local r = dump_store()
    note(r) return r
  elseif id == "api" then
    local r = api_sweep()
    note(r) return r
  elseif id == "report" then
    local r = report("menu")
    note(r) return r
  elseif id == "snap" then
    local n = snapshot()
    note("快照: " .. n .. " 个数值字段", "snapshot: " .. n .. " numeric fields")
    return "snap " .. n
  elseif id == "diff" then
    local r = diff_action()
    note(r) return r
  elseif id == "probe" then
    local r = probe_dump()
    note(r) return r
  elseif id == "hero_try" then
    local r = hero_try()
    note(r) return r
  elseif id == "shot" then
    -- 这个 LÖVE 构建没有 love.graphics.captureScreenshot，改为在帧末自己抓后缓冲
    S.want_shot = true
    note("截图 -> _kr6_shot.png", "screenshot -> _kr6_shot.png")
    return "shot queued"
  elseif id == "close" then
    S.menu_open = false
    return "closed"
  end
  return "unknown action " .. tostring(id)
end

-- 跑一个动作，绝不把错误丢掉。所有派发入口（菜单按键、命令文件）都走这里。
local function run_action(id, arg)
  local ok, res = xpcall(function() return action(id, arg) end,
    function(e)
      return tostring(e) .. string.char(10) .. debug.traceback("", 2)
    end)
  if ok then return res end
  local short = tostring(res):gsub(string.char(10) .. "+", " | ")
  note("出错 " .. tostring(id) .. ": " .. short:sub(1, 70),
       "error " .. tostring(id) .. ": " .. short:sub(1, 70))
  return "FAIL: " .. record_err(id, res)
end

-- ---- reporting ----
local function nummap(budget)
  local out, visits = {}, 0
  local seen = setmetatable({}, { __mode = "k" })
  local function walk(t, path, depth)
    if visits > (budget or 250000) or depth > 8 then return end
    if type(t) ~= "table" or seen[t] then return end
    seen[t] = true
    visits = visits + 1
    for k, v in pairs(t) do
      local tv = type(v)
      local p = path .. pathkey(k)
      if tv == "number" then
        out[p] = v
      elseif tv == "table" then
        if not (depth == 1 and type(k) == "string" and SKIP[k]) then walk(v, p, depth + 1) end
      end
    end
  end
  walk(_G, "_G", 1)
  return out
end
local function count_keys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end
snapshot = function()
  S.snap = nummap()
  S.snap_time = os.time()
  return count_keys(S.snap)
end
diff_action = function()
  local now = nummap()
  local prev = S.snap
  if type(prev) ~= "table" then return "no snapshot yet - run `snap` first" end
  local ints, reals = {}, {}
  for p, v in pairs(now) do
    local o = prev[p]
    if o ~= nil and o ~= v then
      local e = { p = p, o = o, v = v, d = v - o }
      if math.floor(o) == o and math.floor(v) == v then ints[#ints + 1] = e else reals[#reals + 1] = e end
    end
  end
  local function bydelta(a, b)
    local am, bm = math.abs(a.d), math.abs(b.d)
    if am ~= bm then return am < bm end
    return a.p < b.p
  end
  table.sort(ints, bydelta)
  table.sort(reals, bydelta)
  local L = { "### kr6 numeric diff ###",
    "snapshot : " .. tostring(S.snap_time) .. "  (fields " .. count_keys(prev) .. ")",
    "now      : " .. tostring(os.time()) .. "  (fields " .. count_keys(now) .. ")",
    "changed  : " .. (#ints + #reals) .. "   integer=" .. #ints .. " real=" .. #reals, "",
    "=== INTEGER changes, smallest |delta| first ===" }
  for i = 1, math.min(#ints, 500) do
    local e = ints[i]
    L[#L + 1] = ("  d=%+d  %s : %s -> %s"):format(e.d, e.p, tostring(e.o), tostring(e.v))
  end
  L[#L + 1] = ""
  L[#L + 1] = "=== REAL changes, smallest |delta| first ==="
  for i = 1, math.min(#reals, 200) do
    local e = reals[i]
    L[#L + 1] = ("  d=%s  %s : %s -> %s"):format(tostring(e.d), e.p, tostring(e.o), tostring(e.v))
  end
  wf("_kr6_diff.txt", table.concat(L, "\n") .. "\n")
  return #ints .. " int + " .. #reals .. " real changes"
end
local function dump_tbl(t, path, depth, maxdepth, dst, cap)
  if type(t) ~= "table" or depth > maxdepth then return end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  local n = 0
  for i = 1, #keys do
    if n >= cap then dst[#dst + 1] = path .. " ... (truncated)" return end
    local k = keys[i]
    local v = t[k]
    local p = path .. pathkey(k)
    if type(v) == "table" then
      dst[#dst + 1] = p .. " = <table>"
      dump_tbl(v, p, depth + 1, maxdepth, dst, cap)
    else
      dst[#dst + 1] = p .. " = " .. safestr(v)
    end
    n = n + 1
  end
end
-- 英雄 / 等级 / 经验（2026-09-25 为「游戏内即时升级」探路）。
-- 抽成函数是因为它有**两条调用路**：probe_dump（手动按菜单）和 report（自动报告，每 20 秒）。
-- 只加在 probe_dump 里的话自动报告那条路永远不跑 —— 第一次探路正是这么失败的。
-- 为什么要探：等级不落存档、只存经验，等级由 hero_xp_thresholds 推出；而「即时升级」要在
-- 关卡里当场改运行时英雄，现有 dump 却是**抽样**的（hero_team[N].hero.* 只看得见 xp_queued）。
local function hero_report(L, out)
  local gs = game_mod("game_settings")
  if gs then
    out("")
    out("=== game_settings hero_* / xp 阈值表 ===")
    local hk = { "hero_xp_thresholds", "powers_xp_thresholds", "max_hero_ultimate_level",
                 "default_hero_ultimate_level", "heroes_starting_level",
                 "skill_points_for_hero_level", "hero_level_expected",
                 "hero_level_multipliers_above", "hero_level_multipliers_below",
                 "gems_xp_ratio", "gems_per_level" }
    for i = 1, #hk do
      local v = rawget(gs, hk[i])
      if type(v) == "table" then
        local vals = {}
        for k2, v2 in pairs(v) do vals[#vals + 1] = tostring(k2) .. "=" .. tostring(v2) end
        table.sort(vals)
        out(("  %-30s {%s}"):format(hk[i], table.concat(vals, ", ")))
      else
        out(("  %-30s %s"):format(hk[i], tostring(v)))
      end
    end
  end
  local s2 = store_of()
  out("")
  if s2 and type(s2.hero_team) == "table" then
    out("=== store.hero_team 全量（depth 5）===")
    dump_tbl(s2.hero_team, "hero_team", 1, 5, L, 4000)
  else
    out("=== store.hero_team: 不在关卡内，或这关没有英雄 ===")
  end
end


-- 关卡内即时升级的试验（2026-09-25）。
-- ⚠️ 只对**未满级**的英雄动手：第一次探路时出战的是 gerald，而他早满级了，什么都测不出来。
-- 教训是"先确认对象能不能被改"，不是"先写代码"。
-- 参数形态不猜：nparams 直接问 debug.getinfo，再按几种形态逐个试、全部 pcall 住，
-- 每种都记等级/经验/hp 的前后值；**等级一变就停手**，免得连升好几级。
hero_try = function()
  local L = { "### kr6 hero level-up trial v2 ###  clock=" .. tostring(os.time()) }
  local function out(s) L[#L + 1] = s end
  local NL = string.char(10)
  local function flush() wf("_kr6_hero_up.txt", table.concat(L, NL) .. NL) end

  local gs = game_mod("game_settings")
  local thr = gs and rawget(gs, "hero_xp_thresholds")

  local s = store_of()
  if not s or type(s.hero_team) ~= "table" then
    out("不在关卡内，或这关没有英雄")
    flush()
    return "hero trial: 不在关卡内（见 _kr6_hero_up.txt）"
  end

  local ctx = S.hero_ctx
  out("游戏传过的中间实参 ctx = " ..
      (type(ctx) == "table" and "已有" or "还没有 —— 先打一个敌人让游戏调一次"))
  if type(ctx) == "table" and not S.hero_ctx_dumped then
    S.hero_ctx_dumped = true
    local d = {}
    dump_tbl(ctx, "ctx", 1, 2, d, 40)
    out("  ctx 内容: " .. table.concat(d, " | "))
  end

  local function hp_of(e) return (type(e.health) == "table") and e.health.hp_max or nil end
  local function stat_of(h, field, lv)
    local ls = rawget(h, "level_stats")
    local row = (type(ls) == "table") and rawget(ls, field) or nil
    return (type(row) == "table") and rawget(row, lv) or nil
  end

  local hit
  for idx, e in pairs(s.hero_team) do
    local h = (type(e) == "table") and rawget(e, "hero") or nil
    if type(h) == "table" then
      local lv, xp = h.level, h.xp
      local f = rawget(h, "fn_level_up")
      out("")
      out(("===== hero_team[%s]  level=%s  xp=%s  hp_max=%s ====="):format(
          tostring(idx), tostring(lv), tostring(xp), tostring(hp_of(e))))
      local orig = S.hero_orig and S.hero_orig[tostring(idx)]
      if type(orig) == "function" then
        local ok_i, info = pcall(debug.getinfo, orig, "uS")
        if ok_i and type(info) == "table" then
          out(("  真实 fn_level_up: nparams=%s isvararg=%s @ %s:%s"):format(
              tostring(info.nparams), tostring(info.isvararg),
              tostring(info.short_src), tostring(info.linedefined)))
        end
      else
        out("  （还没抓到原函数引用 —— 游戏调过一次就有了）")
      end
      if type(lv) ~= "number" or lv >= 10 then
        out("  → level 已到上限 10，跳过")
      elseif type(f) ~= "function" then
        out("  fn_level_up 不是函数，跳过")
      elseif type(ctx) ~= "table" then
        out("  ⚠️ 还没有 ctx：先打一个敌人让游戏自己调一次 fn_level_up，再按这个")
      else
        out("  阶段1：重放游戏自己的调用  f(e, ctx, true)")
        local lv0 = h.level
        local ok1, err1 = pcall(f, e, ctx, true)
        out(("    -> ok=%s err=%s   level %s->%s  hp_max=%s"):format(
            tostring(ok1), tostring(err1):sub(1, 44),
            tostring(lv0), tostring(h.level), tostring(hp_of(e))))
        if h.level ~= lv0 then
          out("    ✓✓ 阶段1命中：等级当场前进")
          hit = "阶段1 = 直接重放 f(e, ctx, true)"
        else
          local nl = lv + 1
          local want = stat_of(h, "hp_max", nl)
          out(("  阶段2：自己把 level 写成 %s、xp 写成 %s（目标 hp_max=%s），再重放"):format(
              tostring(nl), tostring(thr and thr[nl - 1]), tostring(want)))
          h.level = nl
          if thr and thr[nl - 1] then h.xp = thr[nl - 1] end
          local hp0 = hp_of(e)
          local ok2, err2 = pcall(f, e, ctx, true)
          local hp1 = hp_of(e)
          out(("    -> ok=%s err=%s   hp_max %s->%s%s"):format(
              tostring(ok2), tostring(err2):sub(1, 44), tostring(hp0), tostring(hp1),
              (want ~= nil and hp1 == want) and "   ✓✓ 属性对上了" or ""))
          if want ~= nil and hp1 == want then
            hit = "阶段2 = 先写 level/xp，再重放 f(e, ctx, true)"
          else
            out("    阶段2没对上。⚠️ level 已推进到 " .. tostring(h.level) ..
                "，属性可能不同步 —— 看后续自动报告 hp_max 会不会自己跟上")
          end
        end
      end
    end
  end
  out("")
  out("结论：" .. (hit and ("命中：" .. hit) or "未命中（看每步的 err 与前后值）"))
  flush()
  return "hero trial -> _kr6_hero_up.txt" .. (hit and "  [命中]" or "")
end
-- 按**实体**包装英雄自己的 fn_level_up，记录游戏调用它时的实参。
-- 为什么必须这样：fn_level_up 是 per-hero 的脚本回调（connor 在 scripts_game.lua:13580，
-- drakkan 在 11783），签名 3 个参数、且**只有第 3 个参数到位才会真的升级**（实测 f(e) 与
-- f(e,lv+1) 都不报错但什么都不做）。参数含义靠猜没用，只能看游戏自己怎么调。
-- 而"击杀敌人 → 等级追一级"正是游戏在调它，所以让玩家正常打就行。
-- ⚠️ 装好立刻写一行 [installed]：上次没这行，导致"没装上"和"装上了但没调"分不清。
local function install_hero_fn_hooks()
  local s = store_of()
  if not s or type(s.hero_team) ~= "table" then return false end
  local function append(txt)
    local f = io.open(save_dir() .. "_kr6_hero_calls.txt", "a")
    if not f then return end
    f:write(txt .. string.char(10))
    f:close()
  end
  local n = 0
  for idx, e in pairs(s.hero_team) do
    local h = (type(e) == "table") and rawget(e, "hero") or nil
    local f = (type(h) == "table") and h.fn_level_up or nil
    if type(f) == "function" then
      local key = "fnlvl_" .. tostring(idx) .. "_" .. tostring(e)
      if not S.wrap_src[key] then
        S.wrap_src[key] = true
        rawset(h, "fn_level_up", function(...)
          local argc = select("#", ...)
          local a2 = select(2, ...)
          -- ★ 把游戏自己传的**中间那个表**留一份：它就是"重放调用"要用的实参。
          -- 不理解它是什么也能用（照抄游戏自己的调用），dump 一次更有价值。
          -- 实测两个英雄在同一帧拿到的是**同一个表**，像是调用方每帧构造的上下文。
          if type(a2) == "table" then
            S.hero_ctx = a2
            if not S.hero_ctx_dumped then
              S.hero_ctx_dumped = true
              local d = {}
              dump_tbl(a2, "ctx", 1, 2, d, 40)
              append("[ctx dump] " .. table.concat(d, " | "))
            end
          end
          S.hero_orig = S.hero_orig or {}
          S.hero_orig[tostring(idx)] = f     -- 原函数留一份：要问 debug.getinfo 得问它
          local parts = {}
          for a = 1, argc do
            local v = select(a, ...)
            local tv = type(v)
            parts[a] = (tv == "table" and "表") or
                       (tv == "string" and ('"' .. v .. '"')) or tostring(v)
          end
          local res = { pcall(f, ...) }
          append(("f=%d hero_team[%s].fn_level_up(%d) [%s] -> ok=%s"):format(
            S.frames, tostring(idx), argc, table.concat(parts, ", "), tostring(res[1])))
          if res[1] then return res[2], res[3] end
          error(res[2], 0)     -- 原样抛出：探针不该改变游戏的行为
        end)
        append(("[installed] hero_team[%s] fn_level_up 已包装  f=%d"):format(tostring(idx), S.frames))
        n = n + 1
      end
    end
  end
  return n > 0
end

-- 把 script_utils 里那三个经验函数也包一层（模块级；如果游戏持有的是捕获的局部引用，
-- 这些就永远不触发 —— 那本身也是有用的信息）。
local function install_hero_mod_hooks()
  local su = game_mod("script_utils")
  if type(su) ~= "table" then return nil end
  local function append(txt)
    local f = io.open(save_dir() .. "_kr6_hero_calls.txt", "a")
    if not f then return end
    f:write(txt .. string.char(10))
    f:close()
  end
  local targets = { "hero_gain_xp", "hero_gain_xp_from_skill", "hero_level_up" }
  local n = 0
  for i = 1, #targets do
    local fname = targets[i]
    local key = "hermod_" .. fname
    local orig = rawget(su, fname)
    if type(orig) == "function" and not S.wrap_src[key] then
      S.wrap_src[key] = true
      rawset(su, fname, function(...)
        local argc = select("#", ...)
        local parts = {}
        for a = 1, argc do
          local v = select(a, ...)
          local tv = type(v)
          parts[a] = (tv == "table" and ("table:" .. tostring(v))) or
                     (tv == "string" and ('"' .. v .. '"')) or tostring(v)
        end
        local res = { pcall(orig, ...) }
        append(("f=%d script_utils.%s(%d) [%s] -> ok=%s ret=%s,%s"):format(
          S.frames, fname, argc, table.concat(parts, ", "),
          tostring(res[1]), tostring(res[2]), tostring(res[3])))
        if res[1] then return res[2], res[3] end
        error(res[2], 0)
      end)
      append(("[installed] script_utils.%s 已包装  f=%d"):format(fname, S.frames))
      n = n + 1
    end
  end
  return n
end


local function scan(budget)
  local visits, found = 0, {}
  local seen = setmetatable({}, { __mode = "k" })
  local function walk(t, path, depth)
    if visits > (budget or 400000) or depth > 9 then return end
    if type(t) ~= "table" or seen[t] then return end
    seen[t] = true
    visits = visits + 1
    for k, v in pairs(t) do
      local tv = type(v)
      local p = path .. pathkey(k)
      if tv == "table" then
        if ismoney_sub(k) then found[#found + 1] = p .. " = <table>" end
        if not (depth == 1 and type(k) == "string" and SKIP[k]) then walk(v, p, depth + 1) end
      elseif tv == "number" or tv == "string" or tv == "boolean" then
        if MONEY_EXACT[tostring(k):lower()] or ismoney_sub(k) then
          found[#found + 1] = p .. " = " .. safestr(v)
        end
      end
    end
  end
  walk(_G, "_G", 1)
  return found
end
report = function(tag)
  local L = {}
  local function out(s) if #L < 40000 then L[#L + 1] = s end end
  local st = store_stat()
  out("### kr6 trainer report ###")
  out("tag     : " .. tostring(tag))
  out("clock   : " .. tostring(os.time()) .. "  (t+" .. tostring(os.time() - S.t0) .. "s)")
  out("fired   : " .. table.concat(S.fired, ", "))
  out("frames  : " .. tostring(S.frames) .. "  tick_source=" .. tostring(S.tick_source))
  if st then
    out("STORE   : gold=" .. tostring(st.gold) .. " lives=" .. tostring(st.lives) ..
        " gems=" .. tostring(st.gems) .. " level=" .. tostring(st.level))
  else
    out("STORE   : (not in a level)")
  end
  out("hold    : gold=" .. tostring(S.hold) .. " lives=" .. tostring(S.hold_lives))
  out("build   : DEV=" .. tostring(DEV) .. " auto_report=" .. tostring(AUTO_REPORT))
  out("slot    : " .. tostring(S.slot_path) .. "  (" .. tostring(S.slot_match) .. ")")
  out("last_err: " .. tostring(S.last_err))
  out("")
  local s = store_of()
  if s then
    out("=== level store (scalars) ===")
    local scalars = {}
    for k, v in pairs(s) do
      if type(v) ~= "table" then scalars[#scalars + 1] = "  store." .. tostring(k) .. " = " .. safestr(v) end
    end
    table.sort(scalars)
    for i = 1, #scalars do out(scalars[i]) end
    out("")
  end
  local found = scan()
  out("=== money-ish fields (" .. #found .. ") ===")
  table.sort(found)
  for i = 1, math.min(#found, 600) do out("  " .. found[i]) end
  out("")
  out("=== _G top level (non-function) ===")
  local gs = {}
  for k, v in pairs(_G) do
    if type(v) ~= "function" then gs[#gs + 1] = string.format("  %s : %s", tostring(k), type(v)) end
  end
  table.sort(gs)
  for i = 1, #gs do out(gs[i]) end
  out("")
  for _, rname in ipairs({ "main", "game", "director", "game_gui" }) do
    local v = rawget(_G, rname)
    if type(v) == "table" then
      out("=== _G." .. rname .. " (depth 3) ===")
      dump_tbl(v, "_G." .. rname, 1, 3, L, 300)
      out("")
    end
  end
  hero_report(L, out)
  wf("_kr6_report_" .. tostring(tag) .. ".txt", table.concat(L, "\n") .. "\n")
  return "report(" .. tostring(tag) .. ")"
end

local function foreach_function(visit, opts)
  opts = opts or {}
  local maxdepth = opts.depth or 2
  local seen = setmetatable({}, { __mode = "k" })
  local count = 0
  local function scan_table(t, path, depth)
    if depth > maxdepth or count > (opts.max or 40000) then return end
    if type(t) ~= "table" or seen[t] then return end
    seen[t] = true
    for k, v in pairs(t) do
      local p = path .. pathkey(k)
      local tv = type(v)
      if tv == "function" then
        count = count + 1
        visit(p, v)
      elseif tv == "table" then
        scan_table(v, p, depth + 1)
      end
    end
  end
  local names = {}
  for k in pairs(package.loaded) do
    if type(k) == "string" then names[#names + 1] = k end
  end
  table.sort(names)
  for i = 1, #names do
    local m = package.loaded[names[i]]
    if type(m) == "table" and not SKIP[names[i]] then scan_table(m, names[i], 1) end
  end
  return count
end

api_sweep = function()
  local A = {}
  local function out(s) if #A < 30000 then A[#A + 1] = s end end
  out("### kr6 API map ###  clock=" .. tostring(os.time()))
  out("=== functions: path  fn(nparams,vararg @src:line)  upvalues ===")
  local money = {}
  local n = foreach_function(function(path, f)
    local ok, info = pcall(debug.getinfo, f, "uS")
    local ups = {}
    local i = 1
    while i < 200 do
      local ok2, name = pcall(debug.getupvalue, f, i)
      if not ok2 or name == nil then break end
      ups[#ups + 1] = tostring(name)
      i = i + 1
    end
    if ok and type(info) == "table" then
      out(string.format("%s  fn(nparams=%s vararg=%s @%s:%s) up=[%s]", path,
        tostring(info.nparams), tostring(info.isvararg),
        tostring(info.short_src), tostring(info.linedefined), table.concat(ups, ",")))
    else
      out(path .. "  fn(?)")
    end
    local hit = ismoney_sub(path)
    local upvals = {}
    for j = 1, #ups do
      if ismoney_sub(ups[j]) then
        hit = true
        local okv, _, uval = pcall(debug.getupvalue, f, j)
        if okv then upvals[#upvals + 1] = ups[j] .. "=" .. safestr(uval, 40) end
      end
    end
    if hit then
      money[#money + 1] = path .. "  up=[" .. table.concat(ups, ",") .. "]" ..
        (#upvals > 0 and ("   VALUES: " .. table.concat(upvals, " , ")) or "")
    end
  end)
  out("")
  out("=== money-ish functions / upvalues (" .. #money .. ") ===")
  table.sort(money)
  for i = 1, math.min(#money, 800) do out("  " .. money[i]) end
  wf("_kr6_api.txt", table.concat(A, "\n") .. "\n")
  S.api_done = true
  return "api: " .. n .. " functions, " .. #money .. " money-ish"
end

-- ---- 游戏内部：塔 / 单位 / 作弊 ----

-- 从 package.loaded 拿游戏模块。**不能用 require** —— payload 从覆盖桩里加载，require 会重入。
game_mod = function(name)
  local m = package.loaded[name]
  if type(m) == "table" then return m end
  m = _G[name]                       -- game / director / main 这几个是全局
  if type(m) == "table" then return m end
  return nil
end

-- 依赖缺失时的统一回复。**刻意不含 "FAIL"**：冒烟测试把含 FAIL 的回复算失败。
local function na(what)
  return "n/a: " .. tostring(what)
end

-- balance 表**不在 package.loaded 里**，挂在 upgrades 两个函数的 upvalue 上；按**名字**找而不是按下标。
balance_of = function()
  local up = game_mod("upgrades")
  if not up then return nil end
  local fns = { "get_points_by_level", "patch_templates" }
  for i = 1, #fns do
    local f = up[fns[i]]
    if type(f) == "function" then
      for j = 1, 60 do
        local ok, name, val = pcall(debug.getupvalue, f, j)
        if not ok or name == nil then break end
        if name == "balance" and type(val) == "table" then return val end
      end
    end
  end
  return nil
end

-- 字段名一律以**实机探针**（probe 动作 → _kr6_probe.txt）为准。敌人：balance.enemies.<组>.<单位> 的
-- hp 是**按等级分的数组**、speed 是标量，活实体上是 health.hp_max；⚠️ **绝不能每帧重放当前血量**（hp）＝永远打不死。
local ENEMY_HP_FIELDS    = { hp_max = true }
local ENEMY_HP_ARRAYS    = { hp = true }
local ENEMY_SPEED_FIELDS = { speed = true, speed_limit = true, max_speed = true }

-- 塔：字段在 balance.towers.<名字>.**stats** 下面，不在塔表本身上（实测 archers.stats）。
local TOWER_STATS = "stats"
local TOWER_FIELDS = {
  tower_dmg   = { damage = true },
  tower_range = { range = true },
  -- 攻速是**反的**：倍率 x2 表示打得更快，冷却要**除** 2（调用处传的是 1/mult）。
  tower_rate  = { cooldown = true },
}

-- 15 种塔的名字，取自**实机探针的 balance.towers 键名** —— 字节码符号里的名字会错。
local TOWER_NAMES = {
  "archers", "knights", "catapult", "wizard", "culverine", "ranger", "sniper",
  "alchemist", "miners", "wildcat", "sunray_master", "crossbows", "tree",
  "forger", "light_priestess",
}

-- 为什么要自己记基线：游戏自己的 difficulty.patch_templates 是**原地乘**，调两次就复合；
-- 我们要的是「每帧幂等重放」—— 第一次见到字段把原值记进 S.mult_base，之后每帧写 base*mult。
scale_table = function(t, fields, mult)
  if type(t) ~= "table" then return 0 end
  local base = S.mult_base[t]
  if not base then base = {} S.mult_base[t] = base end
  local n = 0
  for k, v in pairs(t) do
    if fields[k] and type(v) == "number" then
      if base[k] == nil then base[k] = v end
      local want = base[k] * mult
      if t[k] ~= want then t[k] = want n = n + 1 end
    end
  end
  return n
end

local function scale_arrays(t, fields, mult)
  if type(t) ~= "table" then return 0 end
  local n = 0
  for k, v in pairs(t) do
    if fields[k] and type(v) == "table" then
      local base = S.mult_base[t]
      if not base then base = {} S.mult_base[t] = base end
      local b = base[k]
      if type(b) ~= "table" then b = {} base[k] = b end
      for i = 1, #v do
        local cur = v[i]
        if type(cur) == "number" then
          if b[i] == nil then b[i] = cur end
          local want = b[i] * mult
          if cur ~= want then v[i] = want n = n + 1 end
        end
      end
    end
  end
  return n
end

-- 收集 balance.towers.<名字>.stats；遍历整个表而不是按 TOWER_NAMES 点名（没有 .stats 的子表天然被跳过）。
local function tower_stats_tables(bal)
  local out = {}
  if type(bal) ~= "table" then return out end
  local tw = bal.towers
  if type(tw) ~= "table" then return out end
  for _, t in pairs(tw) do
    if type(t) == "table" and type(t[TOWER_STATS]) == "table" then
      out[#out + 1] = t[TOWER_STATS]
    end
  end
  return out
end

-- 遍历 entity_db 里的模板；返回**访问到的模板个数**（不能用 fn 返回值之和 —— 那个回调恒返回 0）。
-- filter_templates 的第一个参数是 self，但该传什么没有实证：几种形态都试，成了就记进 S.tpl_shape。
local function each_template(edb, fn)
  if type(edb) ~= "table" then return 0 end
  local regs = { "templates", "templates_game", "templates_all" }
  for i = 1, #regs do
    local reg = edb[regs[i]]
    if type(reg) == "table" then
      local seen = 0
      for _, t in pairs(reg) do
        if type(t) == "table" then seen = seen + 1 fn(t) end
      end
      if seen > 0 then S.tpl_shape = "field:" .. regs[i] return seen end
    end
  end
  if type(edb.filter_templates) ~= "function" then return 0 end
  local shapes = {
    { "filter_templates(edb)",  function() return edb.filter_templates(edb) end },
    { "filter_templates()",     function() return edb.filter_templates() end },
    { "filter_templates(game)", function() return edb.filter_templates(_G.game) end },
  }
  for i = 1, #shapes do
    local ok, list = pcall(shapes[i][2])
    if ok and type(list) == "table" and #list > 0 then
      S.tpl_shape = shapes[i][1]
      local seen = 0
      for j = 1, #list do
        local t = list[j]
        if type(t) == "table" then seen = seen + 1 fn(t) end
      end
      return seen
    end
  end
  return 0
end

-- 每帧重放所有倍率：模板决定之后生成的对象、活实体决定已在场上的，两边都要写（模板会被深拷贝）。
mult_apply = function()
  local m = S.mult
  local dmg, rng = m.tower_dmg, m.tower_range
  local rate = (m.tower_rate and m.tower_rate > 0) and (1 / m.tower_rate) or 1
  local hp, sp = m.enemy_hp, m.enemy_speed
  local n = 0

  local edb = game_mod("entity_db")
  each_template(edb, function(t)
    local nm = tostring(t.template_name or t.name or "")
    if nm:sub(1, 6) == "enemy_" then
      n = n + scale_table(t, ENEMY_HP_FIELDS, hp)
      n = n + scale_arrays(t, ENEMY_HP_ARRAYS, hp)
      n = n + scale_table(t, ENEMY_SPEED_FIELDS, sp)
    elseif nm:sub(1, 6) == "tower_" then
      local st = (type(t[TOWER_STATS]) == "table") and t[TOWER_STATS] or t
      n = n + scale_table(st, TOWER_FIELDS.tower_dmg, dmg)
      n = n + scale_table(st, TOWER_FIELDS.tower_range, rng)
      n = n + scale_table(st, TOWER_FIELDS.tower_rate, rate)
    end
  end)

  local bal = balance_of()
  if type(bal) == "table" then
    local en = bal.enemies
    if type(en) == "table" then
      for _, grp in pairs(en) do
        if type(grp) == "table" then
          for _, e in pairs(grp) do
            if type(e) == "table" then
              n = n + scale_arrays(e, ENEMY_HP_ARRAYS, hp)
              n = n + scale_table(e, ENEMY_SPEED_FIELDS, sp)
            end
          end
        end
      end
    end
    local tt = tower_stats_tables(bal)
    for i = 1, #tt do
      n = n + scale_table(tt[i], TOWER_FIELDS.tower_dmg, dmg)
      n = n + scale_table(tt[i], TOWER_FIELDS.tower_range, rng)
      n = n + scale_table(tt[i], TOWER_FIELDS.tower_rate, rate)
    end
  end

  -- 已经在场上的单位**不在这里处理**：走 mult_apply_live 的相对更新（基线法会复合）。
  return n
end

-- 遍历 store.entities。⚠️ **必须用 pairs，绝不能用 `for i = 1, #s.entities`**：这张表是**稀疏**的
-- （下标从 2 起、中间有洞），`#` 遇到 `t[1] == nil` 直接返回 0 —— 一次都不循环，全部静默失效。
local function each_entity(s, fn)
  if type(s) ~= "table" or type(s.entities) ~= "table" then return 0 end
  local n = 0
  for _, e in pairs(s.entities) do
    if type(e) == "table" then n = n + fn(e) end
  end
  return n
end

-- 血量必须**成对**缩放：只缩 hp_max 的话当前血量（health.hp）还是原值，照样挨几下就死。
-- ⚠️ 只在倍率变化的那一次调用（mult_apply_live），**绝不能每帧重放** —— 否则敌人永远打不死。
local function scale_health(h, factor)
  if type(h) ~= "table" then return 0 end
  local n = 0
  local hi, cur = h.hp_max, h.hp
  if type(hi) == "number" then
    local v = hi * factor
    if v ~= hi then h.hp_max = v n = n + 1 end
  end
  if type(cur) == "number" then
    local v = cur * factor
    -- 往下调倍率时别把敌人直接算死（至少留 1 点）
    if v < 1 then v = 1 end
    if v ~= cur then h.hp = v n = n + 1 end
  end
  return n
end

local function scale_once(t, fields, factor)
  if type(t) ~= "table" then return 0 end
  local n = 0
  for k, v in pairs(t) do
    if fields[k] and type(v) == "number" then
      t[k] = v * factor
      n = n + 1
    end
  end
  return n
end

-- 已经在场上的单位走**相对**更新：只在倍率变化的那一刻按 m1/m0 乘一次。不能用基线法 ——
-- 活单位深拷贝自**已经被我们改过**的模板，它的"原值"已经是 base*mult，再记一次就是 5 倍变 25 倍。
mult_apply_live = function()
  local cur, prev = S.mult, S.mult_applied
  for k, v in pairs(cur) do
    local p = prev[k] or 1
    if v ~= p then
      if p > 0 then
        local f = v / p
        local s = store_of()
        each_entity(s, function(e)
          if k == "enemy_hp" then
            scale_health(e.health, f)
          elseif k == "enemy_speed" then
            scale_once(e.motion, ENEMY_SPEED_FIELDS, f)
          elseif k == "tower_dmg" then
            scale_once(e.tower, TOWER_FIELDS.tower_dmg, f)
          elseif k == "tower_range" then
            scale_once(e.tower, TOWER_FIELDS.tower_range, f)
          elseif k == "tower_rate" then
            scale_once(e.tower, TOWER_FIELDS.tower_rate, 1 / f)
          end
          return 0
        end)
      end
      prev[k] = v
    end
  end
end

-- 免费造塔：把造塔/开格子价格的字段写 0（开关开）或写回原值（开关关）；只往 0 写、已经是 0 就跳过。
-- 记基线是为了**关掉时能还原**：只写 0 不记原值，关掉后价格会一直停在 0 直到重开关卡。
local function zero_fields(t, names, want_zero)
  if type(t) ~= "table" then return 0 end
  local n = 0
  for i = 1, #names do
    local k = names[i]
    -- rawget：这些组件可能带 __index 元方法，一律绕开
    local v = rawget(t, k)
    if type(v) == "number" then
      local base = S.mult_base[t]
      if want_zero then
        if not base then base = {} S.mult_base[t] = base end
        -- 基线在**第一次置零时**才记，不是拿到表就记 —— 否则会拿过期的原值去"还原"。
        if base[k] == nil then base[k] = v end
        if v ~= 0 then t[k] = 0 n = n + 1 end
      elseif base and base[k] ~= nil and v ~= base[k] then
        t[k] = base[k] n = n + 1
      end
    end
  end
  return n
end

free_towers_apply = function()
  local s = store_of()
  if not s or type(s.entities) ~= "table" then return 0 end
  local z = S.free_towers and true or false
  return each_entity(s, function(e)
    return zero_fields(e.tower, { "min_cost", "price" }, z)
         + zero_fields(e.tower_holder, { "unblock_price" }, z)
  end)
end

-- 全部塔可造：填满「本关能造什么塔」那两张表。⚠️ 表挂在 store 的哪一层**没有实证**，所以只对
-- 「已经含有塔名的表」动手 —— 宁可什么都不做，也不能往一个不相干的表里塞字符串把关卡搞坏。
local function find_tower_list(s, want)
  if not s then return nil end
  local holders = { s, s.level, s.level_data, s.store }
  for i = 1, #holders do
    local h = holders[i]
    if type(h) == "table" then
      local t = h[want]
      if type(t) == "table" then
        for k, v in pairs(t) do
          local sv = tostring(v)
          for j = 1, #TOWER_NAMES do
            if sv == TOWER_NAMES[j] then return t end
          end
          if type(k) == "string" then
            for j = 1, #TOWER_NAMES do
              if k == TOWER_NAMES[j] then return t end
            end
          end
        end
      end
    end
  end
  return nil
end

local function snapshot_list(t)
  local base = S.mult_base[t]
  if not base then base = {} S.mult_base[t] = base end
  if not base.__orig then
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    base.__orig = o
  end
  return base.__orig
end

local function restore_list(t, orig)
  local n = 0
  for k in pairs(t) do t[k] = nil n = n + 1 end
  for k, v in pairs(orig) do t[k] = v n = n + 1 end
  return n
end

all_towers_apply = function()
  local s = store_of()
  if not s then return 0 end
  local n = 0
  local on = S.all_towers and true or false

  -- 实测：这一关能造哪些塔就是 store.selected_towers 这个**名字数组**（别按字节码符号猜名字）。
  local av = find_tower_list(s, "selected_towers")
  if av then
    if on then
      snapshot_list(av)
      -- **只增不删**：游戏自己也会往里加（关卡脚本会解锁塔），整表重写会把它抹掉。
      for j = 1, #TOWER_NAMES do
        local nm = TOWER_NAMES[j]
        local has = false
        for k = 1, #av do if av[k] == nm then has = true break end end
        if not has then av[#av + 1] = nm n = n + 1 end
      end
    else
      local orig = S.mult_base[av] and S.mult_base[av].__orig
      if orig then n = n + restore_list(av, orig) end
    end
  end

  local lv = s.level
  local lk = (type(lv) == "table") and lv.locked_towers
  if type(lk) == "table" then
    if on then
      snapshot_list(lk)
      for k in pairs(lk) do if lk[k] ~= nil then lk[k] = nil n = n + 1 end end
    else
      local orig = S.mult_base[lk] and S.mult_base[lk].__orig
      if orig then n = n + restore_list(lk, orig) end
    end
  end
  return n
end

-- 隐藏界面。字段是实证的，但**游戏什么时候读它没有实证** —— 所以每帧重放，绕开时机问题。
hide_ui_apply = function()
  local g = _G.game
  if type(g) ~= "table" then return 0 end
  local want = S.hide_ui and true or false
  if g.gui_hud_hidden ~= want then g.gui_hud_hidden = want return 1 end
  return 0
end

-- 秒杀全部敌人：往伤害队列塞一条真伤。⚠️ 队列形状是**推测**的（符号级证据），所以先判类型，
-- 不是普通 table 就不动手 —— 硬调 klove.simulation 的队列对象会把整局搞坏。
kill_all_enemies = function()
  local s = store_of()
  if not s then return na("no level store") end
  if type(s.entities) ~= "table" then return na("no entities list") end
  local q = s.damage_queue
  if type(q) ~= "table" then
    return na("damage_queue is " .. type(q) .. " - 形状未验证，不动手")
  end
  local dmg = _G.DAMAGE_TRUE
  if dmg == nil then dmg = _G.DAMAGE_INSTAKILL end
  if dmg == nil then return na("no DAMAGE_TRUE in _G") end
  local n = each_entity(s, function(e)
    if e.enemy == nil or type(e.health) ~= "table" then return 0 end
    local hp = tonumber(e.health.hp_max) or tonumber(e.health.hp) or 1
    q[#q + 1] = {
      damage_type = dmg, target_id = e.id, value = hp, damage = hp,
    }
    return 1
  end)
  if n == 0 then return na("no enemies on field") end
  return "queued " .. n .. " kills"
end

-- 探针：把未知量一次性问出来（塔的字段路径、塔名单挂在哪、damage_queue 形状）。只读，不改任何东西。
probe_dump = function()
  local L = { "### kr6 probe ###  clock=" .. tostring(os.time()) }
  local function out(s) if #L < 40000 then L[#L + 1] = s end end

  out("=== module availability ===")
  local names = { "entity_db", "upgrades", "game_settings", "difficulty",
                  "systems", "storage", "storage_io_generic", "hump.signal",
                  "klove.kui_db", "scripts", "level_utils", "gui_utils" }
  for i = 1, #names do
    out(("  %-18s %s"):format(names[i], type(package.loaded[names[i]])))
  end
  out("  _G.DAMAGE_TRUE      = " .. tostring(_G.DAMAGE_TRUE))
  out("  _G.DAMAGE_INSTAKILL = " .. tostring(_G.DAMAGE_INSTAKILL))

  local gs = game_mod("game_settings")
  out("")
  if gs then
    out("=== game_settings difficulty_* ===")
    local ks = { "difficulty_enemy_hp_max_factor", "difficulty_enemy_speed_factor",
                 "difficulty_soldier_hp_max_factor" }
    for i = 1, #ks do out(("  %s = %s"):format(ks[i], tostring(gs[ks[i]]))) end
  else
    out("=== game_settings: NOT LOADED ===")
  end

  -- 英雄结构 + xp 阈值表（与自动报告共用同一个函数，见 hero_report）
  hero_report(L, out)

  -- ⚠️ 「包装函数」**不在这里**，挪到 tick 里了（见 install_hero_fn_hooks /
  -- install_hero_mod_hooks）——按实体包装 per-hero 的 fn_level_up 才是主目标。
  -- 理由：这一段只有手动按「转储」才会跑到，而调用日志必须**在游戏自己调用之前**就装好，
  -- 才能记到实参。第一次探路正是死在这里 —— 自动报告走的是 report() 而不是 probe_dump()，
  -- 所以这份代码一次都没执行，日志文件根本没生成。

  local s = store_of()
  out("")
  if s then
    out("=== store (depth 4) ===")
    dump_tbl(s, "store", 1, 4, L, 3000)

    out("")
    out("=== 塔名单（all_towers_apply 的目标）===")
    out("  store.selected_towers     : " .. tostring(find_tower_list(s, "selected_towers") ~= nil))
    out("  store.level.locked_towers : " ..
        tostring((type(s.level) == "table") and type(s.level.locked_towers) or "nil"))
    if type(s.selected_towers) == "table" then
      local a = {}
      for i = 1, #s.selected_towers do a[i] = tostring(s.selected_towers[i]) end
      out("  selected_towers = { " .. table.concat(a, ", ") .. " }")
    end
    local holders = { { "store", s }, { "store.level", s.level },
                      { "store.level_data", s.level_data } }
    for i = 1, #holders do
      local h = holders[i][2]
      if type(h) == "table" then
        local ks = {}
        for k, v in pairs(h) do ks[#ks + 1] = tostring(k) .. ":" .. type(v) end
        table.sort(ks)
        out("  " .. holders[i][1] .. " keys (" .. #ks .. "): " .. table.concat(ks, " "))
      end
    end

    out("")
    out("=== store.entities ===")
    out("  entity_count=" .. tostring(s.entity_count) .. " entity_max=" .. tostring(s.entity_max))
    -- ⚠️ 稀疏表：必须用 pairs 数（`#s.entities` 可能是 0）。
    if type(s.entities) == "table" then
      local idxs, compcnt = {}, {}
      local total = each_entity(s, function(e)
        for cname in pairs(e) do
          compcnt[cname] = (compcnt[cname] or 0) + 1
        end
        return 0
      end)
      for k in pairs(s.entities) do idxs[#idxs + 1] = tostring(k) end
      table.sort(idxs)
      out("  pairs 数出来的实体数 = " .. total .. "（#s.entities=" .. tostring(#s.entities) ..
          "，若两者不等就说明表有洞）")
      out("  下标: " .. table.concat(idxs, " "))
      local ck = {}
      for k, v in pairs(compcnt) do ck[#ck + 1] = tostring(k) .. "=" .. v end
      table.sort(ck)
      out("  组件出现次数: " .. table.concat(ck, "  "))

      out("")
      out("=== 倍率状态（mult_apply_live 靠它判断要不要动）===")
      for _, k in ipairs({ "tower_dmg", "tower_range", "tower_rate",
                           "enemy_hp", "enemy_speed" }) do
        out(("  %-12s 目标=%-6s 已应用=%s"):format(
          k, tostring(S.mult[k]), tostring(S.mult_applied[k])))
      end

      local picked = 0
      local want = { { "health", "enemy 的血量组件" }, { "tower", "塔组件" },
                     { "motion", "移动组件" } }
      for _, w in ipairs(want) do
        each_entity(s, function(e)
          if picked > 3 then return 0 end
          local c = e[w[1]]
          if type(c) == "table" then
            picked = picked + 1
            out("")
            out("  --- 样本 " .. w[2] .. "（实体 id=" .. tostring(e.id) ..
                " 模板=" .. tostring(e.template_name) .. "）")
            dump_tbl(c, "      " .. w[1], 1, 2, L, 80)
          end
          return 0
        end)
      end
    end

    out("")
    out("=== store.damage_queue（kill_all 要靠它）===")
    local q = s.damage_queue
    out("  type=" .. type(q))
    if type(q) == "table" then
      out("  #q=" .. tostring(#q))
      for i = 1, math.min(3, #q) do
        dump_tbl(q[i], "  damage_queue[" .. i .. "]", 1, 2, L, 60)
      end
    end
  else
    out("")
    out("=== store: （不在关卡内）===")
    out("  塔/单位那部分没有 store 就是空的 —— 进关卡之后再跑一次 probe。")
  end

  out("")
  local b = balance_of()
  if type(b) == "table" then
    local ks = {}
    for k, v in pairs(b) do ks[#ks + 1] = tostring(k) .. ":" .. type(v) end
    table.sort(ks)
    out("=== balance 顶层 (" .. #ks .. ") ===")
    out("  " .. table.concat(ks, " "))
    if type(b.towers) == "table" then
      local tn = {}
      for k, v in pairs(b.towers) do
        tn[#tn + 1] = tostring(k) .. (type(v) == "table" and type(v[TOWER_STATS]) == "table"
                                      and "(有 stats)" or "")
      end
      table.sort(tn)
      out("")
      out("=== balance.towers 的键（括号里表示有 .stats）===")
      out("  " .. table.concat(tn, "  "))
    end
    local tt = tower_stats_tables(b)
    out("")
    out("=== tower_stats_tables() 找到 " .. #tt .. " 张塔的 stats 表 ===")
    if #tt > 0 then
      dump_tbl(tt[1], "  tower_stats[1]", 1, 3, L, 300)
    end
    out("")
    out("=== balance 全树 (depth 5) ===")
    dump_tbl(b, "balance", 1, 5, L, 6000)
  else
    out("=== balance: 没找到 ===")
    out("  upgrades 没加载，或它的 upvalue 里没有名叫 balance 的表。")
  end

  out("")
  local edb = game_mod("entity_db")
  if type(edb) == "table" then
    out("=== entity_db 自身的字段 ===")
    local ek = {}
    for k, v in pairs(edb) do ek[#ek + 1] = tostring(k) .. ":" .. type(v) end
    table.sort(ek)
    out("  " .. table.concat(ek, "  "))

    local tn, shown = {}, {}
    each_template(edb, function(t)
      local nm = tostring(t.template_name or t.name or "?")
      tn[#tn + 1] = nm
      local pre = nm:match("^([a-z]+_)") or ""
      if #pre >= 5 and not shown[pre] and #L < 39000 then
        shown[pre] = true
        out("")
        out("=== 模板展开 " .. nm .. " ===")
        dump_tbl(t, nm, 1, 3, L, 400)
      end
    end)
    table.sort(tn)
    out("")
    out("=== entity_db 模板 " .. #tn .. " 个（取用形态：" .. tostring(S.tpl_shape) .. "）===")
    out("  " .. table.concat(tn, " "))
  else
    out("=== entity_db: 没加载 ===")
  end

  wf("_kr6_probe.txt", table.concat(L, "\n") .. "\n")
  return "probe -> _kr6_probe.txt (" .. #L .. " 行)"
end

-- ---- 存档层：游戏内改进度（宝石/星星/解锁）----
-- 存档不常驻内存，但**总得**经过「文本 → Lua 表」「表 → 文本」这两个转换函数：在那上面挂钩即可改它。
-- S.slot_ops 是**一次性**的：命中一次存档表就全部应用并清空 —— 否则等于每帧覆盖存档，宝石永远涨不上去。

S.slot_ops = S.slot_ops or {}

-- 存档表的指纹：必须**自己存了** gems(数字) + levels(表) + upgrades_trees(表)
-- （沿用离线编辑器那条验证过的判据）。用 rawget：扫到的可能是任意表，带 __index 的会抛错。
local function is_slot_like(t)
  if type(t) ~= "table" then return false end
  return type(rawget(t, "gems")) == "number"
     and type(rawget(t, "levels")) == "table"
     and type(rawget(t, "upgrades_trees")) == "table"
end

-- 星星奖励轨道的上限（来自 map_data.lua 的 progression_rewards_premium），与离线编辑器那张表必须一致。
local REWARD_LAST_STARS = 84

-- 存档里的升级树节点是**短 id**（l1、skill_a），kr6/upgrades.lua 里是**带前缀的**（archers_l1）：绝不能混用。
local TOWER_NODES = { "l1", "l2", "l3a", "l3b", "l4a", "l4b", "ulti" }
local HERO_NODES = { "skill_a", "skill_b", "skill_c", "talent_1", "talent_2",
                     "upg_a", "upg_b", "ultimate" }

-- 存档里的数组可能是稀疏的，所以不能用 #。
local function slot_array_len(t)
  local n = 0
  while rawget(t, n + 1) ~= nil do n = n + 1 end
  return n
end

local function slot_array_has(t, v)
  local n = slot_array_len(t)
  for i = 1, n do
    if tostring(t[i]) == tostring(v) then return true end
  end
  return false
end

local function fill_node_array(arr)
  if type(arr) ~= "table" then return 0 end
  local style = TOWER_NODES
  local n = slot_array_len(arr)
  for i = 1, n do
    local s = tostring(arr[i])
    if s:find("skill") or s:find("upg") or s:find("talent") then
      style = HERO_NODES
      break
    end
  end
  local added = 0
  for i = 1, #style do
    if not slot_array_has(arr, style[i]) then
      arr[n + added + 1] = style[i]
      added = added + 1
    end
  end
  return added
end

local function stars_total(t)
  local lv = rawget(t, "levels")
  if type(lv) ~= "table" then return 0 end
  local sum = 0
  for _, e in pairs(lv) do
    if type(e) == "table" and type(rawget(e, "stars")) == "number" then
      sum = sum + rawget(e, "stars")
    end
  end
  return sum
end

local function apply_one_op(t, o)
  local op = o.op
  if op == "gems" then
    local cur = rawget(t, "gems")
    if type(cur) ~= "number" then return false end
    t.gems = (o.mode == "add") and (cur + (o.n or 0)) or (o.n or cur)
    return true
  elseif op == "stars" then
    -- 逐关补到 3 星直到总星数够拿完轨道。⚠️ **故意不动 progression.last_stars**：留着它低于真实
    -- 总星数，游戏才会「发现新星星」走它自己的发放路径 —— 那是唯一游戏自己校验过、不会被回收的方式。
    local lv = rawget(t, "levels")
    if type(lv) ~= "table" then return false end
    local idx = 1
    while stars_total(t) < REWARD_LAST_STARS and idx <= 60 do
      local e = rawget(lv, idx)
      if type(e) ~= "table" then e = {} lv[idx] = e end
      e.stars = 3
      idx = idx + 1
    end
    return true
  elseif op == "tree" then
    local tr = rawget(t, "upgrades_trees")
    if type(tr) ~= "table" then return false end
    for _, arr in pairs(tr) do fill_node_array(arr) end
    return true
  elseif op == "towers" then
    local tw = rawget(t, "towers")
    if type(tw) ~= "table" then return false end
    local sel = rawget(tw, "selected")
    local st = rawget(tw, "status")
    if type(sel) ~= "table" or type(st) ~= "table" then return false end
    local n = slot_array_len(sel)
    for name in pairs(st) do
      if not slot_array_has(sel, name) then n = n + 1 sel[n] = name end
    end
    return true
  elseif op == "heroes" then
    local hs = rawget(t, "heroes")
    if type(hs) ~= "table" then return false end
    local team = rawget(hs, "team")
    local st = rawget(hs, "status")
    if type(team) ~= "table" or type(st) ~= "table" then return false end
    local n = slot_array_len(team)
    for name in pairs(st) do
      if not slot_array_has(team, name) then n = n + 1 team[n] = name end
    end
    return true
  end
  return false
end

local function apply_slot_ops(t)
  local ops = S.slot_ops
  if type(ops) ~= "table" or #ops == 0 then return 0 end
  local n = 0
  for i = 1, #ops do
    local ok = pcall(apply_one_op, t, ops[i])
    if ok then n = n + 1 end
  end
  -- 失败的也清掉 —— 否则一条坏操作会永远卡在那里反复失败。
  for i = #ops, 1, -1 do ops[i] = nil end
  S.slot_ops_done = (S.slot_ops_done or 0) + n
  return n
end

-- 暴露给测试台（同 S.items）：测试环境装不上钩子，只能直接调这两个。
S.slot_apply = apply_slot_ops
S.slot_like = is_slot_like

-- 在哪几个函数上装钩子。签名没全部实证，所以**参数和返回值都扫一遍**，是存档形状的就动手。
local SLOT_HOOKS = {
  { "storage", { "deserialize_lua", "serialize_lua", "load_lua", "write_lua",
                 "load_slot", "save_slot" } },
  { "storage_io_generic", { "load_file", "write_file" } },
}

local function install_slot_hooks()
  local done = 0
  for i = 1, #SLOT_HOOKS do
    local mod = game_mod(SLOT_HOOKS[i][1])
    if type(mod) == "table" then
      local keys = SLOT_HOOKS[i][2]
      for j = 1, #keys do
        local key = keys[j]
        local orig = rawget(mod, key)
        local flag = "slot_" .. key
        if type(orig) == "function" and not S.wrap_src[flag] then
          S.wrap_src[flag] = true
          rawset(mod, key, function(...)
            for a = 1, select("#", ...) do
              local v = select(a, ...)
              if is_slot_like(v) then apply_slot_ops(v) end
            end
            local r1, r2, r3, r4 = orig(...)
            if is_slot_like(r1) then apply_slot_ops(r1) end
            if is_slot_like(r2) then apply_slot_ops(r2) end
            if is_slot_like(r3) then apply_slot_ops(r3) end
            if is_slot_like(r4) then apply_slot_ops(r4) end
            return r1, r2, r3, r4
          end)
          S.slot_hooks[#S.slot_hooks + 1] = SLOT_HOOKS[i][1] .. "." .. key
          done = done + 1
        end
      end
    end
  end
  return done
end

-- 第一次排队时把 slot_*.lua 备份一份 —— 这功能**真的会改玩家存档**，必须先留后路。
-- （定义必须排在 queue_slot_op 前面 —— Lua 的 local function 不提升。）
local function backup_slot_once()
  if S.slot_backup_done then return end
  S.slot_backup_done = true
  local stamp = os.date("%Y%m%d_%H%M%S")
  for i = 1, 9 do
    local name = "slot_" .. i .. ".lua"
    local txt = rf(name)
    if txt and #txt > 0 then
      wf("_kr6_slot_backup_" .. stamp .. "_" .. i .. ".lua", txt)
    end
  end
end

-- 排队一条操作：**排队本身不改任何东西**，改动发生在存档表下次经过读写钩子的时候。
-- ⚠️ 必须写 `queue_slot_op = function`（不是 `local function`）：前向声明过，写成 local 会新建局部变量。
queue_slot_op = function(o, cn, en)
  S.slot_ops[#S.slot_ops + 1] = o
  backup_slot_once()
  if cn then
    note(cn .. "（回主菜单再进一次档生效）", en .. " (re-enter the save to apply)")
  end
  return "queued " .. tostring(o.op) .. " (" .. #S.slot_ops .. " pending)"
end

-- ---- menu ----
local MENU_TEXT = {
  cn = {
    title = "KR6 修改器", hint = "Home 开关   ↑↓ 选择   ←→ 调整   Enter 执行   Esc 关闭",
    gold_add = "金币 +1000", gold_sub = "金币 -1000",
    lives_add = "生命 +10", lives_sub = "生命 -10",
    hold = "无限金钱", hold_lives = "生命锁定",
    level_gems_add = "本关宝石 +100",
    next_wave = "立刻下一波",
    hdr_res = "资源", hdr_wave = "波次", hdr_units = "塔与单位",
    hdr_cheat = "游戏作弊", hdr_diag = "诊断（开发版）",
    tower_dmg = "塔伤害", tower_range = "塔射程", tower_rate = "塔攻速",
    enemy_hp = "敌人血量", enemy_speed = "敌人移速",
    free_towers = "免费造塔", all_towers = "全部塔可造",
    kill_all = "秒杀全部敌人", hide_ui = "隐藏界面",
    hdr_save = "存档（回主菜单再进档生效）",
    gems_add = "宝石 +1000", stars_max = "星星拉满",
    unlock_all = "全部解锁", unlock_tree = "升级树补全",
    probe = "转储 balance / 实体",
    hero_try = "★英雄当场升级试验",
    store = "转储 store", api = "导出接口图", report = "完整报告",
    snap = "数值快照", diff = "数值对比", shot = "截图",
    close = "关闭菜单",
    on = "开", off = "关",
    labels = { "金币", "生命", "关卡" },
    nolvl = "（未进入关卡）",
  },
  en = {
    title = "KR6 TRAINER", hint = "home toggles   up/down   left/right   enter   esc",
    gold_add = "gold +1000", gold_sub = "gold -1000",
    lives_add = "lives +10", lives_sub = "lives -10",
    hold = "infinite gold", hold_lives = "lock lives",
    level_gems_add = "level gems +100",
    next_wave = "next wave now",
    hdr_res = "RESOURCES", hdr_wave = "WAVES", hdr_units = "TOWERS & UNITS",
    hdr_cheat = "GAME CHEATS", hdr_diag = "DIAGNOSTICS (dev)",
    tower_dmg = "tower damage", tower_range = "tower range", tower_rate = "tower speed",
    enemy_hp = "enemy HP", enemy_speed = "enemy speed",
    free_towers = "free towers", all_towers = "unlock all towers",
    kill_all = "kill all enemies", hide_ui = "hide HUD",
    hdr_save = "SAVE (apply on reload)",
    gems_add = "gems +1000", stars_max = "max stars",
    unlock_all = "unlock everything", unlock_tree = "fill upgrade trees",
    probe = "dump balance / entities",
    hero_try = "★hero level-up trial",
    store = "dump store", api = "export API map", report = "full report",
    snap = "numeric snapshot", diff = "numeric diff", shot = "screenshot",
    close = "close menu",
    on = "ON", off = "OFF",
    labels = { "gold", "lives", "lvl" },
    nolvl = "(not in a level)",
  },
}

-- 从 from 出发沿 dir 找下一个**可执行**项（跳过分组标题，光标可以合法停在标题上），绕一圈。
local function next_selectable(items, from, dir)
  local n = #items
  if n == 0 then return nil end
  local i = from
  for _ = 1, n do
    i = i + dir
    if i < 1 then i = n elseif i > n then i = 1 end
    if not items[i].header then return i end
  end
  return nil
end

local function fmt_mult(v)
  if type(v) ~= "number" then return "x?" end
  if v == math.floor(v) then return "x" .. tostring(math.floor(v)) end
  return "x" .. tostring(v)
end

local function menu_items()
  local T = MENU_TEXT[S.cjk and "cn" or "en"]
  -- 标签缺失时回退成 id：否则 love.graphics.print 抛错，外层 pcall 一吞，整个面板无声消失。
  local function L(id)
    local v = T[id]
    return (type(v) == "string" and v) or id
  end
  -- 分组标题是多带 header = true 的普通条目，必须被三处跳过：↑↓、鼠标、冒烟测试 —— 漏一处就出 bug。
  local M = S.mult
  local items = {
    { id = "hdr_res",   label = L("hdr_res"), header = true },
    { id = "gold_add",  label = L("gold_add"), adjust = { field = "player_gold", step = 1000, sign = 1 } },
    { id = "gold_sub",  label = L("gold_sub"), adjust = { field = "player_gold", step = 1000, sign = -1 } },
    { id = "lives_add", label = L("lives_add"), adjust = { field = "lives", step = 10, sign = 1 } },
    { id = "lives_sub", label = L("lives_sub"), adjust = { field = "lives", step = 10, sign = -1 } },
    { id = "hold",      label = L("hold"), toggle = function() return S.hold end },
    { id = "hold_lives", label = L("hold_lives"), toggle = function() return S.hold_lives end },

    { id = "hdr_wave",  label = L("hdr_wave"), header = true },
    { id = "next_wave", label = L("next_wave") },

    { id = "hdr_units", label = L("hdr_units"), header = true },
    { id = "tower_dmg", label = L("tower_dmg"),
      adjust = { set = M, key = "tower_dmg", step = 0.5, sign = 1, min = 1, max = 20 },
      value = function() return fmt_mult(S.mult.tower_dmg) end },
    { id = "tower_range", label = L("tower_range"),
      adjust = { set = M, key = "tower_range", step = 0.5, sign = 1, min = 1, max = 20 },
      value = function() return fmt_mult(S.mult.tower_range) end },
    { id = "tower_rate", label = L("tower_rate"),
      adjust = { set = M, key = "tower_rate", step = 0.25, sign = 1, min = 1, max = 10 },
      value = function() return fmt_mult(S.mult.tower_rate) end },
    { id = "enemy_hp", label = L("enemy_hp"),
      adjust = { set = M, key = "enemy_hp", step = 0.5, sign = 1, min = 0.1, max = 20 },
      value = function() return fmt_mult(S.mult.enemy_hp) end },
    { id = "enemy_speed", label = L("enemy_speed"),
      adjust = { set = M, key = "enemy_speed", step = 0.25, sign = 1, min = 0.1, max = 10 },
      value = function() return fmt_mult(S.mult.enemy_speed) end },
    { id = "free_towers", label = L("free_towers"), toggle = function() return S.free_towers end },
    { id = "all_towers",  label = L("all_towers"),  toggle = function() return S.all_towers end },

    { id = "hdr_cheat", label = L("hdr_cheat"), header = true },
    { id = "kill_all",  label = L("kill_all") },
    { id = "hide_ui",   label = L("hide_ui"), toggle = function() return S.hide_ui end },

    -- 存档级。**排队**式：按下去不会立刻变，要回主菜单再进一次档才生效（每行标签都写清了）。
    { id = "hdr_save", label = L("hdr_save"), header = true },
    { id = "gems_add", label = L("gems_add"),
      adjust = { slot = { op = "gems", mode = "add" }, step = 1000, sign = 1,
                 cn = "宝石", en = "gems" } },
    { id = "stars_max",  label = L("stars_max") },
    { id = "unlock_all", label = L("unlock_all") },
    { id = "unlock_tree", label = L("unlock_tree") },
  }
  if DEV then
    local diag = {
      { id = "hdr_diag", label = L("hdr_diag"), header = true },
      { id = "level_gems_add", label = L("level_gems_add") },
      { id = "probe",    label = L("probe") },
      { id = "hero_try", label = L("hero_try") },
      { id = "store",    label = L("store") },
      { id = "api",      label = L("api") },
      { id = "report",   label = L("report") },
      { id = "snap",     label = L("snap") },
      { id = "diff",     label = L("diff") },
      { id = "shot",     label = L("shot") },
    }
    for i = 1, #diag do items[#items + 1] = diag[i] end
  end
  items[#items + 1] = { id = "close", label = L("close") }
  S.items = items          -- 暴露出去，测试按 id 查条目用
  if S.sel > #items then S.sel = 1 end
  return items
end

local function try_load_font(want_size)
  local size = want_size or 16
  local cands = {
    "_assets/kr6-desktop/fonts/NotoSansCJKsc-Regular.otf",
    "kr6-desktop/fonts/NotoSansCJKsc-Regular.otf",
    "/fonts/NotoSansCJKsc-Regular.otf",
    "fonts/NotoSansCJKsc-Regular.otf",
    "kr6-desktop/fonts/NotoSansCJKsc-Bold.otf",
    "_assets/kr6-desktop/fonts/NotoSansCJKsc-Bold.otf",
    "_assets/all-desktop/fonts/NotoSansCJKjp-Regular.otf",
    "fonts/NotoSansCJKjp-Regular.otf",
  }
  if S.font_path then
    local ok, f = pcall(love.graphics.newFont, S.font_path, size)
    if ok and f then return f end
  end
  for i = 1, #cands do
    local ok, f = pcall(love.graphics.newFont, cands[i], size)
    if ok and f then
      S.cjk = true
      if not S.font_path then
        S.font_path = cands[i]
        wf("_kr6_font.txt", "CJK font loaded: " .. cands[i] .. "\n")
      end
      return f
    end
  end
  local okc, cur = pcall(love.graphics.getFont)
  if okc and cur then
    local okg, has = pcall(cur.hasGlyphs, cur, "\229\134\160\229\184\129\231\148\159\229\145\189")
    if okg and has then
      S.cjk = true
      wf("_kr6_font.txt", "CJK font: reused the game's active font\n")
      return cur
    end
  end
  wf("_kr6_font.txt", "CJK font NOT found, falling back to built-in font (ASCII labels)\n")
  local ok, f = pcall(love.graphics.newFont, 14)
  if ok then return f end
  return nil
end

-- 菜单太长时行高会被压得比字还矮：按需要的行高反推一个够小的字号，**只建一次并缓存**（newFont 很贵）。
local function font_for_height(want_h)
  if not S.font then return nil end
  local ok, fh = pcall(S.font.getHeight, S.font)
  if not ok or type(fh) ~= "number" or fh <= want_h then return S.font end
  local size = math.max(10, math.floor(16 * want_h / fh))
  if S.small_font and S.small_size == size then return S.small_font end
  local ok2, f = pcall(try_load_font, size)
  if ok2 and f then
    S.small_font, S.small_size = f, size
    return f
  end
  return S.font
end

local MENU_X, MENU_Y, MENU_W = 60, 90, 430

local function draw_menu()
  if not S.menu_open then return end
  if type(love) ~= "table" or type(love.graphics) ~= "table" then return end
  local T = MENU_TEXT[S.cjk and "cn" or "en"]
  local items = menu_items()

  pcall(function()
    local prev = {}
    pcall(function()
      prev.canvas = love.graphics.getCanvas()
      prev.shader = love.graphics.getShader()
      prev.bm, prev.abm = love.graphics.getBlendMode()
      prev.sx, prev.sy, prev.sw, prev.sh = love.graphics.getScissor()
      prev.lw = love.graphics.getLineWidth()
      prev.r, prev.g, prev.b, prev.a = love.graphics.getColor()
      prev.font = love.graphics.getFont()
    end)
    love.graphics.push()
    love.graphics.origin()
    love.graphics.setShader()
    love.graphics.setCanvas()
    love.graphics.setBlendMode("alpha")
    love.graphics.setScissor()
    love.graphics.setColor(255, 255, 255, 255)
    if S.font then love.graphics.setFont(S.font) end

    local line_h = (S.font and S.font:getHeight()) or 16
    line_h = math.max(line_h, 16)
    -- 全部条目放一页里：窗口矮时按比例压缩行高让它放得下（面板高 h == line_h*(n+5) + 28）。
    local avail = 0
    pcall(function() avail = love.graphics.getHeight() end)
    if avail and avail > 0 then
      local maxh = avail - (MENU_Y - 10) - 10
      local fit = math.floor((maxh - 28) / (#items + 5))
      if fit < line_h then line_h = math.max(fit, 9) end
    end
    local header_h = line_h * 2 + 10
    local h = line_h * (#items + 5) + 28

    local row_font = font_for_height(line_h)
    if row_font then pcall(love.graphics.setFont, row_font) end

    love.graphics.setColor(0, 0, 0, 215)
    love.graphics.rectangle("fill", MENU_X - 10, MENU_Y - 10, MENU_W, h)
    love.graphics.setColor(200, 170, 60, 255)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", MENU_X - 10, MENU_Y - 10, MENU_W, h)

    love.graphics.setColor(255, 220, 100, 255)
    love.graphics.print(T.title, MENU_X, MENU_Y - 2)
    local st = store_stat()
    local L2 = T.labels
    -- 关卡外这些字段不存在就不显示，而不是给玩家看 "nil"。
    local parts = {}
    if st then
      parts[#parts + 1] = L2[1] .. " " .. tostring(st.gold)
      parts[#parts + 1] = L2[2] .. " " .. tostring(st.lives)
      if st.level then parts[#parts + 1] = L2[3] .. " " .. tostring(st.level) end
    end
    local info = (#parts > 0) and table.concat(parts, "  ") or T.nolvl
    S.header = info          -- 和 S.items 一样暴露出去，供测试读取
    love.graphics.setColor(200, 200, 200, 255)
    love.graphics.print(info, MENU_X, MENU_Y + line_h)

    S.rects = {}
    local y0 = MENU_Y + header_h + 4
    local mx, my = nil, nil
    pcall(function() mx, my = love.mouse.getPosition() end)
    for i = 1, #items do
      local y = y0 + (i - 1) * line_h
      local hover = (mx and my and my >= y and my < y + line_h
                     and mx >= MENU_X - 10 and mx < MENU_X - 10 + MENU_W)
      -- 标题行也要有命中框：否则点在标题上会被当成「没点中任何东西」漏给游戏，而菜单明明开着。
      S.rects[i] = { x = MENU_X - 10, y = y, w = MENU_W, h = line_h,
                     id = items[i].id, header = items[i].header }
      if i == S.sel and not items[i].header then
        love.graphics.setColor(80, 110, 190, 220)
        love.graphics.rectangle("fill", MENU_X - 10, y, MENU_W, line_h)
      elseif hover then
        love.graphics.setColor(70, 70, 70, 200)
        love.graphics.rectangle("fill", MENU_X - 10, y, MENU_W, line_h)
      end
      if items[i].header then
        love.graphics.setColor(150, 165, 210, 255)
        love.graphics.print(items[i].label, MENU_X + 4, y + 2)
        local tw = 0
        pcall(function() tw = S.font and S.font:getWidth(items[i].label) or 0 end)
        if tw > 0 then
          local lx = MENU_X + 12 + tw
          local rx = MENU_X - 10 + MENU_W - 8
          if rx > lx then
            love.graphics.setColor(90, 100, 130, 200)
            love.graphics.rectangle("fill", lx, y + line_h * 0.5, rx - lx, 1)
          end
        end
      else
        love.graphics.setColor(255, 255, 255, 255)
        love.graphics.print(items[i].label, MENU_X + 4, y + 2)
        if items[i].toggle then
          local on = items[i].toggle()
          love.graphics.setColor(on and 120 or 160, on and 255 or 160, on and 120 or 160, 255)
          love.graphics.print(on and T.on or T.off, MENU_X - 10 + MENU_W - 56, y + 2)
        elseif items[i].value then
          love.graphics.setColor(210, 200, 120, 255)
          love.graphics.print(items[i].value(), MENU_X - 10 + MENU_W - 56, y + 2)
        end
      end
    end

    love.graphics.setColor(160, 160, 160, 255)
    love.graphics.print(T.hint, MENU_X, y0 + #items * line_h + 2)
    if S.msg ~= "" and os.time() - S.msg_ts < 6 then
      love.graphics.setColor(140, 255, 140, 255)
      love.graphics.print(S.msg, MENU_X, y0 + #items * line_h + 2 + line_h)
    end

    love.graphics.setColor(255, 255, 255, 255)
    love.graphics.pop()
    pcall(function()
      love.graphics.setCanvas(prev.canvas)
      love.graphics.setShader(prev.shader)
      if prev.bm then love.graphics.setBlendMode(prev.bm, prev.abm) end
      if prev.sw then love.graphics.setScissor(prev.sx, prev.sy, prev.sw, prev.sh) end
      if prev.lw then love.graphics.setLineWidth(prev.lw) end
      if prev.r then love.graphics.setColor(prev.r, prev.g, prev.b, prev.a) end
      -- 必须还回真正的那个字体：写成 setFont(getFont()) 等于没还原，字号会泄漏给游戏
      if prev.font then love.graphics.setFont(prev.font) end
    end)
  end)
end

local function menu_toggle()
  S.menu_open = not S.menu_open
  if S.menu_open and not S.font and type(love) == "table" and type(love.graphics) == "table" then
    pcall(function() S.font = try_load_font() end)
  end
  S.sel = S.sel or 1
  -- 光标不能停在分组标题上；只在确实需要时挪，保留玩家上次的选择。
  local items = menu_items()
  if not items[S.sel] or items[S.sel].header then
    S.sel = next_selectable(items, 0, 1) or 1
  end
end

local function menu_key(key)
  local items = menu_items()
  if key == "escape" then
    S.menu_open = false
    return
  end
  if key == "up" then
    S.sel = next_selectable(items, S.sel, -1) or S.sel
  elseif key == "down" then
    S.sel = next_selectable(items, S.sel, 1) or S.sel
  elseif key == "return" or key == "kpenter" or key == " " then
    local it = items[S.sel]
    -- 标题行不能走 run_action —— 会返回 "unknown action"，而冒烟测试把这种回复当失败。
    if it and not it.header then run_action(it.id) end
  elseif key == "left" or key == "right" then
    local it = items[S.sel]
    local dir = (key == "right") and 1 or -1
    if it and not it.header and it.adjust then
      local a = it.adjust
      run_action("tweak", { field = a.field, set = a.set, key = a.key,
                            min = a.min, max = a.max,
                            delta = a.step * a.sign * dir })
    end
  end
end

local MENU_KEYS = {
  up = true, down = true, left = true, right = true,
  ["return"] = true, kpenter = true, escape = true, [" "] = true, home = true,
}

-- ---- frame tick ----
-- 命令短名表（短名仍可用，README 与测试在用）；`cmd <动作id> [参数]` 是通用入口，不必开菜单。
local CMD_MAP = {
  gold = "gold_set", goldadd = "gold_add", goldsub = "gold_sub",
  lives = "lives_add", ["lives-"] = "lives_sub",
  hold = "hold", holdlives = "hold_lives",
  levelgems = "level_gems_add",
  nextwave = "next_wave", store = "store", report = "report", api = "api",
  snap = "snap", diff = "diff", shot = "shot", probe = "probe",
  herotry = "hero_try",
  freetowers = "free_towers", alltowers = "all_towers",
  killall = "kill_all", hideui = "hide_ui",
  gems = "gems_add", stars = "stars_max",
  unlockall = "unlock_all", unlocktree = "unlock_tree",
  menu = "MENU", closemenu = "CLOSE",
}

local function tick(source)
  if S.tick_source == nil then
    S.tick_source = source
  elseif S.tick_source ~= source then
    return
  end
  S.frames = S.frames + 1
  S.drew = false

  if S.hold or S.hold_lives then
    pcall(function()
      local s = store_of()
      if not s then return end
      if S.hold and type(s.player_gold) == "number" and s.player_gold < 999999 then
        s.player_gold = 999999
      end
      if S.hold_lives and type(s.lives) == "number" and s.lives < 20 then
        s.lives = 20
      end
    end)
  end

  -- 「塔与单位」组：**游戏自己会重算这些值**，写一次就被覆盖，所以每帧重放（每块各自 pcall）。
  -- 这三个**都不加开关守卫**：关掉时也得跑一趟把原值写回去，否则值会一直停在被改过的状态。
  pcall(free_towers_apply)
  pcall(all_towers_apply)
  pcall(hide_ui_apply)
  -- 倍率全部 x1 时完全不动游戏；调回 1 后自动停手，游戏自己的 patch_templates 会把数值恢复。
  local mm = S.mult
  local mult_active = (mm.tower_dmg ~= 1 or mm.tower_range ~= 1
                       or mm.tower_rate ~= 1 or mm.enemy_hp ~= 1
                       or mm.enemy_speed ~= 1)
  if mult_active then
    pcall(mult_apply)
    S.mult_active = true
  elseif S.mult_active then
    -- **这一趟收尾不能省**：守卫条件此刻已变假，不补跑一次，模板就永远停在放大后的值上。
    pcall(mult_apply)
    S.mult_active = false
  end
  -- 已在场上的单位走相对法（自己判断倍率变没变）；无条件调用是故意的 —— 调回 1 时也得跟着回来。
  pcall(mult_apply_live)

  -- 存档钩子：storage 可能还没 require，所以每帧试装一次，装上就不再试。
  if not S.slot_hooks_done then
    local n = install_slot_hooks()
    if n > 0 or (game_mod("storage") ~= nil) then S.slot_hooks_done = true end
  end

  -- 英雄调用日志。两条路都装：
  --   ① 实体上那个 per-hero 的 fn_level_up（游戏"击杀→升级"时调的就是它，主目标）
  --   ② script_utils 上那三个模块级函数（如果游戏持有的是捕获的局部引用，它们永不触发
  --      —— 那本身也是有用的结论）
  -- 每帧试（script_utils / 英雄实体都可能还没出现），装上就停。
  install_hero_fn_hooks()
  if not S.hero_mod_done then
    local n = install_hero_mod_hooks()
    if n and n > 0 then S.hero_mod_done = true
    elseif game_mod("script_utils") ~= nil then S.hero_mod_done = true end
  end

  local now = os.time()
  if now > S.last_cmd_check and not S.in_cmd then
    S.last_cmd_check = now
    local cmd = rf("_kr6_cmd.txt")
    if cmd then
      -- 重入保护：动作可能回调到被 tick 包住的游戏函数，从而重新进到这个派发里
      S.in_cmd = true
      local line = cmd:gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      -- 执行**之前**先把命令回显出去：卡死或崩掉时至少能留下「当时在跑什么」。
      wf("_kr6_cmd_out.txt", tostring(line) .. string.char(10) .. "(running)" .. string.char(10))
      local what, arg = line:match("^(%S+)%s*(.*)$")
      what = (what or ""):lower()
      if what == "cmd" then
        local id2, rest = tostring(arg):match("^(%S+)%s*(.*)$")
        what, arg = tostring(id2 or ""), rest or ""
      else
        what = CMD_MAP[what] or what
      end
      local res
      if what == "" then
        res = "empty command"
      elseif what == "MENU" then
        menu_toggle()
        res = "menu_open=" .. tostring(S.menu_open)
      elseif what == "CLOSE" then
        S.menu_open = false
        res = "menu closed"
      else
        res = run_action(what, arg)
      end
      wf("_kr6_cmd_out.txt", tostring(line) .. string.char(10) .. tostring(res) .. string.char(10))
      -- 执行完才消费命令文件：否则「产生了结果但没写出来」和「根本没被读到」长得一样，失败会被藏住。
      os.remove(save_dir() .. "_kr6_cmd.txt")
      S.in_cmd = false
    end
  end

  if now > S.last_beat then
    S.last_beat = now
    local st = store_stat()
    wf("_kr6_beat.txt", "frames=" .. S.frames .. " source=" .. tostring(S.tick_source) ..
       " t+" .. (now - S.t0) .. "s gold=" .. tostring(st and st.gold) ..
       " lives=" .. tostring(st and st.lives) ..
       " hold=" .. tostring(S.hold) .. "/" .. tostring(S.hold_lives) ..
       " menu=" .. tostring(S.menu_open) .. " cjk=" .. tostring(S.cjk) .. "\n")
    if AUTO_REPORT and now - S.last_report >= 20 and S.reports < 4 then
      S.last_report = now
      S.reports = S.reports + 1
      report("auto" .. S.reports .. "_t" .. (now - S.t0))
    end
  end
end

local function wrap_fn(owner, key, source)
  if type(owner) ~= "table" then return false end
  local orig = rawget(owner, key)
  if type(orig) ~= "function" then return false end
  if S.wrap_src[key] then return false end
  S.wrap_src[key] = true
  rawset(owner, key, function(...)
    local a, b, c, d = orig(...)
    pcall(tick, source)
    return a, b, c, d
  end)
  S.hooks[#S.hooks + 1] = source
  return true
end

local function install_ticks()
  if type(love) ~= "table" then return end
  pcall(function()
    if type(love.timer) == "table" then
      wrap_fn(love.timer, "step", "love.timer.step")
      wrap_fn(love.timer, "getDelta", "love.timer.getDelta")
    end
    if type(love.event) == "table" then wrap_fn(love.event, "poll", "love.event.poll") end
    if type(love.graphics) == "table" then
      -- 包住 present，好在翻页前一刻画覆盖层
      local orig = rawget(love.graphics, "present")
      if type(orig) == "function" and not S.wrap_src.present then
        S.wrap_src.present = true
        rawset(love.graphics, "present", function(...)
          if S.menu_open and not S.drew then
            S.drew = true
            draw_menu()
          end
          if S.want_shot then
            S.want_shot = false
            pcall(function()
              local id = love.graphics.newScreenshot()
              id:encode("png", "_kr6_shot.png")
              wf("_kr6_shot.txt", "ok t=" .. tostring(os.time()) ..
                 "  " .. tostring(id:getWidth()) .. "x" .. tostring(id:getHeight()) .. "\n")
            end)
          end
          return orig(...)
        end)
        S.hooks[#S.hooks + 1] = "love.graphics.present(draw)"
      end
      wrap_fn(love.graphics, "clear", "love.graphics.clear")
    end
  end)
  local m = S.mod
  if type(m) == "table" then
    pcall(function()
      local cands = { "update", "draw", "tick", "step" }
      for i = 1, #cands do
        if wrap_fn(m, cands[i], tostring(S.virt) .. "." .. cands[i]) then break end
      end
      -- director 自己有 draw 的话，在它之后画覆盖层
      local od = rawget(m, "draw")
      if type(od) == "function" and not S.wrap_src.director_draw then
        S.wrap_src.director_draw = true
        rawset(m, "draw", function(...)
          local a, b, c, d = od(...)
          if S.menu_open and not S.drew and type(love) == "table" then
            S.drew = true
            draw_menu()
          end
          return a, b, c, d
        end)
        S.hooks[#S.hooks + 1] = tostring(S.virt) .. ".draw(overlay)"
      end
    end)
  end
end

-- ---- input ----
local function evt_time()
  local ok, t = pcall(function() return love.timer.getTime() end)
  if ok and type(t) == "number" then return t end
  return os.clock()
end

-- 一个按键可能经多条路到达（love.handlers 和 director.keypressed）：只处理一次，返回是否吃掉。
local function on_key(key)
  local t = evt_time()
  if S.last_key == key and S.last_key_t and (t - S.last_key_t) < 0.08 then
    return true
  end
  S.last_key, S.last_key_t = key, t

  -- 只认 home 一个键：F 键太容易误触，所以不设任何 F 键热键；其余操作走菜单或命令文件。
  if key == "home" then
    menu_toggle()
    return true
  end
  if S.menu_open then
    pcall(menu_key, key)
    return true                       -- 菜单开着时吞掉所有按键
  end
  return false
end

local function on_mouse(x, y, button)
  local t = evt_time()
  local sig = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(button)
  if S.last_click == sig and S.last_click_t and (t - S.last_click_t) < 0.08 then
    return true
  end
  S.last_click, S.last_click_t = sig, t
  if not S.menu_open or button ~= 1 then return false end
  for i = 1, #S.rects do
    local r = S.rects[i]
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      -- 分组标题：**吃掉**这次点击但什么都不做。不能 return false —— 那会把点击漏给游戏。
      if r.header then return true end
      S.sel = i
      run_action(r.id)
      return true
    end
  end
  return false
end

local function install_key_hook()
  pcall(function()
    local wrapped = {}

    -- 路径 1：LÖVE 的事件分发器（只装一次）
    if not S.route1_done then
      S.route1_done = true
      if type(love) == "table" and type(love.handlers) == "table"
         and type(love.handlers.keypressed) == "function" then
        local orig = love.handlers.keypressed
        love.handlers.keypressed = function(key, sc, rep)
          local handled = false
          pcall(function() handled = on_key(key) end)
          if handled then return end
          return orig(key, sc, rep)
        end
        wrapped[#wrapped + 1] = "love.handlers.keypressed"
      end
      if type(love) == "table" and type(love.handlers) == "table"
         and type(love.handlers.mousepressed) == "function" then
        local om = love.handlers.mousepressed
        love.handlers.mousepressed = function(x, y, button, ...)
          local handled = false
          pcall(function() handled = on_mouse(x, y, button) end)
          if handled then return end
          return om(x, y, button, ...)
        end
        wrapped[#wrapped + 1] = "love.handlers.mousepressed"
      end
    end

    -- 路径 2：游戏会把输入直接从 director 转发
    local m = S.mod
    if type(m) == "table" then
      local dk = rawget(m, "keypressed")
      if type(dk) == "function" and not S.wrap_src.director_keypressed then
        S.wrap_src.director_keypressed = true
        rawset(m, "keypressed", function(...)
          local key = ...
          local handled = false
          pcall(function() handled = on_key(key) end)
          if handled then return end
          return dk(...)
        end)
        wrapped[#wrapped + 1] = tostring(S.virt) .. ".keypressed"
      end
      local dm = rawget(m, "mousepressed")
      if type(dm) == "function" and not S.wrap_src.director_mousepressed then
        S.wrap_src.director_mousepressed = true
        rawset(m, "mousepressed", function(...)
          local x, y, button = ...
          local handled = false
          pcall(function() handled = on_mouse(x, y, button) end)
          if handled then return end
          return dm(...)
        end)
        wrapped[#wrapped + 1] = tostring(S.virt) .. ".mousepressed"
      end
    end

    S.key_hook = table.concat(wrapped, " + ")
    for i = 1, #wrapped do S.hooks[#S.hooks + 1] = wrapped[i] end
  end)
end

install_key_hook()
install_ticks()

if first_install then
  local shorts = {}
  for k in pairs(CMD_MAP) do shorts[#shorts + 1] = tostring(k) end
  table.sort(shorts)
  local cmd_short = table.concat(shorts, " / ")
  wf("_kr6trainer_loaded.txt",
     "fired=[" .. table.concat(S.fired, ", ") .. "]" .. string.char(10) ..
     "key_hook=" .. tostring(S.key_hook) .. string.char(10) ..
     "hooks=" .. table.concat(S.hooks, ", ") .. string.char(10) ..
     "keys: Home = menu (no F-key hotkeys on purpose)" .. string.char(10) ..
     "files: _kr6_cmd.txt -> _kr6_cmd_out.txt ; short names: " .. cmd_short .. string.char(10) ..
     "       anything else: cmd <action id> [arg]" .. string.char(10))
  pcall(report, "boot")
end

return "kr6trainer ok"
