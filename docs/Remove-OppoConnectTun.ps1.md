# Remove-OppoConnectTun.ps1 — 手动清理

## 用途

手动停止 OPPO 服务、注销服务、卸载 OPPO 的 Wintun 网卡。默认只检测（Dry-run），加 `-Apply` 才执行。

## 运行方式

需要管理员：

```powershell
# 仅检测，列出会删除的网卡
powershell -NoProfile -ExecutionPolicy Bypass -File .\Remove-OppoConnectTun.ps1

# 实际执行（停服务 + 删网卡，保留服务注册）
.\Remove-OppoConnectTun.ps1 -Apply

# 同时注销两个服务
.\Remove-OppoConnectTun.ps1 -Apply -ServiceMode Delete
```

## 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-Apply` | 关 | 实际执行；不加时只检测 |
| `-ServiceMode` | `Keep` | `Keep` / `Manual` / `Disabled` / `Delete` |
| `-NoStopServices` | 关 | 不停止服务，直接尝试删卡（通常删不掉） |
| `-KillProcesses` | 关 | 服务停不下时强制结束残留进程 |
| `-Force` | 关 | 对占用中的设备使用 `pnputil /force` |
| `-RebootIfNeeded` | 关 | 允许 `pnputil /reboot`，重启后完成删除 |
| `-AdapterName` | 空 | 只处理指定网卡（可多个） |
| `-InstallDir` | 自动检测 | OPPO 安装目录 |

### `-ServiceMode` 说明

| 模式 | 行为 |
| --- | --- |
| `Keep` | 只停服务、删网卡，服务注册不动 |
| `Manual` | 停止后改为手动启动（开机不再建网卡） |
| `Disabled` | 停止后禁用服务 |
| `Delete` | 停止后注销（删除）服务注册 |

## 执行流程

```text
检测（Get-OppoAdapters / 服务 / 进程 / 代理 TUN）
→ 备份状态快照到 state\oppo-tun-state-*.json
→ 停止服务（Stop-OppoDaemons）
→ 按 -ServiceMode 调整/注销服务
→ pnputil /remove-device 删除 OPPO 适配器
→ 复查是否删净
```

## 注意

- 只删除描述为 `Rust Wintun Tunnel`（或名称 `vgate*` / `utun*`）的适配器，不会动代理的 `Meta Tunnel`。
- 不删除 `wintun.sys` 驱动。
- 注销服务后不需要备份：下次启动 OPPO 客户端会自动 repair。
- `state\` 目录只保存状态快照，用于排查。
