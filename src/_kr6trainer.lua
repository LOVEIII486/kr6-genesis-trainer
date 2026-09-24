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
  shot = true, level_gems_add = true,
}

-- 前向声明。action() 会调这几个函数，但它们定义在文件更下面。没有这几行声明，
-- 这些名字在 action 里根本不在作用域内，于是解析成**同名全局变量**（nil），
-- 结果是菜单和命令文件这两条路调用 snap/diff/report/api 全部报
-- "attempt to call global 'snapshot' (a nil value)"；而心跳那条路正常，
-- 因为 tick() 定义在它们后面 —— 这就是当初「有时好使有时不好使」的来源。
local report, snapshot, diff_action, api_sweep

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
    -- 左右键在可调行上的统一入口：对一个字段加一个带符号的增量。
    -- 新增可调行只要加数据，不用再加分支。
    if type(arg) ~= "table" or type(arg.delta) ~= "number" or arg.delta == 0 then
      return "FAIL: bad tweak"
    end
    local r = add_field(arg.field, arg.delta)
    note(r) return r
  elseif id == "next_wave" then
    local s = store_of()
    if not s then note("不在关卡内", "not in a level") return "no store" end
    s.force_next_wave = true
    note("强制下一波", "force next wave")
    return "force_next_wave=true"
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

--------------------------------------------------------------------- menu
local MENU_TEXT = {
  cn = {
    title = "KR6 修改器", hint = "Home 开关   ↑↓ 选择   ←→ 调整   Enter 执行   Esc 关闭",
    gold_add = "金币 +1000", gold_sub = "金币 -1000",
    lives_add = "生命 +10", lives_sub = "生命 -10",
    hold = "无限金钱", hold_lives = "生命锁定",
    level_gems_add = "本关宝石 +100",
    next_wave = "立刻下一波",
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
    store = "dump store", api = "export API map", report = "full report",
    snap = "numeric snapshot", diff = "numeric diff", shot = "screenshot",
    close = "close menu",
    on = "ON", off = "OFF",
    labels = { "gold", "lives", "lvl" },
    nolvl = "(not in a level)",
  },
}

local function menu_items()
  local T = MENU_TEXT[S.cjk and "cn" or "en"]
  -- 标签缺失时回退成 id。以前缺标签会让 love.graphics.print 抛错，
  -- 而外层 pcall 把错误吞了 —— 整个面板会毫无痕迹地消失。
  local function L(id)
    local v = T[id]
    return (type(v) == "string" and v) or id
  end
  local items = {
    -- 没有「金币 → 999999」这一行：无限金钱已经覆盖了。gold_set 动作仍在，
    -- 供命令通道的 `gold <数值>` 用（那是设精确值，不是设上限）。
    { id = "gold_add",  label = L("gold_add"), adjust = { field = "player_gold", step = 1000, sign = 1 } },
    { id = "gold_sub",  label = L("gold_sub"), adjust = { field = "player_gold", step = 1000, sign = -1 } },
    { id = "lives_add", label = L("lives_add"), adjust = { field = "lives", step = 10, sign = 1 } },
    { id = "lives_sub", label = L("lives_sub"), adjust = { field = "lives", step = 10, sign = -1 } },
    { id = "hold",      label = L("hold"), toggle = function() return S.hold end },
    { id = "hold_lives", label = L("hold_lives"), toggle = function() return S.hold_lives end },
    { id = "next_wave", label = L("next_wave") },
  }
  if DEV then
    -- 诊断工具：对玩家没用，而且会往 Steam 云同步的存档目录里写大文件。
    local diag = {
      { id = "level_gems_add", label = L("level_gems_add") },
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

local function try_load_font()
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
  for i = 1, #cands do
    local ok, f = pcall(love.graphics.newFont, cands[i], 16)
    if ok and f then
      S.cjk = true
      wf("_kr6_font.txt", "CJK font loaded: " .. cands[i] .. "\n")
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
      S.rects[i] = { x = MENU_X - 10, y = y, w = MENU_W, h = line_h, id = items[i].id }
      if i == S.sel then
        love.graphics.setColor(80, 110, 190, 220)
        love.graphics.rectangle("fill", MENU_X - 10, y, MENU_W, line_h)
      elseif hover then
        love.graphics.setColor(70, 70, 70, 200)
        love.graphics.rectangle("fill", MENU_X - 10, y, MENU_W, line_h)
      end
      love.graphics.setColor(255, 255, 255, 255)
      love.graphics.print(items[i].label, MENU_X + 4, y + 2)
      if items[i].toggle then
        local on = items[i].toggle()
        love.graphics.setColor(on and 120 or 160, on and 255 or 160, on and 120 or 160, 255)
        love.graphics.print(on and T.on or T.off, MENU_X - 10 + MENU_W - 56, y + 2)
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
      love.graphics.setFont(love.graphics.getFont())
    end)
  end)
end

local function menu_toggle()
  S.menu_open = not S.menu_open
  if S.menu_open and not S.font and type(love) == "table" and type(love.graphics) == "table" then
    pcall(function() S.font = try_load_font() end)
  end
  S.sel = S.sel or 1
end

local function menu_key(key)
  local items = menu_items()
  if key == "escape" then
    S.menu_open = false
    return
  end
  if key == "up" then
    S.sel = S.sel - 1
    if S.sel < 1 then S.sel = #items end
  elseif key == "down" then
    S.sel = S.sel + 1
    if S.sel > #items then S.sel = 1 end
  elseif key == "return" or key == "kpenter" or key == " " then
    local it = items[S.sel]
    if it then run_action(it.id) end
  elseif key == "left" or key == "right" then
    local it = items[S.sel]
    local dir = (key == "right") and 1 or -1
    if it and it.adjust then
      local a = it.adjust
      -- 每一行语义一致：右键加、左键减
      run_action("tweak", { field = a.field, delta = a.step * a.sign * dir })
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
  snap = "snap", diff = "diff", shot = "shot",
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
  wf("_kr6trainer_loaded.txt",
     "fired=[" .. table.concat(S.fired, ", ") .. "]" .. string.char(10) ..
     "key_hook=" .. tostring(S.key_hook) .. string.char(10) ..
     "hooks=" .. table.concat(S.hooks, ", ") .. string.char(10) ..
     "keys: Home = menu (no F-key hotkeys on purpose)" .. string.char(10) ..
     "files: _kr6_cmd.txt -> _kr6_cmd_out.txt (gold / goldadd / goldsub / lives / lives- / hold / holdlives / levelgems / nextwave / store / report / api / snap / diff / shot / menu / closemenu / cmd <id> [arg])" .. string.char(10))
  pcall(report, "boot")
end

return "kr6trainer ok"
