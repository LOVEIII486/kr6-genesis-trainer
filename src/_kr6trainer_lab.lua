-- ============================================================================
-- 冻结快照（lab）—— **不是发布版**，构建链不会碰它。
--
-- 这是 2026-09-25「功能全开」的那一版：塔/单位全套倍率、免费造塔、全部塔可造、
-- 秒杀全部敌人、隐藏界面、存档组（宝石/星星/全部解锁/升级树）、
-- 外加一整批开发版诊断（probe / 转储 / 接口图 / 报告 / 快照 / 对比 / 截图）。
--
-- 各项的实机验证状态（这是决定精简版保留什么时唯一可靠的依据）：
--   ✅ 已实测有效：敌人血量、敌人移速、星星拉满、升级树补全
--                （存档侧的证据：slot_1.lua 里 28 关 × 3 星 = 84，
--                  升级树 254 个节点，game 自己把 last_stars 更新成了 84）
--   ⚠️ 未实机验证：塔伤害/射程/攻速、免费造塔、全部塔可造、秒杀全部敌人、
--                隐藏界面、宝石 +1000、全部解锁
--
-- 发布版是从**去掉 _lab 的那个同名文件**出的。这份留着是为了不丢记录。
-- 想继续开发它：复制回 src/_kr6trainer.lua 即可。
-- ============================================================================

-- kr6 游戏内修改器
--
-- 由被顶掉的模块（all/director.lua）加载：它先从 _orig/ 读回游戏自己的原始字节码，
-- 再把模块表交到这里。本文件所有代码都在 pcall 保护下，坏不了游戏。
--
-- 只改**关卡内**数值（存档进度改不了，见 docs/ENGINE_NOTES.md 第 5.6 节，
-- 那部分走离线工具 tools/kr6_slot_edit.py）。
--
-- 关卡状态（store，ECS 单例组件）字段：
--   player_gold, lives, gems_collected, gems_per_wave, force_next_wave, level_name
--
-- 热键：只有 Home 开关菜单 —— 不设任何 F 键，太容易误触。
-- 命令文件：往 _kr6_cmd.txt 写一行，结果写到 _kr6_cmd_out.txt。
--   gold / gold 50000 / goldadd / goldsub / lives / lives- / hold / holdlives /
--   levelgems / nextwave / store / report / api / snap / diff / shot / menu /
--   closemenu / cmd <动作id> [参数]
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

-- 兼容已经注入过的旧版本：_G.__kr6trainer 跨次加载保留，旧 S 里没有本轮新增的
-- 字段。缺什么补什么，否则「塔与单位」那几行会读到 nil。
if type(S.mult) ~= "table" then
  S.mult = {
    tower_dmg = 1, tower_range = 1, tower_rate = 1,
    enemy_hp = 1, enemy_speed = 1,
  }
end
-- 已经"烤进"模板/场上的倍率。活单位走相对更新（见 mult_apply_live），
-- 需要知道上一次应用的是多少才能算出 m1/m0。
if type(S.mult_applied) ~= "table" then
  S.mult_applied = {
    tower_dmg = 1, tower_range = 1, tower_rate = 1,
    enemy_hp = 1, enemy_speed = 1,
  }
end
if type(S.mult_base) ~= "table" then
  -- 弱键：实体/组件表被游戏回收后，它们的基线跟着释放，不会越攒越多。
  -- 为什么需要基线见 scale_table 的注释。
  S.mult_base = setmetatable({}, { __mode = "k" })
end
for _, k in ipairs({ "free_towers", "all_towers", "hide_ui" }) do
  if S[k] == nil then S[k] = false end
end
-- 存档钩子的登记表（装上了哪些）与待应用的存档操作队列
if type(S.slot_hooks) ~= "table" then S.slot_hooks = {} end
if type(S.slot_ops) ~= "table" then S.slot_ops = {} end

-- 开发/发布开关。关掉后诊断项（转储 store / 报告 / 接口图 / 数值快照·对比 /
-- 截图）全部消失 —— 玩家用不上，而且它们会往 Steam 云同步的存档目录里写大文件。
-- tools/make_dist.py 与 install.py --release 会把下面这行改成 false；
-- 改不动时 release_flags() 会报错退出，绝不静默发出带诊断的包。
local DEV = true

-- 每 20 秒往存档目录写一份完整状态报告（约 100-600 KB）。该目录被 Steam 云同步，
-- 所以发布版应该关掉它，只用按需触发的那些命令。
local AUTO_REPORT = DEV

S.fired[#S.fired + 1] = tostring(virt)
if first_install then S.virt = tostring(virt) end
S.mod = (type(mod) == "table") and mod or S.mod

local function note(cn, en)
  S.msg = S.cjk and tostring(cn) or tostring(en or cn)
  S.msg_ts = os.time()
end

-- 静默死掉的诊断比大声报错更糟。实机上 `snap`/`diff`/`api`/`report` 曾一起失效且
-- 毫无痕迹：错误被 tick() 的 pcall 吞了，什么文件都没写。
-- 现在每个被记录的错误都落到 _kr6_err.txt（uninstall.py 早就知道这个文件名，
-- 但在此之前没有任何代码写过它）。
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

--------------------------------------------------------------------- helpers
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

----------------------------------------------------------------- the store
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

------------------------------------------------------------------- actions
-- 只在开发版可用的动作（发布版里连命令通道也调不到）
local DIAG_ACTIONS = {
  store = true, api = true, report = true, snap = true, diff = true,
  shot = true, level_gems_add = true, probe = true,
}

-- 前向声明。action() 会调这几个函数，但它们定义在文件更下面。没有这几行声明，
-- 这些名字在 action 里根本不在作用域内，于是解析成**同名全局变量**（nil），
-- 结果是菜单和命令文件这两条路调用 snap/diff/report/api 全部报
-- "attempt to call global 'snapshot' (a nil value)"；而心跳那条路正常，
-- 因为 tick() 定义在它们后面 —— 这就是当初「有时好使有时不好使」的来源。
local report, snapshot, diff_action, api_sweep
-- 本轮新增的一批同理（定义在文件更下面，紧挨 dump_tbl / foreach_function，
-- 因为要用到它们）。定义处一律写成 `名字 = function() ... end` —— 写成
-- `local function` 会新建一个局部变量，上面这行声明仍然是 nil。
local game_mod, balance_of, scale_table, mult_apply, mult_apply_live,
      free_towers_apply, all_towers_apply, hide_ui_apply, kill_all_enemies,
      probe_dump, queue_slot_op

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
    -- 左右键在可调行上的统一入口。**两种目标走同一个分支**，不要为倍率再写一个
    -- elseif：
    --   arg.field → store 里的 number 字段（金币/生命那种）
    --   arg.set   → 我们自己维护的一张倍率表（S.mult），键是 arg.key。
    --               倍率不在 store 里，所以走不了 add_field。
    if type(arg) ~= "table" or type(arg.delta) ~= "number" or arg.delta == 0 then
      return "FAIL: bad tweak"
    end
    if type(arg.slot) == "table" then
      -- 第三种目标：**排队**一条存档操作。存档不在 store 里，也不能立刻写 ——
      -- 得等它下次经过存档读写钩子（见 queue_slot_op 的注释）。
      local o = arg.slot
      o.n = arg.delta
      return queue_slot_op(o, arg.cn or o.op, arg.en or o.op)
    end
    if type(arg.set) == "table" and arg.key ~= nil then
      local cur = tonumber(arg.set[arg.key]) or 1
      local v = cur + arg.delta
      if arg.min and v < arg.min then v = arg.min end
      if arg.max and v > arg.max then v = arg.max end
      -- 只留两位小数：0.25 反复加减会攒出 1.0000000000000002，
      -- 而那个数字会原样印在行尾给玩家看。
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
    -- 三个「每帧重放」型开关：动作只翻状态，真正的写入在 tick() 里
    -- （free_towers_apply / all_towers_apply / hide_ui_apply）——
    -- 游戏自己会重算这些值，写一次会被覆盖，必须每帧补。
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
    -- 这条**不立刻改任何东西**：存档不在内存里，只能排队，等它下次经过
    -- 存档读写钩子时才应用。见 queue_slot_op。
    local n = tonumber(arg) or 1000
    return queue_slot_op({ op = "gems", n = n, mode = "add" },
                         "宝石 +" .. n, "gems +" .. n)
  elseif id == "stars_max" then
    -- 给星是**主力路径**：游戏自己会按轨道把内容发给你，而且不会被回收。
    return queue_slot_op({ op = "stars" }, "星星拉满", "max stars")
  elseif id == "unlock_all" then
    -- 四条一起排。给星那条是主力（游戏自己发放）；直接塞 selected/team 是补充，
    -- 游戏加载时有归属校验（deselect_unowned_units），可能把不属于你的清掉。
    queue_slot_op({ op = "stars" })
    queue_slot_op({ op = "tree" })
    queue_slot_op({ op = "towers" })
    return queue_slot_op({ op = "heroes" }, "全部解锁", "unlock everything")
  elseif id == "unlock_tree" then
    return queue_slot_op({ op = "tree" }, "升级树补全", "fill upgrade trees")
  elseif id == "tower_dmg" or id == "tower_range" or id == "tower_rate"
         or id == "enemy_hp" or id == "enemy_speed" then
    -- 倍率行靠 ←→ 调，本身没有"执行"语义。但每个菜单项必须能用空参调用一次
    -- （冒烟测试就是这么跑遍全菜单的），所以给它一个**只读**的查询动作 ——
    -- 顺带修掉「在倍率行按 Enter 会返回 unknown action」这个瑕疵。
    -- 故意不做成"按 Enter 重置"：误触不该悄悄改数值。
    local v = S.mult[id]
    local cn = ({ tower_dmg = "塔伤害", tower_range = "塔射程",
                  tower_rate = "塔攻速", enemy_hp = "敌人血量",
                  enemy_speed = "敌人移速" })[id] or id
    note(cn .. " x" .. tostring(v) .. "（←→ 调整）", id .. " = x" .. tostring(v))
    return id .. " = x" .. tostring(v)
  -- 诊断动作只在开发版存在：发布版连命令通道也拿不到它们。
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
  elseif id == "shot" then
    -- this LÖVE build has no love.graphics.captureScreenshot; we grab the
    -- 这个 LÖVE 构建没有 captureScreenshot，改为在帧末自己抓后缓冲
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

------------------------------------------------------------------- reporting
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

-------------------------------------------- 游戏内部：塔 / 单位 / 作弊
-- 本段所有对外可见的函数都在文件上方**前向声明**过（见 :217 那段注释），
-- 定义处一律写 `名字 = function() ... end`；写成 `local function` 会新建局部
-- 变量，声明处仍然是 nil。

-- 从 package.loaded 拿一个游戏模块。**不能用 require** —— payload 是从覆盖桩里
-- 加载的，require 会重入。拿不到返回 nil，由调用方降级。
game_mod = function(name)
  local m = package.loaded[name]
  if type(m) == "table" then return m end
  m = _G[name]                       -- game / director / main 这几个是全局
  if type(m) == "table" then return m end
  return nil
end

-- 依赖缺失时的统一回复。**刻意不含 "FAIL"**：冒烟测试把含 FAIL 的回复算失败，
-- 而这些功能在测试台里本来就跑不了 —— 那里一个游戏模块都不加载。
local function na(what)
  return "n/a: " .. tostring(what)
end

-- balance 表（塔与单位的数值源）**不在 package.loaded 里**：它是数据文件，
-- 由某处 eval 出来后挂在闭包上。已知两条可靠路径是 upgrades 模块里两个函数的
-- upvalue。按**名字**找而不是按下标 —— 下标是反编译猜的，名字是实测的。
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

-- 字段名一律以**实机探针**（probe 动作 → _kr6_probe.txt）为准，不是猜的。
--
-- 敌人：balance.enemies.<组>.<单位> 下面
--   hp    = {80,100,120,250}   ← **按等级分的数组**，不是标量
--   speed = 数字               ← 标量
-- 而活实体上是 health.hp_max（实测 240）。
-- ⚠️ 活体上**绝不能碰当前血量**：hp / health 是战斗中每帧都在变的当前值，
-- 每帧按倍率写回去 = 敌人永远打不死。只缩上限。
local ENEMY_HP_FIELDS    = { hp_max = true }
local ENEMY_HP_ARRAYS    = { hp = true }
local ENEMY_SPEED_FIELDS = { speed = true, speed_limit = true, max_speed = true }

-- 塔：字段在 balance.towers.<名字>.**stats** 下面，不在塔表本身上。
-- 实测：balance.towers.archers.stats = { damage = 2, range = 5.5, cooldown = 9.5 }
local TOWER_STATS = "stats"
local TOWER_FIELDS = {
  tower_dmg   = { damage = true },
  tower_range = { range = true },
  -- 攻速是**反的**：倍率 x2 表示打得更快，冷却要**除** 2。
  -- 调用处传的是 1/mult，这里列的是被缩放的字段本身。
  tower_rate  = { cooldown = true },
}

-- 15 种塔的名字。**来自实机探针的 balance.towers 键名**，不是从字节码符号里猜的 ——
-- 早先按符号写成 "sunray"，而真实键是 "sunray_master"，导致它一直漏掉一种塔。
local TOWER_NAMES = {
  "archers", "knights", "catapult", "wizard", "culverine", "ranger", "sniper",
  "alchemist", "miners", "wildcat", "sunray_master", "crossbows", "tree",
  "forger", "light_priestess",
}

-- 把一个表上属于 fields 的 number 字段缩放到 base*mult，返回改了几个。
--
-- 为什么要自己记基线：游戏自己的 difficulty.patch_templates 是**原地乘**，
-- 调两次就复合（翻倍再翻倍）。我们要的是「每帧幂等重放」——反复调也不能累积。
-- 所以第一次见到某个字段时把原值记进 S.mult_base（弱键表），之后每帧写的都是
-- base*mult：反复乘的永远是同一个基线，不复合。
scale_table = function(t, fields, mult)
  if type(t) ~= "table" then return 0 end
  local base = S.mult_base[t]
  if not base then base = {} S.mult_base[t] = base end
  local n = 0
  for k, v in pairs(t) do
    if fields[k] and type(v) == "number" then
      if base[k] == nil then base[k] = v end
      local want = base[k] * mult
      -- 只写确实不同的：稳定之后这里变成纯读，不搅动游戏的表
      if t[k] ~= want then t[k] = want n = n + 1 end
    end
  end
  return n
end

-- 数组字段的版本。balance 里敌人的血量是**按等级分的数组**
-- （实测 balance.enemies.orcs.orc_shaman.hp = {80,100,120,250}），
-- 逐元素缩放，基线也逐元素记。
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

-- balance.towers.<名字>.stats —— 塔的数值就在这一层（实测：
-- balance.towers.archers.stats = { damage = 2, range = 5.5, cooldown = 9.5 }）。
-- 遍历整个 towers 表而不是按 TOWER_NAMES 点名：`common` / `upgrades` 这类子表
-- 没有 .stats，天然被跳过；游戏将来加塔也不用改这里。
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

-- 遍历 entity_db 里的模板，对每个模板调一次 fn。
--
-- ⚠️ 实测 `filter_templates()` 不带参数会报
--    "./all/entity_db.lua:232: attempt to index local 'self' (a nil value)"
-- 它的第一个参数是 self。但 self 到底该传什么没有实证，所以这里**几种形态都试**，
-- 哪个成了就记进 S.tpl_shape，探针会把它报出来 —— 下一轮就能写死成对的那个。
-- 先试直接取注册表字段：能拿到就完全绕开 filter_templates。
-- 返回**访问到的模板个数**（不是 fn 返回值之和 —— 探针那个回调恒返回 0，
-- 用它判断"找没找到形态"就永远判不出来）。改动量由调用方自己在闭包里累加。
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

-- 每帧重放所有倍率。模板决定**之后**生成的对象，活实体决定**已经在场上**的 ——
-- 两边都要写，因为 entity_db.get_template/create_entity 内部会深拷贝
-- （深拷贝是 entity_db 的局部函数，不是公开 API，所以没法从外面判断拷贝时机，
-- 只能两边都写 + 每帧重放）。
mult_apply = function()
  local m = S.mult
  local dmg, rng = m.tower_dmg, m.tower_range
  -- 攻速取倒数：玩家看到的是"打得更快"，字段是冷却
  local rate = (m.tower_rate and m.tower_rate > 0) and (1 / m.tower_rate) or 1
  local hp, sp = m.enemy_hp, m.enemy_speed
  local n = 0

  -- 1) entity_db 的模板（决定**之后**生成的对象）
  local edb = game_mod("entity_db")
  each_template(edb, function(t)
    local nm = tostring(t.template_name or t.name or "")
    if nm:sub(1, 6) == "enemy_" then
      n = n + scale_table(t, ENEMY_HP_FIELDS, hp)
      n = n + scale_arrays(t, ENEMY_HP_ARRAYS, hp)
      n = n + scale_table(t, ENEMY_SPEED_FIELDS, sp)
    elseif nm:sub(1, 6) == "tower_" then
      -- 塔模板的字段挂在哪一层没有实证，所以本层和 .stats 都试一遍
      local st = (type(t[TOWER_STATS]) == "table") and t[TOWER_STATS] or t
      n = n + scale_table(st, TOWER_FIELDS.tower_dmg, dmg)
      n = n + scale_table(st, TOWER_FIELDS.tower_range, rng)
      n = n + scale_table(st, TOWER_FIELDS.tower_rate, rate)
    end
  end)

  -- 2) balance —— 模板的**源头**。实测结构：
  --      balance.enemies.<组>.<单位>  { hp = {80,100,120,250}, speed = n }
  --      balance.towers.<名字>.stats  { damage, range, cooldown }
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

  -- 已经在场上的单位**不在这里处理** —— 它们走 mult_apply_live 的相对更新，
  -- 原因见那个函数的注释（基线法会复合）。
  return n
end

-- 遍历 store.entities。
--
-- ⚠️ **必须用 pairs，绝不能用 `for i = 1, #s.entities`。** 实测这张表是**稀疏**的：
-- 下标从 **2** 开始（`entities[1]` 有可能被回收掉），最大下标到过 602，而同一时刻
-- 只有 86 个实体。Lua 的 `#` 遇到 `t[1] == nil` 直接返回 **0** ——
-- 于是 `for i = 1, #s.entities` 一次都不循环，依赖它的三处（场上单位倍率、
-- 免费造塔、秒杀）**全部静默失效**：代码不报错、测试台全绿、就是没效果。
-- 这个坑是靠实机探针的数据（entities[1] 不存在、entities[490] 存在）才定位到的。
local function each_entity(s, fn)
  if type(s) ~= "table" or type(s.entities) ~= "table" then return 0 end
  local n = 0
  for _, e in pairs(s.entities) do
    if type(e) == "table" then n = n + fn(e) end
  end
  return n
end

-- 血量必须**成对**缩放：只缩 `hp_max` 的话，敌人的**当前血量**（`health.hp`）
-- 还是原来的数字，挨同样多的伤害照样死 —— 从玩家视角看就是「血量倍率没生效」。
-- 实测就是这么被报回来的（`health.hp = 206` / `health.hp_max = 240`，只改了后者）。
--
-- ⚠️ 这个函数**只能用在倍率变化的那一次**（mult_apply_live），绝不能每帧重放：
-- 每帧把当前血量按倍率写回去 = 敌人永远打不死。
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
    -- 往下调倍率时别把敌人直接算死（至少要留 1 点）
    if v < 1 then v = 1 end
    if v ~= cur then h.hp = v n = n + 1 end
  end
  return n
end

-- 只按一个相对因子乘一次，不记基线。给「已经在场上的单位」用。
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

-- 已经在场上的单位走**相对**更新：只在倍率变化的那一刻按 m1/m0 乘一次。
--
-- 为什么不能用上面那套基线法：单位是深拷贝自模板的，而模板已经被我们改过了 ——
-- 一个新克隆出来的单位，它的"原值"其实已经是 base*mult；再把它当基线记一次，
-- 结果就是 5 倍变 25 倍。相对更新天然不复合，也不需要知道基线是多少。
--
-- 它自己判断该不该动（倍率没变就立刻返回），所以 tick 里可以无条件每帧调。
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
            -- 当前血量和上限一起缩 —— 只缩上限等于没缩（见 scale_health 注释）
            scale_health(e.health, f)
          elseif k == "enemy_speed" then
            scale_once(e.motion, ENEMY_SPEED_FIELDS, f)
          elseif k == "tower_dmg" then
            scale_once(e.tower, TOWER_FIELDS.tower_dmg, f)
          elseif k == "tower_range" then
            scale_once(e.tower, TOWER_FIELDS.tower_range, f)
          elseif k == "tower_rate" then
            -- 攻速是反的：倍率调大 = 冷却变小
            scale_once(e.tower, TOWER_FIELDS.tower_rate, 1 / f)
          end
          return 0
        end)
      end
      prev[k] = v
    end
  end
end

-- 免费造塔：把造塔/开格子的价格写 0。字段是实证的
-- （见 docs/reports/_kr6_report_auto3_t40.txt:42-44）。
-- 只往 0 写、且已经是 0 就跳过 —— 稳定之后这里是纯读，也不会把非数字搞坏。
-- 把一张表上的这些字段写 0（开关开）或写回原值（开关关）。原值第一次见到就记下。
-- 记基线是为了**关掉时能还原**：只写 0 不记原值的话，关掉之后价格会一直停在 0，
-- 直到重开关卡。基线复用 S.mult_base（它就是个「按表记原值」的通用存储，弱键）。
local function zero_fields(t, names, want_zero)
  if type(t) ~= "table" then return 0 end
  local n = 0
  for i = 1, #names do
    local k = names[i]
    -- rawget：这些组件可能带 __index 元方法，按项目的老教训一律绕开
    local v = rawget(t, k)
    if type(v) == "number" then
      local base = S.mult_base[t]
      if want_zero then
        if not base then base = {} S.mult_base[t] = base end
        -- 基线在**第一次置零时**才记，不是拿到表就记 —— 否则开关关着的时候游戏
        -- 改了价格，我们会拿一个过期的原值去"还原"。
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
  -- 无条件按 S.free_towers 写（开写 0、关写原值），所以关掉时能还原
  local z = S.free_towers and true or false
  return each_entity(s, function(e)
    return zero_fields(e.tower, { "min_cost", "price" }, z)
         + zero_fields(e.tower_holder, { "unblock_price" }, z)
  end)
end

-- 全部塔可造：把「本关能造什么塔」那两张表填满。
-- ⚠️ 这两张表挂在 store 的哪一层**没有实证**（探针会告诉我们）。所以这里只在
-- 找到「已经含有塔名的表」时才动手 —— 宁可什么都不做，也不能往一个不相干的表里
-- 塞字符串把关卡搞坏。
local function find_tower_list(s, want)
  if not s then return nil end
  local holders = { s, s.level, s.level_data, s.store }
  for i = 1, #holders do
    local h = holders[i]
    if type(h) == "table" then
      local t = h[want]
      if type(t) == "table" then
        -- 确认它确实是塔名表：至少有一个元素是我们认识的塔
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

-- 第一次动某张表时，把它的原始内容浅拷贝存下来（表很小，几十个键），
-- 关掉开关时按这份拷贝还原 —— 这样不必猜「哪些条目是我们加的」。
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

  -- 实测：这一关能造哪些塔就是 store.selected_towers 这个**名字数组**
  -- （探针实测 = {"archers","knights","catapult","wizard","culverine"}）。
  -- 早先找的 available_towers 在整份 store dump 里**根本不存在** —— 那是
  -- 从字节码符号猜出来的名字，猜错了。
  local av = find_tower_list(s, "selected_towers")
  if av then
    if on then
      snapshot_list(av)
      -- **只增不删**：游戏自己往这张表里加东西是合法的（关卡脚本会解锁塔），
      -- 每帧整表重写会把它抹掉。还原只在关掉开关时做一次。
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

  -- 实测：locked_towers 挂在 store.level 下（这一关是空表）。
  -- 空表没法用「含塔名」来验证，所以直接按已知路径取，不走 find_tower_list。
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

-- 隐藏界面。字段是实证的（all/game.lua 里 gui_hud_hidden 与 manual_gui_hide
-- 相邻），但**游戏什么时候读它没有实证** —— 所以每帧重放，绕开时机问题。
hide_ui_apply = function()
  local g = _G.game
  if type(g) ~= "table" then return 0 end
  local want = S.hide_ui and true or false
  if g.gui_hud_hidden ~= want then g.gui_hud_hidden = want return 1 end
  return 0
end

-- 秒杀全部敌人：往伤害队列里给每个敌人塞一条真伤。
-- ⚠️ 队列的形状是**推测**（符号级证据：game_gui_cheats 里 damage_queue 与
-- DAMAGE_TRUE 同块）。所以先判类型，不是普通 table 就不动手 —— 它可能是
-- klove.simulation 的队列对象，那套 API 我们没验证过，硬调会把整局搞坏。
-- 形状猜错的后果也只是这一局效果不对：**不写文件、不改存档**。
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
  -- 识别敌人用 e.enemy 组件（实测场上有 24 个实体带它）
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

-- 探针：一次把所有未知量问出来，免得反复跑实机。只读，不改任何东西。
-- 它解掉三个阻塞项：balance 里塔的字段路径、塔名单挂在哪、damage_queue 的形状。
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
    -- ⚠️ 这张表是**稀疏**的：下标从 2 起、最大到过 602，所以 `#s.entities` 可能是 0。
    -- 必须用 pairs 数（each_entity），否则统计出来的是假的 —— 早先就是被这个坑到，
    -- 抽样只抽到场景物件、以为"场上没有敌人"。
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

      -- 抽一个**带 health 的**实体展开（早先抽的是下标最小的，全是树和场景物件）
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
    -- 塔名直接从 balance.towers 的**键**列出来，不靠 TOWER_NAMES
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
    -- 上一轮就是因为没列这个，才不知道 filter_templates 的 self 该传什么、
    -- 注册表字段叫什么。这次先把家底摊开。
    out("=== entity_db 自身的字段 ===")
    local ek = {}
    for k, v in pairs(edb) do ek[#ek + 1] = tostring(k) .. ":" .. type(v) end
    table.sort(ek)
    out("  " .. table.concat(ek, "  "))

    local tn, shown = {}, {}
    each_template(edb, function(t)
      local nm = tostring(t.template_name or t.name or "?")
      tn[#tn + 1] = nm
      -- 每种前缀展开一个样本，看数值挂在哪一层
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

------------------------------------ 存档层：游戏内改进度（宝石/星星/解锁）
-- 为什么这条路走得通（而"在内存里找存档表"走不通）：
-- 存档层确实是异步文件 IO、存档不常驻内存，但它**总得**经过
-- 「文本 → Lua 表」和「Lua 表 → 文本」这两个转换。我们在转换函数上钩一道，
-- 就能在数据**流动的过程中**改它 —— 不需要存档常驻，也不需要关游戏。
--
-- 待办表 S.slot_ops 是**一次性**的：命中一次存档表就全部应用并清空。
-- 不这么做的话就变成"每帧覆盖存档"，玩家自己赚的宝石永远涨不上去。

S.slot_ops = S.slot_ops or {}

-- 存档表的指纹。沿用离线编辑器那条验证过的判据：必须**自己存了**
-- gems(数字) + levels(表) + upgrades_trees(表)。
-- 用 rawget：扫到的可能是任意表，带 __index 元方法的会抛错
-- （离线编辑器踩过这个 —— 那次报的是 "Unknown event: gems"）。
local function is_slot_like(t)
  if type(t) ~= "table" then return false end
  return type(rawget(t, "gems")) == "number"
     and type(rawget(t, "levels")) == "table"
     and type(rawget(t, "upgrades_trees")) == "table"
end

-- 星星奖励轨道，来自 kr6-desktop/data/map_data.lua 的 progression_rewards_premium。
-- 三处独立来源吻合（字节码解出 / 游戏运行时读出 / 真实存档反推），
-- 与离线编辑器里的那张表**必须保持一致**。
local REWARD_LAST_STARS = 84

-- 存档里的升级树节点是**短 id**（l1、skill_a），而 kr6/upgrades.lua 里是**带前缀的**
-- （archers_l1）。两个命名空间绝不能混用 —— 只沿用该树里已有的风格去补。
local TOWER_NODES = { "l1", "l2", "l3a", "l3b", "l4a", "l4b", "ulti" }
local HERO_NODES = { "skill_a", "skill_b", "skill_c", "talent_1", "talent_2",
                     "upg_a", "upg_b", "ultimate" }

-- Lua 的数组在存档里是按 1..n 存的，但可能是稀疏的，所以不能用 #。
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

-- 把 arr 补成 names 里缺的那些（沿用该表已有的风格，两种节点名不混用）
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

-- 单条操作的实现。每条都自己判类型 —— 存档结构变了宁可什么都不做。
local function apply_one_op(t, o)
  local op = o.op
  if op == "gems" then
    local cur = rawget(t, "gems")
    if type(cur) ~= "number" then return false end
    t.gems = (o.mode == "add") and (cur + (o.n or 0)) or (o.n or cur)
    return true
  elseif op == "stars" then
    -- 逐关补到 3 星，直到总星数够拿完轨道（或已经没有关可补）。
    -- ⚠️ **故意不动 progression.last_stars**：留着它低于真实总星数，
    -- 游戏才会「发现新星星」并走它自己的发放路径把内容给你 ——
    -- 那是唯一游戏自己校验过、不会被回收的方式。
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

-- 把待办全部应用到这张存档表，然后清空。返回应用成功的条数。
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

-- 暴露给测试台（和 S.items 一个道理）。存档改写是会动玩家数据的部分，
-- 必须能单独测 —— 测试环境里没有 storage 模块，钩子装不上，只能直接调这两个。
S.slot_apply = apply_slot_ops
S.slot_like = is_slot_like

-- 在哪几个函数上装钩子。签名没法全部实证（deserialize_lua 收文本返表、
-- serialize_lua 收表返文本、load_lua/write_lua 又是另一种），所以钩子里
-- **参数和返回值都扫一遍**，是存档形状的就动手 —— 不必猜哪个方向是表。
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
            -- 进方向：参数里可能是存档表
            for a = 1, select("#", ...) do
              local v = select(a, ...)
              if is_slot_like(v) then apply_slot_ops(v) end
            end
            local r1, r2, r3, r4 = orig(...)
            -- 出方向：返回值里可能是存档表
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

-- 第一次排队时把存档目录里的 slot_*.lua 备份一份。
-- 这是**真的会改玩家存档**的功能，按项目的规矩必须先留后路。
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

-- 排队一条操作，并给玩家一句说明。**排队本身不改任何东西** ——
-- 真正的改动发生在存档表下次经过读写钩子的时候。
-- ⚠️ 写法必须是 `queue_slot_op = function`（不是 `local function`）：它在文件
-- 上方**前向声明**过，写成 local function 会新建一个局部变量，声明处仍是 nil。
-- cn/en 省略时**不提示** —— 一条动作可能排好几项，只需要最后说一句。
queue_slot_op = function(o, cn, en)
  S.slot_ops[#S.slot_ops + 1] = o
  backup_slot_once()
  if cn then
    note(cn .. "（回主菜单再进一次档生效）", en .. " (re-enter the save to apply)")
  end
  return "queued " .. tostring(o.op) .. " (" .. #S.slot_ops .. " pending)"
end

--------------------------------------------------------------------- menu
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
    store = "dump store", api = "export API map", report = "full report",
    snap = "numeric snapshot", diff = "numeric diff", shot = "screenshot",
    close = "close menu",
    on = "ON", off = "OFF",
    labels = { "gold", "lives", "lvl" },
    nolvl = "(not in a level)",
  },
}

-- 从 from 出发沿 dir 找下一个**可执行**项（跳过分组标题），绕一圈。
-- 光标可以合法地停在标题上（那时不画高亮、Enter/←→ 有守卫），但移动要跳过它们。
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

-- 倍率行尾的文本。整数不拖小数点（×2 而不是 ×2.0）。
local function fmt_mult(v)
  if type(v) ~= "number" then return "x?" end
  if v == math.floor(v) then return "x" .. tostring(math.floor(v)) end
  return "x" .. tostring(v)
end

local function menu_items()
  local T = MENU_TEXT[S.cjk and "cn" or "en"]
  -- 标签缺失时回退成 id。以前缺标签会让 love.graphics.print 抛错，
  -- 而外层 pcall 把错误吞了 —— 整个面板会毫无痕迹地消失。
  local function L(id)
    local v = T[id]
    return (type(v) == "string" and v) or id
  end
  -- 分组标题就是一个多带 header = true 的普通条目，沿用 toggle/adjust 那套
  -- 「可选字段」的约定。它必须被三处跳过：↑↓（next_selectable）、鼠标
  -- （on_mouse）、冒烟测试（test_menu2.py）—— 漏一处就出 bug。
  local M = S.mult
  local items = {
    -- 没有「金币 → 999999」这一行：无限金钱已经覆盖了。gold_set 动作仍在，
    -- 供命令通道的 `gold <数值>` 用（那是设精确值，不是设上限）。
    { id = "hdr_res",   label = L("hdr_res"), header = true },
    { id = "gold_add",  label = L("gold_add"), adjust = { field = "player_gold", step = 1000, sign = 1 } },
    { id = "gold_sub",  label = L("gold_sub"), adjust = { field = "player_gold", step = 1000, sign = -1 } },
    { id = "lives_add", label = L("lives_add"), adjust = { field = "lives", step = 10, sign = 1 } },
    { id = "lives_sub", label = L("lives_sub"), adjust = { field = "lives", step = 10, sign = -1 } },
    { id = "hold",      label = L("hold"), toggle = function() return S.hold end },
    { id = "hold_lives", label = L("hold_lives"), toggle = function() return S.hold_lives end },

    { id = "hdr_wave",  label = L("hdr_wave"), header = true },
    { id = "next_wave", label = L("next_wave") },

    -- 倍率行：左右键调 S.mult 里的那一项（不走 store，所以 tweak 有两个目标）。
    -- 语义固定：右=调高，左=调低。
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

    -- 存档级。**排队**式：按下去不会立刻变，要等存档下次经过读写钩子
    -- （玩家回主菜单再进一次档）。每行都写清了这一点，免得以为是坏的。
    { id = "hdr_save", label = L("hdr_save"), header = true },
    { id = "gems_add", label = L("gems_add"),
      adjust = { slot = { op = "gems", mode = "add" }, step = 1000, sign = 1,
                 cn = "宝石", en = "gems" } },
    { id = "stars_max",  label = L("stars_max") },
    { id = "unlock_all", label = L("unlock_all") },
    { id = "unlock_tree", label = L("unlock_tree") },
  }
  if DEV then
    -- 诊断工具：对玩家没用，而且会往 Steam 云同步的存档目录里写大文件。
    local diag = {
      { id = "hdr_diag", label = L("hdr_diag"), header = true },
      { id = "level_gems_add", label = L("level_gems_add") },
      { id = "probe",    label = L("probe") },
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

-- want_size 省略时是 16（默认字号）。菜单变长后会按需再要一个更小的字号，
-- 见 font_for_height。
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
  -- 已经知道哪个路径能用了就直接用它，换字号时不必再逐个试
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
  -- 兜底：复用游戏当前字体，只要它能画汉字
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

-- 菜单太长时 draw_menu 会把行高压到比字还矮，那样行与行会叠在一起。
-- 这里按需要的行高反推一个够小的字号，**只建一次并缓存**（每帧 newFont 很贵）。
-- 老菜单只有 15 项，从来没触发过压缩；现在 30 项会。
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
    -- 先记下游戏的图形状态，画完原样还回去
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
    -- 全部条目在一页里，窗口矮时按比例压缩行高让它放得下，而不是画到屏幕外。
    -- 面板高 h == line_h*(n+5) + 28。
    local avail = 0
    pcall(function() avail = love.graphics.getHeight() end)
    if avail and avail > 0 then
      local maxh = avail - (MENU_Y - 10) - 10
      local fit = math.floor((maxh - 28) / (#items + 5))
      if fit < line_h then line_h = math.max(fit, 9) end
    end
    local header_h = line_h * 2 + 10
    local h = line_h * (#items + 5) + 28

    -- 行高被压得比字还矮时换小字号 —— 否则文字会行行叠在一起。
    -- 整块面板（含标题与提示行）都用同一个字号，免得互相盖住。
    local row_font = font_for_height(line_h)
    if row_font then pcall(love.graphics.setFont, row_font) end

    -- 面板
    love.graphics.setColor(0, 0, 0, 215)
    love.graphics.rectangle("fill", MENU_X - 10, MENU_Y - 10, MENU_W, h)
    love.graphics.setColor(200, 170, 60, 255)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", MENU_X - 10, MENU_Y - 10, MENU_W, h)

    -- 表头：标题 + 实时数值
    love.graphics.setColor(255, 220, 100, 255)
    love.graphics.print(T.title, MENU_X, MENU_Y - 2)
    local st = store_stat()
    local L2 = T.labels
    -- 有几个值就显示几项：关卡外这些字段不存在，那就不显示，
    -- 而不是给玩家看 "nil"。
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

    -- 条目
    S.rects = {}
    local y0 = MENU_Y + header_h + 4
    local mx, my = nil, nil
    pcall(function() mx, my = love.mouse.getPosition() end)
    for i = 1, #items do
      local y = y0 + (i - 1) * line_h
      local hover = (mx and my and my >= y and my < y + line_h
                     and mx >= MENU_X - 10 and mx < MENU_X - 10 + MENU_W)
      -- 标题行也要有命中框（带上 header 标记）：否则点在标题上会被当成
      -- 「没点中任何东西」漏给游戏，而菜单明明开着。
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
        -- 分组标题：淡色 + 右侧一条细线，和可点条目区分开。字体可能量不出宽度
        -- （S.font 为 nil 时），那就不画线，只靠颜色区分。
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
          -- 倍率行：x1.5 这种。和开/关共用同一个 x 槽，免得再排一次版。
          love.graphics.setColor(210, 200, 120, 255)
          love.graphics.print(items[i].value(), MENU_X - 10 + MENU_W - 56, y + 2)
        end
      end
    end

    -- 操作提示 + 最近一条消息
    love.graphics.setColor(160, 160, 160, 255)
    love.graphics.print(T.hint, MENU_X, y0 + #items * line_h + 2)
    if S.msg ~= "" and os.time() - S.msg_ts < 6 then
      love.graphics.setColor(140, 255, 140, 255)
      love.graphics.print(S.msg, MENU_X, y0 + #items * line_h + 2 + line_h)
    end

    love.graphics.setColor(255, 255, 255, 255)
    love.graphics.pop()
    -- 还回游戏原本绑定的状态
    pcall(function()
      love.graphics.setCanvas(prev.canvas)
      love.graphics.setShader(prev.shader)
      if prev.bm then love.graphics.setBlendMode(prev.bm, prev.abm) end
      if prev.sw then love.graphics.setScissor(prev.sx, prev.sy, prev.sw, prev.sh) end
      if prev.lw then love.graphics.setLineWidth(prev.lw) end
      if prev.r then love.graphics.setColor(prev.r, prev.g, prev.b, prev.a) end
      -- 这行原先是 setFont(getFont()) —— 把自己设回自己，等于没还原，
      -- 于是修改器的字体会泄漏给游戏。改成还回真的那个。
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
  -- 光标不能停在分组标题上：菜单打开时"什么都没选中"很怪，Enter 也没反应。
  -- 只在确实需要时挪（保留玩家上次的选择）。
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
    -- 标题行按下去什么都不做，也**不能**走 run_action —— 那会返回
    -- "unknown action hdr_xxx"，而冒烟测试把这种回复当失败。
    if it and not it.header then run_action(it.id) end
  elseif key == "left" or key == "right" then
    local it = items[S.sel]
    local dir = (key == "right") and 1 or -1
    if it and not it.header and it.adjust then
      local a = it.adjust
      -- 每一行语义一致：右键加、左键减。两种目标都从这一个入口走
      -- （field = store 字段，set = 倍率表），见 action() 里的 tweak 分支。
      run_action("tweak", { field = a.field, set = a.set, key = a.key,
                            min = a.min, max = a.max,
                            delta = a.step * a.sign * dir })
    end
  end
end

-- 开着菜单时要拦下的键（其余一律透传给游戏）
local MENU_KEYS = {
  up = true, down = true, left = true, right = true,
  ["return"] = true, kpenter = true, escape = true, [" "] = true, home = true,
}

---------------------------------------------------------------- frame tick
-- _kr6_cmd.txt 接受的动词。历史短名继续可用（README 里有、测试也在用）；
-- `cmd <动作id> [参数]` 是通用入口，不必开菜单就能驱动任何动作。
local CMD_MAP = {
  gold = "gold_set", goldadd = "gold_add", goldsub = "gold_sub",
  lives = "lives_add", ["lives-"] = "lives_sub",
  hold = "hold", holdlives = "hold_lives",
  levelgems = "level_gems_add",
  nextwave = "next_wave", store = "store", report = "report", api = "api",
  snap = "snap", diff = "diff", shot = "shot", probe = "probe",
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

  -- 「塔与单位」组。这几个开关的共同点是**游戏自己会重算这些值**，写一次就被
  -- 覆盖，所以每帧重放。每块各自 pcall —— 一个出问题不影响其它。
  -- 这三个**都不加开关守卫**：关掉的时候也得跑一趟把原值写回去，否则值会一直
  -- 停在被改过的状态。它们内部自己判断该写什么，稳定之后是纯读，开销可忽略。
  pcall(free_towers_apply)
  pcall(all_towers_apply)
  pcall(hide_ui_apply)
  -- 倍率：全部是 x1 时完全不动游戏（免得每帧白跑一遍模板）。调回 1 之后
  -- 这里自动停手，游戏自己的 patch_templates 会把数值恢复。
  local mm = S.mult
  local mult_active = (mm.tower_dmg ~= 1 or mm.tower_range ~= 1
                       or mm.tower_rate ~= 1 or mm.enemy_hp ~= 1
                       or mm.enemy_speed ~= 1)
  if mult_active then
    -- 模板与 balance：基线法，每帧幂等重放（新生成的单位靠它）
    pcall(mult_apply)
    S.mult_active = true
  elseif S.mult_active then
    -- 最后一根倍率刚被调回 x1。**这一趟收尾不能省**：守卫条件此刻已经变假，
    -- 不补跑一次的话模板就永远停在放大后的值上，再也回不来。
    -- 幂等重放会把 base*1 写回去，写完才真正停手。
    pcall(mult_apply)
    S.mult_active = false
  end
  -- 已经在场上的单位：相对法，它自己判断倍率变没变。
  -- 无条件调用是故意的 —— 倍率调回 1 时也得让场的单位跟着回来。
  pcall(mult_apply_live)

  -- 存档钩子：storage 在 payload 加载时可能还没 require，所以每帧试装一次，
  -- 装上就不再试。它是"游戏内改存档进度"唯一的入口。
  if not S.slot_hooks_done then
    local n = install_slot_hooks()
    if n > 0 or (game_mod("storage") ~= nil) then S.slot_hooks_done = true end
  end

  local now = os.time()
  if now > S.last_cmd_check and not S.in_cmd then
    S.last_cmd_check = now
    local cmd = rf("_kr6_cmd.txt")
    if cmd then
      -- 重入保护：动作可能回调到被 tick 包住的游戏函数，
      -- 那样会重新进到这个派发里
      S.in_cmd = true
      local line = cmd:gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      -- 执行**之前**先把命令回显出去：命令卡死或崩掉时，
      -- 至少能留下「当时在跑什么」的记录。
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
      -- 执行完才消费命令文件。以前「产生了结果但没写出来」和「根本没被读到」
      -- 长得一模一样 —— snap/diff/api/report 的失败就是这么藏住的。
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

------------------------------------------------------------------ input
local function evt_time()
  local ok, t = pcall(function() return love.timer.getTime() end)
  if ok and type(t) == "number" then return t end
  return os.clock()
end

-- 一个按键可能经多条路到达（love.handlers 和游戏自己的 director.keypressed）。
-- 只处理一次，并返回我们有没有吃掉它。
local function on_key(key)
  local t = evt_time()
  if S.last_key == key and S.last_key_t and (t - S.last_key_t) < 0.08 then
    return true
  end
  S.last_key, S.last_key_t = key, t

  -- 只认 home 一个键：功能键太容易误触，所以不设任何 F 键热键。
  -- 其余操作走菜单（home 打开）或命令文件。
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
      -- 分组标题：**吃掉**这次点击但什么都不做。不能 return false —— 那会把
      -- 点击漏给游戏，而菜单明明开着。
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

    -- 路径 2：游戏可能把输入直接从 director 转发（真实日志证实它确实这么做）
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
  -- 短名清单从 CMD_MAP **生成**，不写死。写死过一次，加了新动词忘了同步，
  -- 那个文件就开始撒谎（说只有旧动词可用），排查时被误导。
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
