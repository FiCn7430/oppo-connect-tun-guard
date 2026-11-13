# Start-OppoConnect.vbs — 日常入口（无窗口）

## 用途

双击启动 OPPO 互联的**日常入口**。由 `wscript.exe` 静默运行，不产生任何终端窗口；
需要提权时通过 `ShellExecute "runas"` 重启自身，只弹一次 UAC；
提权后再用隐藏窗口运行 `Start-OppoConnect.ps1`，由它拉起客户端和后台守护。

## 使用方法

- 直接双击本文件，或双击桌面“OPPO互联”快捷方式（快捷方式由 `Create-Shortcut.ps1` 创建）。
- 不需要参数。
- 如果 `.vbs` 被安全软件拦截，可改用管理员 PowerShell 运行 `Start-OppoConnect.ps1`。

## 行为

```text
wscript 运行
 ├─ 检查同目录 Start-OppoConnect.ps1 是否存在
 ├─ 非管理员：ShellExecute wscript.exe "自身" runas（UAC 一次，窗口隐藏）
 └─ 管理员：wscript.Shell.Run "powershell -WindowStyle Hidden -File Start-OppoConnect.ps1"
```

## 依赖

- 同目录的 `Start-OppoConnect.ps1`（必需）。

## 注意

- VBScript 已被微软列入弃用（Windows 11 24H2 起为按需功能），长期可能需要改用 `.ps1` 入口。
- 快捷方式的目标是 `wscript.exe`，参数为本文件，因此不依赖 `.vbs` 文件关联。
