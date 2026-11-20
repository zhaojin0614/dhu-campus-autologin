<#
.SYNOPSIS
    卸载东华大学校园网自动登录。

.DESCRIPTION
    删除计划任务；可选删除配置、运行状态和日志；可选恢复交流电睡眠时间。

.PARAMETER ConfigDir
    配置和运行状态目录，默认与脚本相同。

.PARAMETER RemoveData
    同时删除配置、运行状态、日志和无头 Edge 临时配置目录。
    不会删除脚本本身。

.PARAMETER RestoreSleep
    把交流电睡眠时间恢复为 5 分钟（安装前的原值）。
#>
[CmdletBinding()]
param(
    [string]$ConfigDir = '',
    [switch]$RemoveData,
    [switch]$RestoreSleep
)

$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrWhiteSpace($ConfigDir)) { $ConfigDir = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($ConfigDir)) { $ConfigDir = (Get-Location).Path }
$taskName = 'CampusAutoLogin_DHU'

Write-Host "正在删除计划任务 $taskName ..."
try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    Write-Host '计划任务已删除。' -ForegroundColor Green
} catch {
    Write-Host "计划任务不存在或删除失败: $($_.Exception.Message)" -ForegroundColor Yellow
}

if ($RestoreSleep) {
    & powercfg.exe /change standby-timeout-ac 5 2>$null
    & powercfg.exe /change hibernate-timeout-ac 0 2>$null
    Write-Host '已把交流电睡眠时间恢复为 5 分钟。'
}

if ($RemoveData) {
    # 只删除运行数据文件，绝不递归删除脚本目录
    $runtimeFiles = @(
        'config.json',
        'pause.json',
        'retry-state.json',
        'uu-restart-pending.json',
        'login-backoff.json'
    )
    foreach ($name in $runtimeFiles) {
        $p = Join-Path $ConfigDir $name
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            Write-Host "已删除: $p"
        }
    }

    # 日志在脚本目录下的 logs 子目录
    $scriptLogDir = Join-Path $PSScriptRoot 'logs'
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { $scriptLogDir = Join-Path $ConfigDir 'logs' }
    if (Test-Path -LiteralPath $scriptLogDir) {
        Remove-Item -LiteralPath $scriptLogDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "已删除日志目录: $scriptLogDir"
    }

    # 清理 Edge 临时配置（新版在 TEMP，旧版可能在配置目录）
    $profilePaths = @(
        (Join-Path $env:TEMP 'CampusAutoLogin_EdgeProfile'),
        (Join-Path $ConfigDir 'EdgeProfile')
    )
    foreach ($edgeDir in $profilePaths) {
        if ($edgeDir -and (Test-Path -LiteralPath $edgeDir)) {
            Remove-Item -LiteralPath $edgeDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # 清理可能残留的无头 Edge 进程
    try {
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $cmd = $_.CommandLine
                if (-not $cmd) { return $false }
                foreach ($p in $profilePaths) {
                    if ($p -and $cmd.Contains($p)) { return $true }
                }
                return $false
            } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }

    # 如果 ConfigDir 是之前的独立目录，删除空目录（不碰脚本目录）
    if ((Test-Path -LiteralPath $ConfigDir) -and ($ConfigDir -ne $PSScriptRoot)) {
        if (-not (Get-ChildItem -LiteralPath $ConfigDir -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $ConfigDir -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
Write-Host '卸载完成。'