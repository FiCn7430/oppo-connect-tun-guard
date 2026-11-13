# Invoke-OppoIcsPulse.ps1 — ICS 共存脉冲

## 用途

用 Windows ICS（Internet 连接共享）强制刷新 NAT/路由，尝试让代理 TUN 与 OPPO 网卡暂时共存。原理来自桌面脚本 `Fuck_you_oppo_tun_adapter.ps1`。

## 运行方式

需要管理员（枚举 ICS 连接本身就需要提升）：

```powershell
.\Invoke-OppoIcsPulse.ps1 -TunAdapter vgate0
```

## 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-TunAdapter` | `vgate0` | TUN 的 ICS 连接名；也会匹配描述含 `Mihomo` / `Meta Tunnel` 的连接 |
| `-PublicAdapter` | 空 | 强制指定上网网卡（uplink），默认自动检测 |
| `-HoldSeconds` | `2` | 共享保持时间（秒） |
| `-DryRun` | 关 | 只检测并打印，不修改 ICS |
| `-LogFile` | 自动生成 | 日志文件 |

## 流程

```text
枚举 ICS 连接（HNetCfg.HNetShare）
→ 找真实上网网卡 uplink（IPv4 默认路由，排除虚拟/TUN；默认路由被 TUN 吞掉时回退到“有网关的非虚拟网卡”）
→ 找 TUN 的 ICS 连接
→ 清空现有 ICS
→ TUN 启用“专用共享”（EnableSharing(1)）
→ uplink 启用“公用共享”（EnableSharing(0)）
→ 保持 HoldSeconds 秒
→ 再次清空 ICS
```

## 退出码

| 退出码 | 含义 |
| --- | --- |
| `0` | 成功（DryRun 时表示检测通过） |
| `1` | 找不到 TUN / uplink / ICS 连接，或执行失败 |
| `2` | 不是管理员 |

## 注意

- 执行期间网络会短暂中断（调用方按约 30 秒提示用户）。
- 方式不稳定，不保证长期有效；失败时可用启动器的“重试网卡共存”再试。
- 已知问题：ICS 连接列表中 TUN 可能匹配到代理的 `Meta`，不一定是 `vgate0`（暂未修正）。
