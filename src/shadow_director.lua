-- kr6 模块覆盖桩（部署为 all/director.lua）
--
-- 作用：先从 _orig/ 读回游戏**自己的原始字节码**并执行，拿到它原本的返回值
-- （也就是真正的 director 模块表），再把这张表交给修改器，最后原样返回。
-- 所以游戏跑的还是它自己的代码，我们只是搭了个车。
--
-- 刻意保持最小：只覆盖走正常 require 路径的模块，绝不碰游戏用沙箱环境
-- （level_utils.eval_file + setfenv）加载的那些（关卡文件、constants.lua 等）——
-- 那些环境里没有 string/io，这个文件第 5 行就会炸。
local SEP = string.char(92)
local SAVE = os.getenv("APPDATA") .. SEP .. "kingdom_rush_genesis" .. SEP

local function wf(name, txt)
  local f = io.open(SAVE .. name, "wb")
  if f then f:write(txt) f:close() end
end

local function blob(path)
  local f = io.open(path, "rb")
  if not f then return nil, "cannot open " .. path end
  local s = f:read("*a")
  f:close()
  local chunk, err = loadstring(s, path)
  if not chunk then return nil, "loadstring: " .. tostring(err) end
  return chunk
end

-- 先跑游戏自己的字节码，拿回真正的模块表
local origval
local chunk, cerr = blob(SAVE .. "_orig" .. SEP .. "all_director.luac")
if not chunk then
  wf("_kr6_shadow_err_all_director_lua.txt", "blob failed: " .. tostring(cerr) .. string.char(10))
else
  local ok, v = pcall(chunk, ...)
  if ok then
    origval = v
  else
    wf("_kr6_shadow_err_all_director_lua.txt", "original errored: " .. tostring(v) .. string.char(10))
  end
end

-- 再把模块表交给修改器（它自己全程 pcall 保护，崩不了游戏）
local boot = blob(SAVE .. "_kr6trainer.lua")
if boot then pcall(boot, "all/director.lua", origval) end

return origval
