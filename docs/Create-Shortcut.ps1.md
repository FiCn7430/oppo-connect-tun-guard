# Create-Shortcut.ps1 — 创建桌面快捷方式

## 用途

在桌面创建“OPPO互联”快捷方式，指向无窗口的 `Start-OppoConnect.vbs`。

## 运行方式

普通权限即可（创建快捷方式不需要管理员）：

```powershell
.\Create-Shortcut.ps1
```

## 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-ShortcutPath` | 桌面 `OPPO互联.lnk` | 自定义快捷方式路径 |
| `-Force` | 关 | 已存在时覆盖 |

## 快捷方式内容

| 项目 | 值 |
| --- | --- |
| 目标 | `C:\Windows\System32\wscript.exe` |
| 参数 | `"<项目目录>\Start-OppoConnect.vbs"` |
| 起始位置 | 项目目录 |
| 图标 | `O+Connect.exe` 的图标 |
| 说明 | OPPO 互联启动器（一次 UAC，退出后自动注销服务、卸载网卡） |

## 注意

- 目标显式指定 `wscript.exe`，不依赖 `.vbs` 文件关联。
- 若移动了项目目录，需要重新运行本脚本（或删除旧快捷方式后重建）。
- 快捷方式不需要勾选“以管理员身份运行”，提权由 VBS 内部完成。
