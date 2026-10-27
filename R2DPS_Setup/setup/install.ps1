param([string]$GamePath = '')
# R2DPS one-click installer: finds Remnant 2, installs UE4SS only if missing, installs / updates the mod.
. "$PSScriptRoot\common.ps1"

$Version = '1.0.0'
$PkgMod = Join-Path $PSScriptRoot 'R2DPS'
$BundleDir = Join-Path $PSScriptRoot 'ue4ss_bundle'

Say ""
Say "==============================================" 'Cyan'
Say "  R2DPS $Version 安装（遗迹2 伤害统计）" 'Cyan'
Say "==============================================" 'Cyan'

# 1. game folder
$win64 = Find-GameWin64 $GamePath
Ok "游戏目录：$win64"
Wait-GameClosed
Ensure-Writable $win64 $PSCommandPath

# 2. UE4SS
# Unpacks a UE4SS zip into a temp folder. Returns the folder that holds dwmapi.dll (the game's
# Win64 layout), or $null when the zip is not UE4SS.
function Expand-Ue4ssZip([string]$zip) {
    $tmp = Join-Path $env:TEMP ("R2DPS_ue4ss_" + [guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    # the zip may contain the files directly or inside one top folder
    $dll = Get-ChildItem -LiteralPath $tmp -Recurse -File | Where-Object { $_.Name -in @('dwmapi.dll', 'xinput1_3.dll') } | Select-Object -First 1
    if (-not $dll) { Remove-Item -LiteralPath $tmp -Recurse -Force; return $null }
    return [pscustomobject]@{ Tmp = $tmp; Dir = $dll.DirectoryName }
}

function Test-StageNew($stage) {
    $d = Find-UE4SSDll $stage.Dir
    return ($d -and (Test-DllHasText $d $script:Ue4ssNeed))
}

function Get-Ue4ssDownload {
    Warn "从 GitHub 下载最新 experimental 版 UE4SS..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $hdr = @{ 'User-Agent' = 'R2DPS-Setup' }
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/tags/experimental-latest' -Headers $hdr -TimeoutSec 30
        $asset = $rel.assets | Where-Object { $_.name -match '^UE4SS_v.*\.zip$' } | Sort-Object { [datetime]$_.updated_at } -Descending | Select-Object -First 1
        if (-not $asset) { throw "release 里没找到 UE4SS_v*.zip" }
        $out = Join-Path $env:TEMP $asset.name
        Say "  下载 $($asset.name) ..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $out -UseBasicParsing -Headers $hdr -TimeoutSec 300
        Ok "下载完成"
        return $out
    } catch {
        Say "  下载失败：$($_.Exception.Message)" 'Red'
        Fail "请到 https://github.com/OzakiJUN/Remnant2-DPS-Meter/releases 下载完整安装包（自带 UE4SS），或者把新版 UE4SS 的 zip 手动放进 setup\ue4ss_bundle 再运行一次。"
    }
}

# A UE4SS that has the game-thread timer: the bundled zip if it is new enough, otherwise a download.
function Get-NewUe4ssStage {
    if (Test-Path -LiteralPath $BundleDir) {
        $z = Get-ChildItem -LiteralPath $BundleDir -Filter '*.zip' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($z) {
            $st = Expand-Ue4ssZip $z.FullName
            if (-not $st) { Warn "安装包里的 $($z.Name) 不像 UE4SS（里面没有 dwmapi.dll），不用它" }
            elseif (Test-StageNew $st) { Ok "使用安装包里自带的 UE4SS：$($z.Name)"; return $st }
            else { Warn "安装包里自带的 UE4SS 是旧版（没有游戏线程定时器），不用它"; Remove-Item -LiteralPath $st.Tmp -Recurse -Force }
        }
    }
    $zip = Get-Ue4ssDownload
    $st = Expand-Ue4ssZip $zip
    if (-not $st) { Fail "下载的文件不像 UE4SS：$zip" }
    if (-not (Test-StageNew $st)) {
        Remove-Item -LiteralPath $st.Tmp -Recurse -Force
        Fail "下载的 UE4SS 里也没有 R2DPS 需要的 $($script:Ue4ssNeed)。请截图这个窗口发给作者。"
    }
    return $st
}

# Copies the whole old UE4SS (and its loader dll) to <Win64>\ue4ss_backup_<date>, then removes
# the parts that would clash with the new one (old loader dll / old flat-layout files).
function Backup-OldUE4SS($old, $stage) {
    $bak = Join-Path $win64 ('ue4ss_backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $bak -Force | Out-Null
    foreach ($p in $old.Proxy) { Copy-Item -LiteralPath (Join-Path $win64 $p) -Destination (Join-Path $bak $p) -Force }
    if ($old.Layout -eq 'subfolder') {
        Copy-Item -LiteralPath $old.Root -Destination (Join-Path $bak 'ue4ss') -Recurse -Force
    } elseif ($old.Layout -eq 'flat') {
        foreach ($n in @('UE4SS.dll', 'UE4SS-settings.ini')) {
            $s = Join-Path $win64 $n
            if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $bak $n) -Force }
        }
        foreach ($n in @('Mods', 'UE4SS_Signatures', 'CustomGameConfigs')) {
            $s = Join-Path $win64 $n
            if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $bak $n) -Recurse -Force }
        }
    }
    Ok "旧 UE4SS 已备份到：$bak"
    # a loader dll the new UE4SS does not ship would load the old UE4SS a second time
    foreach ($p in $old.Proxy) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage.Dir $p))) { Remove-Item -LiteralPath (Join-Path $win64 $p) -Force }
    }
    return $bak
}

function Install-UE4SSStage($stage) {
    Copy-Item -Path (Join-Path $stage.Dir '*') -Destination $win64 -Recurse -Force
    Remove-Item -LiteralPath $stage.Tmp -Recurse -Force
}

$u = Get-UE4SSInfo $win64
$freshUe4ss = $false
$ver = '版本未知'
if ($u.Version) { $ver = $u.Version }
if ($u.Installed -and (Test-UE4SSNew $u)) {
    Ok "已安装 UE4SS（$ver），版本满足要求，跳过 UE4SS 安装"
} elseif ($u.Installed) {
    Say ""
    Warn "已安装的 UE4SS（$ver）是旧版：没有 R2DPS 0.6 需要的'游戏线程定时器'。"
    Warn "0.5.x 的闪退就是因为旧版只能在后台线程定时刷新。不升级的话 R2DPS 不会启动（不会崩，只是没有统计）。"
    if (Ask-YesNo "现在升级 UE4SS？（旧的会整个备份，Mods 里的其他 mod 保留）" $true) {
        $stage = Get-NewUe4ssStage
        $old = $u
        $bak = Backup-OldUE4SS $old $stage
        Install-UE4SSStage $stage
        $u = Get-UE4SSInfo $win64
        if (-not $u.Installed -or -not (Test-UE4SSNew $u)) { Fail "升级后检测不到新版 UE4SS。旧的备份在 $bak，请截图这个窗口发给作者。" }
        if ($old.Layout -eq 'flat' -and $u.Layout -eq 'subfolder') {
            # old flat layout: move the user's mods into the new ue4ss\Mods, drop the old flat files
            $oldMods = Join-Path $win64 'Mods'
            if (Test-Path -LiteralPath $oldMods) {
                foreach ($d in Get-ChildItem -LiteralPath $oldMods -Directory) {
                    $to = Join-Path $u.Mods $d.Name
                    if (-not (Test-Path -LiteralPath $to)) { Copy-Item -LiteralPath $d.FullName -Destination $to -Recurse -Force }
                }
            }
            foreach ($n in @('UE4SS.dll', 'UE4SS-settings.ini', 'Mods', 'UE4SS_Signatures', 'CustomGameConfigs')) {
                $s = Join-Path $win64 $n
                if (Test-Path -LiteralPath $s) { Remove-Item -LiteralPath $s -Recurse -Force }
            }
            Ok "旧版是老式布局，已把你的 mod 搬进新的 ue4ss\Mods"
        }
        [IO.File]::WriteAllText((Join-Path $u.Root $script:Ue4ssMarker), "UE4SS upgraded by R2DPS setup $Version on $(Get-Date -Format s), backup: $bak")
        $freshUe4ss = $true
        Ok "UE4SS 已升级（$($u.Layout)）"
    } else {
        Warn "没有升级 UE4SS：R2DPS 照常安装，但进游戏后不会启动。以后想用就再运行一次 Install.bat。"
    }
} else {
    if ($u.Root -and @($u.Proxy).Count -eq 0) { Warn "UE4SS 文件在，但缺少加载用的 dwmapi.dll，重新安装 UE4SS" }
    Install-UE4SSStage (Get-NewUe4ssStage)
    $u = Get-UE4SSInfo $win64
    if (-not $u.Installed) { Fail "UE4SS 安装后仍然检测不到，请把这个窗口截图发给作者。" }
    [IO.File]::WriteAllText((Join-Path $u.Root $script:Ue4ssMarker), "UE4SS installed by R2DPS setup $Version on $(Get-Date -Format s)")
    $freshUe4ss = $true
    Ok "UE4SS 安装完成（$($u.Layout)）"
}
if (-not (Test-Path -LiteralPath $u.Mods)) { New-Item -ItemType Directory -Path $u.Mods -Force | Out-Null }

# 3. the mod itself (config.txt / names.txt are kept and only get new keys appended)
$dst = Join-Path $u.Mods 'R2DPS'
$update = Test-Path -LiteralPath $dst
New-Item -ItemType Directory -Path (Join-Path $dst 'Scripts') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PkgMod 'Scripts\main.lua') -Destination (Join-Path $dst 'Scripts\main.lua') -Force
Copy-Item -LiteralPath (Join-Path $PkgMod 'README_CN.txt') -Destination (Join-Path $dst 'README_CN.txt') -Force
Copy-Item -LiteralPath (Join-Path $PkgMod 'enabled.txt') -Destination (Join-Path $dst 'enabled.txt') -Force
$oldReadme = Join-Path $dst ([string][char]0x4F7F + [char]0x7528 + [char]0x8BF4 + [char]0x660E + '.txt') # old readme name
if (Test-Path -LiteralPath $oldReadme) { Remove-Item -LiteralPath $oldReadme -Force }
# config.txt layout changed (config_version): old file is kept as a backup and replaced
$userCfg = Join-Path $dst 'config.txt'
$pkgCfg = Join-Path $PkgMod 'config.txt'
if (Test-Path -LiteralPath $userCfg) {
    $uv = 0; $pv = 0
    [void][int]::TryParse([string](Get-KeyValue $userCfg 'config_version'), [ref]$uv)
    [void][int]::TryParse([string](Get-KeyValue $pkgCfg 'config_version'), [ref]$pv)
    if ($uv -lt $pv) {
        $bak = Join-Path $dst ('config_backup_v' + $uv + '.txt')
        Copy-Item -LiteralPath $userCfg -Destination $bak -Force
        Copy-Item -LiteralPath $pkgCfg -Destination $userCfg -Force
        Ok "config.txt 换成了新版布局（旧的备份为 $(Split-Path -Leaf $bak)）"
    }
}
foreach ($f in @('config.txt', 'names.txt')) {
    $added = Merge-KeyFile (Join-Path $dst $f) (Join-Path $PkgMod $f) $Version
    if ($update -and $added -gt 0) { Ok "$f 保留了你的修改，补充了 $added 个新条目" }
}
if ($update) { Ok "R2DPS 已更新到 $Version" } else { Ok "R2DPS $Version 安装完成" }

# 4. performance: UE4SS debug windows / dev mods
if ($freshUe4ss) {
    Set-UE4SSPerformance $u
} else {
    Say ""
    if (Ask-YesNo "关闭 UE4SS 的调试窗口和开发者调试 mod？（推荐，减少性能占用）" $true) { Set-UE4SSPerformance $u }
}

# 5. UE4SS's own extra mods (BP mod loader etc.): R2DPS does not need them
Say ""
if (Test-HasLogicMods $win64) {
    Warn "检测到你装了 BP mod（Content\Paks\LogicMods 里有 .pak），它们需要 UE4SS 自带的 BPModLoaderMod。"
    if (Ask-YesNo "仍然关闭 UE4SS 自带的多余 mod？（选 y 的话那些 BP mod 会失效）" $false) { Set-UE4SSLean $u }
} else {
    if (Ask-YesNo "关闭 UE4SS 自带的、R2DPS 用不到的 mod？（BP mod 加载器会在每个敌人/子弹生成时跑脚本，推荐关）" $true) { Set-UE4SSLean $u }
}

Say ""
Say "  全部完成！启动游戏即可。" 'Green'
Say "  - 小 HUD：右上角小地图下面"
Say "  - 战斗中点一下 H 开 / 再点关，按住 H 看完松开就收：屏幕左边的详细面板"
Say "  - Tab 菜单 -> 碎片页：右上角'伤害统计'卡片，点开看完整面板"
Say "  - 设置：$dst\config.txt"
Say "  - 日志：$dst\R2DPS_debug.txt（反馈问题时附上）"
Say ""
Read-Host "按回车退出" | Out-Null
