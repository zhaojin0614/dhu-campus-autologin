# 东华大学校园网自动登录

东华大学校园网每天 0 点会强制退出登录，导致远程控制断开。本脚本会在掉线后自动重新认证，恢复网络和远程连接。以下说明主要介绍安装与使用方法。

## 功能

- **定时检查**：每天 23:30–00:30 每 5 分钟检查一次（覆盖 0 点掉线）；其余时间每小时整点后 1 分钟检查一次；登录 Windows 后 10 分钟内每分钟检查一次（保证 3 轮重试能完成）。
- 校园网 0 点自动退出后，最多 1 分钟内恢复。
- 双重登录方式：
  1. 优先用 HTTP 直接提交认证请求（快、无窗口）；
  2. 如果门户流程有变化，自动用**无头 Edge**打开真实登录页并提交表单，和手工登录完全一致。
- 登录完成后再次检测网络，确认真的恢复。
- **登录成功后自动重启 UU远程 客户端**，解决校园网重新认证后 UU远程显示“无法连接网络”的问题；重启失败会在后续检查中继续重试（最多 2 小时）。
- **可选配合 Windows 自动登录**：如果配置了开机自动进入桌面，重启后脚本会自动运行，无需人工操作（详见“重启后的自动恢复”）。
- 账号密码使用 Windows DPAPI 加密保存，只有当前 Windows 用户能解密。
- 密码错误时会暂停 6 小时，避免反复尝试导致账号被锁。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `setup.cmd` | **双击运行**，打开配置窗口 |
| `setup.ps1` | 首次配置：输入账号密码、保存配置、创建计划任务、关闭睡眠 |
| `campus-autologin.ps1` | 主脚本，负责检测网络和自动登录 |
| `uninstall.cmd` / `uninstall.ps1` | 卸载计划任务，可选删除配置/状态/日志（不会删除脚本） |
| `README.md` | 本说明 |

所有运行时文件都放在脚本所在目录：

```
<脚本目录>\
├─ campus-autologin.ps1      # 主脚本
├─ setup.cmd / setup.ps1     # 首次配置
├─ uninstall.cmd / uninstall.ps1
├─ README.md
├─ config.json               # 账号 + DPAPI 加密后的密码（必需）
├─ pause.json                # 密码错误暂停（出现时才生成）
├─ retry-state.json          # 3 轮重试计数（出现时才生成）
├─ uu-restart-pending.json   # UU远程重启待处理（出现时才生成）
└─ logs\
   └─ autologin-YYYYMMDD.log # 每天一个日志文件
```

`config.json` 是自动登录的运行配置：保存校园网账号、Windows DPAPI 加密后的密码、门户地址、`switchip`/`wlanacname`、UU远程启动方式等。密码不是明文，只有当前 Windows 用户能解密。删除它后脚本无法自动登录，需要重新运行 `setup.cmd`。

无头 Edge 的临时配置放在 `%TEMP%\CampusAutoLogin_EdgeProfile`，每次用完自动删除，不会留在脚本目录。

## 首次配置

**最简单的方式：** 在脚本所在文件夹中双击 `setup.cmd`，按提示输入账号密码。

如果习惯命令行，也可以在该目录打开 PowerShell 执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

按提示输入：

1. 校园网账号（学号/工号）；
2. 校园网密码（输入时不显示）。

脚本会自动：

- 保存加密后的密码；
- 关闭交流电睡眠（原来 5 分钟后睡眠，会直接导致远程连不上）；
- 创建计划任务 `CampusAutoLogin_DHU`：
  - 每天 23:30–00:30 每 5 分钟运行一次（覆盖 0 点掉线）；
  - 其余时间每小时整点后 1 分钟运行一次；
  - 用户登录 Windows 时运行，失败时 10 分钟内可完成 3 轮重试；
  - 任务设置为“错过时间后尽快启动”“唤醒计算机运行”。

想修改检查时间时，重新运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -UpdateTaskOnly -NightWindowStart '23:00' -NightWindowHours 1 -NightWindowIntervalMinutes 5 -HourlyCheckMinute 1 -NoPause
```

看到下面的提示即表示配置成功：

```
计划任务已创建/更新: CampusAutoLogin_DHU
任务上次运行结果: 0（0 表示正常）
```

### 配置后建议做一次真实账号验证

`setup.ps1` 只会在离线时真正登录，所以在线状态下不会验证密码。配置完成后，建议手动执行一次诊断（会向门户真实提交一次账号密码，但不会断开当前网络）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\campus-autologin.ps1 -Diagnose -NoBrowser
```

看日志里的这一行：

- `error=账号密码错误` → 密码填错了，重新运行 `setup.cmd`；
- `outcome=already_online` 或 `outcome=success` → 账号密码能被门户接受，配置正常；
- `outcome=no_session` → 门户没有建立登录会话，通常是当前网络状态特殊，等掉线后脚本会自动重试。

## 验证

查看日志：

```powershell
Get-Content ".\logs\autologin-*.log" -Tail 30
```

正常在线时，日志大致是：

```
[2026-11-17 22:10:01] [INFO] 开始检查: ip=<本机IP> online=True user=<账号>
[2026-11-17 22:10:01] [INFO] 网络已在线，无需登录。
```

断网后，日志会显示：

```
[2026-11-18 00:01:01] [INFO] 开始检查: ip=<本机IP> online=False user=<账号>
[2026-11-18 00:01:01] [INFO] 认证地址: https://portal1.dhu.edu.cn/switch.php?...
[2026-11-18 00:01:02] [INFO] HTTP 登录: status=200 outcome=success ...
[2026-11-18 00:01:06] [INFO] 网络已恢复，自动登录成功。
```

也可以手动运行诊断（会实际请求一次登录接口；当前已在线时门户通常返回“用户已在线”，这是正常的）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\campus-autologin.ps1 -Diagnose
```

只测试 HTTP 方式、不启动浏览器：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\campus-autologin.ps1 -Diagnose -NoBrowser
```

立即手动执行一次登录检查（在线时会直接退出）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\campus-autologin.ps1
```

## 工作原理

1. 用微软 NCSI（`www.msftconnecttest.com`）、百度、小米 204 三个地址判断 IPv4 是否真的能上网。
2. 如果离线，先请求外网地址，让校园网 BRAS 拦截并返回真正的 `switch.php` 认证地址（`portal1.dhu.edu.cn` / `portal2.dhu.edu.cn`）。
3. 用同一个 Cookie 会话打开登录页，向 `/post.php` 提交：
   - `username`
   - `password`
   - `savePWD=on`
   - `MKKey=`
4. 如果 HTTP 方式没有恢复网络，则启动无头 Edge：
   - 打开认证地址对应的登录页；
   - 等待登录表单出现，填入账号密码并提交；
   - 关闭浏览器，再检测网络。
5. 网络恢复即结束；失败则等待 1 分钟、2 分钟后重试，最多 3 轮，3 轮仍失败就停止（跨天自动重置）。
6. 登录成功后，关闭并重新启动 UU远程 客户端，让它重新建立远控连接。
7. 每次登录 Windows 后，触发器会让脚本每分钟运行一次、持续 10 分钟——这是为了让 3 轮重试能完成；10 分钟后恢复到定时检查。

计划任务只在夜间窗口（默认 23:30–00:30，每 5 分钟）、每小时整点后 1 分钟和用户登录 Windows 时运行（登录后 10 分钟内每分钟一次）；其他时间不会执行任何检查。

## UU远程自动重启

校园网重新认证后，UU远程经常会显示“无法连接网络”，但把 UU远程 退出再打开就恢复。脚本在每次**真正完成自动登录**后会：

1. 关闭正在运行的 `GameViewer.exe`（UU远程 客户端）；
2. 用你登录 Windows 时自动启动 UU远程 的同一条命令重新打开它；
3. 等待并确认进程已经起来。

相关日志：

```
[2026-11-18 00:01:06] [INFO] 网络已恢复，自动登录成功。
[2026-11-18 00:01:09] [INFO] 准备重启 UU远程: D:\APPS\GameViewer\GameViewer.exe --auto-run
[2026-11-18 00:01:11] [INFO] 已结束 UU远程进程 PID=27624
[2026-11-18 00:01:20] [INFO] UU远程 已重新启动 (PID: 12345)
```

说明：

- 重启会**短暂断开当前的远程画面**，这属于正常现象；校园网重新认证本身已经让 UU远程 无法连接，重启是为了恢复。
- 如果重启失败，脚本会记录一个 2 小时有效的待处理标记，之后每次计划任务检查时继续重试。
- 不想自动重启时，可以手动运行时加 `-NoUURestart`，或者把 `config.json` 里的 `restartUURemote` 改成 `false`（这个字段是普通布尔值，可以安全手动改）。
- 脚本使用的启动命令来自注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的 `GameViewer` 项，和开机自启完全一致。

## 失败重试与账号保护

脚本**最多尝试 3 轮**，3 轮都失败就停止，不再向门户提交登录：

- **在线时**：只做一次轻量连通性检测，不访问认证门户。
- **第 1 轮失败**：等待 1 分钟后重试第 2 轮；
- **第 2 轮失败**：等待 2 分钟后重试第 3 轮；
- **第 3 轮失败**：停止自动登录，不再尝试，直到：
  - 新的一天到来（跨天自动重置，第二天检查窗口会重新尝试）；
  - 网络恢复在线（手动登录后，脚本下一次检查会自动清除停止状态）；
  - 或手动删除 `retry-state.json`；
  - 或重新运行 `setup.cmd` 重置。
- **门户明确提示账号/密码错误**：第一次收到就暂停 **6 小时**，不会继续试密码。
- **门户提示账号停用/欠费**：同样暂停 6 小时。
- 每轮最多提交 **HTTP 登录 1 次 + 浏览器兜底 1 次**。
- 夜间窗口（23:30–00:30 每 5 分钟）和每小时检查时，计划任务都会运行；“已停止”状态下立即退出，不会提交登录。

相关状态文件（都在脚本目录）：

```
retry-state.json   # 已尝试轮数、下次尝试时间、是否已停止
pause.json         # 密码错误/账号异常暂停 6 小时
```

想立刻重置并重试，可以删除 `retry-state.json` 和 `pause.json`，或者手动运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\campus-autologin.ps1 -Force
```

`-Force` 会跳过 3 轮限制（但不会跳过密码错误暂停）。

## 常见问题

### 日志里出现 `no_session_found`

门户没有建立登录会话，常见于网络状态特殊或直接请求登录接口。脚本会自动改用无头 Edge 再试；如果最终网络是通的，就不用处理。

### 日志里出现“启动 UU远程 失败: 无法使用指定的命名参数解析参数集”

这是旧版本脚本在部分 PowerShell 5.1 环境下 `Split-Path -LiteralPath ... -Parent` 的兼容性问题，当前版本已改为 `[System.IO.Path]::GetDirectoryName()`，不会再出现。确认运行的是最新 `campus-autologin.ps1` 即可。

### 日志里出现 `bad_credentials`

账号或密码错误。脚本会暂停 6 小时。请重新运行 `setup.ps1` 修正密码。暂停记录在：

```
pause.json（脚本所在目录）
```

修正密码后重新运行 `setup.ps1` 会自动覆盖配置；如需立即清除暂停，删除 `pause.json`。

### 计划任务显示上次运行结果不是 0

打开日志看具体错误。常见原因：

- 配置不存在：重新运行 `setup.ps1`；
- 密码解密失败：配置不是当前 Windows 用户创建的，重新运行 `setup.ps1`；
- Edge 路径变化：脚本会自动从注册表查找，一般不需要处理。

### 电脑重启后会自动恢复吗？

取决于是否配置了 Windows 自动登录：

- **已配置自动登录**（开机直接进入桌面）：进入桌面时，UU远程 会随开机自启，脚本也会由“登录触发器”立即运行。校园网会话通常在重启后仍然有效（日志显示 `online=True`，无需登录）；如果掉线，会自动重新认证并重启 UU远程。
- **未配置自动登录**：重启后会停在登录界面，需要先手动登录 Windows；在此之前脚本和远程控制软件都不会启动。

登录后 10 分钟内脚本每分钟检查一次（登录后重试窗口），之后恢复定时检查。

想配置开机自动登录，可以在 Windows 设置中清空登录密码，或使用 `netplwiz` / 微软 Autologon 工具保存密码自动登录。注意这会让任何能物理接触电脑的人直接进入桌面，请自行评估风险。

### 修改了校园网密码

重新运行一次 `setup.ps1` 即可。

### 会不会影响日常使用 Edge？

不会。脚本使用独立的 `EdgeProfile` 目录，不读取也不修改你日常 Edge 的配置和登录状态。

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

同时删除配置和日志：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveData
```

恢复交流电睡眠为 5 分钟：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -RestoreSleep
```

## 注意

- `config.json` 中的密码经 Windows DPAPI 加密，但仍不建议把它发给别人。
- 如需配置开机自动登录，请自行评估物理安全风险：自动登录会让任何能接触电脑的人直接进入桌面。
- 请仅用于本人账号，并遵守学校网络使用规定。
- 校园网认证页面如果大改版，脚本可能需要更新；可查看日志中的 `HTTP 登录`、`浏览器登录` 两行定位问题。