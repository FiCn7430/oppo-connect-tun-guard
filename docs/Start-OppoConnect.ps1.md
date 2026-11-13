# Start-OppoConnect.ps1 — 启动器

## 用途

负责一次完整启动：提权、检测是否已在运行、处理代理 TUN 冲突、拉起 OPPO 客户端、按需执行共存脉冲、启动后台守护。

## 运行方式

通常由 `Start-OppoConnect.vbs` 以管理员权限、隐藏窗口调用；也可以直接在管理员 PowerShell 中运行。

## 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-InstallDir` | 自动检测 | OPPO 安装目录，默认从卸载注册表读取，找不到时用 `C:\Program Files\Oppo Connect` |
| `-GraceSeconds` | `3` | 传给守护的退出宽限（客户端完全退出后等多久清理） |
| `-NoGuard` | 关 | 只拉起客户端，不启动守护 |

## 示例

```powershell
# 正常启动（推荐通过 VBS）
.\Start-OppoConnect.ps1

# 自定义退出宽限
.\Start-OppoConnect.ps1 -GraceSeconds 5

# 只启动客户端，不启动守护
.\Start-OppoConnect.ps1 -NoGuard
```

## 启动流程

1. **自提权**：非管理员时用 `Start-Process -Verb RunAs -WindowStyle Hidden` 重新启动自己（仅一次 UAC）。
2. **已在运行检测**：检查 `O+Connect` 进程与 `Guard-OppoConnectTun.ps1` 进程。
   - 存在 → 弹窗（`Show-AlreadyRunningDialog`）：**重试网卡共存** 或 **忽视这次启动**。
   - 重试：若代理 TUN 与 `vgate0` 都在，执行一次 `Invoke-OppoIcsPulse.ps1`；守护未运行则顺便启动；然后退出。
3. **代理 TUN 检测**：检测处于 Up 的代理 TUN（Meta Tunnel / Mihomo / Clash / sing-box 等）。
   - 有 → 弹窗（`Show-ProxyConflictDialog`）：关闭代理 TUN 后继续 / 直接共存 / 尝试共存 / 中断启动。
   - 直接共存：要求 `vgate0` 已存在，立即执行脉冲修复流量，不启动 OPPO 互联，完成后退出。
4. **启动客户端**：`Start-Process O+Connect.exe`（继承管理员令牌，客户端自动 repair 服务，不再额外弹 UAC）。
5. **共存模式**：等待 `vgate0` 最多 20 秒，出现后执行 `Invoke-OppoIcsPulse.ps1`。
6. **启动守护**：隐藏启动 `Guard-OppoConnectTun.ps1 -Apply -GraceSeconds <n>`。

## 相关文件

- `Start-OppoConnect.vbs`：无窗口入口
- `Guard-OppoConnectTun.ps1`：退出守护
- `Invoke-OppoIcsPulse.ps1`：共存脉冲
- `OppoConnectTun.Common.ps1`：公共函数（检测、日志）

## 注意

- 客户端以管理员权限运行，依赖 UIPI 的功能（如拖拽文件到 OPPO 窗口）可能受影响。
- 共存提示中已说明：若共存失效，可再次运行启动器并选择“重试网卡共存”。
