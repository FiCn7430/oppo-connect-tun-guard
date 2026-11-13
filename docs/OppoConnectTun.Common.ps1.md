# OppoConnectTun.Common.ps1 — 公共函数库

## 用途

被其它脚本 `dot-source` 的公共函数集合：网卡检测、服务操作、日志、通知、状态备份。**不直接运行。**

## 使用方式

```powershell
. (Join-Path $PSScriptRoot 'OppoConnectTun.Common.ps1')
```

## 函数分类

### 日志与基础

| 函数 | 说明 |
| --- | --- |
| `Test-IsAdmin` | 当前是否管理员 |
| `Write-Log` | 控制台 + 文件日志（INFO / OK / WARN / ERROR / DEBUG） |
| `New-LogFile` | 在 `logs\` 下创建带时间戳的日志文件（同一前缀保留最近 2 个：本次 + 上一次） |
| `Resolve-OppoInstallDir` | 从卸载注册表解析 OPPO 安装目录 |

### 网卡检测

| 函数 | 说明 |
| --- | --- |
| `Get-OppoAdapters` | 完整检测（Get-NetAdapter + PnP 注册表 + IP），返回名称/描述/GUID/状态/IP |
| `Get-OppoAdapterRegistryItems` | 轻量检测（只读注册表，约 14ms），返回名称/InstanceId/描述 |
| `Get-ProxyTunAdapters` | 检测代理 TUN（Meta Tunnel / Mihomo / Clash / sing-box 等） |

### 服务与进程

| 函数 | 说明 |
| --- | --- |
| `Get-OppoServiceStates` | 两个 OPPO 服务的状态/启动方式（CIM，较慢） |
| `Get-OppoProcesses` | 所有 OPPO 相关进程 |
| `Get-OppoAppProcesses` | 仅客户端进程（`O+Connect` / `oplus_remote_ui` / `SLDesktopAgent`） |
| `Stop-OppoDaemons` | 停止两个服务（含强制结束兜底） |

### 网卡删除

| 函数 | 说明 |
| --- | --- |
| `Test-OppoAdapterPresent` | 设备节点是否仍存在（读注册表） |
| `Remove-OppoAdapter` | 调用 `pnputil /remove-device`，支持 `/force`、`/reboot` |

### 状态快照与服务管理

| 函数 | 说明 |
| --- | --- |
| `Save-OppoState` | 保存网卡/服务/进程/代理状态快照到 `state\` |
| `Set-OppoServiceStartMode` | 修改服务启动类型（Auto / Manual / Disabled） |
| `Remove-OppoService` | `sc delete` 注销服务 |

## 注意

- 函数依赖脚本作用域变量（`$script:OppoServiceNames`、`$script:ProxySignatures` 等），dot-source 后可直接调用。
- 部分函数需要管理员权限（`Stop-OppoDaemons`、`Remove-OppoAdapter`、`Remove-OppoService` 等）。
