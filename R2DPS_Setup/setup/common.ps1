# R2DPS setup - shared helpers (Windows PowerShell 5.1+)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$script:SetupDir = $PSScriptRoot
$script:GameExe = 'Remnant2-Win64-Shipping.exe'
$script:SteamAppId = '1282100'
$script:Ue4ssMarker = 'R2DPS_installed_ue4ss.txt'
# R2DPS 0.6+ runs all its Lua on the game thread through this UE4SS function (not in old UE4SS builds)
$script:Ue4ssNeed = 'LoopInGameThreadWithDelay'

function Say([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Ok([string]$msg) { Say ("  [OK] " + $msg) 'Green' }
function Warn([string]$msg) { Say ("  [!]  " + $msg) 'Yellow' }
function Fail([string]$msg) {
    Say ("  [X]  " + $msg) 'Red'
    Read-Host "按回车退出" | Out-Null
    exit 1
}

function Ask-YesNo([string]$question, [bool]$defaultYes) {
    $hint = '[y/N]'
    if ($defaultYes) { $hint = '[Y/n]' }
    $a = Read-Host ("  " + $question + " " + $hint)
    if ([string]::IsNullOrWhiteSpace($a)) { return $defaultYes }
    return ($a.Trim().ToLower() -eq 'y')
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- locating the game ----------
function Test-Win64([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $p $script:GameExe))
}

function Resolve-Win64([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    $p = $p.Trim().Trim('"')
    if (Test-Path -LiteralPath $p -PathType Leaf) { $p = Split-Path -Parent $p }
    foreach ($c in @($p, (Join-Path $p 'Remnant2\Binaries\Win64'), (Join-Path $p 'Binaries\Win64'), (Join-Path $p 'Win64'),
                     (Join-Path $p 'common\Remnant2\Remnant2\Binaries\Win64'), (Join-Path $p 'steamapps\common\Remnant2\Remnant2\Binaries\Win64'))) {
        if (Test-Win64 $c) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

function Get-SteamLibraries {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $item = Get-ItemProperty -Path $k -ErrorAction Stop
            foreach ($n in @('SteamPath', 'InstallPath')) {
                $v = $item.$n
                if ($v) { $roots.Add(($v -replace '/', '\')) }
            }
        } catch {}
    }
    $libs = New-Object System.Collections.Generic.List[string]
    foreach ($r in ($roots | Select-Object -Unique)) {
        $libs.Add($r)
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            $text = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
            foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
                $libs.Add(($m.Groups[1].Value -replace '\\\\', '\'))
            }
        }
    }
    return ($libs | Select-Object -Unique)
}

function Find-GameWin64([string]$hint) {
    if ($hint) {
        $r = Resolve-Win64 $hint
        if ($r) { return $r }
        Warn "给定的路径里没找到游戏：$hint"
    }
    foreach ($lib in Get-SteamLibraries) {
        $r = Resolve-Win64 (Join-Path $lib 'steamapps\common\Remnant2')
        if ($r) { return $r }
    }
    foreach ($k in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App $($script:SteamAppId)",
                     "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam App $($script:SteamAppId)")) {
        try {
            $loc = (Get-ItemProperty -Path $k -ErrorAction Stop).InstallLocation
            $r = Resolve-Win64 $loc
            if ($r) { return $r }
        } catch {}
    }
    Warn "没有自动找到遗迹2的安装位置。"
    while ($true) {
        $p = Read-Host "  请把遗迹2的游戏文件夹拖进这个窗口（或粘贴路径），然后回车。直接回车退出"
        if ([string]::IsNullOrWhiteSpace($p)) { Fail "已取消。" }
        $r = Resolve-Win64 $p
        if ($r) { return $r }
        Warn "这个文件夹里没找到 $($script:GameExe)，再试一次（选 steamapps\common\Remnant2 这一层就行）。"
    }
}

function Wait-GameClosed {
    $name = [IO.Path]::GetFileNameWithoutExtension($script:GameExe)
    while (Get-Process -Name $name -ErrorAction SilentlyContinue) {
        Warn "遗迹2 正在运行，请先退出游戏。"
        Read-Host "  退出后按回车继续" | Out-Null
    }
}

function Test-WriteAccess([string]$dir) {
    $probe = Join-Path $dir ("r2dps_write_test_" + [guid]::NewGuid().ToString('N') + ".tmp")
    try {
        [IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch { return $false }
}

# Relaunch the calling script as administrator when the game folder is not writable.
function Ensure-Writable([string]$win64, [string]$scriptPath) {
    if (Test-WriteAccess $win64) { return }
    if (Test-IsAdmin) { Fail "管理员权限下也写不进游戏目录：$win64" }
    Warn "游戏目录需要管理员权限才能写入，马上会弹出权限确认，请点'是'。"
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"", '-GamePath', "`"$win64`"")
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
        Say "  已在新窗口（管理员）中继续，这个窗口可以关掉了。" 'Cyan'
    } catch {
        Fail "没有拿到管理员权限。也可以右键 Install.bat 选'以管理员身份运行'。"
    }
    exit 0
}

# ---------- UE4SS ----------
function Get-UE4SSInfo([string]$win64) {
    $proxy = @('dwmapi.dll', 'xinput1_3.dll') | Where-Object { Test-Path -LiteralPath (Join-Path $win64 $_) }
    $root = $null; $layout = 'none'
    if (Test-Path -LiteralPath (Join-Path $win64 'ue4ss\UE4SS.dll')) { $root = Join-Path $win64 'ue4ss'; $layout = 'subfolder' }
    elseif (Test-Path -LiteralPath (Join-Path $win64 'UE4SS.dll')) { $root = $win64; $layout = 'flat' }
    $mods = $null
    if ($root) { $mods = Join-Path $root 'Mods' }
    $installed = ($null -ne $root) -and (@($proxy).Count -gt 0)
    $info = [ordered]@{
        Win64     = $win64
        Layout    = $layout
        Root      = $root
        Mods      = $mods
        Proxy     = @($proxy)
        Installed = $installed
        Version   = $null
    }
    if ($root) {
        $log = Join-Path $root 'UE4SS.log'
        if (Test-Path -LiteralPath $log) {
            $line = Get-Content -LiteralPath $log -TotalCount 5 -Encoding UTF8 | Where-Object { $_ -match 'UE4SS - v' } | Select-Object -First 1
            if ($line) { $info.Version = ($line -replace '^\[[^\]]*\]\s*', '') }
        }
    }
    return $info
}

# Does this UE4SS.dll provide the game-thread timer R2DPS needs? (the Lua function name is stored
# as plain ASCII inside the DLL)
function Test-DllHasText([string]$dll, [string]$text) {
    if (-not (Test-Path -LiteralPath $dll)) { return $false }
    $bytes = [IO.File]::ReadAllBytes($dll)
    $hay = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    return ($hay.IndexOf($text, [StringComparison]::Ordinal) -ge 0)
}

function Find-UE4SSDll([string]$dir) {
    foreach ($c in @((Join-Path $dir 'ue4ss\UE4SS.dll'), (Join-Path $dir 'UE4SS.dll'))) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Test-UE4SSNew($u) {
    if (-not $u.Root) { return $false }
    return (Test-DllHasText (Join-Path $u.Root 'UE4SS.dll') $script:Ue4ssNeed)
}

# Turn off UE4SS's own debug windows and developer-only C++ mods (they cost performance).
function Set-UE4SSPerformance($u) {
    $ini = Join-Path $u.Root 'UE4SS-settings.ini'
    if (Test-Path -LiteralPath $ini) {
        $text = [IO.File]::ReadAllText($ini)
        foreach ($k in @('ConsoleEnabled', 'GuiConsoleEnabled', 'GuiConsoleVisible')) {
            $text = [regex]::Replace($text, "(?m)^(\s*$k\s*=\s*)\S+", '${1}0')
        }
        [IO.File]::WriteAllText($ini, $text)
        Ok "已关闭 UE4SS 调试窗口"
    }
    $modsTxt = Join-Path $u.Mods 'mods.txt'
    if (Test-Path -LiteralPath $modsTxt) {
        $text = [IO.File]::ReadAllText($modsTxt)
        $new = [regex]::Replace($text, '(?m)^(\s*(KismetDebuggerMod|EventViewerMod|jsbLuaProfilerMod)\s*:\s*)1', '${1}0')
        if ($new -ne $text) { [IO.File]::WriteAllText($modsTxt, $new); Ok "已关闭开发者调试 mod（KismetDebugger / EventViewer）" }
    }
}

# UE4SS's bundled mods that R2DPS does not need. BPModLoaderMod runs Lua on EVERY actor spawn
# (BeginPlay hook) and binds the Insert key in the same Lua state; the others only add a console /
# cheat manager / console commands. Keybinds (UE4SS's own hotkeys) is left alone.
$script:LeanMods = @('BPModLoaderMod', 'BPML_GenericFunctions', 'CheatManagerEnablerMod', 'ConsoleEnablerMod', 'ConsoleCommandsMod', 'LineTraceMod')

# Blueprint mods (.pak in Content\Paks\LogicMods) need BPModLoaderMod
function Test-HasLogicMods([string]$win64) {
    $dir = Join-Path (Split-Path -Parent (Split-Path -Parent $win64)) 'Content\Paks\LogicMods'
    if (-not (Test-Path -LiteralPath $dir)) { return $false }
    return (@(Get-ChildItem -LiteralPath $dir -Filter '*.pak' -File -ErrorAction SilentlyContinue).Count -gt 0)
}

function Set-UE4SSLean($u) {
    $modsTxt = Join-Path $u.Mods 'mods.txt'
    if (-not (Test-Path -LiteralPath $modsTxt)) { return }
    $text = [IO.File]::ReadAllText($modsTxt)
    $names = ($script:LeanMods | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $new = [regex]::Replace($text, "(?m)^(\s*($names)\s*:\s*)1", '${1}0')
    if ($new -ne $text) { [IO.File]::WriteAllText($modsTxt, $new); Ok ("已关闭 UE4SS 自带的、R2DPS 用不到的 mod：" + ($script:LeanMods -join ', ')) }
    else { Ok "UE4SS 自带的多余 mod 已经是关闭状态" }
}

# ---------- key = value files (config.txt / names.txt) ----------
function Get-KeySet([string]$file) {
    $set = @{}
    foreach ($line in [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)) {
        $l = $line.TrimStart([char]0xFEFF)
        if ($l -match '^\s*#') { continue }
        if ($l -match '^\s*([^=]+?)\s*=') { $set[$Matches[1]] = $true }
    }
    return $set
}

function Get-KeyValue([string]$file, [string]$key) {
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    foreach ($line in [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)) {
        $l = $line.TrimStart([char]0xFEFF)
        if ($l -match ('^\s*' + [regex]::Escape($key) + '\s*=\s*(.*?)\s*$')) { return $Matches[1] }
    }
    return $null
}

# Keep the user's file, append keys that only exist in the new default file.
function Merge-KeyFile([string]$userFile, [string]$defaultFile, [string]$version) {
    if (-not (Test-Path -LiteralPath $userFile)) { Copy-Item -LiteralPath $defaultFile -Destination $userFile; return 0 }
    $have = Get-KeySet $userFile
    $add = New-Object System.Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines($defaultFile, [Text.Encoding]::UTF8)) {
        $l = $line.TrimStart([char]0xFEFF)
        if ($l -match '^\s*#') { continue }
        if ($l -match '^\s*([^=]+?)\s*=' -and -not $have.ContainsKey($Matches[1])) { $add.Add($l) }
    }
    if ($add.Count -gt 0) {
        $nl = "`r`n"
        $header = '# ---- added by R2DPS setup ' + $version + ' ----'
        $block = $nl + $header + $nl + ($add -join $nl) + $nl
        [IO.File]::AppendAllText($userFile, $block, (New-Object Text.UTF8Encoding($false)))
    }
    return $add.Count
}
