#requires -Version 5.1
<#
.SYNOPSIS
    在桌面创建“OPPO 互联”快捷方式（指向无窗口的 VBS 启动器）。

.DESCRIPTION
    快捷方式目标为 wscript.exe，参数为 Start-OppoConnect.vbs：
      * 双击不产生终端窗口；
      * UAC 由 VBS 内部的 ShellExecute "runas" 触发（仅一次）；
      * 不依赖 .vbs 文件关联，也不需要在快捷方式属性里勾选“以管理员身份运行”。

.EXAMPLE
    .\Create-Shortcut.ps1
#>
[CmdletBinding()]
param(
    [string]$ShortcutPath = '',
    [switch]$Force
)

$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'OppoConnectTun.Common.ps1')

$target = Join-Path $scriptDir 'Start-OppoConnect.vbs'
if (-not (Test-Path -LiteralPath $target)) {
    Write-Host "找不到启动器: $target" -ForegroundColor Red
    exit 2
}

if (-not $ShortcutPath) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $ShortcutPath = Join-Path $desktop 'OPPO互联.lnk'
}

if ((Test-Path -LiteralPath $ShortcutPath) -and -not $Force) {
    Write-Host "快捷方式已存在: $ShortcutPath（加 -Force 覆盖）" -ForegroundColor Yellow
    exit 0
}

$install = Resolve-OppoInstallDir
$icon    = Join-Path $install 'O+Connect.exe'
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'

try {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($ShortcutPath)
    $lnk.TargetPath       = $wscript
    $lnk.Arguments        = '"{0}"' -f $target
    $lnk.WorkingDirectory = $scriptDir
    $lnk.Description      = 'OPPO 互联启动器（一次 UAC，退出后自动注销服务、卸载网卡）'
    if (Test-Path -LiteralPath $icon) {
        $lnk.IconLocation = '{0},0' -f $icon
    }
    $lnk.Save()
} catch {
    Write-Host ("创建快捷方式失败: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

Write-Host ("已创建快捷方式: {0}" -f $ShortcutPath) -ForegroundColor Green
Write-Host ("目标: {0} `"{1}`"" -f $wscript, $target) -ForegroundColor Gray
