#requires -Version 5.1
<#
.SYNOPSIS
    卸载（注销）OPPO 互联创建的 Wintun 虚拟网卡，解决其与代理 TUN 网卡冲突导致断网的问题。

.DESCRIPTION
    OPPO 互联的 “O+Connect Service”（devicespace.exe，LocalSystem 自启动）会加载
    daemon\wintun.dll 并创建以下虚拟网卡：
      - vgateN ：服务启动时固定创建的“虚拟网关”网卡（Wi-Fi P2P / 软 AP 场景）
      - utunN  ：OPPO 设备通过 USB 接入时按需创建的隧道网卡
    这些网卡会插入自己的路由/接口状态，与代理（如 Clash Verge 的 Meta Tunnel）
    的 TUN 网卡冲突，导致流量丢失。

    本脚本默认只做检测（Dry-run），加 -Apply 才会真正：
      1. 备份当前网卡/服务/路由状态到 state 目录；
      2. 停止 OPPO 常驻守护服务，释放 Wintun 会话；
      3. 用 pnputil /remove-device 删除 OPPO 的两个 Wintun 设备节点；
      4. 复查是否删除干净。
    注意：只删“OPPO 的适配器”，不会删除 wintun.sys 驱动（代理也在用）。

    可选 -ServiceMode 处理两个守护服务的注册：
      Keep（默认） | Manual（改为手动，推荐） | Disabled（禁用） | Delete（注销服务）

.EXAMPLE
    .\Remove-OppoConnectTun.ps1
    仅检测并列出将会删除哪些网卡。

.EXAMPLE
    .\Remove-OppoConnectTun.ps1 -Apply
    实际卸载（需要管理员权限，请在提升的 PowerShell 中运行）。

.EXAMPLE
    .\Remove-OppoConnectTun.ps1 -Apply -KillProcesses -Force
    强制卸载（结束残留进程、对占用中的设备使用 /force）。
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$NoStopServices,
    [switch]$KillProcesses,
    [switch]$Force,
    [switch]$RebootIfNeeded,
    [string[]]$AdapterName = @(),
    [ValidateSet('Keep', 'Manual', 'Disabled', 'Delete')][string]$ServiceMode = 'Keep',
    [string]$InstallDir = ''
)

$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'OppoConnectTun.Common.ps1')

$logDir   = Join-Path $scriptDir 'logs'
$stateDir = Join-Path $scriptDir 'state'
$logFile  = New-LogFile -Dir $logDir -Prefix 'remove'
$install  = Resolve-OppoInstallDir -Preferred $InstallDir
$isAdmin  = Test-IsAdmin

Write-Log '================ OPPO 互联 TUN 网卡卸载工具 ================' INFO $logFile
Write-Log ("时间       : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) INFO $logFile
Write-Log ("主机       : {0}" -f $env:COMPUTERNAME) INFO $logFile
Write-Log ("管理员权限 : {0}" -f $isAdmin) INFO $logFile
Write-Log ("OPPO 目录  : {0}" -f $install) INFO $logFile
Write-Log ("运行模式   : {0}" -f $(if ($Apply) { '实际执行 (Apply)' } else { '仅检测 (Dry-run)' })) INFO $logFile

# ---------------------------------------------------------------------------
# 1. 检测
# ---------------------------------------------------------------------------
$allAdapters   = @(Get-OppoAdapters -InstallDir $install)
$oppoAdapters  = @($allAdapters | Where-Object { $_.IsOppo })
if ($AdapterName.Count -gt 0) {
    $oppoAdapters = @($oppoAdapters | Where-Object { $AdapterName -contains $_.Name })
}
$proxyAdapters = @(Get-ProxyTunAdapters)
$services      = @(Get-OppoServiceStates)
$processes     = @(Get-OppoProcesses)

Write-Log '--- 系统 Wintun 设备节点 ---' INFO $logFile
if ($allAdapters.Count -eq 0) {
    Write-Host '  (无)' -ForegroundColor DarkGray
} else {
    $allAdapters |
        Select-Object @{n='判定';e={ if ($_.IsOppo) { 'OPPO' } else { '-' } }}, Name, Description, Status, InstanceId |
        Format-Table -AutoSize | Out-String -Width 4096 | Write-Host
}

Write-Log '--- OPPO 互联守护服务 ---' INFO $logFile
$services | Select-Object Name, Status, StartMode, ProcessId | Format-Table -AutoSize | Out-String -Width 4096 | Write-Host

Write-Log '--- OPPO 相关进程 ---' INFO $logFile
if ($processes.Count -eq 0) {
    Write-Host '  (无)' -ForegroundColor DarkGray
} else {
    $processes | Select-Object Id, Name, StartTime | Format-Table -AutoSize | Out-String -Width 4096 | Write-Host
}
$appProcs = @($processes | Where-Object { $script:OppoAppProcessNames -contains $_.Name })
if ($appProcs.Count -gt 0) {
    Write-Log '提示：OPPO 互联客户端正在运行，建议先退出客户端再执行卸载，避免其自动重启守护服务。' WARN $logFile
}

Write-Log '--- 代理 TUN 网卡（用于判断冲突源） ---' INFO $logFile
if ($proxyAdapters.Count -eq 0) {
    Write-Host '  (未检测到代理 TUN 网卡)' -ForegroundColor DarkGray
} else {
    $proxyAdapters | Select-Object Name, Description, Status, @{n='IPv4';e={($_.IPv4 -join ', ')}} | Format-Table -AutoSize | Out-String -Width 4096 | Write-Host
    if (@($proxyAdapters | Where-Object { $_.Status -eq 'Up' }).Count -gt 0) {
        Write-Log '检测到处于 Up 状态的代理 TUN 网卡，它就是与 OPPO 互联争抢流量的对象。' WARN $logFile
    }
}

if ($oppoAdapters.Count -eq 0) {
    Write-Log '未发现 OPPO 互联的 TUN 网卡（可能已经卸载，或服务尚未创建）。' OK $logFile
    Write-Log '无需处理。' INFO $logFile
    exit 0
}

Write-Log ("共发现 {0} 个待卸载的 OPPO 网卡：" -f $oppoAdapters.Count) WARN $logFile
$oppoAdapters | Select-Object Name, Description, Status, @{n='IPv4';e={($_.IPv4 -join ', ')}}, InstanceId | Format-Table -AutoSize | Out-String -Width 4096 | Write-Host

# ---------------------------------------------------------------------------
# 2. 计划
# ---------------------------------------------------------------------------
$svcToStop = @($services | Where-Object { $_.Status -ne 'Stopped' -and $_.Status -ne 'Not Installed' } | ForEach-Object { $_.Name })
Write-Log ("计划停止的服务: {0}" -f $(if ($NoStopServices) { '(已跳过，-NoStopServices)' } elseif ($svcToStop.Count -gt 0) { $svcToStop -join ', ' } else { '(无需停止)' })) INFO $logFile
Write-Log ("服务处理方式    : {0}" -f $ServiceMode) INFO $logFile
Write-Log ("计划删除的网卡: {0}" -f (($oppoAdapters | ForEach-Object { $_.Name }) -join ', ')) INFO $logFile

if (-not $Apply) {
    Write-Log '' INFO $logFile
    Write-Log '当前为 Dry-run，未做任何修改。' WARN $logFile
    Write-Log '确认无误后，请以管理员身份运行：' INFO $logFile
    Write-Log ('  powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Apply' -f $PSCommandPath) INFO $logFile
    Write-Log '请在“以管理员身份运行”的 PowerShell 中执行。' INFO $logFile
    exit 0
}

if (-not $isAdmin) {
    Write-Log '执行卸载需要管理员权限。请在“以管理员身份运行”的 PowerShell 中执行。' ERROR $logFile
    exit 2
}

# ---------------------------------------------------------------------------
# 3. 备份状态
# ---------------------------------------------------------------------------
$stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupPath = Join-Path $stateDir ("oppo-tun-state-{0}.json" -f $stamp)
try {
    Save-OppoState -Adapters $allAdapters -Services $services -Processes $processes -Proxies $proxyAdapters `
                   -Path $backupPath -Note '卸载 OPPO 互联 TUN 网卡前的状态快照' | Out-Null
    Write-Log ("状态已备份: {0}" -f $backupPath) OK $logFile
} catch {
    Write-Log ("状态备份失败（继续执行）: {0}" -f $_.Exception.Message) WARN $logFile
}


# ---------------------------------------------------------------------------
# 4. 停止守护服务，释放 Wintun 会话
# ---------------------------------------------------------------------------
if (-not $NoStopServices) {
    Stop-OppoDaemons -LogFile $logFile -KillProcesses:$KillProcesses
    Start-Sleep -Milliseconds 1200   # 等服务释放 Wintun 会话句柄
} else {
    Write-Log '已跳过停止服务（-NoStopServices）。' WARN $logFile
}

# ---------------------------------------------------------------------------
# 4.5 服务注销 / 启动类型调整
# ---------------------------------------------------------------------------
if ($ServiceMode -ne 'Keep') {
    foreach ($s in $services) {
        if ($s.Status -eq 'Not Installed') { continue }
        try {
            switch ($ServiceMode) {
                'Manual'   {
                    Set-OppoServiceStartMode -Name $s.Name -Mode Manual
                    Write-Log ("已改为手动启动（开机不再自启）: {0}" -f $s.Name) OK $logFile
                }
                'Disabled' {
                    Set-OppoServiceStartMode -Name $s.Name -Mode Disabled
                    Write-Log ("已禁用服务（开机不自启，需手动改回）: {0}" -f $s.Name) OK $logFile
                }
                'Delete'   {
                    Remove-OppoService -Name $s.Name
                    Write-Log ("已注销服务: {0}" -f $s.Name) OK $logFile
                }
            }
        } catch {
            Write-Log ("服务处理失败: {0} -> {1}" -f $s.Name, $_.Exception.Message) ERROR $logFile
        }
    }
} else {
    Write-Log '服务注册保持不变（-ServiceMode Keep）。' INFO $logFile
}

# ---------------------------------------------------------------------------
# 5. 删除设备节点
# ---------------------------------------------------------------------------
$failed = New-Object System.Collections.ArrayList
foreach ($adapter in $oppoAdapters) {
    Write-Log ("卸载网卡: {0} ({1})" -f $adapter.Name, $adapter.InstanceId) INFO $logFile
    $code = Remove-OppoAdapter -Adapter $adapter -LogFile $logFile -Force:$Force -RebootIfNeeded:$RebootIfNeeded

    Start-Sleep -Milliseconds 800
    $present = Test-OppoAdapterPresent -InstanceId $adapter.InstanceId

    if ($present -and -not $Force) {
        Write-Log '设备仍存在，尝试 /force 强制删除...' WARN $logFile
        $code = Remove-OppoAdapter -Adapter $adapter -LogFile $logFile -Force -RebootIfNeeded:$RebootIfNeeded
        Start-Sleep -Milliseconds 800
        $present = Test-OppoAdapterPresent -InstanceId $adapter.InstanceId
    }

    if ($present) {
        Write-Log ("卸载失败，设备仍在: {0}" -f $adapter.InstanceId) ERROR $logFile
        [void]$failed.Add($adapter)
    } else {
        Write-Log ("已卸载: {0}" -f $adapter.Name) OK $logFile
    }
}

# ---------------------------------------------------------------------------
# 6. 复查
# ---------------------------------------------------------------------------
Start-Sleep -Milliseconds 500
$remaining = @(Get-OppoAdapters -InstallDir $install | Where-Object { $_.IsOppo })

Write-Log '' INFO $logFile
Write-Log '================ 结果 ================' INFO $logFile
Write-Log ("成功卸载: {0} / {1}" -f ($oppoAdapters.Count - $failed.Count), $oppoAdapters.Count) $(if ($failed.Count -eq 0) { 'OK' } else { 'WARN' }) $logFile

if ($remaining.Count -gt 0) {
    Write-Log ("仍检测到 {0} 个 OPPO 网卡：" -f $remaining.Count) ERROR $logFile
    $remaining | Select-Object Name, Description, Status, InstanceId | Format-Table -AutoSize | Out-String -Width 4096 | Write-Host
    Write-Log '处理建议：' WARN $logFile
    Write-Log '  1) 确认已用管理员权限运行，且 OPPO 守护服务已停止；' WARN $logFile
    Write-Log '  2) 尝试加 -Force 参数（pnputil /force）；' WARN $logFile
    Write-Log '  3) 仍失败可加 -RebootIfNeeded，重启后完成删除。' WARN $logFile
    exit 1
}

# 路由残留检查
$removedIndexes = @($oppoAdapters | Where-Object { $null -ne $_.IfIndex } | ForEach-Object { $_.IfIndex })
if ($removedIndexes.Count -gt 0) {
    $leftRoutes = @(Get-NetRoute -ErrorAction SilentlyContinue | Where-Object { $removedIndexes -contains $_.ifIndex })
    if ($leftRoutes.Count -gt 0) {
        Write-Log ("提示：仍有 {0} 条路由引用已删除的接口（通常在删除设备后会自动清除）。" -f $leftRoutes.Count) WARN $logFile
    }
}

Write-Log 'OPPO 互联的虚拟网卡已全部卸载。' OK $logFile
switch ($ServiceMode) {
    'Keep' {
        Write-Log '注意：服务注册未改动，下次开机仍会自动创建 vgate 网卡。' WARN $logFile
        Write-Log '     长期方案：用 Start-OppoConnect.vbs 启动，退出后由守护自动清理。' INFO $logFile
    }
    'Manual' {
        Write-Log '服务已改为“手动”：开机不会创建网卡；需要时启动服务或用还原脚本恢复。' OK $logFile
        Write-Log '提示：普通权限下 OPPO 客户端无权启动该服务（服务 DACL 未授予交互用户 START），' WARN $logFile
        Write-Log '     所以“打开客户端自动恢复”需要守护脚本以管理员权限启动服务。' WARN $logFile
    }
    'Disabled' {
        Write-Log '服务已禁用：开机不会创建网卡；下次启动客户端会自动 repair。' OK $logFile
    }
    'Delete' {
        Write-Log '服务已注销：下次启动 OPPO 客户端时，它会在已提权上下文里自动重装服务。' OK $logFile
        Write-Log '用 Start-OppoConnect.vbs 启动可避免额外的 UAC。' INFO $logFile
    }
}
Write-Log ("日志文件: {0}" -f $logFile) INFO $logFile
exit 0
