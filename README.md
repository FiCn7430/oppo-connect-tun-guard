# OPPO 互联 TUN 网卡冲突：原理与工具

> 解决 OPPO 互联创建的 `vgate0` / `utun8` 与代理 TUN（Meta Tunnel 等）争抢路由、导致断网的问题。
> 用法：双击桌面“OPPO互联”快捷方式（指向 `Start-OppoConnect.vbs`），一个 UAC 拉起客户端；退出后守护自动清理服务与网卡。

---

## 环境要求

- Windows 10 / 11（PowerShell 5.1、`Get-NetAdapter`、`Get-PnpDevice`）
- 管理员权限（启动器会请求一次 UAC）
- 已安装 OPPO 互联（默认 `C:\Program Files\Oppo Connect`，或注册表 `InstallLocation`）
- 代理侧使用 TUN（Clash Verge / mihomo 的 `Meta Tunnel` 等）

---

## 一、问题原理

OPPO 互联的 **O+Connect Service**（`daemon\devicespace.exe`，LocalSystem，开机自启）加载 `daemon\wintun.dll`，在运行时创建两块 Wintun 网卡：

| 网卡 | 创建时机 | 说明 |
| --- | --- | --- |
| `vgate0` | 服务启动时**必建** | 虚拟网关，用于 P2P / 投屏 |
| `utun8` | OPPO 设备通过 **USB 接入**时按需创建 | USB 隧道，设备断开后删除 |

代理（Clash Verge / mihomo 的 `Meta Tunnel`）也使用同一个 Wintun 驱动。两者同时存在时会争抢接口/路由，导致流量全部丢失。

关键事实：

- 服务是 **开机自启** 的，所以 `vgate0` 在任何时候都可能存在，与是否打开 OPPO 客户端无关。
- 客户端启动时会检查服务，**缺失就自动 repair 重装**（`repairService` / `repairRcService`）。普通双击会因此弹两次 UAC；用本项目的提权启动器可避免。
- 因此日常方案是：**提权启动器拉起客户端 → 退出时守护结束 adb 残留、注销服务、卸载网卡 → 下次启动由客户端自动 repair**。

---

## 二、文件清单

| 文件 | 用途 |
| --- | --- |
| `Start-OppoConnect.vbs` | **日常入口**：双击后无终端窗口，仅一次 UAC，拉起客户端 + 守护 |
| `Start-OppoConnect.ps1` | 启动器：提权、已在运行检测、代理冲突处理、启动客户端与守护 |
| `Guard-OppoConnectTun.ps1` | 退出守护：客户端退出 3 秒后注销服务、卸载网卡、结束 adb 残留；运行期监控代理/`utun8` |
| `Show-GuardPrompt.ps1` | 守护用的冲突提示弹窗（独立进程，不阻塞监控） |
| `Invoke-OppoIcsPulse.ps1` | “直接共存 / 尝试共存”的 ICS 脉冲实现 |
| `Remove-OppoConnectTun.ps1` | 手动清理：停止服务、注销服务、卸载网卡（默认 Dry-run） |
| `Create-Shortcut.ps1` | 在桌面创建“OPPO互联”快捷方式 |
| `OppoConnectTun.Common.ps1` | 公共函数：网卡检测、服务操作、日志（自动清理）、通知 |
| `docs\` | 每个文件的详细说明 |

运行时目录：`logs\`（自动生成，每类日志保留最近 2 个：本次 + 上一次）、`state\`（仅手动运行 `Remove-OppoConnectTun.ps1 -Apply` 时生成）。

### 文档索引

每个文件的详细用法见 `docs\`：

| 文件 | 文档 |
| --- | --- |
| `Start-OppoConnect.vbs` | [docs/Start-OppoConnect.vbs.md](docs/Start-OppoConnect.vbs.md) |
| `Start-OppoConnect.ps1` | [docs/Start-OppoConnect.ps1.md](docs/Start-OppoConnect.ps1.md) |
| `Guard-OppoConnectTun.ps1` | [docs/Guard-OppoConnectTun.ps1.md](docs/Guard-OppoConnectTun.ps1.md) |
| `Show-GuardPrompt.ps1` | [docs/Show-GuardPrompt.ps1.md](docs/Show-GuardPrompt.ps1.md) |
| `Invoke-OppoIcsPulse.ps1` | [docs/Invoke-OppoIcsPulse.ps1.md](docs/Invoke-OppoIcsPulse.ps1.md) |
| `Remove-OppoConnectTun.ps1` | [docs/Remove-OppoConnectTun.ps1.md](docs/Remove-OppoConnectTun.ps1.md) |
| `Create-Shortcut.ps1` | [docs/Create-Shortcut.ps1.md](docs/Create-Shortcut.ps1.md) |
| `OppoConnectTun.Common.ps1` | [docs/OppoConnectTun.Common.ps1.md](docs/OppoConnectTun.Common.ps1.md) |

---

## 三、日常使用

双击桌面 **OPPO互联** 快捷方式（或 `Start-OppoConnect.vbs`）。

```text
VBS（无窗口）→ 一次 UAC
  ├─ 检测客户端/守护是否已在运行
  │    └─ 是：弹窗选择“重试网卡共存”或“忽视这次启动”
  ├─ 检测代理 TUN
  │    ├─ 没有：直接继续
  │    └─ 有：四选一（关闭代理 / 直接共存 / 尝试共存 / 中断启动）
  ├─ 启动 O+Connect.exe（管理员上下文，客户端自动 repair 服务）
  ├─ 若选共存：等 vgate0 最多 20 秒 → 执行 ICS 脉冲
  └─ 启动后台守护
```

关闭 OPPO 互联（**完全退出**，不是最小化到托盘）后无需操作：守护在 3 秒宽限后清理。

---

## 四、代理冲突处理

启动前检测代理 TUN（`Meta Tunnel` / `Mihomo` / `Clash` / `sing-box` 等，且状态为 Up）：

| 选项 | 行为 |
| --- | --- |
| 关闭代理 TUN 后继续 | 每 3 秒检测一次；3 秒后仍未关闭会弹提示（继续等待 3 秒 / 中断），最多提醒 3 次，仍未关闭则强制中断。检测到消失后自动继续启动 |
| 直接共存 | 立即执行 ICS 脉冲（要求 `vgate0` 已存在），不启动 OPPO 互联；用于代理流量已经异常时的快速修复，完成后退出 |
| 尝试共存 | 先启动 OPPO 互联，等 `vgate0` 最多 20 秒，再执行 ICS 脉冲；约 30 秒内网络可能中断，且不保证稳定 |
| 中断启动 | 直接退出，不启动客户端与守护 |

### 共存失效后重试

再次双击启动器时，如果检测到客户端或守护已在运行，会弹窗：

| 选项 | 行为 |
| --- | --- |
| 重试网卡共存 | 若代理 TUN 与 `vgate0` 都在，立即再执行一次 ICS 脉冲；守护未运行则顺便启动；不重启客户端 |
| 忽视这次启动 | 直接退出，不启动任何东西 |

### ICS 脉冲原理

枚举 ICS 连接 → 找真实上网网卡（uplink）与 TUN → 清空现有 ICS → TUN 启用“专用共享”、uplink 启用“公用共享” → 保持 2 秒 → 再次清空 ICS。作用是强制 SharedAccess 重新计算 NAT/路由，让两块虚拟网卡暂时共存。

---

## 五、守护行为

客户端运行期间：

| 项目 | 频率 |
| --- | --- |
| 客户端进程（`O+Connect` / `oplus_remote_ui` / `SLDesktopAgent`） | 每 1 秒 |
| `utun8` 与代理 TUN | 每 3 秒（客户端启动 5 秒后才开始） |

- 启动前已存在的代理 TUN / `utun8` 视为已处理，**不重复提示**；只有运行期间新出现的才弹窗（手动关闭 / ICS 脉冲 / 忽略）。
- 弹窗由独立进程 `Show-GuardPrompt.ps1` 显示，不阻塞监控。
- 客户端完全退出 + 3 秒宽限后：停止服务 → 注销 `O+Connect Service` / `OplusRemoteService` → 卸载 OPPO 网卡 → 结束 adb 残留进程 → 守护退出。
- 不备份服务定义：下次启动时 OPPO 客户端会自动 repair。

---

## 六、手动清理

默认只检测、不修改：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Remove-OppoConnectTun.ps1
```

实际执行（需要管理员，会停下 OPPO 服务）：

```powershell
.\Remove-OppoConnectTun.ps1 -Apply                      # 停服务 + 卸载网卡，保留服务注册
.\Remove-OppoConnectTun.ps1 -Apply -ServiceMode Delete  # 同时注销两个服务
```

其他参数：`-Force`（强制删除占用中的设备）、`-KillProcesses`（停不下服务时结束残留进程）、`-NoStopServices`、`-RebootIfNeeded`。

---

## 七、注意事项

- **不删除 `wintun.sys`**：代理与 OPPO 共用该驱动，脚本只删适配器设备节点。
- 客户端以管理员权限运行；依赖 UIPI 的功能（如从资源管理器拖文件进 OPPO 窗口）可能受影响。
- `.vbs` 入口在 Win7–Win11 可用，但 VBScript 已被微软列为弃用；若被禁用，可用管理员 PowerShell 直接运行 `Start-OppoConnect.ps1`。
- 共存方式不稳定，失败时用“重试网卡共存”或手动关闭代理。
- 日志在 `logs\`，卸载状态快照在 `state\`（仅用于排查，不是服务备份）。

---

## 八、实测时间线（2026-11-14）

| 时间 | 事件 |
| --- | --- |
| 00:31:50 | 普通双击启动客户端 |
| 00:31:56 / 00:31:59 | 客户端两次提权 repair 两个服务（事件 7045） |
| 00:31:57 / 00:32:05 | `vgate0` / `utun8` 重建 |
| 00:54:02 | 客户端退出，守护开始清理 |
| 00:54:13 | 两个服务注销 |
| 00:54:15 / 00:54:16 | `vgate0` / `utun8` 卸载 |

---

## 免责声明

本项目通过停止/注销 OPPO 互联服务、删除其 Wintun 适配器、修改 ICS 共享状态等方式解决网卡冲突，
会短暂中断网络并影响 OPPO 互联的后台功能。请自行评估风险，在了解后果的前提下使用。

## License

未指定。如需开源许可证（MIT / Apache-2.0 等），请补充 `LICENSE` 文件。
