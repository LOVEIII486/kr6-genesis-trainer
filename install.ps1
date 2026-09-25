# kr6-trainer 安装脚本
#
# 请把整个文件夹解压到**游戏根目录**（和 Kingdom Rush Genesis.exe 放在一起），
# 然后双击 install.bat。
#
# 本脚本做什么：从游戏自己的 exe 里取出它自己的 all/director.lua，
# 连同安装包里的两个文件一起写进游戏的存档目录。
# **不修改游戏目录里的任何文件。**
#
# 想先看会做什么而不写文件：install.bat -DryRun
# 手动指定位置：install.bat -GameDir "游戏目录" -SaveDir "存档目录"

param(
    [string]$GameDir = '',
    [string]$SaveDir = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$ExeName   = 'Kingdom Rush Genesis.exe'
$GameName  = 'Kingdom Rush Genesis'   # 游戏文件夹名（Steam 库里就是这个名字）
$Identity  = 'kingdom_rush_genesis'
$Target    = 'all/director.lua'      # 要被顶掉的那个模块（游戏自己的代码）
$Here      = $PSScriptRoot

function Say($msg)  { Write-Host $msg }
function Fail($msg) { Write-Host "错误：$msg" -ForegroundColor Red; exit 1 }

# 问注册表 + Steam 自己的库清单，拿到这台机器上所有的 Steam 库根目录。
# 硬编码猜路径覆盖不全（有玩家的库根是 D:\GAME），只能当兜底。
function Get-SteamLibraries {
    $out = @()
    try {
        $sp = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
    } catch { return $out }
    if (-not $sp) { return $out }
    $sp = $sp -replace '/', '\'
    $out += $sp
    $vdf = $sp + '\steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        try {
            $txt = Get-Content -LiteralPath $vdf -Raw -ErrorAction Stop
            foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) {
                $p = $m.Groups[1].Value -replace '\\\\', '\'
                if ($p) { $out += $p.TrimEnd('\') }
            }
        } catch { }
    }
    return $out
}

# FileStream.Read 不保证一次读满，补一个读满的辅助
function Read-Fully($stream, [byte[]]$buffer, [int]$count) {
    $got = 0
    while ($got -lt $count) {
        $n = $stream.Read($buffer, $got, $count - $got)
        if ($n -le 0) { break }
        $got += $n
    }
    return $got
}

# 游戏 exe = love.exe 的字节 + 追加在后面的 .love zip。
# 用中央目录结束记录（EOCD）定位 zip；中央目录里的偏移是相对 .love 起始的，
# 所以要整体加上 love.exe 那一段的长度（$delta）。
function Get-ZipEntry([string]$exe, [string]$wanted) {
    $fs = [IO.File]::Open($exe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $len = $fs.Length
        if ($len -lt 1024) { Fail '文件太小，不像这个游戏的主程序' }

        $tailLen = [Math]::Min(65557, $len)
        $fs.Seek($len - $tailLen, [IO.SeekOrigin]::Begin) | Out-Null
        $tail = New-Object byte[] $tailLen
        Read-Fully $fs $tail $tailLen | Out-Null

        $eocd = -1
        for ($i = $tailLen - 22; $i -ge 0; $i--) {
            if ($tail[$i] -eq 0x50 -and $tail[$i + 1] -eq 0x4B -and
                $tail[$i + 2] -eq 0x05 -and $tail[$i + 3] -eq 0x06) { $eocd = $i; break }
        }
        if ($eocd -lt 0) { Fail '在这个 exe 里找不到 zip 结束记录 —— 游戏版本不对？' }

        $count   = [BitConverter]::ToUInt16($tail, $eocd + 10)
        $cdSize  = [BitConverter]::ToUInt32($tail, $eocd + 12)
        $cdOff   = [BitConverter]::ToUInt32($tail, $eocd + 16)
        $cmtLen  = [BitConverter]::ToUInt16($tail, $eocd + 20)
        $cdStart = $len - $cmtLen - 22 - $cdSize
        $delta   = $cdStart - $cdOff

        $fs.Seek($cdStart, [IO.SeekOrigin]::Begin) | Out-Null
        $cd = New-Object byte[] $cdSize
        Read-Fully $fs $cd $cdSize | Out-Null

        $p = 0
        for ($k = 0; $k -lt $count; $k++) {
            if ([BitConverter]::ToUInt32($cd, $p) -ne 0x02014B50) { break }
            $meth = [BitConverter]::ToUInt16($cd, $p + 10)
            $csz  = [BitConverter]::ToUInt32($cd, $p + 20)
            $usz  = [BitConverter]::ToUInt32($cd, $p + 24)
            $nlen = [BitConverter]::ToUInt16($cd, $p + 28)
            $elen = [BitConverter]::ToUInt16($cd, $p + 30)
            $clen = [BitConverter]::ToUInt16($cd, $p + 32)
            $lho  = [BitConverter]::ToUInt32($cd, $p + 42)
            $name = [Text.Encoding]::UTF8.GetString($cd, $p + 46, $nlen)

            if ($name -eq $wanted) {
                $fs.Seek($lho + $delta, [IO.SeekOrigin]::Begin) | Out-Null
                $lh = New-Object byte[] 30
                Read-Fully $fs $lh 30 | Out-Null
                if ([BitConverter]::ToUInt32($lh, 0) -ne 0x04034B50) { Fail '本地文件头不合法' }
                $fs.Seek(([BitConverter]::ToUInt16($lh, 26) + [BitConverter]::ToUInt16($lh, 28)),
                         [IO.SeekOrigin]::Current) | Out-Null

                $raw = New-Object byte[] $csz
                Read-Fully $fs $raw $csz | Out-Null
                if ($meth -eq 0) { return $raw }
                if ($meth -ne 8) { Fail "不支持的压缩方式 $meth" }

                $ms = New-Object IO.MemoryStream(, $raw)
                $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Decompress)
                $out = New-Object IO.MemoryStream
                $ds.CopyTo($out)
                $ds.Dispose()
                $bytes = $out.ToArray()
                if ($bytes.Length -ne $usz) { Fail "解出来的大小不对（$($bytes.Length) != $usz）" }
                return $bytes
            }
            $p += 46 + $nlen + $elen + $clen
        }
        Fail "游戏里找不到 $wanted"
    } finally {
        $fs.Dispose()
    }
}

function Write-File([string]$path, [byte[]]$bytes) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllBytes($path, $bytes)
}

# ------------------------------------------------------------------ 主流程

# 优先用脚本自己所在的位置推游戏目录
$game = $GameDir
if (-not $game) {
    # 从脚本所在目录**逐级向上**找 exe：发行包解压出来是 kr6-trainer\ 一层子文件夹，
    # 所以脚本所在目录通常不是游戏根，而是它的下一层。只看本层会永远命中不了。
    $probe = $Here
    for ($up = 0; $up -lt 3 -and $probe; $up++) {
        if (Test-Path ($probe.TrimEnd('\') + '\' + $ExeName)) { $game = $probe; break }
        $parent = Split-Path -Parent $probe
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }
}
if (-not $game) {
    # 再问 Steam 要库目录（注册表 + libraryfolders.vdf 能覆盖非默认装法），
    # 最后才回落到硬编码的猜测。
    $cands = @()
    foreach ($lib in Get-SteamLibraries) {
        $cands += [IO.Path]::Combine($lib, 'steamapps', 'common', $GameName)
    }
    $cands += @(
        'C:\Program Files (x86)\Steam\steamapps\common\' + $GameName,
        'C:\Program Files\Steam\steamapps\common\' + $GameName,
        'D:\Steam\steamapps\common\' + $GameName,
        'D:\Game\Steam\steamapps\common\' + $GameName,
        'E:\Steam\steamapps\common\' + $GameName
    )
    foreach ($d in $cands) {
        # 用字符串拼接而**不是** Join-Path：Join-Path 会解析盘符，玩家机器上
        # 不存在的盘会抛 DriveNotFoundException；Test-Path 对不存在的盘只返回 False。
        if (Test-Path ($d.TrimEnd('\') + '\' + $ExeName)) { $game = $d; break }
    }
}
if (-not $game) {
    Fail "找不到 $ExeName。`n请把压缩包里的文件解压到游戏根目录（和 exe 放一起），或用 -GameDir 指定。"
}
# 同上：$GameDir 是玩家给的，盘符可能不存在，用 Join-Path 会抛异常。
$exe = $game.TrimEnd('\') + '\' + $ExeName
if (-not (Test-Path $exe)) { Fail "$ExeName 不在 $game 里" }

# ⚠️ 判空必须在**拼路径之前**：Join-Path 对空值是抛异常，不是返回空。
# 顺序写反的话，下面那句有用的提示永远轮不到，玩家只会看到一段天书。
if (-not $SaveDir -and -not $env:APPDATA) {
    Fail '环境变量 APPDATA 不存在，请用 -SaveDir 指定目录'
}
# 用字符串拼接而不是 Join-Path：-SaveDir 是玩家给的，盘符可能根本不存在，
# Join-Path 会解析盘符并抛出 DriveNotFoundException。
$save = if ($SaveDir) { $SaveDir } else { $env:APPDATA + '\' + $Identity }
$save = $save.TrimEnd('\')

$payloadSrc = Join-Path $Here 'mod\_kr6trainer.lua'
$shadowSrc  = Join-Path $Here 'mod\director.lua'
foreach ($f in @($payloadSrc, $shadowSrc)) {
    if (-not (Test-Path $f)) { Fail "缺少文件：$f`n（请先完整解压压缩包，不要只复制单个文件）" }
}

Say "游戏目录：$game"
Say "存档目录：$save"
Say "正在从游戏自己的 exe 里取出 $Target ..."

$blob = Get-ZipEntry $exe $Target
if ($blob.Length -lt 3 -or $blob[0] -ne 0x1B -or $blob[1] -ne 0x4C -or $blob[2] -ne 0x4A) {
    Fail '取出的不是本游戏需要的代码 —— 游戏版本变了？'
}
Say "  取出成功：$($blob.Length) 字节"

$payload = [IO.File]::ReadAllBytes($payloadSrc)
$shadow  = [IO.File]::ReadAllBytes($shadowSrc)

# ⚠️ **顺序别调换**：覆盖桩必须**最后**写。它会让游戏去加载另外两份，先写它而
# 中途失败的话，游戏下次启动就是「装了但什么都没发生」；这个顺序只会留下无用文件。
$plan = @(
    @{ path = ($save + '\_orig\all_director.luac'); bytes = $blob },
    @{ path = ($save + '\_kr6trainer.lua');         bytes = $payload },
    @{ path = ($save + '\all\director.lua');        bytes = $shadow }
)

Say ''
foreach ($item in $plan) {
    $verb = if ($DryRun) { '将写入' } else { '写入  ' }
    Say "$verb $($item.path)  ($($item.bytes.Length) 字节)"
}
if ($DryRun) { Say "`n（-DryRun：什么都没写）"; exit 0 }

foreach ($item in $plan) { Write-File $item.path $item.bytes }

# 游戏**正在跑**的时候装：文件能写进去，但那个进程在启动时就已经把旧版本读进内存了，
# 不会重新读 —— 玩家会看到「装了但什么都没发生」。这个坑真的踩过（自己也踩过），
# 所以这里明确说一句，而不是让玩家去猜。
$running = @(Get-Process -Name ($ExeName -replace '\.exe$', '') -ErrorAction SilentlyContinue).Count -gt 0

Say ''
Say '安装完成。'
Say ''
if ($running) {
    Say '  ⚠ 游戏现在正开着 —— 请**先退出游戏再重新启动**，否则刚才装的不会生效。'
    Say ''
}
Say '  1. 启动游戏'
Say '  2. 游戏里按 Home 键开关修改器菜单'
Say '     ↑↓ 选择   ←→ 调整   Enter 执行   Esc 关闭（鼠标点击也行）'
Say ''
Say '卸载：双击 uninstall.bat'
Say ''
Say '提醒：改存档进度的功能会写你的存档，用之前请先备份存档目录。'
