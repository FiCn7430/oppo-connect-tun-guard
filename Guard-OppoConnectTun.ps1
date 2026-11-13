#requires -Version 5.1
<#
.SYNOPSIS
    OPPO 互联退出守护：客户端进程完全退出后，停止并注销服务、卸载 Wintun 网卡。

.DESCRIPTION
    由 Start-OppoConnect.ps1 以管理员权限在后台启动（隐藏窗口）。
    每 IntervalSeconds 秒检查一次 OPPO 客户端进程（O+Connect.exe / oplus_remote_ui.exe /
    SLDesktopAgent.exe）。当所有客户端进程消失并持续 GraceSeconds 秒后：
      1. 停止并注销 “O+Connect Service”“OplusRemoteService”
         （不备份服务定义：下次启动 OPPO 客户端时它会自行 repair）；
      2. 卸载 vgate*/utun* 两块 Wintun 网卡；
      3. 写日志并退出。
    守护启动时会先等待客户端进程出现（最多 WaitClientSeconds 秒），避免误清理。

.EXAMPLE
    .\Guard-OppoConnectTun.ps1 -Apply
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [int]$IntervalSeconds = 1,
    [int]$GraceSeconds = 3,
    [int]$WaitClientSeconds = 90,
    [string]$InstallDir = ''
)

$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'OppoConnectTun.Common.ps1')

$logDir   = Join-Path $scriptDir 'logs'
$logFile  = New-LogFile -Dir $logDir -Prefix 'guard'
$install  = Resolve-OppoInstallDir -Preferred $InstallDir
$isAdmin  = Test-IsAdmin

# 单实例保护
$mutex = New-Object System.Threading.Mutex($false, 'Global\OppoConnectTunGuard')
if (-not $mutex.WaitOne(0)) {
    Write-Log '已有守护进程在运行，本次退出。' WARN $logFile
    exit 0
}

Write-Log '================ OPPO 互联退出守护 ================' INFO $logFile
Write-Log ("时间       : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) INFO $logFile
Write-Log ("管理员权限 : {0}" -f $isAdmin) INFO $logFile
Write-Log ("轮询间隔   : {0}s，退出宽限: {1}s" -f $IntervalSeconds, $GraceSeconds) INFO $logFile

if ($Apply -and -not $isAdmin) {
    Write-Log '守护需要管理员权限才能停服务/删网卡；本次仅监控。' ERROR $logFile
}

# 等待客户端出现，避免启动器与客户端启动的竞态
$deadline = (Get-Date).AddSeconds($WaitClientSeconds)
while ((Get-Date) -lt $deadline) {
    if (@(Get-OppoAppProcesses).Count -gt 0) { break }
    Start-Sleep -Milliseconds 500
}
if (@(Get-OppoAppProcesses).Count -eq 0) {
    Write-Log ("等待客户端 {0}s 仍未出现，守护退出（不做清理）。" -f $WaitClientSeconds) WARN $logFile
    exit 0
}


Write-Log '检测到 OPPO 客户端，开始监控退出状态...' OK $logFile
$lastSeen = Get-Date
$clientFirstSeen = Get-Date
$tick = 0
$proxyNow = $false
$utunNow = $false
$proxyList = @()

# 启动前已存在的代理 TUN / utun8 视为已处理，不再重复提示；只有之后新出现的才提示
$initialProxy = @(Get-ProxyTunAdapters | Where-Object { $_.Status -eq 'Up' })
$initialUtun  = @(Get-OppoAdapterRegistryItems -InstallDir $install | Where-Object { $_.IsOppo -and $_.Name -match '^utun' })
$proxyPrompted = ($initialProxy.Count -gt 0)
$utunPrompted  = ($initialUtun.Count -gt 0)
if ($proxyPrompted) { Write-Log '启动时代理 TUN 已存在，不再重复提示代理冲突。' INFO $logFile }
if ($utunPrompted)  { Write-Log '启动时 utun8 已存在，不再重复提示 utun8。' INFO $logFile }


function Start-GuardPrompt {
    param([string]$Kind, [string]$ProxyNames)

    $prompt = Join-Path $scriptDir 'Show-GuardPrompt.ps1'
    $promptArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Kind {1} -ProxyNames "{2}" -LogFile "{3}"' -f $prompt, $Kind, $ProxyNames, $logFile
    Start-Process -FilePath 'powershell.exe' -ArgumentList $promptArgs -WindowStyle Hidden
}

while ($true) {
    $apps = @(Get-OppoAppProcesses)
    if ($apps.Count -gt 0) {
        $lastSeen = Get-Date

        # 客户端启动 5 秒后才开始检测，避免早期误判
        if (((Get-Date) - $clientFirstSeen).TotalSeconds -ge 5) {
            # utun8 与代理 TUN 都每 3 秒检测一次
            if (($tick % 3) -eq 0) {
                $utun = @(Get-OppoAdapterRegistryItems -InstallDir $install | Where-Object { $_.IsOppo -and $_.Name -match '^utun' })
                $utunNow = ($utun.Count -gt 0)

                $proxyList = @(Get-ProxyTunAdapters | Where-Object { $_.Status -eq 'Up' })
                $proxyNow = ($proxyList.Count -gt 0)
                if (-not $proxyNow) {
                    $proxyPrompted = $false
                    $utunPrompted = $false
                }
            }

            if ($proxyNow -and -not $proxyPrompted) {
                # 代理 TUN 新出现：异步弹窗提示一次（不阻塞监控循环）
                $proxyPrompted = $true
                $names = ($proxyList | ForEach-Object { $_.Name }) -join ', '
                Write-Log ("检测到代理 TUN: {0}" -f $names) WARN $logFile
                if ($utunNow) { $utunPrompted = $true }
                Start-GuardPrompt -Kind 'Proxy' -ProxyNames $names
            }
            elseif ($proxyNow -and $utunNow -and -not $utunPrompted) {
                # 代理已在运行，utun8 后来出现：异步弹窗提示一次
                $utunPrompted = $true
                Write-Log '检测到 utun8 且代理 TUN 在运行，提示用户处理。' WARN $logFile
                $names = ($proxyList | ForEach-Object { $_.Name }) -join ', '
                Start-GuardPrompt -Kind 'Utun' -ProxyNames $names
            }
        }
    } elseif (((Get-Date) - $lastSeen).TotalSeconds -ge $GraceSeconds) {
        Write-Log 'OPPO 客户端进程已完全退出，开始清理...' INFO $logFile

        # 轻量枚举（只读注册表，约 30ms），避免 Get-NetAdapter 的 1~2 秒开销
        $adapters = @(Get-OppoAdapterRegistryItems -InstallDir $install | Where-Object { $_.IsOppo })

        if ($Apply -and $isAdmin) {
            # 1) 并行停止两个服务（不再逐个等待）
            $svcNames = @($script:OppoServiceNames)
            foreach ($name in $svcNames) {
                $s = Get-Service -Name $name -ErrorAction SilentlyContinue
                if ($s -and $s.Status -ne 'Stopped') {
                    Write-Log ("停止服务: {0}" -f $name) INFO $logFile
                    try { Stop-Service -Name $name -Force -NoWait -ErrorAction Stop }
                    catch { Write-Log ("停止服务失败: {0} -> {1}" -f $name, $_.Exception.Message) WARN $logFile }
                }
            }
            $stopDeadline = (Get-Date).AddSeconds(8)
            while ((Get-Date) -lt $stopDeadline) {
                $pending = @($svcNames | ForEach-Object {
                    $s = Get-Service -Name $_ -ErrorAction SilentlyContinue
                    if ($s -and $s.Status -ne 'Stopped') { $_ }
                })
                if ($pending.Count -eq 0) { break }
                Start-Sleep -Milliseconds 250
            }
            # 兜底：仍未停止则强杀服务进程
            foreach ($name in $svcNames) {
                $s = Get-Service -Name $name -ErrorAction SilentlyContinue
                if ($s -and $s.Status -ne 'Stopped') {
                    $wmi = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $name.Replace("'", "''")) -ErrorAction SilentlyContinue
                    if ($wmi -and $wmi.ProcessId -gt 0) {
                        Stop-Process -Id $wmi.ProcessId -Force -ErrorAction SilentlyContinue
                        Write-Log ("强制结束服务进程: {0}" -f $name) WARN $logFile
                    }
                }
            }

            # 2) 注销服务（不备份：下次启动时 OPPO 客户端会自行 repair）
            foreach ($name in $svcNames) {
                if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { continue }
                try {
                    Remove-OppoService -Name $name
                    Write-Log ("已注销服务: {0}" -f $name) OK $logFile
                } catch {
                    Write-Log ("注销服务失败: {0} -> {1}" -f $name, $_.Exception.Message) ERROR $logFile
                }
            }

            # 3) 卸载网卡（轮询消失，不再固定 sleep）
            foreach ($a in $adapters) {
                Remove-OppoAdapter -Adapter $a -LogFile $logFile | Out-Null
                $gone = $false
                $deadline = (Get-Date).AddSeconds(2)
                while ((Get-Date) -lt $deadline) {
                    if (-not (Test-OppoAdapterPresent -InstanceId $a.InstanceId)) { $gone = $true; break }
                    Start-Sleep -Milliseconds 100
                }
                if ($gone) {
                    Write-Log ("已卸载网卡: {0}" -f $a.Name) OK $logFile
                } else {
                    Write-Log ("卸载失败: {0}" -f $a.Name) ERROR $logFile
                }
            }

            # 4) 最后结束 OPPO 自带的 adb 残留进程（只杀安装目录下的 adb，不动其他 adb）
            $adbKilled = 0
            foreach ($p in @(Get-Process -Name 'adb' -ErrorAction SilentlyContinue)) {
                $adbPath = $p.Path
                if (-not $adbPath) {
                    try {
                        $cim = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $p.Id) -ErrorAction SilentlyContinue
                        if ($cim) { $adbPath = $cim.ExecutablePath }
                    } catch { }
                }
                if (-not $adbPath) { continue }
                if (-not $adbPath.StartsWith($install, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

                try {
                    Stop-Process -Id $p.Id -Force -ErrorAction Stop
                    $adbKilled++
                    Write-Log ("已结束 OPPO adb 进程: PID {0}" -f $p.Id) OK $logFile
                } catch {
                    Write-Log ("结束 adb 进程失败: PID {0}" -f $p.Id) WARN $logFile
                }
            }
            if ($adbKilled -eq 0) { Write-Log '没有发现 OPPO 的 adb 残留进程。' INFO $logFile }
        } else {
            Write-Log '[监控] 本应清理服务与网卡（未加 -Apply 或无管理员权限）。' WARN $logFile
        }

        Write-Log '清理流程结束，守护退出。' OK $logFile
        break
    }

    Start-Sleep -Seconds $IntervalSeconds
    $tick++
}

$mutex.ReleaseMutex()
exit 0
