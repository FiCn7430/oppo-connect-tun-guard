# Guard-OppoConnectTun.ps1 — 退出守护

## 用途

后台守护进程。客户端运行期间监控退出状态与网卡冲突；客户端完全退出后注销服务、卸载网卡。

## 运行方式

通常由 `Start-OppoConnect.ps1` 以管理员权限、隐藏窗口启动：

```text
powershell -WindowStyle Hidden -File Guard-OppoConnectTun.ps1 -Apply -GraceSeconds 3
```

也可以手动运行（需要管理员，否则只能监控、不能清理）。

## 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-Apply` | 关 | 真正执行清理；不加时只监控、写日志 |
| `-IntervalSeconds` | `1` | 进程检测间隔（秒） |
| `-GraceSeconds` | `3` | 客户端完全退出后的宽限（秒） |
| `-WaitClientSeconds` | `90` | 启动时等待客户端出现的最长时间 |
| `-InstallDir` | 自动检测 | OPPO 安装目录 |

## 行为

1. **单实例保护**：命名 Mutex `Global\OppoConnectTunGuard`，已在运行则直接退出。
2. **等待客户端**：最多 `WaitClientSeconds` 秒；一直没出现就退出，不做清理。
3. **初始快照**：记录启动时代理 TUN / `utun8` 是否已存在。已存在的视为已处理，不再重复提示。
4. **运行期监控**：
   - 每 1 秒检测客户端进程（`O+Connect` / `oplus_remote_ui` / `SLDesktopAgent`）。
   - 客户端启动 5 秒后，每 3 秒检测 `utun8` 与代理 TUN。
   - 新出现的代理 TUN 或 `utun8` → 启动独立进程 `Show-GuardPrompt.ps1` 弹窗（不阻塞监控）。
5. **退出清理**（客户端全部消失且超过宽限）：
   - 并行停止 `O+Connect Service` / `OplusRemoteService`；
   - 注销两个服务（不备份，下次启动客户端会自动 repair）；
   - 卸载 OPPO 的 `vgate0` / `utun8`（只删描述为 `Rust Wintun Tunnel` 的适配器）；
   - 最后结束 OPPO 自带的 `adb.exe` 残留进程（只匹配安装目录下的 adb，不动其他 adb）；
   - 退出。

## 相关文件

- `Show-GuardPrompt.ps1`：冲突弹窗（独立进程）
- `Invoke-OppoIcsPulse.ps1`：脉冲（由弹窗进程调用）
- `OppoConnectTun.Common.ps1`：检测与清理函数

## 注意

- 守护在客户端运行期间常驻；客户端退出后自动结束。
- 清理日志在 `logs\guard-*.log`，每类日志保留最近 2 个（本次 + 上一次）。
- 若客户端崩溃或被强杀，同样会触发清理。
