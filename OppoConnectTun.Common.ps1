#requires -Version 5.1
# ============================================================================
# OPPO 互联虚拟网卡（Wintun）管理公共函数库
# 说明：本文件由其它脚本 dot-source 使用，不直接运行。
# 原理：OPPO 互联的 “O+Connect Service”（devicespace.exe，LocalSystem 自启动）
#       在服务启动时通过 daemon\wintun.dll 创建 vgateN 虚拟网关网卡，
#       在 OPPO 设备通过 USB 接入时按需创建 utunN 隧道网卡。
#       这些网卡与代理（Clash Verge 的 Meta Tunnel 等）的 TUN 网卡争抢路由，
#       导致流量进入黑洞。本库只处理“OPPO 的适配器”，绝不动 wintun 驱动本身
#       （代理也依赖同一个 wintun.sys）。
# ============================================================================

$ErrorActionPreference = 'Stop'

$script:OppoDefaultInstallDir = 'C:\Program Files\Oppo Connect'
$script:OppoServiceNames      = @('O+Connect Service', 'OplusRemoteService')
$script:OppoProcessNames      = @('O+Connect', 'oplus_remote_service', 'oplus_remote_ui', 'devicespace', 'SLDesktopAgent', 'pantaChannelService', 'unlock_helper', 'logupload')
$script:OppoAppProcessNames   = @('O+Connect', 'oplus_remote_ui', 'SLDesktopAgent')
$script:ProxySignatures       = @('Meta Tunnel', 'Mihomo', 'Clash', 'sing-box', 'singbox', 'tun2socks', 'NekoRay', 'v2ray', 'V2Ray', 'Shadowsocks', 'Hysteria', 'Trojan')
$script:ToolRoot              = $PSScriptRoot

function Test-IsAdmin {
    [CmdletBinding()]
    param()
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO',
        [string]$LogFile
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = 'Gray'
    switch ($Level) {
        'OK'    { $color = 'Green' }
        'WARN'  { $color = 'Yellow' }
        'ERROR' { $color = 'Red' }
        'INFO'  { $color = 'Cyan' }
    }
    Write-Host $line -ForegroundColor $color
    if ($LogFile) {
        try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }
}

function New-LogFile {
    [CmdletBinding()]
    param([string]$Dir, [string]$Prefix)
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }

    $path = Join-Path $Dir ('{0}-{1}.log' -f $Prefix, (Get-Date -Format 'yyyyMMdd-HHmmss'))

    # 日志自动清理：同一前缀只保留最近 2 个（本次 + 上一次）
    try {
        $same = @(Get-ChildItem -LiteralPath $Dir -Filter ($Prefix + '-*.log') -File -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -Skip 1)
        if ($same.Count -gt 0) {
            $same | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    } catch { }

    return $path
}

function Resolve-OppoInstallDir {
    [CmdletBinding()]
    param([string]$Preferred)
    if ($Preferred -and (Test-Path -LiteralPath $Preferred)) { return $Preferred.TrimEnd('\') }

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $keys) {
        $entry = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -like '*OPPO*互联*' -or $_.DisplayName -like '*O+Connect*' } |
                 Select-Object -First 1
        if ($entry -and $entry.InstallLocation) {
            return ([string]$entry.InstallLocation).TrimEnd('\')
        }
    }
    return $script:OppoDefaultInstallDir
}

# ----------------------------------------------------------------------------
# 网卡检测
# ----------------------------------------------------------------------------
function Get-OppoAdapters {
    [CmdletBinding()]
    param(
        [string]$InstallDir,
        [object[]]$NetAdapters,
        [switch]$NoIP
    )
    if (-not $InstallDir) { $InstallDir = $script:OppoDefaultInstallDir }
    if ($null -eq $NetAdapters) {
        $NetAdapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue)
    }
    $netAdapters = $NetAdapters

    # 主路径：直接读 PnP 枚举注册表（Get-PnpDevice 一次约 5 秒，太慢，不适合轮询）
    $devices = New-Object System.Collections.ArrayList
    $enumRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\SWD\WINTUN'
    foreach ($key in @(Get-ChildItem -LiteralPath $enumRoot -ErrorAction SilentlyContinue)) {
        $keyGuid = $key.PSChildName
        if ($keyGuid -notmatch '^\{[0-9a-fA-F\-]{36}\}$') { continue }
        $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        $keyDesc = ''
        if ($props) {
            $keyDesc = [string]$props.DeviceDesc
            if (-not $keyDesc) { $keyDesc = [string]$props.FriendlyName }
        }
        [void]$devices.Add([pscustomobject]@{
            InstanceId  = ('SWD\WINTUN\' + $keyGuid)
            Guid        = $keyGuid.Trim('{}')
            Description = $keyDesc
        })
    }

    # 兜底：注册表枚举为空时再用 Get-PnpDevice
    if ($devices.Count -eq 0) {
        try {
            foreach ($pnpDev in @(Get-PnpDevice -Class Net -ErrorAction Stop | Where-Object { $_.InstanceId -like 'SWD\WINTUN\*' })) {
                $pnpGuid = ''
                if ($pnpDev.InstanceId -match '\{([0-9a-fA-F\-]{36})\}') { $pnpGuid = $matches[1] }
                [void]$devices.Add([pscustomobject]@{
                    InstanceId  = [string]$pnpDev.InstanceId
                    Guid        = $pnpGuid
                    Description = [string]$pnpDev.FriendlyName
                })
            }
        } catch { }
    }

    $result = New-Object System.Collections.ArrayList

    foreach ($dev in $devices) {
        $guid = [string]$dev.Guid
        if ($guid -eq '' -and $dev.InstanceId -match '\{([0-9a-fA-F\-]{36})\}') { $guid = $matches[1] }

        $na = $null
        if ($guid -ne '') {
            $na = $netAdapters | Where-Object {
                $_.InterfaceGuid -and (($_.InterfaceGuid -replace '[{}]', '') -eq $guid)
            } | Select-Object -First 1
        }
        if (-not $na) {
            $na = $netAdapters | Where-Object { $_.PnPDeviceID -eq $dev.InstanceId } | Select-Object -First 1
        }

        $name    = ''
        $ifIndex = $null
        $desc    = ''
        $status  = ''
        if ($na) {
            $name    = [string]$na.Name
            $ifIndex = $na.ifIndex
            $desc    = [string]$na.InterfaceDescription
            $status  = [string]$na.Status
        }
        if (-not $desc) { $desc = [string]$dev.FriendlyName }
        if (-not $desc) { $desc = [string]$dev.Description }

        $isOppo = $false
        $reason = ''
        if ($desc -match 'Rust\s*Wintun\s*Tunnel') {
            $isOppo = $true
            $reason = '描述包含 Rust Wintun Tunnel（OPPO 守护进程特征）'
        } elseif ($name -match '^(vgate|utun)\d*$' -and $desc -match 'Wintun') {
            $isOppo = $true
            $reason = '名称 vgate*/utun* 且为 Wintun 隧道'
        }

        $ipv4 = @()
        if (-not $NoIP -and $null -ne $ifIndex) {
            $ipv4 = @(Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                      ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength })
        }

        [void]$result.Add([pscustomobject]@{
            Name        = $name
            InstanceId  = [string]$dev.InstanceId
            Guid        = $guid
            Description = $desc
            Status      = $status
            IfIndex     = $ifIndex
            IPv4        = $ipv4
            IsOppo      = $isOppo
            MatchReason = $reason
        })
    }

    # 兜底：极端情况下 Get-PnpDevice 不可用时，按网卡特征识别
    if ($result.Count -eq 0) {
        foreach ($na in $netAdapters) {
            if ($na.PnPDeviceID -notlike 'SWD\WINTUN\*') { continue }
            $isOppo = ($na.InterfaceDescription -match 'Rust\s*Wintun\s*Tunnel') -or
                      ($na.Name -match '^(vgate|utun)\d*$' -and $na.InterfaceDescription -match 'Wintun')
            if (-not $isOppo) { continue }
            [void]$result.Add([pscustomobject]@{
                Name        = [string]$na.Name
                InstanceId  = [string]$na.PnPDeviceID
                Guid        = (($na.InterfaceGuid -replace '[{}]', ''))
                Description = [string]$na.InterfaceDescription
                Status      = [string]$na.Status
                IfIndex     = $na.ifIndex
                IPv4        = @(Get-NetIPAddress -InterfaceIndex $na.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                                ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength })
                IsOppo      = $true
                MatchReason = '按 Wintun + vgate/utun 名称识别'
            })
        }
    }

    return $result.ToArray()
}

# 轻量版：只读 PnP 枚举 + Network 连接名注册表，用于清理阶段快速定位设备
function Get-OppoAdapterRegistryItems {
    [CmdletBinding()]
    param([string]$InstallDir)
    if (-not $InstallDir) { $InstallDir = $script:OppoDefaultInstallDir }

    $items = New-Object System.Collections.ArrayList
    $enumRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\SWD\WINTUN'
    $netRoot  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\{4d36e972-e325-11ce-bfc1-08002be10318}'

    foreach ($key in @(Get-ChildItem -LiteralPath $enumRoot -ErrorAction SilentlyContinue)) {
        $guid = $key.PSChildName
        if ($guid -notmatch '^\{[0-9a-fA-F\-]{36}\}$') { continue }

        $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        $desc  = [string]$props.DeviceDesc
        if (-not $desc) { $desc = [string]$props.FriendlyName }

        $name = ''
        $conn = Join-Path $netRoot ($guid + '\Connection')
        $connProps = Get-ItemProperty -LiteralPath $conn -ErrorAction SilentlyContinue
        if ($connProps) { $name = [string]$connProps.Name }

        $isOppo = $false
        if ($desc -match 'Rust\s*Wintun\s*Tunnel') { $isOppo = $true }
        elseif ($name -match '^(vgate|utun)\d*$' -and $desc -match 'Wintun') { $isOppo = $true }

        [void]$items.Add([pscustomobject]@{
            Name        = $name
            InstanceId  = ('SWD\WINTUN\' + $guid)
            Guid        = $guid.Trim('{}')
            Description = $desc
            IsOppo      = $isOppo
        })
    }
    return $items.ToArray()
}

function Get-ProxyTunAdapters {
    [CmdletBinding()]
    param([object[]]$NetAdapters)
    if ($null -eq $NetAdapters) {
        $NetAdapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue)
    }
    $adapters = $NetAdapters
    $found = New-Object System.Collections.ArrayList

    foreach ($a in $adapters) {
        $text = '{0} {1}' -f $a.InterfaceDescription, $a.Name
        $isProxy = $false
        foreach ($sig in $script:ProxySignatures) {
            if ($text -like "*$sig*") { $isProxy = $true; break }
        }
        if (-not $isProxy) { continue }

        [void]$found.Add([pscustomobject]@{
            Name        = [string]$a.Name
            Description = [string]$a.InterfaceDescription
            Status      = [string]$a.Status
            IfIndex     = $a.ifIndex
            IPv4        = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                            ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength })
        })
    }
    return $found.ToArray()
}

function Get-OppoServiceStates {
    [CmdletBinding()]
    param()
    $out = New-Object System.Collections.ArrayList
    foreach ($n in $script:OppoServiceNames) {
        $safe = $n.Replace("'", "''")
        $svc = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $safe) -ErrorAction SilentlyContinue
        if ($svc) {
            [void]$out.Add([pscustomobject]@{
                Name      = [string]$svc.Name
                Status    = [string]$svc.State
                StartMode = [string]$svc.StartMode
                ProcessId = $svc.ProcessId
                PathName  = [string]$svc.PathName
            })
        } else {
            [void]$out.Add([pscustomobject]@{
                Name = $n; Status = 'Not Installed'; StartMode = ''; ProcessId = $null; PathName = ''
            })
        }
    }
    return $out.ToArray()
}

function Get-OppoProcesses {
    [CmdletBinding()]
    param()
    $names = $script:OppoProcessNames
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.Name })
}

function Get-OppoAppProcesses {
    [CmdletBinding()]
    param()
    $names = $script:OppoAppProcessNames
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.Name })
}

# ----------------------------------------------------------------------------
# 服务 / 网卡操作（需要管理员）
# ----------------------------------------------------------------------------
function Stop-OppoDaemons {
    [CmdletBinding()]
    param(
        [string]$LogFile,
        [switch]$KillProcesses,
        [int]$TimeoutSeconds = 25
    )
    foreach ($n in $script:OppoServiceNames) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Log "未找到服务: $n" WARN $LogFile
            continue
        }
        if ($svc.Status -eq 'Stopped') {
            Write-Log "服务已是停止状态: $n" INFO $LogFile
            continue
        }

        Write-Log "停止服务: $n (当前 $($svc.Status))" INFO $LogFile
        try {
            Stop-Service -Name $n -Force -ErrorAction Stop
            $svc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds($TimeoutSeconds))
            Write-Log "服务已停止: $n" OK $LogFile
        } catch {
            Write-Log "服务停止失败: $n -> $($_.Exception.Message)" ERROR $LogFile
            # 兜底：强制结束该服务进程，释放 Wintun 会话
            try {
                $wmi = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $n.Replace("'", "''")) -ErrorAction SilentlyContinue
                if ($wmi -and $wmi.ProcessId -gt 0) {
                    Stop-Process -Id $wmi.ProcessId -Force -ErrorAction Stop
                    Write-Log "已强制结束服务进程: $n (PID $($wmi.ProcessId))" WARN $LogFile
                }
            } catch {
                Write-Log "强制结束服务进程失败: $n -> $($_.Exception.Message)" ERROR $LogFile
            }
        }
    }

    if ($KillProcesses) {
        foreach ($p in @(Get-OppoProcesses)) {
            if ($p.Name -eq 'O+Connect') { continue }   # 不主动杀用户界面进程
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                Write-Log "已结束进程: $($p.Name) (PID $($p.Id))" WARN $LogFile
            } catch { }
        }
    }
}


function Test-OppoAdapterPresent {
    [CmdletBinding()]
    param([string]$InstanceId)
    # 直接看 PnP 枚举注册表，比 Get-PnpDevice 快得多（后者约 5 秒）
    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $InstanceId
    return (Test-Path -LiteralPath $regPath)
}

function Remove-OppoAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Adapter,
        [string]$LogFile,
        [switch]$Force,
        [switch]$RebootIfNeeded
    )
    $stdoutFile = [IO.Path]::GetTempFileName()
    $stderrFile = [IO.Path]::GetTempFileName()
    $argList = @('/remove-device', $Adapter.InstanceId)
    if ($Force) { $argList += '/force' }
    if ($RebootIfNeeded) { $argList += '/reboot' }

    try {
        $p = Start-Process -FilePath 'pnputil.exe' -ArgumentList $argList -NoNewWindow -Wait -PassThru `
                           -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $code = $p.ExitCode
        $text = @()
        if (Test-Path $stdoutFile) { $text += (Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue) }
        if (Test-Path $stderrFile) { $text += (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue) }
    } finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }

    Write-Log ("pnputil /remove-device {0} -> 退出码 {1}" -f $Adapter.InstanceId, $code) INFO $LogFile
    foreach ($line in ($text -join "`r`n") -split "`r?`n") {
        $t = $line.Trim()
        if ($t) { Write-Log ("  {0}" -f $t) INFO $LogFile }
    }
    return $code
}

# ----------------------------------------------------------------------------
# 状态备份
# ----------------------------------------------------------------------------
function Save-OppoState {
    [CmdletBinding()]
    param(
        $Adapters,
        $Services,
        $Processes,
        $Proxies,
        [string]$Path,
        [string]$Note
    )
    $state = [ordered]@{
        savedAt  = (Get-Date).ToString('o')
        host     = $env:COMPUTERNAME
        user     = $env:USERNAME
        note     = $Note
        services = @($Services | ForEach-Object {
            [ordered]@{ name = $_.Name; status = $_.Status; startMode = $_.StartMode }
        })
        processes = @($Processes | ForEach-Object {
            [ordered]@{ name = $_.Name; id = $_.Id }
        })
        proxies = @($Proxies | ForEach-Object {
            [ordered]@{ name = $_.Name; description = $_.Description; status = $_.Status; ipv4 = @($_.IPv4) }
        })
        adapters = @($Adapters | ForEach-Object {
            [ordered]@{
                name        = $_.Name
                instanceId  = $_.InstanceId
                guid        = $_.Guid
                description = $_.Description
                status      = $_.Status
                ifIndex     = $_.IfIndex
                ipv4        = @($_.IPv4)
            }
        })
    }

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($state | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}


# ----------------------------------------------------------------------------
# 服务启动类型 / 注销（需要管理员）
# ----------------------------------------------------------------------------

function Set-OppoServiceStartMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('Auto', 'Manual', 'Disabled')][string]$Mode
    )
    $scStart = @{ Auto = 'auto'; Manual = 'demand'; Disabled = 'disabled' }[$Mode]
    $out = @(& sc.exe config "$Name" start= $scStart 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ("sc config 失败: {0}" -f ($out -join ' '))
    }
}

function Remove-OppoService {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    $out = @(& sc.exe delete "$Name" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ("sc delete 失败: {0}" -f ($out -join ' '))
    }
}

