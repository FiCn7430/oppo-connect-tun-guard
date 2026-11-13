#requires -Version 5.1
<#
.SYNOPSIS
    OPPO 互联启动器：一次 UAC 提权 -> 拉起客户端 -> 后台守护。

.DESCRIPTION
    背景：OPPO 客户端启动时会检查 “O+Connect Service / OplusRemoteService”，
    服务缺失时它会自己调用 ShellExecuteEx(..., "runas") 执行安装（每次一个服务），
    于是普通双击启动会弹两次 UAC。

    本脚本先把自己提权到管理员，再启动 O+Connect.exe，客户端继承管理员令牌，
    它的“修复服务”动作就不再触发 UAC。随后启动后台守护进程
    Guard-OppoConnectTun.ps1，由守护在客户端完全退出后停止并注销服务、卸载网卡。

    典型闭环：
      1) 上次退出后：服务已注销、网卡已卸载（由守护完成）；
      2) 用户双击 Start-OppoConnect.vbs：一次 UAC；
      3) 客户端以管理员身份启动，静默重建服务与网卡；
      4) 客户端完全退出 -> 守护停止/注销服务、卸载网卡 -> 守护退出。

.EXAMPLE
    .\Start-OppoConnect.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [int]$GraceSeconds = 3,
    [switch]$NoGuard
)

$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'OppoConnectTun.Common.ps1')

$install = Resolve-OppoInstallDir -Preferred $InstallDir
$exe     = Join-Path $install 'O+Connect.exe'

# ---- 未提权：以管理员重新启动自己（唯一一次 UAC） ----
if (-not (Test-IsAdmin)) {
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Host "找不到 OPPO 互联客户端: $exe" -ForegroundColor Red
        exit 2
    }
    Write-Host '正在请求管理员权限...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($InstallDir) { $argList += @('-InstallDir', ('"{0}"' -f $InstallDir)) }
    if ($NoGuard) { $argList += '-NoGuard' }
    if ($GraceSeconds -ne 3) { $argList += @('-GraceSeconds', $GraceSeconds) }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $argList
    exit 0
}

# ---- 已提权：拉起客户端 + 守护 ----
$logDir  = Join-Path $scriptDir 'logs'
$logFile = New-LogFile -Dir $logDir -Prefix 'start'

Write-Log '================ OPPO 互联启动器 ================' INFO $logFile
Write-Log ("时间       : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) INFO $logFile
Write-Log ("管理员权限 : True") INFO $logFile
Write-Log ("OPPO 目录  : {0}" -f $install) INFO $logFile

if (-not (Test-Path -LiteralPath $exe)) {
    Write-Log ("找不到客户端: {0}" -f $exe) ERROR $logFile
    exit 2
}

function Show-ProxyConflictDialog {
    param([object[]]$Proxies)

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '检测到代理 TUN 网卡'
    $form.ClientSize = New-Object System.Drawing.Size(640, 350)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $title = New-Object System.Windows.Forms.Label
    $title.Location = New-Object System.Drawing.Point(16, 14)
    $title.Size = New-Object System.Drawing.Size(608, 26)
    $title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $title.Text = '检测到代理 TUN 网卡正在运行'

    $list = New-Object System.Windows.Forms.Label
    $list.Location = New-Object System.Drawing.Point(16, 46)
    $list.Size = New-Object System.Drawing.Size(608, 74)
    $list.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $list.Text = (($Proxies | ForEach-Object { '  • ' + $_.Name + '   (' + $_.Description + ')' }) -join "`r`n") +
                 "`r`n`r`nOPPO 互联的虚拟网卡会与它争抢路由，直接启动可能导致全部断网。"

    $warn = New-Object System.Windows.Forms.Label
    $warn.Location = New-Object System.Drawing.Point(16, 126)
    $warn.Size = New-Object System.Drawing.Size(608, 44)
    $warn.ForeColor = [System.Drawing.Color]::DarkRed
    $warn.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $warn.Text = '直接共存：立即脉冲、不启动 OPPO 互联；尝试共存：先启动 OPPO 互联再脉冲。两者都会短暂中断网络。'

    $note = New-Object System.Windows.Forms.Label
    $note.Location = New-Object System.Drawing.Point(16, 176)
    $note.Size = New-Object System.Drawing.Size(608, 52)
    $note.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $note.ForeColor = [System.Drawing.Color]::DimGray
    $note.Text = '提示：直接共存一般用于“没有启动 OPPO 互联、也没有创建网卡”时，因未知原因导致的代理失效修复。'

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = '关闭代理 TUN 后继续'
    $btnClose.Location = New-Object System.Drawing.Point(16, 240)
    $btnClose.Size = New-Object System.Drawing.Size(290, 42)

    $btnDirect = New-Object System.Windows.Forms.Button
    $btnDirect.Text = '直接共存（立即修复流量）'
    $btnDirect.Location = New-Object System.Drawing.Point(322, 240)
    $btnDirect.Size = New-Object System.Drawing.Size(290, 42)

    $btnCoexist = New-Object System.Windows.Forms.Button
    $btnCoexist.Text = '尝试共存（先启动 OPPO 互联）'
    $btnCoexist.Location = New-Object System.Drawing.Point(16, 292)
    $btnCoexist.Size = New-Object System.Drawing.Size(290, 42)

    $btnAbort = New-Object System.Windows.Forms.Button
    $btnAbort.Text = '中断启动'
    $btnAbort.Location = New-Object System.Drawing.Point(322, 292)
    $btnAbort.Size = New-Object System.Drawing.Size(290, 42)

    $script:conflictChoice = 'Abort'
    $btnClose.Add_Click({ $script:conflictChoice = 'CloseProxy'; $this.FindForm().Close() })
    $btnDirect.Add_Click({ $script:conflictChoice = 'DirectCoexist'; $this.FindForm().Close() })
    $btnCoexist.Add_Click({ $script:conflictChoice = 'Coexist'; $this.FindForm().Close() })
    $btnAbort.Add_Click({ $script:conflictChoice = 'Abort'; $this.FindForm().Close() })

    $form.Controls.AddRange(@($title, $list, $warn, $note, $btnClose, $btnDirect, $btnCoexist, $btnAbort))
    $form.AcceptButton = $btnClose
    $form.CancelButton = $btnAbort

    [void]$form.ShowDialog()
    $form.Dispose()
    return $script:conflictChoice
}

function Show-AlreadyRunningDialog {
    param([int]$ClientCount, [bool]$GuardRunning)

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'OPPO 互联已在运行'
    $form.ClientSize = New-Object System.Drawing.Size(640, 300)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $title = New-Object System.Windows.Forms.Label
    $title.Location = New-Object System.Drawing.Point(16, 14)
    $title.Size = New-Object System.Drawing.Size(608, 26)
    $title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $title.Text = '检测到 OPPO 互联已在运行'

    $info = New-Object System.Windows.Forms.Label
    $info.Location = New-Object System.Drawing.Point(16, 46)
    $info.Size = New-Object System.Drawing.Size(608, 120)
    $info.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $guardText = if ($GuardRunning) { '运行中' } else { '未运行' }
    $info.Text = ('客户端进程: {0} 个' -f $ClientCount) + "`r`n" +
                 ('守护进程: {0}' -f $guardText) + "`r`n`r`n" +
                 '如果之前的网卡共存失效，可以选择 重试网卡共存 立即再执行一次 ICS 脉冲；' + "`r`n" +
                 '否则选择 忽视这次启动，不会重复启动客户端或守护。'

    $btnRetry = New-Object System.Windows.Forms.Button
    $btnRetry.Text = '重试网卡共存'
    $btnRetry.Location = New-Object System.Drawing.Point(120, 210)
    $btnRetry.Size = New-Object System.Drawing.Size(190, 46)

    $btnIgnore = New-Object System.Windows.Forms.Button
    $btnIgnore.Text = '忽视这次启动'
    $btnIgnore.Location = New-Object System.Drawing.Point(330, 210)
    $btnIgnore.Size = New-Object System.Drawing.Size(190, 46)

    $script:runningChoice = 'Ignore'
    $btnRetry.Add_Click({ $script:runningChoice = 'Retry'; $this.FindForm().Close() })
    $btnIgnore.Add_Click({ $script:runningChoice = 'Ignore'; $this.FindForm().Close() })

    $form.Controls.AddRange(@($title, $info, $btnRetry, $btnIgnore))
    $form.AcceptButton = $btnRetry
    $form.CancelButton = $btnIgnore

    [void]$form.ShowDialog()
    $form.Dispose()
    return $script:runningChoice
}

function Start-OppoGuard {
    if ($NoGuard) { return }
    $guard = Join-Path $scriptDir 'Guard-OppoConnectTun.ps1'
    $guardArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Apply -GraceSeconds {1}' -f $guard, $GraceSeconds
    if ($InstallDir) { $guardArgs += (' -InstallDir "{0}"' -f $InstallDir) }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $guardArgs -WindowStyle Hidden
}

function Wait-OppoAdapters {
    param([int]$TimeoutSeconds = 20)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $vgate = $null
    while ((Get-Date) -lt $deadline) {
        $items = @(Get-OppoAdapterRegistryItems -InstallDir $install)
        $vgate = $items | Where-Object { $_.Name -match '^vgate' } | Select-Object -First 1
        if ($vgate) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $vgate) { return @() }
    return @(Get-OppoAdapterRegistryItems -InstallDir $install | Where-Object { $_.IsOppo })
}

# ---- 检测是否已在运行（支持“重试共存”） ----
$clientProcs = @(Get-Process -Name 'O+Connect' -ErrorAction SilentlyContinue)
$guardProcs  = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*Guard-OppoConnectTun.ps1*' })
if ($clientProcs.Count -gt 0 -or $guardProcs.Count -gt 0) {
    Write-Log ("检测到已在运行: 客户端 {0} 个，守护 {1} 个" -f $clientProcs.Count, $guardProcs.Count) WARN $logFile
    $runningChoice = Show-AlreadyRunningDialog -ClientCount $clientProcs.Count -GuardRunning ($guardProcs.Count -gt 0)
    Write-Log ("已在运行处理选择: {0}" -f $runningChoice) INFO $logFile

    if ($runningChoice -eq 'Retry') {
        $proxyUpNow = @(Get-ProxyTunAdapters | Where-Object { $_.Status -eq 'Up' })
        $vgateNow   = @(Get-OppoAdapterRegistryItems -InstallDir $install | Where-Object { $_.IsOppo -and $_.Name -match '^vgate' })
        if ($proxyUpNow.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('当前没有检测到代理 TUN，无需执行共存。', '无需共存', 'OK', 'Information')
        } elseif ($vgateNow.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('当前没有检测到 OPPO 的 vgate0 网卡，无法执行共存。', '无法共存', 'OK', 'Warning')
        } else {
            Write-Log '用户选择重试网卡共存，执行 ICS 脉冲...' INFO $logFile
            $pulse = Join-Path $scriptDir 'Invoke-OppoIcsPulse.ps1'
            $pulseArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -TunAdapter vgate0 -LogFile "{1}"' -f $pulse, $logFile
            $pulseProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $pulseArgs -WindowStyle Hidden -Wait -PassThru
            if ($pulseProc.ExitCode -ne 0) {
                [void][System.Windows.Forms.MessageBox]::Show('共存脉冲执行失败。可稍后再次运行启动器重试。', '共存失败', 'OK', 'Warning')
            } else {
                [void][System.Windows.Forms.MessageBox]::Show('共存脉冲已执行完成。如果仍然断网，可再次运行启动器重试。', '共存完成', 'OK', 'Information')
            }
        }
        Start-OppoGuard
        exit 0
    }

    Write-Log '用户选择忽视这次启动。' INFO $logFile
    exit 0
}

# ---- 启动前：代理 TUN 冲突检查 ----
$coexistRequested = $false
$proxyUp = @(Get-ProxyTunAdapters | Where-Object { $_.Status -eq 'Up' })
if ($proxyUp.Count -gt 0) {
    Write-Log ("检测到代理 TUN 处于 Up 状态: {0}" -f (($proxyUp | ForEach-Object { $_.Name }) -join ', ')) WARN $logFile

    $choice = Show-ProxyConflictDialog -Proxies $proxyUp
    Write-Log ("代理冲突处理选择: {0}" -f $choice) INFO $logFile

    if ($choice -eq 'Abort') {
        Write-Log '用户选择中断启动：未启动客户端，也未启动守护。' WARN $logFile
        exit 0
    }
    elseif ($choice -eq 'CloseProxy') {
        $closeTip = '请先在代理软件中关闭 TUN 模式（例如 Clash Verge 的 TUN 开关）。' + "`r`n" + '关闭后点击“确定”，脚本会自动检测；检测到它消失后会立即继续启动。'
        [void][System.Windows.Forms.MessageBox]::Show($closeTip, '请关闭代理 TUN', 'OK', 'Information')

        $remind = 0
        $closed = $false
        while (-not $closed) {
            # 与检测间隔同步：每 3 秒检测一次，未关闭就提醒
            $waitSeconds = 3

            $deadline = (Get-Date).AddSeconds($waitSeconds)
            while ((Get-Date) -lt $deadline) {
                if (@(Get-ProxyTunAdapters | Where-Object { $_.Status -eq 'Up' }).Count -eq 0) { $closed = $true; break }
                Start-Sleep -Seconds 3
            }
            if ($closed) { break }

            $remind++
            if ($remind -gt 3) {
                [void][System.Windows.Forms.MessageBox]::Show('已提醒 3 次仍未检测到代理 TUN 关闭，启动已强制中断。', '已中断', 'OK', 'Warning')
                Write-Log '提醒 3 次仍未关闭代理 TUN，强制中断启动。' ERROR $logFile
                exit 0
            }

            $msg = '尚未检测到代理 TUN 关闭。' + "`r`n`r`n" +
                   '· 检测到它消失后会自动继续启动 OPPO 互联' + "`r`n" +
                   ('· 这是第 {0}/3 次提醒，继续等待 3 秒' -f $remind) + "`r`n`r`n" +
                   '是否继续等待？选择“否”将中断启动。'
            $ans = [System.Windows.Forms.MessageBox]::Show($msg, '等待关闭代理 TUN', 'YesNo', 'Question')
            if ($ans.ToString() -ne 'Yes') {
                Write-Log '用户选择中断启动。' WARN $logFile
                exit 0
            }
        }
        Write-Log '代理 TUN 已关闭，继续启动。' OK $logFile
    }
    elseif ($choice -eq 'DirectCoexist') {
        $vgateNow = @(Get-OppoAdapterRegistryItems -InstallDir $install | Where-Object { $_.IsOppo -and $_.Name -match '^vgate' })
        if ($vgateNow.Count -eq 0) {
            $tip = '当前没有检测到 OPPO 的 vgate0 网卡，无法直接共存。' + "`r`n" +
                   '请选择 尝试共存 先启动 OPPO 互联。'
            [void][System.Windows.Forms.MessageBox]::Show($tip, '无法直接共存', 'OK', 'Warning')
            Write-Log '没有 vgate0，直接共存不可用。' WARN $logFile
            exit 0
        }

        Write-Log '用户选择直接共存，立即执行 ICS 脉冲...' INFO $logFile
        $pulse = Join-Path $scriptDir 'Invoke-OppoIcsPulse.ps1'
        $pulseArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -TunAdapter vgate0 -LogFile "{1}"' -f $pulse, $logFile
        $pulseProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $pulseArgs -WindowStyle Hidden -Wait -PassThru
        if ($pulseProc.ExitCode -ne 0) {
            [void][System.Windows.Forms.MessageBox]::Show('共存脉冲执行失败。可稍后再次运行启动器重试。', '共存失败', 'OK', 'Warning')
            Write-Log '直接共存脉冲执行失败。' ERROR $logFile
        } else {
            [void][System.Windows.Forms.MessageBox]::Show('共存脉冲已执行完成。如果流量仍未恢复，可再次运行启动器选择直接共存。', '共存完成', 'OK', 'Information')
            Write-Log '直接共存脉冲完成。' OK $logFile
        }
        exit 0
    }
    elseif ($choice -eq 'Coexist') {
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "将执行 ICS 脉冲尝试让代理 TUN 与 OPPO 网卡共存：`r`n· 先启动 OPPO 互联，等待 vgate0 出现（最多 20 秒）`r`n· 随后执行脉冲，约 30 秒内网络可能中断`r`n· 该方式不稳定，可能需要再次手动处理`r`n· 若共存失效，可再次运行启动器并选择 重试网卡共存`r`n`r`n是否继续？",
            '尝试共存', 'OKCancel', 'Warning')
        if ($confirm.ToString() -ne 'OK') {
            Write-Log '用户取消共存操作，启动中断。' WARN $logFile
            exit 0
        }
        $coexistRequested = $true
        Write-Log '已记录“共存”选择，将在 OPPO 网卡创建后执行 ICS 脉冲。' INFO $logFile
    }
}

Write-Log '启动 OPPO 互联客户端（服务与网卡由客户端自行恢复，启动器不做任何检测/恢复）...' INFO $logFile
Start-Process -FilePath $exe -WorkingDirectory $install

# ---- 共存模式：等 OPPO 网卡创建后执行 ICS 脉冲 ----
if ($coexistRequested) {
    Write-Log '等待 OPPO 虚拟网卡创建（vgate0，最多 20 秒）...' INFO $logFile
    $oppoAdapters = @(Wait-OppoAdapters -TimeoutSeconds 20)
    if ($oppoAdapters.Count -eq 0) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "20 秒内未检测到 OPPO 虚拟网卡，共存操作无法执行。`r`n是否仍继续启动 OPPO 互联？",
            '共存未执行', 'YesNo', 'Warning')
        if ($ans.ToString() -ne 'Yes') {
            Write-Log '共存未执行，用户选择中断。' WARN $logFile
            exit 0
        }
    } else {
        Write-Log ("检测到 OPPO 网卡: {0}，执行 ICS 脉冲（约 30 秒网络可能中断）..." -f (($oppoAdapters | ForEach-Object { $_.Name }) -join ', ')) INFO $logFile
        $pulse = Join-Path $scriptDir 'Invoke-OppoIcsPulse.ps1'
        $pulseArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -TunAdapter vgate0 -LogFile "{1}"' -f $pulse, $logFile
        $pulseProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $pulseArgs -WindowStyle Hidden -Wait -PassThru
        if ($pulseProc.ExitCode -ne 0) {
            $retry = [System.Windows.Forms.MessageBox]::Show(
                'ICS 脉冲失败（SharedAccess 服务可能被禁用）。仍要继续启动 OPPO 互联吗？',
                '共存失败', 'OKCancel', 'Warning')
            if ($retry.ToString() -ne 'OK') {
                Write-Log '共存失败后用户选择中断。' WARN $logFile
                exit 0
            }
        } else {
            Write-Log 'ICS 脉冲完成。' OK $logFile
        }
    }
}

Start-OppoGuard
if ($NoGuard) {
    Write-Log '已跳过守护（-NoGuard）。' WARN $logFile
} else {
    Write-Log '后台守护已启动（客户端完全退出后自动注销服务、卸载网卡）。' OK $logFile
}

Write-Log '启动器完成。' OK $logFile
exit 0
