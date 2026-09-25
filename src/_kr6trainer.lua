-- kr6 游戏内修改器
--
-- 由被顶掉的模块（all/director.lua）加载：它先从 _orig/ 读回游戏自己的原始字节码，
-- 再把模块表交到这里。本文件所有代码都在 pcall 保护下，坏不了游戏。
--
-- **这是精简版**：只放已经实机验证过、且当前确实要提供的东西。
-- 功能全开的那个版本冻结在 src/_kr6trainer_lab.lua（塔/单位全套倍率、免费造塔、
-- 全部塔可造、秒杀、隐藏界面、存档组全套、外加一整批开发版诊断）。
--
-- 本版提供：
--   关卡内   金币 / 生命 / 无限金钱 / 生命锁定 / 立刻下一波
--   塔与单位 **敌人血量、敌人移速**（倍率，只在本关生效，退出关卡即还原）
--   存档     星星拉满 / 升级树补全 —— **排队式**，回主菜单再进一次档生效
--
-- 存档那两项走的是**拦存档读写**：游戏的存档层是异步文件 IO、存档不常驻内存，
-- 但它总得经过「文本 → Lua 表」和「Lua 表 → 文本」两个转换，在那两个函数上
-- 钩一道就能在数据流动的过程中改它。详见 docs/ENGINE_NOTES.md 第 5.6 节的「更正」。
--
-- 关卡状态（store，ECS 单例组件）字段：
--   player_gold, lives, force_next_wave, level_name, entities, damage_queue ...
--
-- 热键：只有 Home 开关菜单 —— 不设任何 F 键，太容易误触。
-- 命令文件：往 _kr6_cmd.txt 写一行，结果写到 _kr6_cmd_out.txt。
--   gold / gold 50000 / goldadd / goldsub / lives / lives- / hold / holdlives /
--   nextwave / stars / unlocktree / menu / closemenu / cmd <动作id> [参数]
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
-- 字段。缺什么补什么，否则「塔与单位」那两行会读到 nil。
if type(S.mult) ~= "table" then
  S.mult = { enemy_hp = 1, enemy_speed = 1 }
end
-- 已经"烤进"模板/场上的倍率。活单位走相对更新（见 mult_apply_live），
-- 需要知道上一次应用的是多少才能算出 m1/m0。
if type(S.mult_applied) ~= "table" then
  S.mult_applied = { enemy_hp = 1, enemy_speed = 1 }
end
if type(S.mult_base) ~= "table" then
  -- 弱键：实体/组件表被游戏回收后，它们的基线跟着释放，不会越攒越多。
  -- 为什么需要基线见 scale_table 的注释。
  S.mult_base = setmetatable({}, { __mode = "k" })
end
-- 存档钩子的登记表（装上了哪些）与待应用的存档操作队列
if type(S.slot_hooks) ~= "table" then S.slot_hooks = {} end
if type(S.slot_ops) ~= "table" then S.slot_ops = {} end

-- 这一版是**精简版**：没有任何开发版才有东西 —— 没有 DEV 开关、没有诊断项、
-- 没有探针。功能全开的那个版本冻结在 src/_kr6trainer_lab.lua。
-- 因此构建链也不再需要 release_flags 去改写开关（那条路已同步简化）。

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


------------------------------------------------------------------- actions
-- 前向声明。action() 会调这几个函数，但它们定义在文件更下面。没有这几行声明，
-- 这些名字在 action 里根本不在作用域内，于是解析成**同名全局变量**（nil）——
-- 这个坑真踩过：snap/diff/report/api 当初就是这么做无声息地坏掉的，
-- 而且只有某一个动作挂、其余正常，最难查。
-- 定义处**必须**写成 `名字 = function() ... end`；写成 `local function`
-- 会新建一个局部变量，上面这行声明仍然是 nil。
local game_mod, balance_of, scale_table, mult_apply, mult_apply_live, queue_slot_op

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
  elseif id == "stars_max" then
    -- 给星是**主力路径**：游戏自己会按奖励轨道把内容发给你，而且不会被回收 ——
    -- 比直接往 towers.selected / heroes.team 里塞稳（游戏加载时有归属校验
    -- deselect_unowned_units，塞进去的可能被清掉）。这一点和离线编辑器一致。
    -- 实测有效：slot_1.lua 里 28 关 × 3 星 = 84，游戏自己把 last_stars 更新成了 84。
    return queue_slot_op({ op = "stars" }, "星星拉满", "max stars")
  elseif id == "unlock_tree" then
    return queue_slot_op({ op = "tree" }, "升级树补全", "fill upgrade trees")
  elseif id == "enemy_hp" or id == "enemy_speed" then
    -- 倍率行靠 ←→ 调，本身没有"执行"语义。但每个菜单项必须能用空参调用一次
    -- （冒烟测试就是这么跑遍全菜单的），所以给它一个**只读**的查询动作 ——
    -- 顺带修掉「在倍率行按 Enter 会返回 unknown action」这个瑕疵。
    -- 故意不做成"按 Enter 重置"：误触不该悄悄改数值。
    local v = S.mult[id]
    local cn = ({ enemy_hp = "敌人血量", enemy_speed = "敌人移速" })[id] or id
    note(cn .. " x" .. tostring(v) .. "（←→ 调整）", id .. " = x" .. tostring(v))
    return id .. " = x" .. tostring(v)
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
    end
  end)

  -- 2) balance —— 模板的**源头**。实测结构：
  --      balance.enemies.<组>.<单位>  { hp = {80,100,120,250}, speed = n }
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
          end
          return 0
        end)
      end
      prev[k] = v
    end
  end
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
  if op == "stars" then
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
    next_wave = "立刻下一波",
    hdr_res = "资源", hdr_wave = "波次", hdr_units = "塔与单位",
    hdr_save = "存档（回主菜单再进档生效）",
    enemy_hp = "敌人血量", enemy_speed = "敌人移速",
    stars_max = "星星拉满", unlock_tree = "升级树补全",
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
    next_wave = "next wave now",
    hdr_res = "RESOURCES", hdr_wave = "WAVES", hdr_units = "TOWERS & UNITS",
    hdr_save = "SAVE (apply on reload)",
    enemy_hp = "enemy HP", enemy_speed = "enemy speed",
    stars_max = "max stars", unlock_tree = "fill upgrade trees",
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

    -- 倍率行：左右键调 S.mult 里的那一项（不走 store，所以 tweak 有第二种目标）。
    -- 语义固定：右=调高，左=调低。
    { id = "hdr_units", label = L("hdr_units"), header = true },
    { id = "enemy_hp", label = L("enemy_hp"),
      adjust = { set = M, key = "enemy_hp", step = 0.5, sign = 1, min = 0.1, max = 20 },
      value = function() return fmt_mult(S.mult.enemy_hp) end },
    { id = "enemy_speed", label = L("enemy_speed"),
      adjust = { set = M, key = "enemy_speed", step = 0.25, sign = 1, min = 0.1, max = 10 },
      value = function() return fmt_mult(S.mult.enemy_speed) end },

    -- 存档级。**排队**式：按下去不会立刻变，要等存档下次经过读写钩子
    -- （玩家回主菜单再进一次档）。分组标题里写明了这一点，免得以为是坏的。
    { id = "hdr_save", label = L("hdr_save"), header = true },
    { id = "stars_max",  label = L("stars_max") },
    { id = "unlock_tree", label = L("unlock_tree") },
  }
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
  nextwave = "next_wave",
  stars = "stars_max", unlocktree = "unlock_tree",
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
  -- 倍率：全部是 x1 时完全不动游戏（免得每帧白跑一遍模板）。调回 1 之后
  -- 这里自动停手，游戏自己的 patch_templates 会把数值恢复。
  local mm = S.mult
  local mult_active = (mm.enemy_hp ~= 1 or mm.enemy_speed ~= 1)
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
end

return "kr6trainer ok"
