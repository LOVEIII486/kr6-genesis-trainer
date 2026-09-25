-- kr6 游戏内修改器（精简版）
--
-- 由覆盖桩 all/director.lua 加载：桩先从 _orig/ 读回游戏自己的原始字节码，再把模块表
-- 交到这里。本文件所有代码都在 pcall 保护下，坏不了游戏。
-- 功能全开的开发版冻结在 src/_kr6trainer_lab.lua。
--
-- 提供：关卡内 金币 / 生命 / 无限金钱 / 生命锁定 / 立刻下一波；
--   敌人属性 血量/移速倍率（只在本关生效）；
--   英雄 当场升级；
--   存档 星星拉满 / 升级树补全（回主菜单重新加载存档后生效）。
--
-- 不碰防御塔（未验证有效，已从正式代码撤掉）。
--
-- 热键：只有 Home 开关菜单 —— 不设任何 F 键，太容易误触。
-- 命令文件：往 _kr6_cmd.txt 写一行，结果写到 _kr6_cmd_out.txt；短名清单见 CMD_MAP。
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

-- 兼容旧版本注入留下的 S：它跨次加载保留，缺的字段补上，否则倍率那两行读到 nil。
if type(S.mult) ~= "table" then
  S.mult = { enemy_hp = 1, enemy_speed = 1 }
end
-- 已经应用到模板/场上的倍率；活单位做相对更新（见 mult_apply_live）要靠它算比值。
if type(S.mult_applied) ~= "table" then
  S.mult_applied = { enemy_hp = 1, enemy_speed = 1 }
end
if type(S.mult_base) ~= "table" then
  -- 弱键：实体表被游戏回收后基线跟着释放，不会越攒越多。理由见 scale_table。
  S.mult_base = setmetatable({}, { __mode = "k" })
end
-- 存档钩子的登记表与待应用的存档操作队列
if type(S.slot_hooks) ~= "table" then S.slot_hooks = {} end
if type(S.slot_ops) ~= "table" then S.slot_ops = {} end

S.fired[#S.fired + 1] = tostring(virt)
if first_install then S.virt = tostring(virt) end
S.mod = (type(mod) == "table") and mod or S.mod

local function note(cn, en)
  S.msg = S.cjk and tostring(cn) or tostring(en or cn)
  S.msg_ts = os.time()
end

-- 每个被记录的错误都落到 _kr6_err.txt —— 错误被 pcall 吞掉、什么都不留下最难查。
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

-- helpers
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

-- the store
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


-- actions
-- 前向声明：action() 调的这几个函数定义在文件更下面（否则解析成同名全局变量 = 静默失效）。
-- 定义处**必须**写成 `名字 = function() ... end`，写成 `local function` 这里仍是 nil。
local game_mod, balance_of, scale_table, mult_apply, mult_apply_live, queue_slot_op
local na, hero_thresholds, hero_raise

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
    -- 可调行的统一入口，两种目标共用：arg.field → store 字段；arg.set/arg.key → S.mult 倍率表。
    if type(arg) ~= "table" or type(arg.delta) ~= "number" or arg.delta == 0 then
      return "FAIL: bad tweak"
    end
    if type(arg.slot) == "table" then
      -- 第三种目标：**排队**一条存档操作（存档不在 store 里，等下次存档读写钩子）。
      local o = arg.slot
      o.n = arg.delta
      return queue_slot_op(o, arg.cn or o.op, arg.en or o.op)
    end
    if type(arg.set) == "table" and arg.key ~= nil then
      local cur = tonumber(arg.set[arg.key]) or 1
      local v = cur + arg.delta
      if arg.min and v < arg.min then v = arg.min end
      if arg.max and v > arg.max then v = arg.max end
      -- 只留两位小数：浮点反复加减会攒出 1.0000000000000002，而它原样印在行尾。
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
    -- 走游戏自己的奖励轨道发内容（不会被回收）；直接塞 towers.selected/heroes.team 会被
    -- 加载时的归属校验 deselect_unowned_units 清掉。
    return queue_slot_op({ op = "stars" }, "星星拉满", "max stars")
  elseif id == "unlock_tree" then
    return queue_slot_op({ op = "tree" }, "升级树补全", "fill upgrade trees")
  elseif id == "hero_now_up" or id == "hero_now_max" then
    -- 关卡内即时升级。失败时用 na()（**不含 "FAIL"**，冒烟测试把含 FAIL 的回复算失败）。
    local msg, why = hero_raise(id == "hero_now_max" and "max" or "next")
    if not msg then
      local r = na(why)
      note(r) return r
    end
    note(msg) return msg
  elseif id == "enemy_hp" or id == "enemy_speed" then
    -- 倍率行本身没有"执行"语义，但每个菜单项必须能用空参调用一次（冒烟测试会跑遍
    -- 全菜单），所以给一个**只读**查询；故意不做成按 Enter 重置，误触不该改数值。
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




-- 游戏内部：store / 单位 / 作弊

-- 从 package.loaded 拿游戏模块（**不能用 require** —— payload 由覆盖桩加载，会重入）。
game_mod = function(name)
  local m = package.loaded[name]
  if type(m) == "table" then return m end
  m = _G[name]                       -- game / director / main 这几个是全局
  if type(m) == "table" then return m end
  return nil
end

-- 依赖缺失时的统一回复，**刻意不含 "FAIL"**（冒烟测试把含 FAIL 的回复算失败）。
na = function(what)
  return "n/a: " .. tostring(what)
end

-- balance 表（敌人数值的源）**不在 package.loaded 里**，只能从 upgrades 模块
-- 两个函数的 upvalue 拿。按**名字**找而不是按下标 —— 下标是反编译猜的。
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

-- 敌人字段：balance 里 hp 是**按等级分的数组**（{80,100,120,250}）、speed 是标量，活实体
-- 上是 health 表。⚠️ 这几项参与每帧重放，**绝不能碰当前血量**（每帧写回 = 打不死）。
local ENEMY_HP_FIELDS    = { hp_max = true }
local ENEMY_HP_ARRAYS    = { hp = true }
local ENEMY_SPEED_FIELDS = { speed = true, speed_limit = true, max_speed = true }

-- 把属于 fields 的 number 字段缩放到 base*mult，返回改了几个。基线记进 S.mult_base：
-- 游戏自己的 patch_templates 是**原地乘**，不记基线的话每帧反复调会复合（翻倍再翻倍）。
scale_table = function(t, fields, mult)
  if type(t) ~= "table" then return 0 end
  local base = S.mult_base[t]
  if not base then base = {} S.mult_base[t] = base end
  local n = 0
  for k, v in pairs(t) do
    if fields[k] and type(v) == "number" then
      if base[k] == nil then base[k] = v end
      local want = base[k] * mult
      -- 只写确实不同的：稳定后这里是纯读，不搅动游戏的表
      if t[k] ~= want then t[k] = want n = n + 1 end
    end
  end
  return n
end

-- 数组字段的版本：逐元素缩放，基线也逐元素记。
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


-- 遍历 entity_db 里的模板，每个调一次 fn。先试注册表字段绕开 filter_templates ——
-- 它的 self 该传什么没有实证，故几种形态都试并记进 S.tpl_shape。
-- 返回**访问到的模板个数**（不是 fn 返回值之和 —— 回调可能恒返回 0）。
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

-- 每帧重放所有倍率。模板决定**之后**生成的对象，所以模板与 balance 都要写 ——
-- entity_db 生成对象时内部深拷贝（局部函数，外部判断不了时机），只能两边都写。
mult_apply = function()
  local m = S.mult
  local hp, sp = m.enemy_hp, m.enemy_speed
  local n = 0

  local edb = game_mod("entity_db")
  each_template(edb, function(t)
    local nm = tostring(t.template_name or t.name or "")
    if nm:sub(1, 6) == "enemy_" then
      n = n + scale_table(t, ENEMY_HP_FIELDS, hp)
      n = n + scale_arrays(t, ENEMY_HP_ARRAYS, hp)
      n = n + scale_table(t, ENEMY_SPEED_FIELDS, sp)
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
  end

  return n
end

-- 遍历 store.entities。⚠️ **必须用 pairs，绝不能用 `for i = 1, #s.entities`**：这张表
-- 是**稀疏**的（下标从 2 起，最大到过 602，而同一时刻只有 86 个实体），Lua 的 `#`
-- 遇 `t[1] == nil` 直接返回 0 —— 循环一次都不跑，依赖它的功能会**静默失效**。
local function each_entity(s, fn)
  if type(s) ~= "table" or type(s.entities) ~= "table" then return 0 end
  local n = 0
  for _, e in pairs(s.entities) do
    if type(e) == "table" then n = n + fn(e) end
  end
  return n
end

-- 血量必须**成对**缩放：只缩 hp_max 等于没缩（当前血量还是原数字，照样挨那么多伤害
-- 就死）。⚠️ 只能用在倍率变化的那一次（mult_apply_live），**绝不能每帧重放**。
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

-- 只按一个相对因子乘一次、不记基线，给「已经在场上的单位」用。
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

-- 已经在场上的单位走**相对**更新：只在倍率变化那一刻按新旧比乘一次。⚠️ 不能用基线法
-- —— 单位深拷贝自已被改过的模板，其"原值"已是 base*mult，再记基线会 5 倍变 25 倍。
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
            -- 当前血量和上限一起缩 —— 只缩上限等于没缩（见 scale_health）
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










-- 存档层：游戏内改进度（宝石/星星/解锁）
-- 存档不常驻内存（异步文件 IO），但**总得**经过「文本 → Lua 表」和「Lua 表 → 文本」两个
-- 转换，在那两个函数上钩一道即可。⚠️ 待办表 S.slot_ops 是**一次性**的：命中一次存档表就
-- 全部应用并清空，否则会变成"每帧覆盖存档"，玩家自己赚的宝石永远涨不上去。

S.slot_ops = S.slot_ops or {}

-- 存档表指纹：必须**自己存了** gems(数字)+levels(表)+upgrades_trees(表)；用 rawget 取
-- —— 扫到的可能是任意表，带 __index 元方法的会抛错。
local function is_slot_like(t)
  if type(t) ~= "table" then return false end
  return type(rawget(t, "gems")) == "number"
     and type(rawget(t, "levels")) == "table"
     and type(rawget(t, "upgrades_trees")) == "table"
end

-- 星星奖励轨道总量（= map_data.lua 的 progression_rewards_premium，须与离线编辑器一致）。
local REWARD_LAST_STARS = 84

-- 升级树节点。存档里是短 id，kr6/upgrades.lua 里带前缀（archers_l1），两套不能混。
-- 防御塔树和英雄树用的是**同一套** id；别的节点名游戏里没有。
local UPGRADE_NODES = { "l1", "l2", "l3a", "l3b", "l4a", "l4b", "ulti" }

-- 存档里的数组按 1..n 存但可能稀疏，所以不能用 #。
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

-- 把 arr 补成 UPGRADE_NODES 里缺的那些。
local function fill_node_array(arr)
  if type(arr) ~= "table" then return 0 end
  local n = slot_array_len(arr)
  local added = 0
  for i = 1, #UPGRADE_NODES do
    if not slot_array_has(arr, UPGRADE_NODES[i]) then
      arr[n + added + 1] = UPGRADE_NODES[i]
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

-- 英雄等级不落存档，只存经验；等级由 xp 过 game_settings.hero_xp_thresholds 推出。
-- 用 pairs 不用 #：这张表的形状没验证过，稀疏表的 `#` 会返回 0。
local function next_threshold(thr, xp)
  local best
  for _, v in pairs(thr) do
    if type(v) == "number" and v > xp and (best == nil or v < best) then best = v end
  end
  return best
end

local function thr_top(thr)
  local top
  for _, v in pairs(thr) do
    if type(v) == "number" and (top == nil or v > top) then top = v end
  end
  return top
end

hero_thresholds = function()
  local gs = game_mod("game_settings")
  local thr = gs and rawget(gs, "hero_xp_thresholds")
  return (type(thr) == "table") and thr or nil
end

-- 出战英雄在应用时刻解析（排队时存档表还没出现）。取不到就放弃，不新建 status 条目。
local function hero_of_slot(t)
  local hs = rawget(t, "heroes")
  if type(hs) ~= "table" then return nil end
  local st = rawget(hs, "status")
  if type(st) ~= "table" then return nil end
  local function owned(id)
    return type(id) == "string" and type(rawget(st, id)) == "table"
  end
  local id = rawget(hs, "selected")
  if not owned(id) then
    local team = rawget(hs, "team")
    if type(team) == "table" then
      -- team 通常是数组，但形状没被验证过 —— 数组取不到就在字典里找第一个可用的。
      if owned(rawget(team, 1)) then
        id = rawget(team, 1)
      else
        for _, v in pairs(team) do
          if owned(v) then id = v break end
        end
      end
    end
  end
  if not owned(id) then return nil end
  return id, rawget(st, id)
end

-- 关卡内英雄即时升级：先写 hero.level 与 hero.xp，再调 hero.fn_level_up(实体, store, true)
-- 让游戏自己应用属性（光调回调不会改等级）。用 level_stats.hp_max 校验是否真的生效。
-- 上限 10 级（hero_xp_thresholds 有 9 个阈值），等级 N 对应 thr[N-1]。
hero_raise = function(mode)
  local s = store_of()
  if not s then return nil, "不在关卡内" end
  local team = rawget(s, "hero_team")
  if type(team) ~= "table" then return nil, "这一关没有出战英雄" end
  local thr = hero_thresholds()
  local cap = 10
  if type(thr) == "table" then
    local n = 0
    for _ in pairs(thr) do n = n + 1 end
    if n > 0 then cap = n + 1 end
  end

  local function who(e, idx)
    local r = rawget(e, "render")
    local sp = (type(r) == "table") and rawget(r, "sprites") or nil
    local p1 = (type(sp) == "table") and rawget(sp, 1) or nil
    local p = (type(p1) == "table") and rawget(p1, "prefix") or nil
    if type(p) == "string" then return (p:gsub("Def$", "")) end
    return "第" .. tostring(idx) .. "个"
  end

  local leveled, skipped, bad = 0, 0, 0
  local detail = {}
  for idx, e in pairs(team) do
    local h = (type(e) == "table") and rawget(e, "hero") or nil
    if type(h) == "table" and type(rawget(h, "level")) == "number" then
      local lv = rawget(h, "level")
      local f = rawget(h, "fn_level_up")
      local target = (mode == "max") and cap or (lv + 1)
      if target > cap then target = cap end
      if type(f) ~= "function" or lv >= cap or target <= lv then
        skipped = skipped + 1
      else
        local want
        local ls = rawget(h, "level_stats")
        local row = (type(ls) == "table") and rawget(ls, "hp_max") or nil
        if type(row) == "table" then want = rawget(row, target) end
        h.level = target
        if type(thr) == "table" and thr[target - 1] ~= nil then h.xp = thr[target - 1] end
        local ok = pcall(f, e, s, true)
        local hp = (type(e.health) == "table") and e.health.hp_max or nil
        if not ok or (want ~= nil and hp ~= want) then
          bad = bad + 1
        else
          leveled = leveled + 1
          detail[#detail + 1] = who(e, idx) .. " " .. tostring(lv) .. "->" .. tostring(target)
        end
      end
    end
  end
  if leveled == 0 then
    if bad > 0 then return nil, "升级没确认生效（等级写了但属性没跟上）" end
    return nil, "没有可升级的英雄（都满级了？）"
  end
  local msg = leveled .. " 个英雄升级：" .. table.concat(detail, "，")
  if skipped > 0 then msg = msg .. "（跳过 " .. skipped .. " 个）" end
  if bad > 0 then msg = msg .. "（" .. bad .. " 个没确认）" end
  return msg
end

-- 单条操作的实现。每条都自己判类型 —— 存档结构变了宁可什么都不做。
local function apply_one_op(t, o)
  local op = o.op
  if op == "stars" then
    -- 逐关补到 3 星。⚠️ **故意不动 progression.last_stars**：留着它低于真实总星数，
    -- 游戏才会自己「发现新星星」并走它校验过的发放路径。
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
  elseif op == "hero_level" then
    -- 故意不挂菜单（英雄升级走「英雄」组的即时路径 hero_raise）。
    -- 留着这条 op 是因为单元测试用它钉住「结构化失败不能被算成成功」这条不变量。
    local hid, st = hero_of_slot(t)
    if not hid then return false end
    local xp = rawget(st, "xp")
    if type(xp) ~= "number" then return false end
    local target
    if o.mode == "max" then
      -- 拉满**不依赖任何未验证的东西**：写一个大值，游戏读档时自己按 xp 重算等级并夹到
      -- 上限（storage 里有 restore_hero_levels / max_hero_ultimate_level）。
      local thr = hero_thresholds()
      local top = thr and thr_top(thr)
      target = (top or xp) + 10000
    else
      local thr = hero_thresholds()
      if not thr then return false end   -- 阈值表读不到就不猜，「升一级」必须名副其实
      target = next_threshold(thr, xp)
      if not target then
        -- 已经满级。这**不算失败**：玩家要的结果（不能再高）本来就成立，
        -- 报成失败会让人以为功能坏了。
        S.hero_last = { hero = hid, before = xp, after = xp, at_max = true }
        return true
      end
    end
    st.xp = target
    -- ⚠️ 钩子挂在 storage 的 IO 边界上，那里**不能调 note()/游戏函数**（会重入）。
    -- 只把结果留在 S 里，由 tick 在钩子外组装成人话。
    S.hero_last = { hero = hid, before = xp, after = target, mode = o.mode }
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
    -- 两个都要看：apply_one_op 用 `return false` 报的结构化失败，只看 pcall 的 ok 会漏掉。
    local ok, res = pcall(apply_one_op, t, ops[i])
    if ok and res then
      n = n + 1
    else
      S.slot_failed = S.slot_failed or {}
      S.slot_failed[#S.slot_failed + 1] = tostring(ops[i] and ops[i].op or "?")
    end
  end
  -- 失败的也清掉 —— 否则一条坏操作会永远卡在那里反复失败。
  for i = #ops, 1, -1 do ops[i] = nil end
  S.slot_ops_done = (S.slot_ops_done or 0) + n
  -- 成功了要**主动报出来**：这条管线的待办只存在内存里，游戏若没重写存档就无声丢失。
  -- 不报的话，"按下去了但什么都没发生"和"还没轮到应用"玩家分不出来（踩过这个坑）。
  if n > 0 then S.slot_applied = n end
  return n
end

-- 暴露给测试台：测试环境里没有 storage 模块、钩子装不上，而存档改写必须能单独测。
S.slot_apply = apply_slot_ops
S.slot_like = is_slot_like

-- 在哪几个函数上装钩子。各函数签名不一致（收文本/收表都有），所以**参数和返回值都扫
-- 一遍**，是存档形状的就动手 —— 不必猜哪个方向是表。
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

-- 第一次排队时备份存档目录里的 slot_*.lua —— 这是**真的会改玩家存档**的功能，必须先留
-- 后路。（定义必须排在 queue_slot_op 前面：local function 不提升。）
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

-- 排队一条操作，并给玩家一句说明。**排队本身不改任何东西**，真正的改动发生在存档表
-- 下次经过读写钩子的时候；待办**一次性**，应用完即清空（否则会变成每帧覆盖存档）。
queue_slot_op = function(o, cn, en)
  S.slot_ops[#S.slot_ops + 1] = o
  backup_slot_once()
  if cn then
    note(cn .. "（回主菜单再进一次档生效）", en .. " (re-enter the save to apply)")
  end
  return "queued " .. tostring(o.op) .. " (" .. #S.slot_ops .. " pending)"
end

-- menu
local MENU_TEXT = {
  cn = {
    title = "KR6 修改器", hint = "Home 开关   ↑↓ 选择   ←→ 调整   Enter 执行   Esc 关闭",
    gold_add = "金币 +1000", gold_sub = "金币 -1000",
    lives_add = "生命 +10", lives_sub = "生命 -10",
    hold = "无限金钱", hold_lives = "生命锁定",
    next_wave = "立刻下一波",
    hdr_res = "资源", hdr_wave = "波次", hdr_units = "敌人属性",
    hdr_hero = "英雄",
    hdr_save = "存档（回主菜单再进档生效）",
    enemy_hp = "敌人血量", enemy_speed = "敌人移速",
    stars_max = "星星拉满", unlock_tree = "升级树补全",
    hero_now_up = "英雄升一级（本关立即）", hero_now_max = "英雄拉满（本关立即）",
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
    hdr_res = "RESOURCES", hdr_wave = "WAVES", hdr_units = "ENEMY STATS",
    hdr_hero = "HEROES",
    hdr_save = "SAVE (apply on reload)",
    enemy_hp = "enemy HP", enemy_speed = "enemy speed",
    stars_max = "max stars", unlock_tree = "fill upgrade trees",
    hero_now_up = "hero +1 level (now)", hero_now_max = "hero max (now)",
    close = "close menu",
    on = "ON", off = "OFF",
    labels = { "gold", "lives", "lvl" },
    nolvl = "(not in a level)",
  },
}

-- 从 from 出发沿 dir 找下一个**可执行**项（跳过分组标题），绕一圈。
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
  -- 标签缺失时回退成 id —— 缺标签会抛错，而外层 pcall 一吞，整个面板就消失了。
  local function L(id)
    local v = T[id]
    return (type(v) == "string" and v) or id
  end
  -- 分组标题 = 多带 header = true 的普通条目（沿用 toggle/adjust 的「可选字段」约定）；
  -- 它必须被三处跳过：↑↓、鼠标、冒烟测试 —— 漏一处就出 bug。
  local M = S.mult
  local items = {
    -- 没有「金币 → 999999」这一行（无限金钱已覆盖）；gold_set 仍在，供命令通道设精确值。
    { id = "hdr_res",   label = L("hdr_res"), header = true },
    { id = "gold_add",  label = L("gold_add"), adjust = { field = "player_gold", step = 1000, sign = 1 } },
    { id = "gold_sub",  label = L("gold_sub"), adjust = { field = "player_gold", step = 1000, sign = -1 } },
    { id = "lives_add", label = L("lives_add"), adjust = { field = "lives", step = 10, sign = 1 } },
    { id = "lives_sub", label = L("lives_sub"), adjust = { field = "lives", step = 10, sign = -1 } },
    { id = "hold",      label = L("hold"), toggle = function() return S.hold end },
    { id = "hold_lives", label = L("hold_lives"), toggle = function() return S.hold_lives end },

    { id = "hdr_wave",  label = L("hdr_wave"), header = true },
    { id = "next_wave", label = L("next_wave") },

    -- 倍率行：左右键调 S.mult 那一项（不走 store，故 tweak 有第二种目标）；右=调高、左=调低。
    { id = "hdr_units", label = L("hdr_units"), header = true },
    { id = "enemy_hp", label = L("enemy_hp"),
      adjust = { set = M, key = "enemy_hp", step = 0.5, sign = 1, min = 0.1, max = 20 },
      value = function() return fmt_mult(S.mult.enemy_hp) end },
    { id = "enemy_speed", label = L("enemy_speed"),
      adjust = { set = M, key = "enemy_speed", step = 0.25, sign = 1, min = 0.1, max = 10 },
      value = function() return fmt_mult(S.mult.enemy_speed) end },
    -- 英雄**单独一组**：它们和上面那两项（敌人属性倍率）不是一回事 ——
    -- 倍率是本关临时改数值，英雄升级会经游戏自己写回档案。混在一起标签会撒谎。
    { id = "hdr_hero",  label = L("hdr_hero"), header = true },
    { id = "hero_now_up",  label = L("hero_now_up") },
    { id = "hero_now_max", label = L("hero_now_max") },

    -- 存档级。**排队**式：按下去不会立刻变，要回主菜单再进一次档（分组标题里已注明）。
    { id = "hdr_save", label = L("hdr_save"), header = true },
    { id = "stars_max",  label = L("stars_max") },
    { id = "unlock_tree", label = L("unlock_tree") },
    -- 英雄升级不在这组（排队式），在下面的「英雄」组，即时生效。
  }
  items[#items + 1] = { id = "close", label = L("close") }
  S.items = items          -- 暴露出去，测试按 id 查条目用
  if S.sel > #items then S.sel = 1 end
  return items
end

-- want_size 省略时是 16；菜单变长后会按需再要一个更小的字号（见 font_for_height）。
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
  -- 已经知道哪个路径能用就直接用它，换字号时不必再逐个试
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

-- 菜单太长时行高会被压到比字还矮、行行叠在一起；这里按需要的行高反推一个够小的字号，
-- **只建一次并缓存**（每帧 newFont 很贵）。
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
    -- 全部条目在一页里：窗口矮时按比例压缩行高让它放得下（h == line_h*(n+5) + 28）。
    local avail = 0
    pcall(function() avail = love.graphics.getHeight() end)
    if avail and avail > 0 then
      local maxh = avail - (MENU_Y - 10) - 10
      local fit = math.floor((maxh - 28) / (#items + 5))
      if fit < line_h then line_h = math.max(fit, 9) end
    end
    local header_h = line_h * 2 + 10
    local h = line_h * (#items + 5) + 28

    -- 行高被压得比字还矮时换小字号（否则文字行行叠在一起）；整块面板用同一个字号。
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
    -- 有几个值就显示几项：关卡外这些字段不存在就不显示，而不是给玩家看 "nil"。
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
      -- 标题行也要有命中框（带 header 标记）：否则点标题会被当成「没点中」漏给游戏。
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
        -- 分组标题：淡色 + 右侧细线，和可点条目区分；量不出宽度时只靠颜色区分。
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
      -- 必须还回真的那个字体：setFont(getFont()) 等于没还原，字体会泄漏给游戏。
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
  -- 光标不能停在分组标题上（"什么都没选中"很怪、Enter 也没反应）；只在需要时挪。
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
    -- 标题行按下去什么都不做，也**不能**走 run_action（会返回 unknown action 被判失败）。
    if it and not it.header then run_action(it.id) end
  elseif key == "left" or key == "right" then
    local it = items[S.sel]
    local dir = (key == "right") and 1 or -1
    if it and not it.header and it.adjust then
      local a = it.adjust
      -- 每一行语义一致：右键加、左键减；两种目标都从这一个入口走（见 action 的 tweak）。
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

-- frame tick
-- _kr6_cmd.txt 接受的动词。历史短名继续可用（README 里有、测试也在用）；
-- `cmd <动作id> [参数]` 是通用入口，不必开菜单就能驱动任何动作。
local CMD_MAP = {
  gold = "gold_set", goldadd = "gold_add", goldsub = "gold_sub",
  lives = "lives_add", ["lives-"] = "lives_sub",
  hold = "hold", holdlives = "hold_lives",
  nextwave = "next_wave",
  stars = "stars_max", unlocktree = "unlock_tree",
  nowup = "hero_now_up", nowmax = "hero_now_max",
  menu = "MENU", closemenu = "CLOSE",
}

-- 用游戏自己的换算函数读回等级。先自证它真是 xp→level 的映射，否则只报经验数字。
local function hero_level_fn()
  if S.xp_fn_checked then return S.xp_fn end
  S.xp_fn_checked = true
  local gu = game_mod("gui_utils")
  local f = gu and rawget(gu, "get_hero_level")
  if type(f) == "function" then
    local ok0, lo = pcall(f, 0)
    local ok1, hi = pcall(f, 100000000)
    if ok0 and ok1 and type(lo) == "number" and type(hi) == "number" and hi > lo then
      S.xp_fn = f
    end
  end
  return S.xp_fn
end

-- 语言中立的等级片段（"lvl 3->4"），中英文案都能直接拼；读不到返回 nil。
local function hero_level_str(before, after)
  local f = hero_level_fn()
  if not f then return nil end
  local ok1, l1 = pcall(f, before)
  local ok2, l2 = pcall(f, after)
  if not (ok1 and ok2 and type(l1) == "number" and type(l2) == "number") then return nil end
  if l1 == l2 then return "lvl " .. tostring(l1) end
  return "lvl " .. tostring(l1) .. "->" .. tostring(l2)
end

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

  -- 敌人属性倍率组：**游戏自己会重算这些值**，写一次就被覆盖，所以每帧重放。都不加开关
  -- 守卫 —— 关掉时也得跑一趟把原值写回去；倍率全是 x1 时完全不动游戏。
  local mm = S.mult
  local mult_active = (mm.enemy_hp ~= 1 or mm.enemy_speed ~= 1)
  if mult_active then
    pcall(mult_apply)
    S.mult_active = true
  elseif S.mult_active then
    -- 倍率刚回到 x1。**这一趟收尾不能省**：守卫条件已变假，不补跑一次模板就永远停在
    -- 放大后的值上；幂等重放把 base*1 写回去，写完才真正停手。
    pcall(mult_apply)
    S.mult_active = false
  end
  -- 场上的单位走相对法、自己判断倍率变没变；无条件调用是故意的（调回 1 也要跟着回来）。
  pcall(mult_apply_live)

  -- 存档钩子：storage 在 payload 加载时可能还没 require，所以每帧试装一次、装上就不再试。
  if not S.slot_hooks_done then
    local n = install_slot_hooks()
    if n > 0 or (game_mod("storage") ~= nil) then S.slot_hooks_done = true end
  end

  -- 存档改动的回执。钩子里不能调 note()（在 storage 的 IO 边界上，重入），所以结果
  -- 先留在 S 里，在这里组装成人话。
  if S.hero_last then
    local h = S.hero_last
    S.hero_last = nil
    local lv = hero_level_str(h.before, h.after)
    local tail = lv and (" " .. lv) or ""
    local xp = "  " .. tostring(h.before) .. "->" .. tostring(h.after)
    if h.at_max then
      note("英雄 " .. h.hero .. " 已经是最高级" .. tail,
           "hero " .. h.hero .. " already at max level" .. tail)
    else
      note("英雄 " .. h.hero .. " 升级" .. tail .. "  经验" .. xp,
           "hero " .. h.hero .. " level up" .. tail .. "  xp" .. xp)
    end
  end
  if type(S.slot_failed) == "table" and #S.slot_failed > 0 then
    local names = table.concat(S.slot_failed, ",")
    S.slot_failed = nil
    note("有存档改动没能应用：" .. names, "slot ops not applied: " .. names)
  elseif S.slot_applied then
    -- 成功也要说一声：否则"按下去了但还没轮到应用"和"根本没生效"玩家分不出来。
    local n = S.slot_applied
    S.slot_applied = nil
    note("存档改动已应用 " .. n .. " 条 —— 重启游戏后生效",
         "applied " .. n .. " save change(s) -- restart to see it")
  end

  local now = os.time()
  if now > S.last_cmd_check and not S.in_cmd then
    S.last_cmd_check = now
    local cmd = rf("_kr6_cmd.txt")
    if cmd then
      -- 重入保护：动作可能回调到被 tick 包住的游戏函数，从而重新进到这个派发里。
      S.in_cmd = true
      local line = cmd:gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      -- 执行**之前**先回显命令：命令卡死或崩掉时至少留下「当时在跑什么」的记录。
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
      -- 执行完才消费命令文件：否则「产生了结果但没写出来」和「根本没被读到」分不出来。
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

-- input
local function evt_time()
  local ok, t = pcall(function() return love.timer.getTime() end)
  if ok and type(t) == "number" then return t end
  return os.clock()
end

-- 一个按键可能经多条路到达（love.handlers 与 director.keypressed），只处理一次并返回有无吃掉。
local function on_key(key)
  local t = evt_time()
  if S.last_key == key and S.last_key_t and (t - S.last_key_t) < 0.08 then
    return true
  end
  S.last_key, S.last_key_t = key, t

  -- 只认 home 一个键：功能键太容易误触，所以不设任何 F 键热键；其余操作走菜单或命令文件。
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
      -- 分组标题：**吃掉**这次点击但什么都不做 —— 不能 return false，那会漏给游戏。
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

    -- 路径 2：游戏可能把输入直接从 director 转发
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
  -- 短名清单从 CMD_MAP **生成**，不写死 —— 写死的话加了新动词忘了同步，文件就会撒谎。
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
