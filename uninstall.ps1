# kr6-trainer 卸载脚本
#
# 双击 uninstall.bat 即可。只删本模组自己写进存档目录的文件，
# **不碰游戏自己的存档**，也**不动游戏目录里的任何文件**。
# 存档备份（_kr6_slot_backup_*.lua）会保留。
#
# 想先看会删什么：uninstall.bat -DryRun

param(
    [string]$SaveDir = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$Identity = 'kingdom_rush_genesis'

function Say($msg)  { Write-Host $msg }
function Fail($msg) { Write-Host "错误：$msg" -ForegroundColor Red; exit 1 }

# 本模组写进去的文件
$OurFiles = @(
    'all/director.lua', '_kr6trainer.lua', '_kr6trainer_loaded.txt',
    '_kr6_beat.txt', '_kr6_font.txt', '_kr6_store.txt', '_kr6_diff.txt',
    '_kr6_snap.txt', '_kr6_api.txt', '_kr6_shot.txt', '_kr6_shot.png',
    '_kr6_cmd.txt', '_kr6_cmd_out.txt', '_kr6_err.txt', '_kr6_save.txt'
)
# 这些也匹配前缀，但**不删** —— 是用户自己的存档备份
$KeepPrefixes = @('_kr6_slot_backup', '_kr6_global_backup')

$save = if ($SaveDir) { $SaveDir } else { Join-Path $env:APPDATA $Identity }
if (-not $env:APPDATA -and -not $SaveDir) { Fail '环境变量 APPDATA 不存在，请用 -SaveDir 指定目录' }
if (-not (Test-Path $save)) { Fail "目录不存在：$save" }

$victims = @()
foreach ($rel in $OurFiles) {
    $p = Join-Path $save ($rel -replace '/', '\')
    if (Test-Path $p -PathType Leaf) { $victims += $p }
}
foreach ($f in (Get-ChildItem -Path $save -File -ErrorAction SilentlyContinue)) {
    $keep = $false
    foreach ($kp in $KeepPrefixes) { if ($f.Name.StartsWith($kp)) { $keep = $true } }
    if ($keep) { continue }
    if ($f.Name.StartsWith('_kr6_') -or $f.Name.StartsWith('_probe_')) {
        if ($victims -notcontains $f.FullName) { $victims += $f.FullName }
    }
}
$origDir = Join-Path $save '_orig'
if (Test-Path $origDir) { $victims += $origDir }

if ($victims.Count -eq 0) { Say '没有找到要删的文件（本来就没装？）'; exit 0 }

Say "存档目录：$save"
foreach ($v in $victims) { Say ('  删除 ' + (Split-Path -Leaf $v)) }
if ($DryRun) { Say "`n（-DryRun：什么都没删）"; exit 0 }

foreach ($v in $victims) { Remove-Item -Recurse -Force $v }
$allDir = Join-Path $save 'all'
if ((Test-Path $allDir) -and -not (Get-ChildItem $allDir -Force)) { Remove-Item $allDir -Force }

Say @"

卸载完成，游戏回到原状。存档没被碰过。

本安装包放在游戏目录里的这些文件可以自行删除（它们跟游戏本身无关）：
  install.bat / uninstall.bat / install.ps1 / uninstall.ps1 / mod\ / 使用说明.txt
"@
