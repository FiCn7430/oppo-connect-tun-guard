#requires -Version 5.1
<#
.SYNOPSIS
    守护进程的冲突提示弹窗（独立进程，避免阻塞守护的监控循环）。

.DESCRIPTION
    由 Guard-OppoConnectTun.ps1 以独立隐藏进程启动。
    弹窗让用户选择：
      · 手动关闭代理 TUN
      · 使用 ICS 脉冲（调用 Invoke-OppoIcsPulse.ps1）
      · 忽略，继续

.EXAMPLE
    .\Show-GuardPrompt.ps1 -Kind Proxy -ProxyNames "Meta" -LogFile "D:\...\guard.log"
#>
[CmdletBinding()]
param(
    [ValidateSet('Proxy', 'Utun')][string]$Kind = 'Proxy',
    [string]$ProxyNames = '',
    [string]$LogFile = '',
    [string]$TunAdapter = 'vgate0'
)

$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'OppoConnectTun.Common.ps1')

if (-not $LogFile) {
    $LogFile = New-LogFile -Dir (Join-Path $scriptDir 'logs') -Prefix 'prompt'
}

Write-Log ("显示冲突提示: {0} ({1})" -f $Kind, $ProxyNames) INFO $LogFile

Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

if ($Kind -eq 'Utun') {
    $titleText = '检测到 utun8 与代理 TUN 共存'
    $msgText   = '代理 TUN 仍在运行，utun8 可能与它再次冲突导致断网。请选择处理方式：'
} else {
    $titleText = '检测到代理 TUN'
    $msgText   = '代理 TUN 与 OPPO 互联网卡可能争抢路由导致断网。请选择处理方式：'
}

$form = New-Object System.Windows.Forms.Form
$form.Text = $titleText
$form.ClientSize = New-Object System.Drawing.Size(620, 300)
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$title = New-Object System.Windows.Forms.Label
$title.Location = New-Object System.Drawing.Point(16, 14)
$title.Size = New-Object System.Drawing.Size(588, 26)
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$title.Text = $titleText

$list = New-Object System.Windows.Forms.Label
$list.Location = New-Object System.Drawing.Point(16, 46)
$list.Size = New-Object System.Drawing.Size(588, 80)
$list.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$list.Text = '  · ' + ($ProxyNames -replace ', ', "`r`n  · ") + "`r`n`r`n" + $msgText

$warn = New-Object System.Windows.Forms.Label
$warn.Location = New-Object System.Drawing.Point(16, 132)
$warn.Size = New-Object System.Drawing.Size(588, 40)
$warn.ForeColor = [System.Drawing.Color]::DarkRed
$warn.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$warn.Text = '“使用脉冲”会短暂中断网络；手动关闭代理 TUN 更稳定。'

$btnManual = New-Object System.Windows.Forms.Button
$btnManual.Text = '手动关闭代理 TUN'
$btnManual.Location = New-Object System.Drawing.Point(16, 238)
$btnManual.Size = New-Object System.Drawing.Size(190, 42)

$btnPulse = New-Object System.Windows.Forms.Button
$btnPulse.Text = '使用 ICS 脉冲'
$btnPulse.Location = New-Object System.Drawing.Point(222, 238)
$btnPulse.Size = New-Object System.Drawing.Size(190, 42)

$btnIgnore = New-Object System.Windows.Forms.Button
$btnIgnore.Text = '忽略，继续'
$btnIgnore.Location = New-Object System.Drawing.Point(428, 238)
$btnIgnore.Size = New-Object System.Drawing.Size(190, 42)

$script:choice = 'Ignore'
$btnManual.Add_Click({ $script:choice = 'Manual'; $this.FindForm().Close() })
$btnPulse.Add_Click({ $script:choice = 'Pulse'; $this.FindForm().Close() })
$btnIgnore.Add_Click({ $script:choice = 'Ignore'; $this.FindForm().Close() })

$form.Controls.AddRange(@($title, $list, $warn, $btnManual, $btnPulse, $btnIgnore))
$form.AcceptButton = $btnManual
$form.CancelButton = $btnIgnore

[void]$form.ShowDialog()
$form.Dispose()

Write-Log ("提示选择: {0}" -f $script:choice) INFO $LogFile

switch ($script:choice) {
    'Pulse' {
        $pulse = Join-Path $scriptDir 'Invoke-OppoIcsPulse.ps1'
        $pulseArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -TunAdapter {1} -LogFile "{2}"' -f $pulse, $TunAdapter, $LogFile
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $pulseArgs -WindowStyle Hidden -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            Write-Log 'ICS 脉冲执行失败。' ERROR $LogFile
        } else {
            Write-Log 'ICS 脉冲完成。' OK $LogFile
        }
    }
    'Manual' {
        [void][System.Windows.Forms.MessageBox]::Show('请手动关闭代理 TUN；关闭后 OPPO 互联将继续运行。', '请关闭代理 TUN', 'OK', 'Information')
        Write-Log '用户选择手动关闭代理 TUN。' INFO $LogFile
    }
    default {
        Write-Log '用户忽略提示。' WARN $LogFile
    }
}

exit 0
