<#
.SYNOPSIS
    东华大学校园网自动登录 —— 配置脚本。

.DESCRIPTION
    1. 提示输入校园网账号和密码（密码输入时不显示）。
    2. 使用 Windows DPAPI 加密密码，保存到脚本目录。
    3. 创建名为 CampusAutoLogin_DHU 的计划任务：
         - 每天 23:30–00:30（默认）每 5 分钟检查一次（覆盖 0 点掉线）；
         - 其余时间每小时整点后 1 分钟检查一次；
         - 用户登录 Windows 时也检查，失败时 10 分钟内可完成 3 轮重试。
    4. 关闭交流电睡眠，避免远程连接时电脑休眠。

    需要重新配置（例如改了校园网密码）时，重新运行本脚本即可覆盖旧配置。
    只想修改检查时间/重建计划任务时，可加 -UpdateTaskOnly。

.PARAMETER ConfigDir
    配置和运行状态目录，默认与脚本相同。

.PARAMETER Username
    可选：直接传入账号（主要用于测试/无人值守）。

.PARAMETER Password
    可选：SecureString 密码（主要用于测试/无人值守）。

.PARAMETER NightWindowStart
    夜间检查窗口开始时间，默认 23:30。例如 '23:00'。

.PARAMETER NightWindowHours
    夜间检查窗口持续小时数，默认 1（即 23:30–00:30）。

.PARAMETER NightWindowIntervalMinutes
    夜间检查窗口内的检查间隔（分钟），默认 5。

.PARAMETER HourlyCheckMinute
    其余时间每小时的检查分钟数（整点后第几分钟），默认 1。

.PARAMETER UpdateTaskOnly
    不读写账号密码，只按当前参数重建计划任务。

.PARAMETER NoTask
    只保存配置，不创建计划任务。

.PARAMETER NoPower
    不修改电源设置。

.PARAMETER NoPause
    结束后不等待回车（用于脚本调用）。
#>
[CmdletBinding()]
param(
    [string]$ConfigDir = '',
    [string]$Username,
    [Security.SecureString]$Password,
    [string]$NightWindowStart = '23:30',
    [int]$NightWindowHours = 1,
    [int]$NightWindowIntervalMinutes = 5,
    [int]$HourlyCheckMinute = 1,
    [switch]$UpdateTaskOnly,
    [switch]$NoTask,
    [switch]$NoPower,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigDir)) { $ConfigDir = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($ConfigDir)) { $ConfigDir = (Get-Location).Path }
$taskName = 'CampusAutoLogin_DHU'
$scriptPath = Join-Path $PSScriptRoot 'campus-autologin.ps1'

function Write-Title {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
}

Write-Title '东华大学校园网自动登录 —— 配置'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "找不到主脚本: $scriptPath"
}

if (-not $UpdateTaskOnly) {
    if ([string]::IsNullOrWhiteSpace($Username)) {
        do {
            $Username = Read-Host '请输入校园网账号（学号/工号）'
        } while ([string]::IsNullOrWhiteSpace($Username))
    }
    $Username = $Username.Trim()

    if (-not $Password) {
        do {
            $Password = Read-Host '请输入校园网密码（输入时不显示）' -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            try {
                $testPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            } finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
            if ([string]::IsNullOrEmpty($testPlain)) {
                Write-Host '密码不能为空，请重新输入。' -ForegroundColor Yellow
            }
        } while ([string]::IsNullOrEmpty($testPlain))
        $testPlain = $null
    }

    # 取出明文（只在内存中使用），用于加密
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    if ([string]::IsNullOrEmpty($plainPassword)) {
        throw '密码不能为空。'
    }

    Add-Type -AssemblyName System.Security
    $entropy = [Text.Encoding]::UTF8.GetBytes('CampusAutoLogin-v1')
    $encrypted = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($plainPassword),
        $entropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $encryptedBase64 = [Convert]::ToBase64String($encrypted)

    # 及时清理明文变量
    $plainPassword = $null
    [GC]::Collect()

    if (-not (Test-Path -LiteralPath $ConfigDir)) {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    }

    # 自动识别 UU远程 的启动方式（校园网重新登录后需要重启它）
    $uuExe = ''
    $uuArgs = ''
    try {
        $run = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction Stop).GameViewer
        if ($run -match '^\s*"([^"]+)"\s*(.*)$') {
            $uuExe = $matches[1]
            $uuArgs = $matches[2]
        } elseif ($run -match '^\s*(\S+\.exe)\s*(.*)$') {
            $uuExe = $matches[1]
            $uuArgs = $matches[2]
        }
    } catch { }
    if (-not $uuExe -and (Test-Path -LiteralPath 'D:\APPS\GameViewer\GameViewer.exe')) {
        $uuExe = 'D:\APPS\GameViewer\GameViewer.exe'
        $uuArgs = '--auto-run'
    }

    $config = [ordered]@{
        version           = 1
        username          = $Username
        passwordEncrypted = $encryptedBase64
        portalBase        = 'https://portal1.dhu.edu.cn'
        portalBases       = @('https://portal1.dhu.edu.cn', 'https://portal2.dhu.edu.cn')
        switchip          = '192.168.5.2'
        wlanacname        = 'Bras_M6K_DHSJ'
        restartUURemote   = $true
        uuRemoteExe       = $uuExe
        uuRemoteArgs      = $uuArgs
        createdAt         = (Get-Date).ToString('s')
    }

    $configPath = Join-Path $ConfigDir 'config.json'
    $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8

    # 重新配置时清除暂停和重试计数，避免新密码仍被旧状态挡住
    $pausePath = Join-Path $ConfigDir 'pause.json'
    if (Test-Path -LiteralPath $pausePath) {
        Remove-Item -LiteralPath $pausePath -Force -ErrorAction SilentlyContinue
    }
    $retryPath = Join-Path $ConfigDir 'retry-state.json'
    if (Test-Path -LiteralPath $retryPath) {
        Remove-Item -LiteralPath $retryPath -Force -ErrorAction SilentlyContinue
    }
    $legacyBackoffPath = Join-Path $ConfigDir 'login-backoff.json'
    if (Test-Path -LiteralPath $legacyBackoffPath) {
        Remove-Item -LiteralPath $legacyBackoffPath -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host "配置已保存: $configPath" -ForegroundColor Green
    Write-Host "账号: $Username"

    if (-not $NoPower) {
        Write-Host ''
        Write-Host '正在关闭交流电睡眠/休眠（防止远程连接时电脑休眠）...'
        & powercfg.exe /change standby-timeout-ac 0 2>$null
        & powercfg.exe /change hibernate-timeout-ac 0 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host '已设置：插电时永不睡眠。' -ForegroundColor Green
        } else {
            Write-Host '电源设置修改失败（可能需要管理员权限），不影响自动登录本身。' -ForegroundColor Yellow
        }
    }
} else {
    Write-Host ''
    Write-Host '仅重建计划任务，不修改账号密码配置。'
}

# ---------------------------------------------------------------------------
# 计划任务：
#   夜间窗口：每天 NightWindowStart 开始，每 NightWindowIntervalMinutes 分钟一次，
#             持续 NightWindowHours 小时（默认 23:30–00:30，每 5 分钟）；
#   其余时间：每小时整点后第 HourlyCheckMinute 分钟检查一次；
#   用户登录 Windows 时也检查。
# ---------------------------------------------------------------------------
if (-not $NoTask) {
    try { $nightStart = [datetime]::Parse($NightWindowStart) } catch { $nightStart = [datetime]::Parse('23:30') }
    if ($NightWindowHours -lt 1) { $NightWindowHours = 1 }
    if ($NightWindowIntervalMinutes -lt 1) { $NightWindowIntervalMinutes = 5 }
    if ($HourlyCheckMinute -lt 0 -or $HourlyCheckMinute -gt 59) { $HourlyCheckMinute = 1 }

    Write-Host ''
    Write-Host ('正在创建计划任务（每天 {0:HH:mm}–{1:HH:mm} 每 {2} 分钟一次；其余时间每小时第 {3} 分钟检查一次；登录时也检查）...' -f `
        $nightStart, $nightStart.AddHours($NightWindowHours), $NightWindowIntervalMinutes, $HourlyCheckMinute)

    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Scheduled' -f $scriptPath
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments

    $triggers = @()

    # 夜间检查窗口（覆盖 0 点掉线）
    $nightTrigger = New-ScheduledTaskTrigger -Daily -At $nightStart
    $nightTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $NightWindowIntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Hours $NightWindowHours)).Repetition
    $triggers += $nightTrigger

    # 其余时间：每小时整点后第 HourlyCheckMinute 分钟检查一次
    $hourlyStart = (Get-Date).Date.AddMinutes($HourlyCheckMinute)
    $hourlyTrigger = New-ScheduledTaskTrigger -Once -At $hourlyStart `
        -RepetitionInterval (New-TimeSpan -Hours 1) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $triggers += $hourlyTrigger

    # 登录 Windows 时检查；10 分钟内允许完成 3 轮重试
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $logonTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 1) `
        -RepetitionDuration (New-TimeSpan -Minutes 10)).Repetition
    $triggers += $logonTrigger

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -WakeToRun `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -MultipleInstances IgnoreNew

    $principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive `
        -RunLevel Limited

    try {
        Register-ScheduledTask -TaskName $taskName `
            -Action $action `
            -Trigger $triggers `
            -Settings $settings `
            -Principal $principal `
            -Force | Out-Null

        Write-Host "计划任务已创建/更新: $taskName" -ForegroundColor Green

        # 立即启动一次，验证任务能正常运行（在线时脚本只会记一条日志后退出）
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 4
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        if ($info) {
            Write-Host "任务上次运行结果: $($info.LastTaskResult)（0 表示正常）"
        }
    } catch {
        Write-Host "计划任务创建失败: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '可以稍后右键“以管理员身份运行 PowerShell”，再执行本脚本。' -ForegroundColor Yellow
    }
}

$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}
Write-Host ''
Write-Host '配置完成。' -ForegroundColor Green
Write-Host "配置目录: $ConfigDir"
Write-Host "日志目录: $logDir"
Write-Host ''
Write-Host '说明：'
Write-Host ('  - 每天 {0:HH:mm}–{1:HH:mm} 每 {2} 分钟检查一次；其余时间每小时第 {3} 分钟检查一次；登录 Windows 时也检查；' -f $nightStart, $nightStart.AddHours($NightWindowHours), $NightWindowIntervalMinutes, $HourlyCheckMinute)
Write-Host '  - 失败最多重试 3 轮（间隔 1/2 分钟），3 轮仍失败就停止，新的一天自动重置；'
Write-Host '  - 密码用 Windows DPAPI 加密，只有当前 Windows 用户能解密；'
Write-Host '  - 校园网密码修改后，请重新运行本脚本。'
Write-Host ''

if (-not $NoPause) {
    Read-Host '按回车退出' | Out-Null
}