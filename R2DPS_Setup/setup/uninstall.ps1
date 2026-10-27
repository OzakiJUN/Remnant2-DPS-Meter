param([string]$GamePath = '')
# R2DPS uninstaller: removes the mod; removes UE4SS only if this setup installed it and you agree.
. "$PSScriptRoot\common.ps1"

Say ""
Say "=== R2DPS 卸载 ===" 'Cyan'
$win64 = Find-GameWin64 $GamePath
Ok "游戏目录：$win64"
Wait-GameClosed
Ensure-Writable $win64 $PSCommandPath

$u = Get-UE4SSInfo $win64
if (-not $u.Root) { Warn "没有检测到 UE4SS，也就没有 R2DPS 可卸载。"; Read-Host "按回车退出" | Out-Null; exit 0 }

$dst = Join-Path $u.Mods 'R2DPS'
if (Test-Path -LiteralPath $dst) {
    if (Ask-YesNo "删除 R2DPS（包括你改过的 config.txt / names.txt）？" $true) {
        Remove-Item -LiteralPath $dst -Recurse -Force
        Ok "R2DPS 已删除"
    }
} else { Warn "没有找到 R2DPS 文件夹" }

$marker = Join-Path $u.Root $script:Ue4ssMarker
if ((Test-Path -LiteralPath $marker) -and $u.Layout -eq 'subfolder') {
    $others = @()
    if (Test-Path -LiteralPath $u.Mods) {
        $std = @('shared', 'Keybinds', 'BPModLoaderMod', 'BPML_GenericFunctions', 'CheatManagerEnablerMod', 'ConsoleCommandsMod',
                 'ConsoleEnablerMod', 'SplitScreenMod', 'LineTraceMod', 'ActorDumperMod', 'jsbLuaProfilerMod')
        $others = @(Get-ChildItem -LiteralPath $u.Mods -Directory | Where-Object { $std -notcontains $_.Name } | ForEach-Object { $_.Name })
    }
    Say ""
    Say "  UE4SS 是这个安装程序装的。" 'Cyan'
    if ($others.Count -gt 0) { Warn ("Mods 里还有其他 mod：" + ($others -join ', ') + "，删除 UE4SS 后它们也会失效。") }
    if (Ask-YesNo "连 UE4SS 一起删除？" $false) {
        foreach ($p in $u.Proxy) { Remove-Item -LiteralPath (Join-Path $win64 $p) -Force }
        Remove-Item -LiteralPath $u.Root -Recurse -Force
        Ok "UE4SS 已删除"
    }
} elseif ($u.Installed) {
    Say "  UE4SS 不是这个安装程序装的，保留不动。" 'Gray'
}

Say ""
Say "  完成。" 'Green'
Read-Host "按回车退出" | Out-Null
