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

$ExeName  = 'Kingdom Rush Genesis.exe'
$Identity = 'kingdom_rush_genesis'
$Target   = 'all/director.lua'      # 要被顶掉的那个模块（游戏自己的代码）
$Here     = $PSScriptRoot

function Say($msg)  { Write-Host $msg }
function Fail($msg) { Write-Host "错误：$msg" -ForegroundColor Red; exit 1 }

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

# 优先用脚本自己所在的目录当游戏目录（发行版就是让你解压到游戏根目录）
$game = $GameDir
if (-not $game -and (Test-Path (Join-Path $Here $ExeName))) { $game = $Here }
if (-not $game) {
    $cands = @(
        'C:\Program Files (x86)\Steam\steamapps\common\Kingdom Rush Genesis',
        'C:\Program Files\Steam\steamapps\common\Kingdom Rush Genesis',
        'D:\Steam\steamapps\common\Kingdom Rush Genesis',
        'D:\Game\Steam\steamapps\common\Kingdom Rush Genesis',
        'E:\Steam\steamapps\common\Kingdom Rush Genesis'
    )
    foreach ($d in $cands) { if (Test-Path (Join-Path $d $ExeName)) { $game = $d; break } }
}
if (-not $game) {
    Fail "找不到 $ExeName。`n请把本文件夹解压到游戏根目录（和 exe 放一起），或用 -GameDir 指定。"
}
$exe = Join-Path $game $ExeName
if (-not (Test-Path $exe)) { Fail "$ExeName 不在 $game 里" }

$save = if ($SaveDir) { $SaveDir } else { Join-Path $env:APPDATA $Identity }
if (-not $env:APPDATA -and -not $SaveDir) { Fail '环境变量 APPDATA 不存在，请用 -SaveDir 指定目录' }

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

$plan = @(
    @{ path = (Join-Path $save 'all\director.lua');        bytes = $shadow },
    @{ path = (Join-Path $save '_orig\all_director.luac'); bytes = $blob },
    @{ path = (Join-Path $save '_kr6trainer.lua');         bytes = $payload }
)

Say ''
foreach ($item in $plan) {
    $verb = if ($DryRun) { '将写入' } else { '写入  ' }
    Say "$verb $($item.path)  ($($item.bytes.Length) 字节)"
}
if ($DryRun) { Say "`n（-DryRun：什么都没写）"; exit 0 }

foreach ($item in $plan) { Write-File $item.path $item.bytes }

Say @"

安装完成。

  1. 启动游戏
  2. 游戏里按 Home 键开关修改器菜单
     ↑↓ 选择   ←→ 调整   Enter 执行   Esc 关闭（鼠标点击也行）

卸载：双击 uninstall.bat

提醒：改存档进度的功能会写你的存档，用之前请先备份存档目录。
"@
