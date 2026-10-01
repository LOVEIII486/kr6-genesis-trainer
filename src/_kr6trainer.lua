-- kr6 游戏内修改器。
--
-- 装载：覆盖桩 all/director.lua 先从 _orig/ 读回游戏自己的字节码，再把模块表交到这里。
-- 本文件全部代码包在 pcall 里。
--
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
    fired = {}, hooks = {}, wrap_src = {}, tick_source = nil,
    hold = false, hold_lives = false, last_level_check = 0, mult_tag = nil,
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
-- 技能无 CD 的三个开关（分开的，各自定位目标，见 apply_nocd）
if type(S.nocd) ~= "table" then
  S.nocd = { power = false, hero = false, tower = false }
end
-- 被清掉的原值。**必须记**：清的是"冷却时长"，游戏不会自己写回去，不记就恢复不了。
-- 弱键，对象回收即释放。
if type(S.nocd_base) ~= "table" then
  S.nocd_base = setmetatable({}, { __mode = "k" })
end
-- 击杀金币倍率（**最低 1，即完全不动**）与基线（基线按倍率表的键记，见 gold_push）
if type(S.gold) ~= "table" then S.gold = { mult = 1 } end
if type(S.gold.mult) ~= "number" then S.gold.mult = 1 end
if type(S.gold_base) ~= "table" then S.gold_base = {} end
-- 整体速度。这里存的只是意图值，真正生效的是每帧写进**游戏自己的** game.DBG_TIME_MULT
-- （见 speed_apply）—— 那个字段发行版里没人碰，而 game:update 每帧读它。
if type(S.speed) ~= "table" then S.speed = { mult = 1 } end
if type(S.speed.mult) ~= "number" then S.speed.mult = 1 end
-- 防御塔的四项倍率（射程 / 攻速 / 伤害 / 技能CD），以及「每座塔已经乘上去的倍率」。
-- 弱键：塔被拆或升级后表被回收，记录跟着释放，不会越攒越多。
if type(S.tower) ~= "table" then S.tower = { range = 1, rate = 1, damage = 1, cd = 1 } end
if type(S.tower.range) ~= "number" then S.tower.range = 1 end
if type(S.tower.rate) ~= "number" then S.tower.rate = 1 end
if type(S.tower.damage) ~= "number" then S.tower.damage = 1 end
if type(S.tower.cd) ~= "number" then S.tower.cd = 1 end
if type(S.tower_seen) ~= "table" then
  S.tower_seen = setmetatable({}, { __mode = "k" })
end
-- 英雄的四项倍率（血量 / 伤害 / 攻速 / 技能CD）。**单开一张表，不复用 S.mult** ——
-- mult_apply_live 与换关复位都写死了 enemy_hp / enemy_speed 两个键，塞进去会被当成没变化。
if type(S.hero) ~= "table" then S.hero = { hp = 1, damage = 1, rate = 1, cd = 1 } end
if type(S.hero.hp) ~= "number" then S.hero.hp = 1 end
if type(S.hero.damage) ~= "number" then S.hero.damage = 1 end
if type(S.hero.rate) ~= "number" then S.hero.rate = 1 end
if type(S.hero.cd) ~= "number" then S.hero.cd = 1 end
-- 每一项各记「已经乘上去的倍率」。一律弱键，实体被游戏回收后跟着释放。
if type(S.hero_seen) ~= "table" then S.hero_seen = setmetatable({}, { __mode = "k" }) end
if type(S.tower_cd_seen) ~= "table" then S.tower_cd_seen = setmetatable({}, { __mode = "k" }) end
if type(S.hero_bullet_seen) ~= "table" then S.hero_bullet_seen = setmetatable({}, { __mode = "k" }) end
-- 动画 sprite 被我们改过的 fps **原值**。还原时必须写回原值、不能写 nil —— 模板里有
-- 非 nil 的 fps（templates_game.lua 两处），写 nil 会改掉那两处的游戏行为。
if type(S.anim_base) ~= "table" then S.anim_base = setmetatable({}, { __mode = "k" }) end
-- 每个模板的攻击动画名集合（按模板名缓存：动画名来自模板，不随实体变，也不会过期）
if type(S.anim_groups) ~= "table" then S.anim_groups = {} end
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
local game_mod, scale_table, mult_apply, mult_apply_live, queue_slot_op
local na, hero_thresholds, power_thresholds, hero_raise
local nocd_restore
local gold_factor_tbl, gold_pop, install_gold_hook
local anim_apply, install_anim_hook, hero_bullet_apply, unlock_achievements

-- 新增七项可调倍率的只读查询表（给 action 用）。⚠️ 存的是**引用**（set 指向 S 上的表），
-- 值在调用那一刻才读 —— 存值会永远停在初始的 x1。
-- 可调行本身没有"执行"语义，但每个菜单项都必须能用空参调用一次（冒烟测试会跑遍全菜单）。
local MULT_NEW_ROWS = {
  { "tower_damage",   S.tower, "damage", "塔伤害",     "tower damage" },
  { "tower_atkspd",   S.tower, "rate",   "塔攻速",     "tower attack speed" },
  { "tower_skill_cd", S.tower, "cd",     "塔技能CD",   "tower skill cd" },
  { "hero_hp",        S.hero,  "hp",     "英雄血量",   "hero HP" },
  { "hero_damage",    S.hero,  "damage", "英雄伤害",   "hero damage" },
  { "hero_atkspd",    S.hero,  "rate",   "英雄攻速",   "hero attack speed" },
  { "hero_skill_cd",  S.hero,  "cd",     "英雄技能CD", "hero skill cd" },
}
local MULT_NEW_BY_ID = {}
for i = 1, #MULT_NEW_ROWS do MULT_NEW_BY_ID[MULT_NEW_ROWS[i][1]] = MULT_NEW_ROWS[i] end

-- 倍率行的**档位表**（←→ 与滑条都从这里取值）。值只能取自表里，所以往下再往上必然精确
-- 回到原值 —— 加法步长 + 下限夹取会漂（x1 往下停在 0.1，再往上永远回不到 1.0）。
-- ⚠️ 必须写**精确字面量**：算式（1 + 0.5）会攒出 0.30000000000000004，下面的相等判断匹配不上。
local MULT_STEPS = {
  0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1,
  1.5, 2, 3, 4, 5, 6, 7, 8, 9, 10,
}

-- 「整体速度」**专用**的档位表，不能复用 MULT_STEPS：game:update 用的是数值 for
-- （`for i = 1, mult`），非整数且 >1 只跑一轮 = x1 —— 表里那个 1.5 会静默失效。
-- <1 走的是另一条分支（dt 缩放），是慢放。
local SPEED_STEPS = { 0.5, 1, 2, 3, 4 }
local SPEED_OK = { [0.5] = true, [1] = true, [2] = true, [3] = true, [4] = true }

-- 行自己的档位表；没写就用通用那张。
local function steps_of(a)
  return (a and a.steps) or MULT_STEPS
end

-- 本行可用的档位下标区间（表是升序的，过滤掉范围外的之后仍是一段连续区间）
local function ladder_range(steps, lo, hi)
  local i0, i1 = 1, #steps
  if lo then while i0 <= #steps and steps[i0] < lo do i0 = i0 + 1 end end
  if hi then while i1 >= 1 and steps[i1] > hi do i1 = i1 - 1 end end
  return i0, i1
end

-- cur 落在 [i0,i1] 里的第几档（不在表上就取最近的一档；相等时取靠下的那个）。
local function ladder_nearest(steps, cur, i0, i1)
  local idx, bestd = i0, nil
  for j = i0, i1 do
    local d = math.abs(steps[j] - cur)
    if bestd == nil or d < bestd then bestd, idx = d, j end
  end
  return idx
end

-- 在档位表里移动 d 格。cur 不在表上时（旧版本注入留下的值）先吸附到最近的一档。
local function ladder_move(steps, cur, d, lo, hi)
  local i0, i1 = ladder_range(steps, lo, hi)
  if i1 < i0 then return cur end
  local i = ladder_nearest(steps, cur, i0, i1) + (d or 0)
  if i < i0 then i = i0 elseif i > i1 then i = i1 end
  return steps[i]
end

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
  elseif id == "gold_mult" then
    -- 可调行没有"执行"语义，但每个菜单项必须能用空参调用一次（冒烟测试会跑遍全菜单），
    -- 所以给一个**只读**查询；调整走 ←→（tweak 的第二种目标，见 menu_items 里的 adjust）。
    local v = S.gold.mult
    local r = "击杀金币 x" .. tostring(v) .. "（←→ 调整，最低 x1）"
    note(r, "kill gold x" .. tostring(v) .. " (left/right, min x1)")
    return r
  elseif id == "game_speed" then
    -- 同 gold_mult：可调行没有"执行"语义，给一个只读查询（冒烟测试会空参跑一遍全菜单）。
    local v = S.speed.mult
    local r = "游戏速度 x" .. tostring(v) .. "（←→ 调整）"
    note(r, "game speed x" .. tostring(v) .. " (left/right)")
    return r
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
      -- 倍率行走**档位表**：arg.delta 是档位序号的增量（±1，见 menu_key），不是数值增量。
      -- 值只能取自表里，所以不会像加法步长那样漂（往下再往上回不到 1.0）。
      local cur = tonumber(arg.set[arg.key]) or 1
      local v = ladder_move(steps_of(arg), cur, arg.delta, arg.min, arg.max)
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
    return queue_slot_op({ op = "tree" }, "塔树升满", "max tower trees")
  elseif id == "power_max" then
    return queue_slot_op({ op = "power_max" }, "法术升满", "max powers")
  elseif id == "nocd_power" or id == "nocd_hero" or id == "nocd_tower" then
    -- 即时生效：打开后 tick 每帧清零，1 秒后播报清了几个（自检）。
    local key = id:sub(6)                       -- power / hero / tower
    local v = not S.nocd[key]
    S.nocd[key] = v
    if v then
      S.nocd_report, S.nocd_since = true, os.time()
    else
      -- 关掉就**把原值写回去**：清的是"冷却时长"，游戏不会自己重写，不还原就会"关了还在连放"。
      nocd_restore()
    end
    local cn = ({ power = "法术", hero = "英雄技能", tower = "塔技能" })[key] or key
    local r = cn .. "无CD: " .. (v and "开" or "关")
    note(r, key .. " no cooldown: " .. (v and "on" or "off"))
    return r
  elseif id == "ach_unlock" then
    local msg, why = unlock_achievements()
    if not msg then
      local r = na(why)
      note(r) return r
    end
    note(msg) return msg
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
  elseif id == "tower_range" then
    -- 和 enemy_hp / enemy_speed 同款：可调行本身没有"执行"语义，给一个**只读**查询
    -- （冒烟测试会用空参跑遍全菜单），调整走 ←→。
    local v = S.tower.range
    local r = "塔射程 x" .. tostring(v) .. "（←→ 调整）"
    note(r, "tower range = x" .. tostring(v))
    return "tower_range = x" .. tostring(v)
  elseif MULT_NEW_BY_ID[id] then
    -- 和 enemy_hp / tower_range 同款：只读查询，调整走 ←→，误触 Enter 不该改数值。
    local row = MULT_NEW_BY_ID[id]
    local v = row[2][row[3]]
    local r = row[4] .. " x" .. tostring(v) .. "（←→ 调整）"
    note(r, id .. " = x" .. tostring(v))
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

-- 击杀金币倍率。击杀与漏怪共用同一张倍率表，但各自在函数开头读一次、落在两个系统里
-- （sys.health:on_update ← 击杀 / sys.goal_line:on_update ← 漏怪），所以只在击杀那一趟
-- 临时改表就够，漏怪读到的还是原值。倍率 1 时完全不动游戏。
-- ⚠️ 别改成 enemy.gold（数值来源，退款路径不读倍率表）或 hand_of_midas_factor（会重播金币动画）。
local GOLD_FACTOR_TBL = "gold_enemy_factor_per_mode"

gold_factor_tbl = function()
  local GS = game_mod("game_settings")
  local t = (type(GS) == "table") and rawget(GS, GOLD_FACTOR_TBL) or nil
  return (type(t) == "table") and t or nil
end

-- 表 → 基线 × 倍率。基线只在第一次见面时记（游戏自己从不写这张表，写点为零）。
local function gold_push()
  local t = gold_factor_tbl()
  if not t then return nil end
  local m = S.gold.mult
  for k, v in pairs(t) do
    if type(v) == "number" then
      if S.gold_base[k] == nil then S.gold_base[k] = v end
      local want = S.gold_base[k] * m
      if v ~= want then t[k] = want end
    end
  end
  return t
end

-- 还原成基线。传进来的表为 nil 时什么都不做。
gold_pop = function(t)
  if type(t) ~= "table" then return end
  for k, v in pairs(S.gold_base) do
    if t[k] ~= v then t[k] = v end
  end
end

install_gold_hook = function()
  if S.gold_hook_done then return false end
  local sys = game_mod("systems")
  local h = (type(sys) == "table") and rawget(sys, "health") or nil
  local orig = (type(h) == "table") and rawget(h, "on_update") or nil
  if type(orig) ~= "function" then return false end
  S.gold_hook_done = true
  rawset(h, "on_update", function(...)
    -- 倍率 1 = 完全不动游戏（也就不必还原），这条短路是热路径上的主要开销
    if S.gold.mult == 1 then return orig(...) end
    local t = gold_push()
    -- 出错也要还原：否则表永远停在 ×2 上，漏怪金币也跟着翻倍。
    local ok, a, b, c, d = pcall(orig, ...)
    gold_pop(t)
    if not ok then error(a) end
    return a, b, c, d
  end)
  S.hooks[#S.hooks + 1] = "systems.health.on_update(gold x2)"
  return true
end

-- 敌人字段的真实路径 —— **都在子表里**，不在模板/实体顶层：
--   模板 t.health.hp_max / t.motion.max_speed；活实体 e.health.hp_max / e.motion.max_speed
-- ⚠️ 这几项每帧重放，**绝不能碰当前血量**（每帧写回 = 打不死）。
local ENEMY_HP_FIELDS    = { hp_max = true }
local ENEMY_SPEED_FIELDS = { max_speed = true, speed_limit = true, speed = true }

-- 把属于 fields 的 number 字段缩放到 base*mult，返回改了几个。基线记进 S.mult_base：
-- 游戏自己的 patch_templates 是**原地乘**，不记基线的话每帧反复调会复合（翻倍再翻倍）。
scale_table = function(t, fields, mult)
  if type(t) ~= "table" then return 0 end
  local base = S.mult_base[t]
  if not base then base = {} S.mult_base[t] = base end
  local n = 0
  for k, v in pairs(t) do
    if fields[k] and type(v) == "number" then
      -- 基线只记一次；**记到非数字时要重记** —— 模板上的 hp_max 在关卡初始化时会被
      -- difficulty:patch_templates 从「按难度分的数组」就地换成数字，那一刻类型会变。
      if type(base[k]) ~= "number" then base[k] = v end
      local want = base[k] * mult
      -- 只写确实不同的：稳定后这里是纯读，不搅动游戏的表
      if t[k] ~= want then t[k] = want n = n + 1 end
    end
  end
  return n
end

-- ⚠️ 别在这加"缩数组字段"的版本：模板上的 hp_max 在关卡初始化时会被 difficulty:patch_templates
-- 从数组**就地换成数字**，先缩数组再缩换出来的数字就是平方。

-- 遍历 entity_db 里的模板，每个调一次 fn，返回**访问到的个数**（不是 fn 返回值之和）。
-- 不用 filter_templates()：它每次都新建一张全模板表（2054 项）。
local function each_template(edb, fn)
  if type(edb) ~= "table" then return 0 end
  local reg = rawget(edb, "entities")
  if type(reg) ~= "table" then
    -- 兜底：万一将来改名，退回游戏自己的过滤器（等价于遍历同一张表，只是多分配一次）
    if type(edb.filter_templates) ~= "function" then return 0 end
    local ok, list = pcall(edb.filter_templates, edb)
    if not ok or type(list) ~= "table" then return 0 end
    local seen = 0
    for i = 1, #list do
      local t = list[i]
      if type(t) == "table" then seen = seen + 1 fn(t) end
    end
    return seen
  end
  local seen = 0
  for _, t in pairs(reg) do
    if type(t) == "table" then seen = seen + 1 fn(t) end
  end
  return seen
end

-- 每帧重放所有倍率。**只写模板，绝不写 balance** —— 模板每关开头从 balance 重建，
-- 两边都写下一关就变平方。只写模板还让关内的改动立刻对新出场的敌人生效。
mult_apply = function()
  local m = S.mult
  local hp, sp = m.enemy_hp, m.enemy_speed
  local n = 0

  local edb = game_mod("entity_db")
  each_template(edb, function(t)
    local nm = tostring(rawget(t, "template_name") or rawget(t, "name") or "")
    if nm:sub(1, 6) == "enemy_" then
      local hl = rawget(t, "health")
      if type(hl) == "table" then n = n + scale_table(hl, ENEMY_HP_FIELDS, hp) end
      local mo = rawget(t, "motion")
      if type(mo) == "table" then n = n + scale_table(mo, ENEMY_SPEED_FIELDS, sp) end
    end
  end)

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

-- 技能无CD。**冷却不在 store 的直接字段上**，三类各有各的位置（探针实测）：
--   法术 power_<id>_control 实体的直接字段；英雄 hero 实体（带 .hero 的）的 timed_attacks / hero.skills；
--   塔　 tower_<名>_lvl<N> 实体的 attacks / timed_attacks。
-- 三类都是「找到实体 → 进技能容器 → 把计时字段清零」，基础攻击不在容器里（见下面 clear_entity_cds）。
local CD_FIELDS = {
  cd = true, ["_cd"] = true, cooldown = true, ts = true, ["_ts"] = true,
  next = true, next_ts = true, timer = true, time_left = true,
  cooldown_left = true, delay = true, remaining = true, remained = true,
}
local CD_CONTAINERS = { "attacks", "timed_attacks", "skills", "main_script" }

-- 走进容器把计时字段清零。seen 数的是**看到几个候选字段（不管值是多少）** —— 只数
-- "值 > 0" 的会分不出「没有这种字段」和「字段恰好在 0」。
-- 记下原值再写掉；同一个字段只记第一次（那次才是游戏自己的值）。
local function cd_set(obj, k, v)
  local box = S.nocd_base[obj]
  if not box then box = {} S.nocd_base[obj] = box end
  if box[k] == nil then box[k] = rawget(obj, k) end
  obj[k] = v
end

-- 关掉任一个开关时把记下的原值全部写回（还开着的那些下一帧会重新清）
nocd_restore = function()
  local n = 0
  for obj, box in pairs(S.nocd_base) do
    if type(obj) == "table" then
      for k, v in pairs(box) do
        obj[k] = v
        n = n + 1
      end
    end
  end
  S.nocd_base = setmetatable({}, { __mode = "k" })
  return n
end

-- 基础攻击的判据 —— 引擎自己就用这个标记（模板给普攻打 basic_attack = true，
-- 游戏自己的 reset_cooldowns_of_attacks 也只看它）。
-- ⚠️ 必须**整张 list 一起看**：炮塔的真普攻可能在 list[2]，营寨的 list[1] 反而是技能。
-- 规则：list 里有一条打了标记就只认标记；一条都没有才按位置兜底成第 1 条。
-- 返回 (条目数, 带标记的条目数)，调用方用 marked > 0 决定走哪条路。
local function list_marks(list)
  local n, marked = 0, 0
  for _, at in pairs(list) do
    if type(at) == "table" then
      n = n + 1
      if rawget(at, "basic_attack") ~= nil then marked = marked + 1 end
    end
  end
  return n, marked
end

local function is_basic_atk(at, i, any_marked)
  if any_marked then return rawget(at, "basic_attack") == true end
  return i == 1
end

local function clear_container(node, acc, depth, skip)
  if type(node) ~= "table" or depth > 2 then return end
  for k, v in pairs(node) do
    if type(v) == "number" then
      if type(k) == "string" and CD_FIELDS[k] then
        acc.seen = acc.seen + 1
        if v ~= 0 then cd_set(node, k, 0) acc.cleared = acc.cleared + 1 end
      end
    elseif type(v) == "table" then
      if not (skip and skip[v]) then clear_container(v, acc, depth + 1, skip) end
    end
  end
end

-- 实体的技能容器：英雄的在 .hero、防御塔的在 .tower（实体自己那层没有）。
local function clear_entity_cds(e, acc)
  local nodes = { e }
  for i = 1, 2 do
    local sub = rawget(e, i == 1 and "hero" or "tower")
    if type(sub) == "table" then nodes[#nodes + 1] = sub end
  end
  for i = 1, #nodes do
    for j = 1, #CD_CONTAINERS do
      local name = CD_CONTAINERS[j]
      local c = rawget(nodes[i], name)
      if type(c) == "table" then
        local skip
        if name == "attacks" then
          -- ⚠️ **跳过基础攻击**：塔的普攻节奏归「塔攻速」那一项管。
          -- 旧版把 attacks 整片清（含 `list[1].cooldown`），把普攻节奏也清零了 ——
          -- 和上面那句"只动容器内部、天然不碰基础攻击"的注释正好相反。
          local list = rawget(c, "list")
          if type(list) == "table" then
            local _, marked = list_marks(list)
            skip = {}
            for k, at in pairs(list) do
              if type(at) == "table" and is_basic_atk(at, k, marked > 0) then skip[at] = true end
            end
          end
        end
        clear_container(c, acc, 0, skip)
      end
    end
  end
end

local function tpl_name(e)
  local nm = rawget(e, "template_name")
  return (type(nm) == "string") and nm or ""
end

-- 塔 / 英雄的判据。
-- 英雄扫 store.entities、不看 store.hero_team：剧情英雄（alleria / blackburn / denas）
-- 走 LU.insert_hero，那条路**不写** hero_team（只有 insert_hero_kr5 才写），
-- 只看 hero_team 会静静漏掉它们。
local function is_tower(e)
  local nm = tpl_name(e)
  if nm:sub(1, 6) ~= "tower_" or nm:find("holder", 1, true) then return false end
  -- ⚠️ 光看名字前缀不够：`tower_stage_*` 也是 tower_ 开头，但那是**敌人/机关的塔**
  -- （8 关打玩家单位的守方弩炮、16 关的树人、13 关的日光塔）。调「塔攻速/伤害」会把
  -- 它们一起调 —— 玩家等于在给敌人上 buff。游戏自己的判据是 `tower.can_be_mod`
  -- （组件默认 true，这类模板显式置 false：kr6/templates_game.lua:12015/12054/12449…）。
  local t = rawget(e, "tower")
  if type(t) == "table" then
    if rawget(t, "can_be_mod") == false then return false end
    local ty = rawget(t, "type")
    if ty == "holder" or ty == "build_animation" then return false end
  end
  return true
end

local function is_hero(e)
  return type(rawget(e, "hero")) == "table"
end

-- 法术冷却：冷却**时长**在每个法术按钮自己身上 ——
--   game_gui._ingame_fit_width_y0.powers_view.view.children[i].cooldown_time（施放时从 2 跳到 20 秒）
-- ⚠️ 按钮上的 tm.phase 是每帧重算的进度，写它没用（进度条闪一下），要清的是时长本身。
-- tm 里那份按英雄 / 塔同一套规则一起清。
local POWER_CD_FIELDS = { "cooldown_time", "cooldown", "cooldown_max", "cooldown_min" }

local function clear_button_list(kids, acc)
  if type(kids) ~= "table" then return end
  for i = 1, 6 do
    local b = kids[i]
    if type(b) == "table" then
      acc.seen = acc.seen + 1
      for _, k in ipairs(POWER_CD_FIELDS) do
        local v = rawget(b, k)
        if type(v) == "number" and v > 0 then
          cd_set(b, k, 0)
          acc.cleared = acc.cleared + 1
        end
      end
      local tm = rawget(b, "tm")
      if type(tm) == "table" then clear_container(tm, acc, 0) end
    end
  end
end

-- 从 game_gui 里找到法术按钮那一排
local function clear_power_buttons(acc)
  local gg = game_mod("game_gui")
  if type(gg) ~= "table" then return end
  local row = rawget(gg, "_ingame_fit_width_y0")
  local pv = type(row) == "table" and rawget(row, "powers_view") or nil
  local view = type(pv) == "table" and rawget(pv, "view") or nil
  clear_button_list(type(view) == "table" and rawget(view, "children") or nil, acc)
end


-- 返回 {power={seen,cleared}, hero=..., tower=...}，按类播报（自检）。
local function apply_nocd()
  local by = { power = { seen = 0, cleared = 0 }, hero = { seen = 0, cleared = 0 },
               tower = { seen = 0, cleared = 0 } }
  local s = store_of()
  if not s then return by end
  if S.nocd.hero then
    each_entity(s, function(e)
      if is_hero(e) then clear_entity_cds(e, by.hero) end
      return 0
    end)
  end
  if S.nocd.tower then
    each_entity(s, function(e)
      if is_tower(e) then clear_entity_cds(e, by.tower) end
      return 0
    end)
  end
if S.nocd.power then
    clear_power_buttons(by.power)   -- 实测有效：清按钮上的冷却时长
  end
  return by
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










-- 防御塔的四项倍率：射程 / 攻速 / 伤害 / 技能CD。字段都在**活塔实体**上、选敌那一刻现读：
--   a.range / a.list[i].cooldown / a.list[i].shoot_time / e.tower.damage_factor
-- ⚠️ **不是** balance.towers.<名>.stats.*：那个只喂 UI 数字，改了只有面板变。
-- ⚠️ 伤害也**不是**改子弹模板：法师 brilliance 会在建 / 拆塔时从 _orig_* 重算整片模板。
-- 攻速受**射击动画时长**卡着（周期 = max(cooldown, 动画时长)），必须三层一起改：
-- 冷却 + 动画 fps + shoot_time（前摇是绝对秒数，x2 以上立刻撞上；②③ 同系数缩才对得上）。
-- 一律**相对缩放、不记基线** —— 游戏的 range_factor 是乘法 buff，记基线会把 buff 期间的值
-- 错记成基线；记「已乘上去的倍率」还能天然覆盖塔升级重建实体。
local TOWER_ONE = { range = 1, rate = 1, damage = 1 }

-- 把 from 的倍率换成 to 的（乘一次差值）。攻速是"越大越快"，落在冷却 / 前摇上要取倒数。
local function tower_rescale(e, from, to)
  local a = rawget(e, "attacks")
  if type(a) == "table" then
    if type(a.range) == "number" and to.range ~= from.range then
      a.range = a.range * (to.range / from.range)
    end
    local fc = from.rate / to.rate          -- 冷却该乘的倍数 = 攻速倍数的倒数
    if fc ~= 1 then
      -- ⚠️ **容器级**的 attacks.cooldown 也要缩：炮塔 / 树人 / 炼金 / 三管炮这 4 座的门控读的是
      -- 它、不是 list[1]。不缩这个，它们的周期就死卡在原冷却上，菜单调到 x10 也没用。
      if type(a.cooldown) == "number" then a.cooldown = a.cooldown * fc end
      local list = rawget(a, "list")
      -- pairs 不用 #：容器形状没实证，稀疏表的 `#` 会返回 0
      if type(list) == "table" then
        local _, marked = list_marks(list)
        for i, at in pairs(list) do
          -- 只动**基础攻击**，技能那几条归「塔技能CD」管 —— 两边用的是同一套判据，
          -- 正好互补，谁都碰不到对方那条（各判各的会让技能被缩两次、系数相消）。
          if type(at) == "table" and is_basic_atk(at, i, marked > 0) then
            if type(at.cooldown) == "number" then at.cooldown = at.cooldown * fc end
            if type(at.shoot_time) == "number" then at.shoot_time = at.shoot_time * fc end
          end
        end
      end
    end
  end
  -- 伤害在 .tower 子表上（attacks 里没有这个字段）
  if to.damage ~= from.damage then
    local t = rawget(e, "tower")
    if type(t) == "table" and type(t.damage_factor) == "number" then
      t.damage_factor = t.damage_factor * (to.damage / from.damage)
    end
  end
end

local function tower_apply()
  local s = store_of()
  if not s then return 0 end
  local want = S.tower
  local n = 0
  each_entity(s, function(e)
    if is_tower(e) then
      local got = S.tower_seen[e]
      -- 逐字段兜底：S 跨次注入存活，旧版代码写下的记录可能没有 damage 这一格，
      -- 直接比会把 nil 当"不同"，再拿它做 `1 / nil` 算术 → 整趟 each_entity 中断。
      local g = { range = (got and got.range) or 1, rate = (got and got.rate) or 1,
                  damage = (got and got.damage) or 1 }
      -- 比**值**不比表：存的是副本，同一张表比较恒不相等，会每帧重乘
      if not got or g.range ~= want.range or g.rate ~= want.rate
         or g.damage ~= want.damage then
        tower_rescale(e, g, want)
        S.tower_seen[e] = { range = want.range, rate = want.rate, damage = want.damage }
        n = n + 1
      end
    end
    return 0
  end)
  return n
end

-- 防御塔技能冷却倍率。与「塔技能无CD」开关是**两套独立状态**（那个是清零 + 记原值还原）。
--   1. attacks.list[1] 是**基础攻击**，归攻速管，这里跳过。
--   2. static_cooldown 的条目跳过（游戏自己的重置逻辑也排除它们）。
--   3. attacks.min_cooldown 是**第二层地板**（法师塔共享），不缩它技能有硬顶。
-- wildcat 之类每帧从 powers.skill_X.cooldown[级] 重拷 → 源和派生都要缩，只缩派生会被覆盖回原样。
local function tower_cd_scale(e, f)
  local n = 0
  local function scale_at(at)
    if type(at) ~= "table" or rawget(at, "static_cooldown") == true then return end
    local cd = rawget(at, "cooldown")
    if type(cd) == "number" then at.cooldown = cd * f n = n + 1 end
  end
  local a = rawget(e, "attacks")
  if type(a) == "table" then
    local mn = rawget(a, "min_cooldown")
    if type(mn) == "number" then a.min_cooldown = mn * f n = n + 1 end
    local list = rawget(a, "list")
    if type(list) == "table" then
      -- **只动技能**：基础攻击那几条归「塔攻速」管（与上面同一套判据的补集）
      local _, marked = list_marks(list)
      for i, at in pairs(list) do
        if not is_basic_atk(at, i, marked > 0) then scale_at(at) end
      end
    end
  end
  local ta = rawget(e, "timed_attacks")
  local tl = type(ta) == "table" and rawget(ta, "list") or nil
  if type(tl) == "table" then
    for _, at in pairs(tl) do scale_at(at) end
  end
  -- powers.skill_X.cooldown：可能是数字，也可能是**按等级索引的表**（wildcat 那种源）
  local p = rawget(e, "powers")
  if type(p) == "table" then
    for _, v in pairs(p) do
      if type(v) == "table" then
        local cd = rawget(v, "cooldown")
        if type(cd) == "number" then
          v.cooldown = cd * f n = n + 1
        elseif type(cd) == "table" then
          for j, x in pairs(cd) do
            if type(x) == "number" then cd[j] = x * f n = n + 1 end
          end
        end
      end
    end
  end
  return n
end

local function tower_cd_apply()
  -- 「塔技能无CD」开着时整个跳过：那些字段现在被清成 0，乘什么都没意义；更要紧的是
  -- **不能记** —— 记了我们就会以为已经缩过，等开关关掉把原值写回后倍率静默失效。
  if S.nocd.tower then return 0 end
  local s = store_of()
  if not s then return 0 end
  local want = S.tower.cd
  local n = 0
  each_entity(s, function(e)
    if is_tower(e) then
      local got = S.tower_cd_seen[e]
      if got == nil then got = 1 end
      if got ~= want then
        tower_cd_scale(e, want / got)
        S.tower_cd_seen[e] = want
        n = n + 1
      end
    end
    return 0
  end)
  return n
end

-- 英雄四项倍率：血量 / 伤害 / 攻速 / 技能CD。判据是「实体带 .hero」（含剧情英雄）。
-- 血量 / 攻速 / 技能CD 都会被游戏自己重写（升级回调 fn_level_up），所以一律**相对缩放**：
--   血量 health.hp_max + hp（成对）+ hero.level_stats.hp_max[]（升级是从这张数组重写的）
--   伤害 unit.damage_factor（引擎级总倍率）
--   攻速 容器级 cooldown + 基础攻击的 cooldown / hit_time（前摇是绝对秒数，第二层地板）
--   CD   timed_attacks.list 的**全部**条目 —— 下标不固定（gerald 的 [1] 是 skill_a，zefira 的 [1] 是大招）
local HERO_ONE = { hp = 1, damage = 1, rate = 1, cd = 1 }
local HERO_ATK_CONT = { "melee", "ranged", "ultimate_melee" }

local function hero_rescale(e, from, to)
  local n = 0
  if to.hp ~= from.hp then
    local f = to.hp / from.hp
    local h = rawget(e, "health")
    if type(h) == "table" then n = n + scale_health(h, f) end
    local hero = rawget(e, "hero")
    local ls = type(hero) == "table" and rawget(hero, "level_stats") or nil
    local row = type(ls) == "table" and rawget(ls, "hp_max") or nil
    if type(row) == "table" then
      for i, v in pairs(row) do
        if type(v) == "number" then row[i] = v * f n = n + 1 end
      end
    end
  end
  if to.damage ~= from.damage then
    local u = rawget(e, "unit")
    if type(u) == "table" and type(u.damage_factor) == "number" then
      u.damage_factor = u.damage_factor * (to.damage / from.damage)
      n = n + 1
    end
    -- 不认 unit.damage_factor 的那几支子弹要另走模板（见 hero_bullet_apply）
    n = n + hero_bullet_apply(e, to.damage)
  end
  if to.rate ~= from.rate then
    local fc = from.rate / to.rate
    for i = 1, #HERO_ATK_CONT do
      local c = rawget(e, HERO_ATK_CONT[i])
      if type(c) == "table" then
        local cc = rawget(c, "cooldown")
        if type(cc) == "number" then c.cooldown = cc * fc n = n + 1 end
        local list = rawget(c, "list") or rawget(c, "attacks")
        if type(list) == "table" then
          -- 同样只动基础攻击（melee.attacks[2] 常是 special_attack，没这个标记）
          local _, marked = list_marks(list)
          for i, at in pairs(list) do
            if type(at) == "table" and rawget(at, "disabled") ~= true
               and is_basic_atk(at, i, marked > 0) then
              if type(at.cooldown) == "number" then at.cooldown = at.cooldown * fc n = n + 1 end
              if type(at.hit_time) == "number" then at.hit_time = at.hit_time * fc n = n + 1 end
              if type(at.shoot_time) == "number" then at.shoot_time = at.shoot_time * fc n = n + 1 end
            end
          end
        end
      end
    end
  end
  if to.cd ~= from.cd then
    local f = to.cd / from.cd
    local ta = rawget(e, "timed_attacks")
    local list = type(ta) == "table" and rawget(ta, "list") or nil
    if type(list) == "table" then
      for _, at in pairs(list) do
        if type(at) == "table" and rawget(at, "disabled") ~= true
           and type(rawget(at, "cooldown")) == "number" then
          at.cooldown = at.cooldown * f n = n + 1
        end
      end
    end
  end
  return n
end

-- 远程伤害的坑：子弹带不带 use_unit_damage_factor 决定它吃不吃 unit.damage_factor。
--   带 → 缩 unit 就够，**模板绝不能碰**（两边都缩会平方）；
--   不带 → 缩 unit 完全不起作用，必须改**子弹模板**的 damage_min/max（bolin / myriath）。
-- 按运行时的实际标志判定，不写死英雄名单。
local function find_template(name)
  local edb = game_mod("entity_db")
  if type(edb) ~= "table" then return nil end
  local gt = rawget(edb, "get_template")
  if type(gt) == "function" then
    local ok, t = pcall(gt, edb, name)
    if ok and type(t) == "table" then return t end
  end
  local reg = rawget(edb, "entities")
  if type(reg) ~= "table" then return nil end
  local hit = rawget(reg, name)
  if type(hit) == "table" then return hit end
  -- 注册表的**键**不一定等于 template_name，所以还得扫一遍（只在倍率变化时发生，不在热路径）
  for _, t in pairs(reg) do
    if type(t) == "table" and rawget(t, "template_name") == name then return t end
  end
  return nil
end

-- 只对"不认 unit.damage_factor"的子弹动手。返回补了几处。
local HERO_BULLET_STATS = { "ranged_damage_min", "ranged_damage_max" }

hero_bullet_apply = function(e, want)
  local r = rawget(e, "ranged")
  if type(r) ~= "table" then return 0 end
  local list = rawget(r, "attacks") or rawget(r, "list")
  if type(list) ~= "table" then return 0 end
  local n, any_plain = 0, false
  for _, at in pairs(list) do
    if type(at) == "table" then
      local bn = rawget(at, "bullet")
      if type(bn) == "string" then
        local t = find_template(bn)
        local b = type(t) == "table" and rawget(t, "bullet") or nil
        if type(b) == "table" and rawget(b, "use_unit_damage_factor") ~= true then
          any_plain = true
          local got = S.hero_bullet_seen[t]
          if got == nil then got = 1 end
          if got ~= want then
            local f = want / got
            if type(b.damage_min) == "number" then b.damage_min = b.damage_min * f n = n + 1 end
            if type(b.damage_max) == "number" then b.damage_max = b.damage_max * f n = n + 1 end
            S.hero_bullet_seen[t] = want
          end
        end
      end
    end
  end
  -- level_stats 那两张按等级索引的数组**只在查明确有"不认标志"的子弹时才缩**：
  -- 升级回调是从它们重写子弹模板的，不缩就白改；但认标志的英雄缩了会**平方**
  -- （数组 → 模板，再乘 unit.damage_factor）。
  if not any_plain then return n end
  local hero = rawget(e, "hero")
  local ls = type(hero) == "table" and rawget(hero, "level_stats") or nil
  if type(ls) == "table" then
    for _, key in ipairs(HERO_BULLET_STATS) do
      local row = rawget(ls, key)
      if type(row) == "table" then
        local got = S.hero_bullet_seen[row]
        if got == nil then got = 1 end
        if got ~= want then
          local f = want / got
          for i, v in pairs(row) do
            if type(v) == "number" then row[i] = v * f n = n + 1 end
          end
          S.hero_bullet_seen[row] = want
        end
      end
    end
  end
  return n
end

local function hero_apply()
  local s = store_of()
  if not s then return 0 end
  local want = S.hero
  local n = 0
  each_entity(s, function(e)
    if is_hero(e) then
      local got = S.hero_seen[e]
      -- 逐字段兜底（同 tower_apply：S 跨次注入存活，旧记录可能缺格）
      local g = { hp = (got and got.hp) or 1, damage = (got and got.damage) or 1,
                  rate = (got and got.rate) or 1, cd = (got and got.cd) or 1 }
      -- 「英雄技能无CD」开着时，timed_attacks 的冷却被清成 0 —— 这一项按"维持现状"处理，
      -- 既不缩也不记（理由同 tower_cd_apply：记了会让倍率在开关关掉后静默失效）。
      local want_cd = want.cd
      if S.nocd.hero then want_cd = g.cd end
      if not got or g.hp ~= want.hp or g.damage ~= want.damage
         or g.rate ~= want.rate or g.cd ~= want_cd then
        local to = { hp = want.hp, damage = want.damage, rate = want.rate, cd = want_cd }
        hero_rescale(e, g, to)
        S.hero_seen[e] = to
        n = n + 1
      end
    end
    return 0
  end)
  return n
end

-- 攻速的**第三层**：把攻击动画本身放快。
-- 射击周期 = max(cooldown, 射击动画时长)：箭塔 shoot 是 28 帧 @30fps ≈ 0.93s，而 cooldown 只有
-- {1, 0.9, 0.7, 0.6} —— **2 级以上光缩 cooldown 是白改**，动画才是地板。
-- 落点 sys.render:on_update **之前**：它每 tick 现读 s.fps 送进 A:fni，没有缓存 → 当帧生效
-- （挂 tick() 会晚一帧）。
-- ⚠️ fps 是**每实体 × 每 sprite 索引**的，会影响那条索引上的**所有**动画 → 只按动画名精确匹配，
--    不在攻击期间就写回原值。箭塔 idle 只 1 帧看不出来，英雄不行（同一条索引上还挂着 walk/death）。
-- ⚠️ 还原写**记下来的原值**，绝不写 nil：模板里有两处非 nil 的 fps。
local ANIM_FPS = 30            -- 动画默认帧率（all/constants.lua FPS = 30，animation_db.fps）
local ANIM_CONT = { "attacks", "timed_attacks", "melee", "ranged", "ultimate_melee" }

local function fps_base(s)
  local box = S.anim_base[s]
  if box == nil then
    box = { orig = rawget(s, "fps") }
    S.anim_base[s] = box
  end
  return box.orig
end

-- 这个模板可能播的攻击动画名。按模板名缓存（动画名来自模板，实体上不会变）。
local function anim_groups_for(e)
  local nm = tpl_name(e)
  if nm == "" then return nil end
  local got = S.anim_groups[nm]
  if got ~= nil then
    if got == false then return nil end
    return got
  end
  local out = {}
  local nodes = { e, rawget(e, "tower"), rawget(e, "hero") }
  for i = 1, 3 do
    local nd = nodes[i]
    if type(nd) == "table" then
      for j = 1, #ANIM_CONT do
        local c = rawget(nd, ANIM_CONT[j])
        if type(c) == "table" then
          local list = rawget(c, "list") or rawget(c, "attacks") or c
          if type(list) == "table" then
            for _, at in pairs(list) do
              if type(at) == "table" then
                local an = rawget(at, "animation")
                if type(an) == "string" then out[an] = true end
              end
            end
          end
        end
      end
    end
  end
  if next(out) == nil then S.anim_groups[nm] = false return nil end
  S.anim_groups[nm] = out
  return out
end

-- 这个 sprite 现在播的是不是攻击动画。
--   ① sprite.name 直接等于组名 —— angles 里没有这个组时游戏就是用组名播的（all/utils.lua）
--   ② sprite.name 是该组 angles 展开出来的名（箭塔 angles.shoot = {"shootback","shoot"}）
--   ③ 基名 + "_" 前缀：模板写 "attack"，游戏实际播 "attack_1" / "attack_4_explosive"
--   ④ relax（**只给塔**）：见下面的长注释
local function is_attack_sprite(s, groups, relax)
  local nm = rawget(s, "name")
  if type(nm) ~= "string" then return false end
  if groups[nm] then return true end
  local ang = rawget(s, "angles")
  if type(ang) == "table" then
    for g in pairs(groups) do
      local l = rawget(ang, g)
      if type(l) == "table" then
        for _, v in pairs(l) do if v == nm then return true end end
      end
    end
  end
  for g in pairs(groups) do
    if nm:sub(1, #g + 1) == g .. "_" then return true end
  end
  if relax and rawget(s, "loop") ~= true and not nm:find("idle", 1, true) then return true end
  return false
end

-- ⚠️ 塔要放宽（relax），英雄不放宽。
-- 「分段射击」的塔会播一串**模板里没声明过**的动画名：炮塔是 rotation_N（瞄准 / 收招），
-- 法师塔是 shootstart / shootend / buff。只按模板里那个基名匹配就一条都命不中，周期纹丝不动。
-- 放宽依据：塔脚本里被 y_animation_play / y_animation_wait **等待**的动画名没有一个像待机名，
-- 全是射击 / 技能 / 出场序列的一环。**待机必须排除** —— idle / idle_2 / idlenothing 有用
-- loop=false 起的，光看 loop 会把它们一起加速。
-- 副作用：stun / 出场 / 技能光效这类一次性动画也会变快，都只是观感、不影响数值。
local function anim_rate_apply(e, rate, relax)
  local r = rawget(e, "render")
  local list = type(r) == "table" and rawget(r, "sprites") or nil
  if type(list) ~= "table" then return 0 end
  local groups = anim_groups_for(e)
  local n = 0
  for _, s in pairs(list) do
    if type(s) == "table" then
      local base = fps_base(s)
      -- rate == 1 时 want 就是 base —— 这正是"收尾那趟"要用到的还原路径
      local want = base
      if rate ~= 1 and (groups or relax) and is_attack_sprite(s, groups or {}, relax) then
        want = (base or ANIM_FPS) * rate
      end
      if rawget(s, "fps") ~= want then s.fps = want n = n + 1 end
    end
  end
  return n
end

-- 把碰过的 sprite 全部还回原值。只还 S.anim_base 里记过的 —— 没记录 = 我们没碰过，
-- 绝不能顺手写 nil（会改掉带 fps 的那两处模板）。
local function anim_restore()
  local n = 0
  for s, box in pairs(S.anim_base) do
    if type(s) == "table" and rawget(s, "fps") ~= box.orig then
      s.fps = box.orig
      n = n + 1
    end
  end
  return n
end

anim_apply = function()
  local tr, hr = S.tower.rate, S.hero.rate
  if tr == 1 and hr == 1 then
    -- 全回到 x1：补跑一趟把那批 sprite 还回去，然后停手（这一趟不能省）
    if not S.anim_active then return 0 end
    S.anim_active = false
    return anim_restore()
  end
  S.anim_active = true
  local s = store_of()
  if not s then return 0 end
  local n = 0
  each_entity(s, function(e)
    local rate
    if is_tower(e) then rate = tr
    elseif is_hero(e) then rate = hr
    else return 0 end
    -- rate == 1 的那一类也要走一趟：它可能刚被调回 x1，得把 sprite 还回去
    n = n + anim_rate_apply(e, type(rate) == "number" and rate or 1, is_tower(e))
    return 0
  end)
  return n
end

install_anim_hook = function()
  if S.anim_hook_done then return false end
  local sys = game_mod("systems")
  local r = (type(sys) == "table") and rawget(sys, "render") or nil
  local orig = (type(r) == "table") and rawget(r, "on_update") or nil
  if type(orig) ~= "function" then return false end
  S.anim_hook_done = true
  rawset(r, "on_update", function(...)
    if S.tower.rate ~= 1 or S.hero.rate ~= 1 or S.anim_active then
      -- 出错要留痕：裸 pcall 会把错误吞成"改了没反应"
      local ok, err = pcall(anim_apply)
      if not ok then record_err("anim@render", err) end
    end
    return orig(...)
  end)
  S.hooks[#S.hooks + 1] = "systems.render.on_update(attack fps)"
  return true
end

-- 存档层：游戏内改进度（星星 / 升级树 / 法术）。存档不常驻内存（异步文件 IO），但总得经过
-- 「文本 → Lua 表」和「Lua 表 → 文本」两个转换，在那两个函数上钩一道即可。
-- ⚠️ 待办表 S.slot_ops 是**一次性**的：命中一次存档表就全部应用并清空，否则会变成"每帧覆盖存档"。

S.slot_ops = S.slot_ops or {}

-- 存档表指纹：必须**自己存了** gems(数字)+levels(表)+upgrades_trees(表)；用 rawget 取
-- —— 扫到的可能是任意表，带 __index 元方法的会抛错。
local function is_slot_like(t)
  if type(t) ~= "table" then return false end
  return type(rawget(t, "gems")) == "number"
     and type(rawget(t, "levels")) == "table"
     and type(rawget(t, "upgrades_trees")) == "table"
end

-- 星星奖励轨道总量（= map_data.lua 的 progression_rewards_premium，换版本要对着游戏数据核）。
local REWARD_LAST_STARS = 84

-- 升级树节点。存档里是短 id，kr6/upgrades.lua 里带前缀（archers_l1），两套不能混。
-- 防御塔树和英雄树用的是**同一套** id；别的节点名游戏里没有。
-- 三类升级树的节点名**各不相同**（从游戏 kr6/upgrades.lua 的 id 池解出，再用游戏自己写进
-- 存档的节点交叉验证过）。存档里存的是**短 id** —— 树前缀去掉后的那截。
local TOWER_TREE_KEYS = { archers = true, artillery = true, barracks = true, mages = true }
local TOWER_NODES = { "l1", "l2", "l3a", "l3b", "l4a", "l4b", "ulti" }
-- 法术树：2/4/5 层各是二选一（a|b），3/6 层单节点 —— 满树 = 一条完整路径 5 个。
local POWER_NODES = { "l2a", "l3", "l4a", "l5a", "l6" }
local POWER_PAIRS = { { "l2a", "l2b" }, { "l4a", "l4b" }, { "l5a", "l5b" } }
-- 在**别的**树种类里合法、但在法术树里一定是写错的名字（旧版把塔的节点名写了进来）。
-- ⚠️ 别把 l4a/l4b 算进来 —— 那两个法术树本来就有。
local POWER_WRONG = { l1 = true, l2 = true, l3a = true, l3b = true, ulti = true }

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

-- 补全一棵树：pairs 里那些二选一的层级，**已有哪个就留哪个**（都没有才填第一个），
-- 其余节点缺什么补什么；wrong 里的名字先删掉。返回 (补了几个, 删了几个)。
local function fill_tree(arr, nodes, pairs, wrong)
  if type(arr) ~= "table" then return 0, 0 end
  local removed = 0
  if wrong then
    local keep, n = {}, slot_array_len(arr)
    for i = 1, n do
      local v = arr[i]
      if type(v) == "string" and wrong[v] then
        removed = removed + 1
      else
        keep[#keep + 1] = v
      end
    end
    if removed > 0 then
      for i = n, 1, -1 do arr[i] = nil end
      for i = 1, #keep do arr[i] = keep[i] end
    end
  end
  local skip = {}
  if pairs then
    for i = 1, #pairs do
      local a, b = pairs[i][1], pairs[i][2]
      if slot_array_has(arr, a) or slot_array_has(arr, b) then skip[a], skip[b] = true, true end
    end
  end
  local added, n = 0, slot_array_len(arr)
  for i = 1, #nodes do
    local v = nodes[i]
    if not skip[v] and not slot_array_has(arr, v) then
      arr[n + added + 1] = v
      added = added + 1
    end
  end
  return added, removed
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

-- 法术的经验阈值表（同名同源，也在 game_settings 里）。读不到就返回 nil —— 上层会拒绝执行。
power_thresholds = function()
  local gs = game_mod("game_settings")
  local thr = gs and rawget(gs, "powers_xp_thresholds")
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
-- 满级成就的 id（前四个按英雄、最后一个按法术，见 kr6/achievements_handlers.lua）。
local ACH_IDS = { "TIME_SAVIOUR", "BATTLEMAGE", "SHARPSHOOTER", "BATTLEBORN",
                  "PLAYING_WITH_POWER" }

local function ach_have(id)
  local A = game_mod("achievements")
  if type(A) ~= "table" or type(rawget(A, "have")) ~= "function" then return nil end
  local ok, v = pcall(A.have, A, id)
  return (ok and v == true) or nil
end

-- 直接解锁满级成就：**直接发游戏自己的信号**。
-- 这两个成就只认游戏**自己**发出来的信号，而我们直接写数值时信号从没发过：
--   英雄 hero-level-increased 只在**关卡内升级路径**发（fn_level_up 内部不发）→「英雄拉满」拿不到；
--   法术 power-level-increased 在**关卡结束存档**时发、且要求 `old_level < new_level` ——
--   把存档经验直接填到 6 级两个 level 相等，永远发不出来。
-- signal 是 hump.signal 单例，emit 没有守卫；成就自身的持久化在 A:got 里。
-- ⚠️ 英雄那个处理器要求**发信号那一刻正好 10 级**，所以先补到 10 级再发。
unlock_achievements = function()
  local sig = game_mod("hump.signal")
  if type(sig) ~= "table" or type(rawget(sig, "emit")) ~= "function" then
    return nil, "拿不到信号模块（hump.signal 没加载）"
  end
  local s = store_of()
  if not s then return nil, "不在关卡内" end

  -- 先记下动之前的状态，播报时才能如实说"这次新解锁了哪几个"
  local before = {}
  for i = 1, #ACH_IDS do before[ACH_IDS[i]] = ach_have(ACH_IDS[i]) end

  local sent, failed = 0, 0
  local team = rawget(s, "hero_team")
  if type(team) == "table" then
    for _, e in pairs(team) do
      local h = (type(e) == "table") and rawget(e, "hero") or nil
      if type(h) == "table" and type(rawget(h, "level")) == "number" then
        -- 处理器写死了 `entity.hero.level == 10`，所以先补到 10 级
        local f = rawget(h, "fn_level_up")
        if h.level < 10 and type(f) == "function" then
          h.level = 10
          pcall(f, e, s, true)
        end
        if h.level >= 10 then
          local ok, err = pcall(sig.emit, "hero-level-increased", e)
          if ok then sent = sent + 1 else failed = failed + 1 record_err("ach@hero", err) end
        end
      end
    end
  end
  -- 法术：处理器只看 `new_level >= 6`，不看是哪个法术，所以按 6 发即可
  do
    local ok, err = pcall(sig.emit, "power-level-increased", "power", 6)
    if ok then sent = sent + 1 else failed = failed + 1 record_err("ach@power", err) end
  end

  if sent == 0 then return nil, "没有可发的信号" end
  local newly = {}
  for i = 1, #ACH_IDS do
    local id = ACH_IDS[i]
    if ach_have(id) and not before[id] then newly[#newly + 1] = id end
  end
  local msg = "已发 " .. sent .. " 个满级信号"
  if #newly > 0 then
    msg = msg .. "，本次解锁：" .. table.concat(newly, "、")
  else
    msg = msg .. "（对应成就此前已解锁）"
  end
  if failed > 0 then msg = msg .. "（" .. failed .. " 个出错，见 _kr6_err.txt）" end
  return msg
end

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
    -- tower_* 那 16 个槽位游戏自己从不写（它的 tower_x_lvl1..4 是另一套机制），一律不碰。
    for k, arr in pairs(tr) do
      if type(k) == "string" and TOWER_TREE_KEYS[k] then fill_tree(arr, TOWER_NODES) end
    end
    return true
  elseif op == "power_max" then
    -- 法术**光填树会变成负点数**：点数按等级发（upgrades.lua 的
    -- get_points_by_level），买树上的节点花的就是它（get_spent_points）。所以先把等级
    -- 拉满 —— 经验写到阈值表顶以上，游戏读档时自己按经验重算等级并补发点数（和英雄拉满
    -- 同一条路），再填树。阈值表读不到就**整条失败、不填树**：宁可不做，也不造负点数。
    local ps = rawget(t, "powers")
    local st = (type(ps) == "table") and rawget(ps, "status") or nil
    if type(st) ~= "table" then return false end
    local thr = power_thresholds()
    local top = thr and thr_top(thr)
    local tr = rawget(t, "upgrades_trees")
    local n = 0
    for id, e in pairs(st) do
      if type(id) == "string" and type(e) == "table"
         and type(rawget(e, "xp")) == "number" then
        e.xp = (top or e.xp) + 10000
        n = n + 1
        if type(tr) == "table" then
          fill_tree(rawget(tr, "power_" .. id), POWER_NODES, POWER_PAIRS, POWER_WRONG)
        end
      end
    end
    return n > 0
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
  -- 成功了要**主动报出来**：待办只存在内存里，游戏若没重写存档就无声丢失 ——
  -- 不报的话玩家分不出"按了没反应"和"还没轮到应用"。
  if n > 0 then S.slot_applied = n end
  return n
end

-- 暴露给测试台：测试环境里没有 storage 模块、钩子装不上，而存档改写必须能单独测。
S.mult_live = mult_apply_live        -- 暴露给测试台：倍率那条在测试里要能单独调
S.mult_apply = mult_apply            -- 模板那条（测试台没有 entity_db，直接喂一张假模板表）
S.tower_apply_fn = tower_apply       -- 塔射程/攻速/伤害那条（测试台喂假的塔实体）
S.tower_cd_apply_fn = tower_cd_apply -- 塔技能CD 那条（独立状态，和「无CD」开关不是一回事）
S.hero_apply_fn = hero_apply         -- 英雄血量/伤害/攻速/技能CD 那条
S.anim_apply_fn = anim_apply         -- 攻速第三层：攻击动画的 fps（测试台喂假 sprite）
S.anim_restore_fn = anim_restore
S.anim_install = install_anim_hook
S.nocd_clear_buttons = clear_button_list   -- 测试台没有 game_gui，直接喂几个假按钮
S.nocd_clear_entity = clear_entity_cds     -- 同上：英雄/塔那条
S.nocd_restore = nocd_restore              -- 关掉开关时要能还原（可逆性测试）
S.slot_apply = apply_slot_ops
S.slot_like = is_slot_like
S.gold_push = gold_push              -- 测试台：击杀金币 ×2 那条要能单独驱动
S.gold_pop = gold_pop
S.gold_install = install_gold_hook

-- 存档只在**两个**函数上过（签名已从源码确认）：
--   读 storage:load_lua(f, force) → 存档是**返回值**；写 storage:save_slot(data, idx, ..) → 是**第一个参数**。
-- 读挂 load_lua 而不是 load_slot：后者自己就是调它，而且 main.lua 有一条绕过 load_slot 直接读存档的路。
-- save_slot 是 slot 文件**唯一**的写入者（delete_slot 只删不写）。
local SLOT_HOOKS = {
  { "storage", "load_lua",  "ret" },
  { "storage", "save_slot", "arg" },
}

local function install_slot_hooks()
  local done = 0
  for i = 1, #SLOT_HOOKS do
    local mod = game_mod(SLOT_HOOKS[i][1])
    local key, mode = SLOT_HOOKS[i][2], SLOT_HOOKS[i][3]
    if type(mod) == "table" then
      local orig = rawget(mod, key)
      local flag = "slot_" .. key
      if type(orig) == "function" and not S.wrap_src[flag] then
        S.wrap_src[flag] = true
        rawset(mod, key, function(...)
          if mode == "arg" then
            local a = ...
            if is_slot_like(a) then apply_slot_ops(a) end
          end
          local r1, r2, r3, r4 = orig(...)
          if mode == "ret" and is_slot_like(r1) then apply_slot_ops(r1) end
          return r1, r2, r3, r4
        end)
        S.slot_hooks[#S.slot_hooks + 1] = SLOT_HOOKS[i][1] .. "." .. key
        done = done + 1
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
    -- ⚠️ 提示行只能用**游戏字体里有的字**：那是游戏裁剪过的子集字体（只 1901 个码位），
    -- 实测缺「执」「闭」两个字 —— 写上去就是空白。改这行前先把字过一遍字体 cmap。
    title = "KR6 修改器", hint = "Home/Tab 开关  ↑↓选择  ←→调整  Enter 确定  Esc 收起",
    gold_add = "金币 +1000", gold_sub = "金币 -1000",
    lives_add = "生命 +10", lives_sub = "生命 -10",
    hold = "无限金钱", hold_lives = "生命锁定",
    gold_mult = "击杀金币倍率",
    next_wave = "立刻下一波",
    hdr_speed = "速度", game_speed = "游戏速度",
    hdr_res = "资源", hdr_wave = "波次", hdr_units = "敌人属性",
    hdr_tower = "防御塔",
    hdr_hero = "英雄",
    hdr_save = "存档（回主菜单再进档生效）",
    enemy_hp = "敌人血量", enemy_speed = "敌人移速",
    tower_range = "塔射程",
    tower_damage = "塔伤害", tower_atkspd = "塔攻速", tower_skill_cd = "塔技能CD",
    hero_hp = "英雄血量", hero_damage = "英雄伤害",
    hero_atkspd = "英雄攻速", hero_skill_cd = "英雄技能CD",
    stars_max = "星星拉满", unlock_tree = "塔树升满", power_max = "法术升满",
    hdr_cd = "技能无CD（开关）",
    nocd_power = "法术无CD", nocd_hero = "英雄技能无CD", nocd_tower = "塔技能无CD",
    hero_now_up = "英雄升一级（本关立即）", hero_now_max = "英雄拉满（本关立即）",
    -- 直接发游戏自己的满级信号（英雄 + 法术），见 unlock_achievements
    ach_unlock = "解锁满级成就（立即）",
    -- ⚠️ 不写「关闭」：字体子集里没有「闭」这个字（画出来是空白）—— 见 hint 那条注释。
    close = "收起菜单",
    on = "开", off = "关",
    labels = { "金币", "生命", "关卡" },
    nolvl = "（未进入关卡）",
    credit = "B站: LOVEIII486",
    warn = "如果你花钱购买说明你被骗了",
  },
  en = {
    title = "KR6 TRAINER", hint = "home / tab toggles   up/down   left/right   enter   esc",
    gold_add = "gold +1000", gold_sub = "gold -1000",
    lives_add = "lives +10", lives_sub = "lives -10",
    hold = "infinite gold", hold_lives = "lock lives",
    gold_mult = "kill gold mult",
    next_wave = "next wave now",
    hdr_speed = "SPEED", game_speed = "game speed",
    hdr_res = "RESOURCES", hdr_wave = "WAVES", hdr_units = "ENEMY STATS",
    hdr_tower = "TOWERS",
    hdr_hero = "HEROES",
    hdr_save = "SAVE (apply on reload)",
    enemy_hp = "enemy HP", enemy_speed = "enemy speed",
    tower_range = "tower range",
    tower_damage = "tower damage", tower_atkspd = "tower attack speed",
    tower_skill_cd = "tower skill cd",
    hero_hp = "hero HP", hero_damage = "hero damage",
    hero_atkspd = "hero attack speed", hero_skill_cd = "hero skill cd",
    stars_max = "max stars", unlock_tree = "max tower trees", power_max = "max powers",
    hdr_cd = "NO-COOLDOWN (SWITCHES)",
    nocd_power = "no power cooldown", nocd_hero = "no hero skill cd",
    nocd_tower = "no tower skill cd",
    hero_now_up = "hero +1 level (now)", hero_now_max = "hero max (now)",
    ach_unlock = "unlock max-level achievements (now)",
    close = "close menu",
    on = "ON", off = "OFF",
    labels = { "gold", "lives", "lvl" },
    nolvl = "(not in a level)",
    credit = "bilibili: LOVEIII486",
    warn = "if you paid money for this, you were scammed",
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
    -- 击杀金币倍率。**只放大击杀**：漏怪也给金币，但那走另一个系统，不受这里影响。
    -- 下限 x1（= 完全不动），所以它和「敌人血量」一样是 x1 起步的可调行，不是开关。
    { id = "gold_mult", label = L("gold_mult"),
      adjust = { set = S.gold, key = "mult", min = 1, max = 10 },
      value = function() return fmt_mult(S.gold.mult) end },

    { id = "hdr_wave",  label = L("hdr_wave"), header = true },
    { id = "next_wave", label = L("next_wave") },

    -- 整体速度 = 游戏**自己**的时间倍率（game.DBG_TIME_MULT）：>1 时 game:update 一帧连跑
    -- N 次 simulation，移动/伤害/波次/冷却/动画一起快；<1 是慢放。档位表是这行专用的
    -- （见 SPEED_STEPS），换关复位见 tick。
    { id = "hdr_speed", label = L("hdr_speed"), header = true },
    { id = "game_speed", label = L("game_speed"),
      adjust = { set = S.speed, key = "mult", steps = SPEED_STEPS },
      value = function() return fmt_mult(S.speed.mult) end },

    -- 倍率行：左右键调 S.mult 那一项（不走 store，故 tweak 有第二种目标）；右=调高、左=调低。
    { id = "hdr_units", label = L("hdr_units"), header = true },
    { id = "enemy_hp", label = L("enemy_hp"),
      adjust = { set = M, key = "enemy_hp", min = 0.1, max = 10 },
      value = function() return fmt_mult(S.mult.enemy_hp) end },
    { id = "enemy_speed", label = L("enemy_speed"),
      adjust = { set = M, key = "enemy_speed", min = 0.1, max = 10 },
      value = function() return fmt_mult(S.mult.enemy_speed) end },
    -- 防御塔四项。字段都在**活塔实体**上、选敌时现读，所以改完立刻生效；塔升级会重建实体，
    -- 新表由 tower_apply 自己补上。
    -- ⚠️ 不是 balance.towers.*.stats.*（那个只喂 UI 数字）。攻速必须三层一起改（冷却 / 动画 fps / 前摇）。
    { id = "hdr_tower", label = L("hdr_tower"), header = true },
    { id = "tower_damage", label = L("tower_damage"),
      adjust = { set = S.tower, key = "damage", min = 0.1, max = 10 },
      value = function() return fmt_mult(S.tower.damage) end },
    { id = "tower_atkspd", label = L("tower_atkspd"),
      adjust = { set = S.tower, key = "rate", min = 0.1, max = 10 },
      value = function() return fmt_mult(S.tower.rate) end },
    { id = "tower_range", label = L("tower_range"),
      adjust = { set = S.tower, key = "range", min = 0.1, max = 10 },
      value = function() return fmt_mult(S.tower.range) end },
    { id = "tower_skill_cd", label = L("tower_skill_cd"),
      adjust = { set = S.tower, key = "cd", min = 0.1, max = 1 },
      value = function() return fmt_mult(S.tower.cd) end },

    -- 英雄**单独一组**：它们和上面那两项（敌人属性倍率）不是一回事 ——
    -- 倍率是本关临时改数值，英雄升级会经游戏自己写回档案。混在一起标签会撒谎。
    { id = "hdr_hero",  label = L("hdr_hero"), header = true },
    -- 英雄四项。命中判据一律是「实体带 .hero」——**含剧情英雄**（alleria / blackburn /
    -- denas 不在 store.hero_team 里，只看那个列表会漏）。
    { id = "hero_hp", label = L("hero_hp"),
      adjust = { set = S.hero, key = "hp", min = 0.1, max = 10 },
      value = function() return fmt_mult(S.hero.hp) end },
    { id = "hero_damage", label = L("hero_damage"),
      adjust = { set = S.hero, key = "damage", min = 0.1, max = 10 },
      value = function() return fmt_mult(S.hero.damage) end },
    { id = "hero_atkspd", label = L("hero_atkspd"),
      adjust = { set = S.hero, key = "rate", min = 0.1, max = 10 },
      value = function() return fmt_mult(S.hero.rate) end },
    { id = "hero_skill_cd", label = L("hero_skill_cd"),
      adjust = { set = S.hero, key = "cd", min = 0.1, max = 1 },
      value = function() return fmt_mult(S.hero.cd) end },
    { id = "hero_now_up",  label = L("hero_now_up") },
    { id = "hero_now_max", label = L("hero_now_max") },
    -- 排在「拉满」后面：拉满会绕过游戏的升级信号（拿不到满级成就），
    -- 这一项就是给那种情况兜底的 —— 先拉满再点它，照样能拿成就。
    -- 直接发游戏自己的满级信号（英雄 + 法术），不用回关卡里打死敌人。见 unlock_achievements。
    { id = "ach_unlock", label = L("ach_unlock") },

    -- 技能冷却。三项**分开**（三类技能的冷却记在不同地方），各自开关、即时生效。
    { id = "hdr_cd", label = L("hdr_cd"), header = true },
    { id = "nocd_power", label = L("nocd_power"), toggle = function() return S.nocd.power end },
    { id = "nocd_hero",  label = L("nocd_hero"),  toggle = function() return S.nocd.hero end },
    { id = "nocd_tower", label = L("nocd_tower"), toggle = function() return S.nocd.tower end },

    -- 存档级。**排队**式：按下去不会立刻变，要回主菜单再进一次档（分组标题里已注明）。
    { id = "hdr_save", label = L("hdr_save"), header = true },
    { id = "stars_max",  label = L("stars_max") },
    { id = "unlock_tree", label = L("unlock_tree") },
    { id = "power_max",  label = L("power_max") },
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
      if not S.font_path then S.font_path = cands[i] end
      return f
    end
  end
  -- 兜底：复用游戏当前字体，只要它能画汉字
  local okc, cur = pcall(love.graphics.getFont)
  if okc and cur then
    local okg, has = pcall(cur.hasGlyphs, cur, "\229\134\160\229\184\129\231\148\159\229\145\189")
    if okg and has then
      S.cjk = true
      return cur
    end
  end
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
-- 条目之外要预留的行数：分组标题占位 + 热键提示 + 署名 + 声明 + 临时消息 + 边距。
-- 面板高度和「按窗口高反推字号」都用它，改了要一起对上，否则底部会被裁掉。
local EXTRA_LINES = 7

-- 滑条：把**档位下标**线性铺到轨道上（不用对数 —— 档位表本身在 1 附近密、在 10 附近疏，
-- 线性铺开自动就是接近对数的手感：x1 落在第 10 档，差不多是轨道正中）。
-- ⚠️ 行高太矮时不摆滑条、也不响应轨道点击，自动退回纯 ←→（任何分辨率都不会挤成一团）。
local SLIDER_MIN_H = 12

-- 这一行可用的档位下标区间 + 它的档位表；没有可调语义、或只剩一档时返回 nil。
local function slider_span(it)
  if not (it and it.adjust and it.adjust.set and it.adjust.key) then return nil end
  local a = it.adjust
  local steps = steps_of(a)
  local i0, i1 = ladder_range(steps, a.min, a.max)
  if i1 <= i0 then return nil end
  return i0, i1, steps
end

local function item_by_id(id)
  local items = S.items or {}
  for i = 1, #items do
    if items[i].id == id then return items[i] end
  end
  return nil
end

-- 按鼠标 x 设值（按下的那一刻 + 拖动期间每帧都调）。用的轨道几何是**上一帧**存的，布局稳定。
local function slider_set_at(id, mxs)
  local it = item_by_id(id)
  local i0, i1, steps = slider_span(it)
  if not i0 then return false end
  local tr = nil
  for i = 1, #S.rects do
    if S.rects[i].id == id then tr = S.rects[i].track break end
  end
  if not tr or tr.w <= 0 then return false end
  local frac = (mxs - tr.x) / tr.w
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
  local v = steps[i0 + math.floor(frac * (i1 - i0) + 0.5)]
  local a = it.adjust
  if a.set[a.key] ~= v then a.set[a.key] = v end
  return true
end

local function draw_menu()
  if not S.menu_open then return end
  if type(love) ~= "table" or type(love.graphics) ~= "table" then return end
  local T = MENU_TEXT[S.cjk and "cn" or "en"]
  -- ⚠️ 这一句在下面那个 pcall **外面**：它一抛错，菜单就整个不画（表现成"按了没反应"），
  -- 而且外面几层都没有 pcall。所以这里自己接住并留痕。
  local ok_items, items = pcall(menu_items)
  if not ok_items then
    record_err("menu_items", items)
    return
  end

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
      local fit = math.floor((maxh - 28) / (#items + EXTRA_LINES))
      if fit < line_h then line_h = math.max(fit, 9) end
    end
    local header_h = line_h * 2 + 10
    local h = line_h * (#items + EXTRA_LINES) + 28

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

    local y0 = MENU_Y + header_h + 4
    local mx, my = nil, nil
    pcall(function() mx, my = love.mouse.getPosition() end)
    -- 滑条拖动：**每帧轮询**鼠标状态，不装 mousemoved/mousereleased —— 松手、菜单关闭、
    -- 鼠标移出窗口这些都天然自愈，不会留下卡住的拖动状态。
    -- 放在重建 S.rects **之前**：用的就是上一帧那份轨道几何（布局是稳的）。
    if S.drag then
      local down = false
      if mx and type(love.mouse.isDown) == "function" then
        local okd, d = pcall(love.mouse.isDown, 1)
        down = (okd and d == true)
      end
      if down then slider_set_at(S.drag, mx) else S.drag = nil end
    end
    S.rects = {}
    for i = 1, #items do
      local y = y0 + (i - 1) * line_h
      local hover = (mx and my and my >= y and my < y + line_h
                     and mx >= MENU_X - 10 and mx < MENU_X - 10 + MENU_W)
      -- 滑条轨道：画在数值左边。命中框用**整行高**（好点中），可见的那条只有几像素。
      local track = nil
      if not items[i].header and line_h >= SLIDER_MIN_H then
        local t0 = slider_span(items[i])
        if t0 then
          local lw = 0
          pcall(function() lw = row_font and row_font:getWidth(items[i].label) or 0 end)
          local tx = MENU_X + 8 + lw + 12
          local tmax = MENU_X - 10 + MENU_W - 62
          if tx < tmax - 30 then track = { x = tx, y = y, w = tmax - tx, h = line_h } end
        end
      end
      -- 标题行也要有命中框（带 header 标记）：否则点标题会被当成「没点中」漏给游戏。
      S.rects[i] = { x = MENU_X - 10, y = y, w = MENU_W, h = line_h,
                     id = items[i].id, header = items[i].header, track = track }
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
        if track then
          -- 档位下标 → 轨道位置（线性）。当前值不在表上时吸附最近的一档，和 ←→ 一致。
          local a = items[i].adjust
          local i0, i1, steps = slider_span(items[i])
          local idx = ladder_nearest(steps, tonumber(a.set[a.key]) or 1, i0, i1)
          local kx = track.x + ((idx - i0) / (i1 - i0)) * track.w
          local cy = y + line_h * 0.5
          love.graphics.setColor(55, 55, 55, 230)
          love.graphics.rectangle("fill", track.x, cy - 2, track.w, 4)
          love.graphics.setColor(110, 140, 210, 235)
          love.graphics.rectangle("fill", track.x, cy - 2, kx - track.x, 4)
          local kh = math.min(line_h - 4, 12)
          love.graphics.setColor(235, 235, 235, 255)
          love.graphics.rectangle("fill", kx - 2, cy - kh * 0.5, 4, kh)
        end
      end
    end

    local by = y0 + #items * line_h + 2
    -- ⚠️ 提示那行最容易超宽（大窗口下行高不压缩、字号满格，中文提示会比面板还宽）。
    -- 量一下，放不下就换小一号字重画 —— 小字号只建一次，别每帧 newFont。
    local hfont, hw = row_font, 0
    if type(T.hint) == "string" and hfont then
      pcall(function() hw = hfont:getWidth(T.hint) end)
      if hw > MENU_W - 10 then
        if S.hint_font == nil then
          local okh, fh2 = pcall(try_load_font, 12)
          S.hint_font = (okh and fh2) or false
        end
        if S.hint_font then hfont = S.hint_font end
      end
      -- 用**最终选定**的字号再量一次并暴露出去：测试按面板宽度钉着这条，
      -- 保证提示行在任何分辨率/字号下都不会超出面板（S.rects[1].w 就是 MENU_W）。
      hw = 0
      pcall(function() hw = hfont:getWidth(T.hint) end)
      S.hint_w = hw
    end
    if hfont then pcall(love.graphics.setFont, hfont) end
    love.graphics.setColor(160, 160, 160, 255)
    love.graphics.print(T.hint, MENU_X, by)
    if hfont ~= row_font then pcall(love.graphics.setFont, row_font) end
    -- 署名与声明常驻底部；临时消息排它们下面，出现时不会顶动上面几行。
    -- ⚠️ 先判类型：文案缺失时 print(nil) 会抛错，被外层 pcall 一吞就是「底部整块不画」
    -- —— 和标签缺失让整个面板消失是同一类坑（见 labelless_items 那条断言）。
    if type(T.credit) == "string" then
      love.graphics.setColor(210, 190, 110, 255)
      love.graphics.print(T.credit, MENU_X, by + line_h)
    end
    if type(T.warn) == "string" then
      love.graphics.setColor(255, 150, 150, 255)
      love.graphics.print(T.warn, MENU_X, by + line_h * 2)
    end
    if S.msg ~= "" and os.time() - S.msg_ts < 6 then
      love.graphics.setColor(140, 255, 140, 255)
      love.graphics.print(S.msg, MENU_X, by + line_h * 3)
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
      -- 每一行语义一致：右键加、左键减。两种目标都从这一个入口走（见 action 的 tweak）：
      --   倍率行（set/key）→ delta 是**档位序号**的增量（±1），走档位表
      --   store 字段行（field）→ delta 才是数值增量（金币 ±1000 那种）
      if a.set then
        run_action("tweak", { set = a.set, key = a.key, min = a.min, max = a.max,
                              steps = a.steps, delta = dir })
      else
        run_action("tweak", { field = a.field, delta = a.step * a.sign * dir })
      end
    end
  end
end

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

-- 整体速度：把意图值写进**游戏自己的** game.DBG_TIME_MULT（>1 一帧连跑 N 次 simulation:update，
-- <1 走 dt 缩放）。不装钩子、不碰 store，所以没有任何"游戏会重算它"的问题 —— 每帧幂等写一次
-- 只是防脏值与被外力改掉。SPEED_OK 之外的值一律当 x1：0 或负数会让 simulation 的累加器
-- 永远过不了线（游戏直接冻住），宁可退回原速。
local function speed_apply()
  local g = _G.game
  if type(g) ~= "table" then return "n/a: no game table" end
  local v = S.speed.mult
  if not SPEED_OK[v] then v = 1 S.speed.mult = 1 end
  if rawget(g, "DBG_TIME_MULT") ~= v then g.DBG_TIME_MULT = v end
  return "OK: speed x" .. tostring(v)
end
S.speed_apply_fn = speed_apply   -- 暴露给测试台（写的是 _G.game.DBG_TIME_MULT）

-- frame tick
local function tick(source)
  if S.tick_source == nil then
    S.tick_source = source
  elseif S.tick_source ~= source then
    return
  end
  S.drew = false

  -- 技能无CD：开着才跑。放在 tick 最前面 —— 下面 1Hz 那段要拿这一趟的结果做自检回执。
  if S.nocd.power or S.nocd.hero or S.nocd.tower then
    local ok, h = pcall(apply_nocd)
    S.nocd_hits = (ok and type(h) == "table") and h or nil
  end

  -- 倍率只在本关生效：关卡一换就归 1（归 1 后下面那一趟 mult_apply 会把模板写回原值）。
  -- 每秒看一次足够 —— 换关不是逐帧事件。
  local now = os.time()
  if now > S.last_level_check then
    S.last_level_check = now
    local s = store_of()
    local tag = s and tostring(s.level_name or s) or nil
    if tag then
      if S.mult_tag and S.mult_tag ~= tag then
        S.mult.enemy_hp, S.mult.enemy_speed = 1, 1
        S.speed.mult = 1     -- 整体速度同理：只在本关生效
      end
      S.mult_tag = tag
    end
    -- 技能无CD 的自检回执：**按类**报清了几个（power/hero/tower 都是 0 就是全没找对地方）。
    if S.nocd_report then
      local h, parts, total = S.nocd_hits or {}, {}, 0
      local kinds = { { "power", S.nocd.power }, { "hero", S.nocd.hero }, { "tower", S.nocd.tower } }
      for i = 1, #kinds do
        if kinds[i][2] then
          local v = h[kinds[i][1]] or {}
          total = total + (v.seen or 0)
          parts[#parts + 1] = kinds[i][1] .. " " .. (v.seen or 0) .. "/" .. (v.cleared or 0)
        end
      end
      local txt = table.concat(parts, " / ")
      if total > 0 then
        S.nocd_report = false
        note("技能无CD " .. txt, "no cooldown " .. txt)
      elseif now - (S.nocd_since or now) >= 2 then
        S.nocd_report = false
        note("技能无CD 没找到技能容器：" .. txt, "no cooldown containers: " .. txt)
      end
    end
  end

  -- 整体速度：每帧幂等写一次（值没变就只是一个字段比较）。放在上面那段换关复位**之后**，
  -- 复位当帧就能生效。不在关卡里（没有 game 表）时什么也不做。
  pcall(speed_apply)

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

  -- 防御塔的四项：同一套「开着就跑、关掉补跑一趟收尾」。
  -- 收尾那趟不能省：守卫条件已变假，不补跑就永远停在放大后的值上。
  local tw = S.tower
  if tw.range ~= 1 or tw.rate ~= 1 or tw.damage ~= 1 then
    pcall(tower_apply)
    S.tower_active = true
  elseif S.tower_active then
    pcall(tower_apply)
    S.tower_active = false
  end
  -- 塔技能CD 是**独立一项**（和上面三项不同源），所以另开一个状态。
  -- ⚠️「无CD」开着时**不许清收尾标志**：这一项整个冻结（tower_cd_apply 自己会立刻返回），
  -- 清了就再也不会补缩 —— 而 nocd_restore 写回的是"打开开关那一刻"的值，那时还带着旧倍率，
  -- 结果就是菜单显示 x1、冷却却按旧倍率走，且永不自愈。
  if tw.cd ~= 1 or S.nocd.tower then
    pcall(tower_cd_apply)
    S.tower_cd_active = true
  elseif S.tower_cd_active then
    pcall(tower_cd_apply)
    S.tower_cd_active = false
  end

  -- 英雄的四项：同样一套。CD 那一项在「英雄技能无CD」开着时是冻结的，
  -- 所以那期间也不许清收尾标志（理由同上）。
  local hh = S.hero
  if hh.hp ~= 1 or hh.damage ~= 1 or hh.rate ~= 1 or hh.cd ~= 1 or S.nocd.hero then
    pcall(hero_apply)
    S.hero_active = true
  elseif S.hero_active then
    pcall(hero_apply)
    S.hero_active = false
  end

  -- 存档钩子：storage 在 payload 加载时可能还没 require，所以每帧试装一次、装上就不再试。
  if not S.slot_hooks_done then
    local n = install_slot_hooks()
    if n > 0 or (game_mod("storage") ~= nil) then S.slot_hooks_done = true end
  end

  -- 金币钩子同理：systems 可能比 payload 晚 require，每帧试装一次，装上就不再试。
  if not S.gold_hook_done then install_gold_hook() end
  -- 攻击动画的 fps 钩子同理（攻速的第三层，见 anim_apply）。
  if not S.anim_hook_done then pcall(install_anim_hook) end

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

end

local function wrap_fn(owner, key, source)
  if type(owner) ~= "table" then return false end
  local orig = rawget(owner, key)
  if type(orig) ~= "function" then return false end
  if S.wrap_src[key] then return false end
  S.wrap_src[key] = true
  rawset(owner, key, function(...)
    local a, b, c, d = orig(...)
    -- ⚠️ tick 里出错必须留痕：裸 pcall 会把它吞掉，表现成"改了没反应"，查起来极费劲。
    local ok, e = pcall(tick, source)
    if not ok then record_err("tick@" .. tostring(source), e) end
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

  -- 只有这两个键是热键：Home / Tab（有些键盘没有 Home 键）。
  -- ⚠️ **不要用 F1–F3**：游戏自己 all/constants.lua 里 key_item_1/2/3 = "f1"/"f2"/"f3"，
  -- 那是玩家的物品热键，抢了它玩家就按不出物品。F 键在笔记本上还常被固件占成媒体键。
  if key == "home" or key == "tab" then
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
      -- 点中滑条轨道 → 设值并进入拖动，**不**走 run_action（那是"执行 / 只读回执"）。
      -- 行左侧的文字区仍然保持原来的语义，点它不会误改数值。
      if r.track and x >= r.track.x and x < r.track.x + r.track.w then
        S.drag = r.id
        slider_set_at(r.id, x)
        return true
      end
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
  -- 装上了什么钩子，落一行盘 —— 玩家报「没反应」时这是唯一的现场证据。
  wf("_kr6trainer_loaded.txt",
     "fired=[" .. table.concat(S.fired, ", ") .. "]" .. string.char(10) ..
     "key_hook=" .. tostring(S.key_hook) .. string.char(10) ..
     "hooks=" .. table.concat(S.hooks, ", ") .. string.char(10) ..
     "keys: Home / Tab = menu" .. string.char(10))
end

return "kr6trainer ok"
