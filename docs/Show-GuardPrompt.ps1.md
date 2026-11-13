# Show-GuardPrompt.ps1 — 守护的冲突弹窗

## 用途

由 `Guard-OppoConnectTun.ps1` 以独立进程启动的提示窗口。负责显示冲突信息、接收用户选择，并执行对应动作。

**独立进程的原因**：如果守护自己同步弹窗（`ShowDialog`），整个监控循环会被阻塞；客户端退出时守护无法清理。独立进程只负责 UI，守护继续监控。

## 运行方式

不直接运行，由守护自动启动：

```text
powershell -WindowStyle Hidden -File Show-GuardPrompt.ps1 -Kind Proxy -ProxyNames "Meta" -LogFile "...\guard.log"
```

## 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-Kind` | `Proxy` | `Proxy`（代理 TUN 新出现）或 `Utun`（utun8 新出现） |
| `-ProxyNames` | 空 | 代理 TUN 名称，多个用 `, ` 分隔 |
| `-LogFile` | 自动生成 | 写入守护日志文件 |
| `-TunAdapter` | `vgate0` | 脉冲使用的 TUN 名称 |

## 用户选择

| 按钮 | 行为 |
| --- | --- |
| 手动关闭代理 TUN | 弹提示让用户去关闭，记录日志 |
| 使用 ICS 脉冲 | 启动 `Invoke-OppoIcsPulse.ps1` 并等待结果 |
| 忽略，继续 | 只记录日志 |

## 注意

- 窗口置顶显示；关闭窗口（X）等同于“忽略”。
- 需要 `System.Windows.Forms`；PowerShell 5.1 默认 STA，可直接使用。
