#requires -Version 5.1
<#
.SYNOPSIS
    ICS 脉冲：尝试让代理 TUN 与 OPPO 互联虚拟网卡共存。

.DESCRIPTION
    原理来自桌面脚本 Fuck_you_oppo_tun_adapter.ps1：
      1. 枚举所有 ICS 连接（HNetCfg.HNetShare）；
      2. 找到有 IPv4 默认路由的真实上网网卡（uplink，排除虚拟/TUN）；
      3. 找到 TUN 的 ICS 连接（默认 vgate0，也匹配 Mihomo / Meta Tunnel）；
      4. 清空现有 ICS -> 在 TUN 上启用“专用共享” -> 在 uplink 上启用“公用共享”
         -> 保持 HoldSeconds 秒 -> 再次清空 ICS。
    这会强制 SharedAccess 重新计算 NAT/路由，期间网络会短暂中断，且不保证稳定。

.EXAMPLE
    .\Invoke-OppoIcsPulse.ps1 -TunAdapter vgate0
#>
[CmdletBinding()]
param(
    [string]$TunAdapter   = 'vgate0',
    [string]$PublicAdapter = '',
    [int]$HoldSeconds     = 2,
    [switch]$DryRun,
    [string]$LogFile      = ''
)

$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'OppoConnectTun.Common.ps1')

if (-not $LogFile) {
    $LogFile = New-LogFile -Dir (Join-Path $scriptDir 'logs') -Prefix 'icspulse'
}

if (-not (Test-IsAdmin)) {
    Write-Log 'ICS 脉冲需要管理员权限（枚举 ICS 连接本身就需要提升）。' ERROR $LogFile
    exit 2
}

Write-Log '================ ICS 脉冲（尝试共存） ================' INFO $LogFile
Write-Log ("TUN: {0}，保持: {1}s" -f $TunAdapter, $HoldSeconds) INFO $LogFile

function Get-IcsItems {
    $list = New-Object System.Collections.ArrayList
    try {
        $mgr = New-Object -ComObject HNetCfg.HNetShare
        foreach ($conn in $mgr.EnumEveryConnection()) {
            try {
                $props = $mgr.NetConnectionProps($conn)
                $cfg   = $mgr.INetSharingConfigurationForINetConnection($conn)
                [void]$list.Add([pscustomobject]@{
                    Name           = [string]$props.Name
                    DeviceName     = [string]$props.DeviceName
                    SharingEnabled = [bool]$cfg.SharingEnabled
                    SharingType    = $cfg.SharingConnectionType
                    Config         = $cfg
                })
            } catch { }
        }
    } catch {
        Write-Log ("枚举 ICS 连接失败: {0}" -f $_.Exception.Message) WARN $LogFile
    }
    return $list.ToArray()
}

function Disable-AllIcs {
    param($Items)
    foreach ($item in $Items) {
        try {
            if ($item.SharingEnabled) {
                Write-Log ("关闭 ICS: {0}" -f $item.Name) INFO $LogFile
                $item.Config.DisableSharing()
                Start-Sleep -Milliseconds 400
            }
        } catch { }
    }
}

function Find-IcsItemByName {
    param($Items, [string]$Name, [string]$Description = '')
    if (-not $Name) { return $null }
    foreach ($i in $Items) { if ($i.Name -eq $Name) { return $i } }
    if ($Description) {
        foreach ($i in $Items) { if ($i.DeviceName -eq $Description) { return $i } }
    }
    foreach ($i in $Items) {
        if ($i.Name -like ('*' + $Name + '*')) { return $i }
        if ($Description -and $i.DeviceName -like ('*' + $Description + '*')) { return $i }
    }
    return $null
}

function Find-TunIcsItem {
    param($Items)
    $hits = @($Items | Where-Object {
        $_.Name -eq $TunAdapter -or
        $_.Name -like ('*' + $TunAdapter + '*') -or
        $_.DeviceName -like '*Mihomo*' -or
        $_.DeviceName -like '*Meta Tunnel*'
    })
    if ($hits.Count -eq 0) { return $null }
    return $hits[0]
}

function Get-UplinkAdapter {
    if ($PublicAdapter) {
        return [pscustomobject]@{ Name = $PublicAdapter; InterfaceDescription = '' }
    }
    $virtual = '(?i)(wintun|tap|tunnel|vpn|loopback|hyper-v|vmware|virtualbox|radmin|mihomo|clash|meta)'
    $routes  = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                 Sort-Object RouteMetric)
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue)
    foreach ($r in $routes) {
        $a = $adapters | Where-Object { $_.ifIndex -eq $r.ifIndex } | Select-Object -First 1
        if (-not $a) { continue }
        if ([string]$a.Status -ne 'Up') { continue }
        $text = '{0} {1}' -f $a.Name, $a.InterfaceDescription
        if ($text -match $virtual) { continue }
        if ($a.Name -match '^(vgate|utun|Meta|Mihomo|Clash)') { continue }
        return [pscustomobject]@{ Name = $a.Name; InterfaceDescription = $a.InterfaceDescription }
    }

    # 回退：默认路由被 TUN 吞掉时，找有网关、非 APIPA 的 Up 真实网卡
    foreach ($a in $adapters) {
        if ([string]$a.Status -ne 'Up') { continue }
        $text = '{0} {1}' -f $a.Name, $a.InterfaceDescription
        if ($text -match $virtual) { continue }
        if ($a.Name -match '^(vgate|utun|Meta|Mihomo|Clash)') { continue }
        $usable = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notlike '169.254.*' })
        if ($usable.Count -eq 0) { continue }
        return [pscustomobject]@{ Name = $a.Name; InterfaceDescription = $a.InterfaceDescription }
    }
    return $null
}

$items = @(Get-IcsItems)
if ($items.Count -eq 0) {
    Write-Log '无法枚举 ICS 连接（SharedAccess 服务可能被禁用）。' ERROR $LogFile
    exit 1
}

$tunItem = Find-TunIcsItem -Items $items
if (-not $tunItem) {
    Write-Log ("未找到 TUN 的 ICS 连接: {0}" -f $TunAdapter) ERROR $LogFile
    exit 1
}

$uplink = Get-UplinkAdapter
if (-not $uplink) {
    Write-Log '未检测到可用的真实上网网卡（uplink）。' ERROR $LogFile
    exit 1
}
Write-Log ("Uplink: {0} ({1})" -f $uplink.Name, $uplink.InterfaceDescription) INFO $LogFile

$publicItem = Find-IcsItemByName -Items $items -Name $uplink.Name -Description $uplink.InterfaceDescription
if (-not $publicItem) {
    Write-Log ("Uplink 不在 ICS 连接列表中: {0}" -f $uplink.Name) ERROR $LogFile
    exit 1
}

if ($DryRun) {
    Write-Log ("DryRun: TUN={0}，Uplink={1}，ICS 连接可用，未做任何修改。" -f $tunItem.Name, $publicItem.Name) OK $LogFile
    exit 0
}

$ok = $false
try {
    Write-Log '清空现有 ICS...' INFO $LogFile
    Disable-AllIcs -Items $items
    Start-Sleep -Seconds 1

    $items      = @(Get-IcsItems)
    $tunItem    = Find-TunIcsItem -Items $items
    $publicItem = Find-IcsItemByName -Items $items -Name $uplink.Name -Description $uplink.InterfaceDescription
    if (-not $tunItem)    { throw '清空 ICS 后 TUN 连接消失' }
    if (-not $publicItem) { throw '清空 ICS 后 Uplink 连接消失' }

    Write-Log ("在 TUN 上启用专用共享: {0}" -f $tunItem.Name) INFO $LogFile
    $tunItem.Config.EnableSharing(1)
    Start-Sleep -Milliseconds 800

    Write-Log ("在 Uplink 上启用公用共享: {0}" -f $publicItem.Name) INFO $LogFile
    $publicItem.Config.EnableSharing(0)
    Start-Sleep -Seconds $HoldSeconds

    $ok = $true
    Write-Log 'ICS 脉冲完成。' OK $LogFile
} catch {
    Write-Log ("ICS 脉冲失败: {0}" -f $_.Exception.Message) ERROR $LogFile
} finally {
    Disable-AllIcs -Items @(Get-IcsItems)
}

if ($ok) { exit 0 } else { exit 1 }
