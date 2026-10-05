-- kr6 模块覆盖桩（部署为 all/director.lua）
--
-- 先从 _orig/ 读回游戏**自己的原始字节码**执行，拿到的模块表交给修改器，最后原样返回
-- —— 游戏跑的还是它自己的代码。
-- ⚠️ 只覆盖走正常 require 的模块；游戏用沙箱环境（level_utils.eval_file + setfenv）加载的
-- 绝不碰 —— 那些环境里没有 string/io。
-- 存档目录。⚠️ Windows 上 Lua 的 io.open 用**系统 ANSI 代码页**解释路径（游戏 exe 的
-- manifest 没声明 activeCodePage），而 love.filesystem.getSaveDirectory() 给的是 **UTF-8**
-- 字节 —— 用户名含中文等非 ASCII 字符时两者对不上，**所有文件读写都会失败**
-- （v12 的真实事故：这里读不到 _orig，游戏拿到 boolean 直接崩）。
-- 所以：先用 LÖVE 的路径试写；不行就把它转成 ANSI 码页再试（只有 Windows 需要转）。
-- 都不行才退回 %APPDATA% 猜测 —— 那是 v11 用了 11 个版本的写法。
local function ansi_path(p)
  if type(jit) ~= "table" or jit.os ~= "Windows" then return nil end
  local ok, ffi = pcall(require, "ffi")
  if not ok then return nil end
  pcall(ffi.cdef, "int MultiByteToWideChar(unsigned int, unsigned long, const char*, int, void*, int);")
  pcall(ffi.cdef, "int WideCharToMultiByte(unsigned int, unsigned long, const void*, int, char*, int, const char*, int*);")
  local n = ffi.C.MultiByteToWideChar(65001, 0, p, -1, nil, 0)
  if n <= 0 then return nil end
  local w = ffi.new("wchar_t[?]", n)
  if ffi.C.MultiByteToWideChar(65001, 0, p, -1, w, n) <= 0 then return nil end
  local m = ffi.C.WideCharToMultiByte(0, 0, w, -1, nil, 0, nil, nil)
  if m <= 0 then return nil end
  local a = ffi.new("char[?]", m)
  if ffi.C.WideCharToMultiByte(0, 0, w, -1, a, m, nil, nil) <= 0 then return nil end
  return ffi.string(a, m - 1)
end

local function usable(p)   -- 这个路径的字节 io.open 认不认：往那个目录写个探针文件试试
  local f = io.open(p .. "_kr6_probe.tmp", "wb")
  if not f then return false end
  f:close()
  os.remove(p .. "_kr6_probe.tmp")
  return true
end

local function save_dir()
  local lfs = (type(love) == "table") and love.filesystem
  local p
  if lfs and lfs.getSaveDirectory then
    local ok, d = pcall(lfs.getSaveDirectory)
    if ok and type(d) == "string" and d ~= "" then p = (d:gsub("/+$", "")) .. "/" end
  end
  local best = (p and usable(p)) and p or nil
  if not best and p then
    local a = ansi_path(p)
    if a and usable(a) then best = a end
  end
  if not best then
    local base = os.getenv("APPDATA")
    if base then best = base .. "/kingdom_rush_genesis/" end
  end
  return best or p or "./"
end
local SAVE = save_dir()

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
local chunk, cerr = blob(SAVE .. "_orig/all_director.luac")
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
