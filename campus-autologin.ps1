<#
.SYNOPSIS
    东华大学校园网自动登录脚本（适用 portal1/portal2.dhu.edu.cn 认证门户）。

.DESCRIPTION
    工作方式：
      1. 先检测 IPv4 互联网是否可用（标准网络连通性探测）。
      2. 如果在线，直接退出（正常情况下每分钟检查一次，开销很小）。
      3. 如果离线，先触发运营商的认证跳转，拿到真正的 switch.php 地址，
         然后用 HTTP 方式提交账号密码。
      4. HTTP 方式不成功时，自动用无头 Edge 打开真实登录页并提交表单，
         与手工登录完全一致，作为兜底。
      5. 登录后再次检测网络，确认恢复。

    密码使用 Windows DPAPI（CurrentUser）加密保存，只有当前 Windows 用户能解密，
    不会以明文写入磁盘或日志。

.PARAMETER ConfigDir
    配置和运行状态目录，默认与脚本相同。

.PARAMETER Scheduled
    计划任务模式：不输出到控制台，只写日志。

.PARAMETER Force
    即使当前在线也尝试登录一遍（门户通常会返回 no_session_found，属正常）。

.PARAMETER Diagnose
    诊断模式：打印配置、网络状态、门户地址和登录接口返回内容，方便排查。

.PARAMETER NoBrowser
    禁用无头 Edge 兜底，只走 HTTP 登录。

.PARAMETER NoUURestart
    登录成功后不重启 UU远程（默认会重启，修复“无法连接网络”）。
#>
[CmdletBinding()]
param(
    [string]$ConfigDir = '',
    [switch]$Scheduled,
    [switch]$Force,
    [switch]$Diagnose,
    [switch]$NoBrowser,
    [switch]$NoUURestart
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 常量与路径
# ---------------------------------------------------------------------------
$script:AppName       = 'CampusAutoLogin'
$script:TaskName      = 'CampusAutoLogin_DHU'

# 先确定脚本所在目录；所有配置、状态和日志都放在这个目录下
$script:ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:ScriptDir)) {
    try { $script:ScriptDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path) } catch { }
}
if ([string]::IsNullOrWhiteSpace($script:ScriptDir)) { $script:ScriptDir = (Get-Location).Path }

# 默认配置目录就是脚本目录
if ([string]::IsNullOrWhiteSpace($ConfigDir)) { $ConfigDir = $script:ScriptDir }

$script:BaseDir       = $ConfigDir
$script:ConfigPath    = Join-Path $script:BaseDir 'config.json'
$script:PausePath     = Join-Path $script:BaseDir 'pause.json'
$script:BackoffPath   = Join-Path $script:BaseDir 'retry-state.json'
$script:UUPendingPath = Join-Path $script:BaseDir 'uu-restart-pending.json'

# 日志放在脚本目录下的 logs 子目录
$script:LogDir        = Join-Path $script:ScriptDir 'logs'
$script:LogFile       = Join-Path $script:LogDir ('autologin-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

# 无头 Edge 的临时配置放到 TEMP，用完即删，避免污染脚本目录
$script:EdgeProfile   = Join-Path $env:TEMP 'CampusAutoLogin_EdgeProfile'
if ([string]::IsNullOrWhiteSpace($env:TEMP)) { $script:EdgeProfile = Join-Path $script:BaseDir 'EdgeProfile' }

$script:Entropy       = [Text.Encoding]::UTF8.GetBytes('CampusAutoLogin-v1')
$script:UserAgent     = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36 Edg/157.0.0.0'
$script:CdpWs         = $null
$script:CdpId         = 0

# PowerShell 5.1 默认可能没有启用 TLS 1.2
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }
try {
    Add-Type -AssemblyName System.Web
    Add-Type -AssemblyName System.Security
} catch { }

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
function Initialize-Log {
    if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    }
    # 清理 14 天前的日志
    try {
        Get-ChildItem -LiteralPath $script:LogDir -Filter 'autologin-*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $msg = ($Message -replace "`r?`n", ' ')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $msg
    if (-not $Scheduled) {
        Write-Host $line
    }
    try {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch { }
}

function Get-Snippet {
    param([string]$Text, [int]$Max = 500)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) }
    return $t
}

# ---------------------------------------------------------------------------
# 配置 / 密码解密
# ---------------------------------------------------------------------------
function Get-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "找不到配置文件 $script:ConfigPath，请先运行 setup.ps1 完成首次配置。"
    }
    $cfg = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $cfg.username) { throw '配置文件中缺少 username。' }
    if (-not $cfg.passwordEncrypted) { throw '配置文件中缺少 passwordEncrypted，请重新运行 setup.ps1。' }
    return $cfg
}

function Unprotect-Password {
    param($Config)
    $bytes = [Convert]::FromBase64String($Config.passwordEncrypted)
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $bytes,
        $script:Entropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($plainBytes)
}

function Get-Pause {
    if (-not (Test-Path -LiteralPath $script:PausePath)) { return $null }
    try {
        $p = Get-Content -LiteralPath $script:PausePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([datetime]$p.until -gt (Get-Date)) { return $p }
        Remove-Item -LiteralPath $script:PausePath -Force -ErrorAction SilentlyContinue
    } catch {
        Remove-Item -LiteralPath $script:PausePath -Force -ErrorAction SilentlyContinue
    }
    return $null
}

function Set-Pause {
    param([int]$Hours, [string]$Reason)
    $obj = [ordered]@{
        until  = (Get-Date).AddHours($Hours).ToString('s')
        reason = $Reason
    }
    $obj | ConvertTo-Json | Set-Content -LiteralPath $script:PausePath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# 登录重试次数限制
# 最多尝试 3 轮；3 轮仍失败就停止，不再向门户提交登录。
# 密码错误仍然第一次就暂停 6 小时。
# ---------------------------------------------------------------------------
function Get-RetryState {
    if (-not (Test-Path -LiteralPath $script:BackoffPath)) { return $null }
    try {
        return Get-Content -LiteralPath $script:BackoffPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Remove-Item -LiteralPath $script:BackoffPath -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Save-RetryState {
    param($State)
    $State | ConvertTo-Json | Set-Content -LiteralPath $script:BackoffPath -Encoding UTF8
}

function Clear-RetryState {
    Remove-Item -LiteralPath $script:BackoffPath -Force -ErrorAction SilentlyContinue
}

function Register-LoginRound {
    # 返回 1..3 表示本轮轮次；返回 0 表示 3 轮已用完，应停止。
    $state = Get-RetryState
    if (-not $state) {
        $state = [pscustomobject]@{ rounds = 0; stopped = $false; nextAttempt = ''; lastFailureAt = '' }
    }
    if ($state.stopped) { return 0 }

    $rounds = [int]$state.rounds + 1
    if ($rounds -gt 3) {
        $state.rounds = 3
        $state.stopped = $true
        $state.nextAttempt = ''
        Save-RetryState $state
        return 0
    }

    $state.rounds = $rounds
    $state.stopped = $false
    $state.nextAttempt = ''
    Save-RetryState $state
    return $rounds
}

function Set-RetryFailure {
    $state = Get-RetryState
    if (-not $state) {
        $state = [pscustomobject]@{ rounds = 0; stopped = $false; nextAttempt = ''; lastFailureAt = '' }
    }
    $rounds = [int]$state.rounds

    if ($rounds -ge 3) {
        $state.stopped = $true
        $state.nextAttempt = ''
        $state.lastFailureAt = (Get-Date).ToString('s')
        Save-RetryState $state
        return $state
    }

    # 第 1 轮失败等 1 分钟，第 2 轮失败等 2 分钟，第 3 轮失败直接停止
    $delayMinutes = 1
    if ($rounds -ge 2) { $delayMinutes = 2 }
    $state.nextAttempt = (Get-Date).AddMinutes($delayMinutes).ToString('s')
    $state.lastFailureAt = (Get-Date).ToString('s')
    Save-RetryState $state
    return $state
}

# ---------------------------------------------------------------------------
# UU远程重启
# 校园网重新认证后，UU远程客户端常显示“无法连接网络”，退出重开即可恢复。
# ---------------------------------------------------------------------------
function Get-UURemoteLaunchInfo {
    param($Config)

    if ($Config.uuRemoteExe) {
        $exe = [string]$Config.uuRemoteExe
        if (Test-Path -LiteralPath $exe) {
            $launchArgs = ''
            if ($Config.uuRemoteArgs) { $launchArgs = [string]$Config.uuRemoteArgs }
            return [pscustomobject]@{ Exe = $exe; Args = $launchArgs }
        }
    }

    # 优先使用用户登录时自动启动 UU远程 的那条 Run 命令
    try {
        $run = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction Stop).GameViewer
        if ($run) {
            if ($run -match '^\s*"([^"]+)"\s*(.*)$') {
                $exe = $matches[1]
                $launchArgs = $matches[2]
            } elseif ($run -match '^\s*(\S+\.exe)\s*(.*)$') {
                $exe = $matches[1]
                $launchArgs = $matches[2]
            } else {
                $exe = $null
                $launchArgs = ''
            }
            if ($exe -and (Test-Path -LiteralPath $exe)) {
                return [pscustomobject]@{ Exe = $exe; Args = $launchArgs }
            }
        }
    } catch { }

    $fallback = 'D:\APPS\GameViewer\GameViewer.exe'
    if (Test-Path -LiteralPath $fallback) {
        return [pscustomobject]@{ Exe = $fallback; Args = '--auto-run' }
    }
    return $null
}

function Get-UURestartEnabled {
    param($Config)
    if ($null -eq $Config.restartUURemote) { return $true }
    return [bool]$Config.restartUURemote
}

function Get-UURestartPending {
    if (-not (Test-Path -LiteralPath $script:UUPendingPath)) { return $false }
    try {
        $p = Get-Content -LiteralPath $script:UUPendingPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([datetime]$p.until -gt (Get-Date)) { return $true }
        Remove-Item -LiteralPath $script:UUPendingPath -Force -ErrorAction SilentlyContinue
    } catch {
        Remove-Item -LiteralPath $script:UUPendingPath -Force -ErrorAction SilentlyContinue
    }
    return $false
}

function Set-UURestartPending {
    $obj = [ordered]@{
        until  = (Get-Date).AddHours(2).ToString('s')
        reason = '校园网重新登录后重启 UU远程'
    }
    $obj | ConvertTo-Json | Set-Content -LiteralPath $script:UUPendingPath -Encoding UTF8
}

function Clear-UURestartPending {
    Remove-Item -LiteralPath $script:UUPendingPath -Force -ErrorAction SilentlyContinue
}

function Restart-UURemote {
    param($Config)

    if ($NoUURestart) {
        Write-Log '本次指定了 -NoUURestart，跳过 UU远程 重启。'
        return $true
    }
    if (-not (Get-UURestartEnabled $Config)) {
        Write-Log '配置已禁用 UU远程 重启，跳过。'
        return $true
    }

    $info = Get-UURemoteLaunchInfo $Config
    if (-not $info) {
        Write-Log '找不到 UU远程 启动项，无法重启。' 'WARN'
        return $false
    }

    Write-Log "准备重启 UU远程: $($info.Exe) $($info.Args)"

    $procs = @(Get-Process -Name 'GameViewer' -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        Write-Log "找到 $($procs.Count) 个 UU远程 进程，正在关闭..."
        foreach ($p in $procs) {
            try { $null = $p.CloseMainWindow() } catch { }
        }
        Start-Sleep -Seconds 2

        foreach ($p in @(Get-Process -Name 'GameViewer' -ErrorAction SilentlyContinue)) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                Write-Log "已结束 UU远程进程 PID=$($p.Id)"
            } catch {
                Write-Log "结束 UU远程进程失败 PID=$($p.Id): $($_.Exception.Message)" 'WARN'
            }
        }
        Start-Sleep -Seconds 2
    } else {
        Write-Log '当前没有运行中的 UU远程 客户端进程，直接启动。'
    }

    try {
        $parent = [System.IO.Path]::GetDirectoryName($info.Exe)
        if ([string]::IsNullOrWhiteSpace($info.Args)) {
            Start-Process -FilePath $info.Exe -WorkingDirectory $parent -ErrorAction Stop
        } else {
            Start-Process -FilePath $info.Exe -ArgumentList $info.Args -WorkingDirectory $parent -ErrorAction Stop
        }
        Write-Log '已发出 UU远程 启动命令，等待其启动...'
    } catch {
        Write-Log "启动 UU远程 失败: $($_.Exception.Message)" 'ERROR'
        return $false
    }

    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 2
        $newProcs = @(Get-Process -Name 'GameViewer' -ErrorAction SilentlyContinue)
        if ($newProcs.Count -gt 0) {
            Write-Log "UU远程 已重新启动 (PID: $($newProcs[0].Id))"
            return $true
        }
    }

    Write-Log 'UU远程 启动命令已执行，但 20 秒内未检测到进程。' 'WARN'
    return $false
}

# ---------------------------------------------------------------------------
# 网络检测
# ---------------------------------------------------------------------------
function Get-PrimaryIPv4 {
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric |
            Select-Object -First 1
        if ($route) {
            $addr = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1
            if ($addr) { return $addr.IPAddress }
        }
    } catch { }

    try {
        $line = (ipconfig) | Select-String -Pattern 'IPv4' | Select-Object -First 1
        if ($line -and $line.ToString() -match '(\d{1,3}(?:\.\d{1,3}){3})') {
            return $matches[1]
        }
    } catch { }
    return $null
}

function Test-IPv4Online {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        # 微软 NCSI：最标准的“能否正常上网”判断
        try {
            $body = & $curl -4 -s -S --noproxy '*' --max-time 6 'http://www.msftconnecttest.com/connecttest.txt' 2>$null
            if ($LASTEXITCODE -eq 0 -and $body) {
                $text = ($body -join "`n")
                if ($text -match 'Microsoft Connect Test') { return $true }
            }
        } catch { }

        try {
            $code = & $curl -4 -s -o NUL -w '%{http_code}' --noproxy '*' --max-time 6 'https://www.baidu.com/' 2>$null
            if ($LASTEXITCODE -eq 0 -and "$code" -eq '200') { return $true }
        } catch { }

        try {
            $code = & $curl -4 -s -o NUL -w '%{http_code}' --noproxy '*' --max-time 6 'http://connect.rom.miui.com/generate_204' 2>$null
            if ($LASTEXITCODE -eq 0 -and "$code" -eq '204') { return $true }
        } catch { }
        return $false
    }

    # curl 不存在时的 .NET 兜底
    try {
        $r = Invoke-HttpRequest -Url 'http://www.msftconnecttest.com/connecttest.txt' -TimeoutSec 6
        if ($r.StatusCode -eq 200 -and $r.Body -match 'Microsoft Connect Test') { return $true }
    } catch { }
    try {
        $r = Invoke-HttpRequest -Url 'https://www.baidu.com/' -TimeoutSec 6
        if ($r.StatusCode -eq 200) { return $true }
    } catch { }
    return $false
}

# ---------------------------------------------------------------------------
# HTTP 工具
# ---------------------------------------------------------------------------
function Invoke-HttpRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Method = 'GET',
        [string]$Body = $null,
        [System.Net.CookieContainer]$Cookies = $null,
        [string]$Referer = $null,
        [bool]$AllowAutoRedirect = $true,
        [int]$TimeoutSec = 15
    )

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.AllowAutoRedirect = $AllowAutoRedirect
    $req.Proxy = $null
    $req.UserAgent = $script:UserAgent
    $req.Accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    $req.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    try { $req.ServicePoint.Expect100Continue = $false } catch { }

    if ($Cookies) { $req.CookieContainer = $Cookies }
    if ($Referer) { $req.Referer = $Referer }

    if ($Method -eq 'POST') {
        if ($null -eq $Body) { $Body = '' }
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType = 'application/x-www-form-urlencoded'
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }

    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $resp = $_.Exception.Response
        } else {
            throw
        }
    }

    $status = [int]$resp.StatusCode
    $headers = @{}
    foreach ($k in $resp.Headers.AllKeys) {
        if ($k) { $headers[$k] = $resp.Headers[$k] }
    }

    $reader = New-Object System.IO.StreamReader -ArgumentList @($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $reader.Close()
    $finalUrl = $resp.ResponseUri.AbsoluteUri
    $resp.Close()

    return [pscustomobject]@{
        StatusCode = $status
        Headers    = $headers
        Body       = $text
        FinalUrl   = $finalUrl
    }
}

function Resolve-Url {
    param([string]$Base, [string]$Location)
    if (-not $Location) { return $Base }
    try {
        $u = New-Object -TypeName System.Uri -ArgumentList @([Uri]$Base, $Location)
        return $u.AbsoluteUri
    } catch {
        return $Location
    }
}

# ---------------------------------------------------------------------------
# 门户发现
# ---------------------------------------------------------------------------
function Get-PortalDiscovery {
    param($Config, [System.Net.CookieContainer]$Cookies)

    $candidates = @(
        'http://www.msftconnecttest.com/redirect',
        'http://baidu.com/',
        'http://www.baidu.com/',
        'http://connect.rom.miui.com/generate_204'
    )

    foreach ($url in $candidates) {
        try {
            $r = Invoke-HttpRequest -Url $url -Cookies $Cookies -AllowAutoRedirect $false -TimeoutSec 8

            $location = $null
            if ($r.Headers.ContainsKey('Location')) { $location = $r.Headers['Location'] }

            if ($location) {
                $next = Resolve-Url $url $location
                if ($next -match 'switch\.php') {
                    return [pscustomobject]@{ SwitchUrl = $next; SourceUrl = $url; Discovered = $true }
                }
                try {
                    $r2 = Invoke-HttpRequest -Url $next -Cookies $Cookies -AllowAutoRedirect $false -TimeoutSec 8
                    $location2 = $null
                    if ($r2.Headers.ContainsKey('Location')) { $location2 = $r2.Headers['Location'] }
                    if ($location2) {
                        $next2 = Resolve-Url $next $location2
                        if ($next2 -match 'switch\.php') {
                            return [pscustomobject]@{ SwitchUrl = $next2; SourceUrl = $url; Discovered = $true }
                        }
                    }
                    if ($r2.Body -match '(?i)(https?://[^"''<>\s]*switch\.php\?[^"''<>\s]+)') {
                        return [pscustomobject]@{ SwitchUrl = $matches[1]; SourceUrl = $url; Discovered = $true }
                    }
                    if ($r2.Body -match '(?i)((?:https?://[^"''<>\s]+)?/switch\.php\?[^"''<>\s]+)') {
                        $next2 = Resolve-Url $next $matches[1]
                        if ($next2 -match 'switch\.php') {
                            return [pscustomobject]@{ SwitchUrl = $next2; SourceUrl = $url; Discovered = $true }
                        }
                    }
                } catch { }
            }

            if ($r.Body -match '(?i)(https?://[^"''<>\s]*switch\.php\?[^"''<>\s]+)') {
                return [pscustomobject]@{ SwitchUrl = $matches[1]; SourceUrl = $url; Discovered = $true }
            }

            if ($r.Body -match '(?i)((?:https?://[^"''<>\s]+)?/switch\.php\?[^"''<>\s]+)') {
                $next = Resolve-Url $url $matches[1]
                if ($next -match 'switch\.php') {
                    return [pscustomobject]@{ SwitchUrl = $next; SourceUrl = $url; Discovered = $true }
                }
            }

            if ($r.Body -match '(?i)(?:window\.)?location(?:\.href)?\s*=\s*["'']([^"'']+)["'']') {
                $next = Resolve-Url $url $matches[1]
                if ($next -match 'switch\.php') {
                    return [pscustomobject]@{ SwitchUrl = $next; SourceUrl = $url; Discovered = $true }
                }
            }

            if ($r.Body -match '(?i)location\.replace\(\s*["'']([^"'']+)["'']') {
                $next = Resolve-Url $url $matches[1]
                if ($next -match 'switch\.php') {
                    return [pscustomobject]@{ SwitchUrl = $next; SourceUrl = $url; Discovered = $true }
                }
            }

            if ($r.Body -match '(?i)<meta[^>]+refresh[^>]+url\s*=\s*([^"''>\s]+)') {
                $next = Resolve-Url $url $matches[1]
                if ($next -match 'switch\.php') {
                    return [pscustomobject]@{ SwitchUrl = $next; SourceUrl = $url; Discovered = $true }
                }
            }
        } catch {
            Write-Log "门户探测失败 [$url]: $($_.Exception.Message)" 'WARN'
        }
    }

    # 兜底：用当前 IP 和配置中的 BRAS 参数直接构造 switch.php 地址。
    $ip = Get-PrimaryIPv4
    if (-not $ip) { $ip = $Config.ip }
    $base = [string]$Config.portalBase
    if ([string]::IsNullOrWhiteSpace($base)) { $base = 'https://portal1.dhu.edu.cn' }
    $switchUrl = '{0}/switch.php?switchip={1}&ip={2}&url=http://www.msftconnecttest.com/redirect&wlanacname={3}' -f `
        $base.TrimEnd('/'), $Config.switchip, $ip, $Config.wlanacname

    return [pscustomobject]@{
        SwitchUrl  = $switchUrl
        SourceUrl  = 'http://www.msftconnecttest.com/redirect'
        Discovered = $false
    }
}

# ---------------------------------------------------------------------------
# HTTP 登录
# ---------------------------------------------------------------------------
function Invoke-HttpLogin {
    param($Config, [string]$Password, [string]$SwitchUrl, [System.Net.CookieContainer]$Cookies)

    $page = Invoke-HttpRequest -Url $SwitchUrl -Cookies $Cookies -AllowAutoRedirect $true -TimeoutSec 15
    Write-Log "登录页: status=$($page.StatusCode) final=$($page.FinalUrl)"

    if ($page.Body -notmatch 'name\s*=\s*["'']username["'']') {
        Write-Log "登录页中未找到用户名输入框，返回内容: $(Get-Snippet $page.Body 300)" 'WARN'
    }

    $uri = [Uri]$page.FinalUrl
    $postUrl = '{0}://{1}/post.php' -f $uri.Scheme, $uri.Authority
    $body = 'username={0}&password={1}&savePWD=on&MKKey=' -f `
        [System.Web.HttpUtility]::UrlEncode([string]$Config.username), `
        [System.Web.HttpUtility]::UrlEncode($Password)

    $result = Invoke-HttpRequest -Url $postUrl -Method 'POST' -Body $body -Cookies $Cookies `
        -Referer $page.FinalUrl -AllowAutoRedirect $false -TimeoutSec 15

    $postStatus = $result.StatusCode
    $postBody = $result.Body
    $postLocation = ''
    if ($result.Headers.ContainsKey('Location')) { $postLocation = [string]$result.Headers['Location'] }

    $final = $result
    if ($postStatus -ge 300 -and $postStatus -lt 400 -and $postLocation) {
        $nextUrl = Resolve-Url $postUrl $postLocation
        Write-Log "登录请求跳转: $nextUrl"
        try {
            $final = Invoke-HttpRequest -Url $nextUrl -Cookies $Cookies -AllowAutoRedirect $true -TimeoutSec 15
        } catch {
            Write-Log "跟随登录跳转失败: $($_.Exception.Message)" 'WARN'
        }
    }

    $combined = $postBody
    if ($final.Body -and $final.Body -ne $postBody) {
        $combined = $postBody + "`n" + $final.Body
    }

    return [pscustomobject]@{
        StatusCode   = $postStatus
        Headers      = $result.Headers
        Body         = $combined
        PostBody     = $postBody
        PostLocation = $postLocation
        PortalError  = (Decode-PortalError $postLocation)
        FinalUrl     = $final.FinalUrl
    }
}

function Decode-PortalError {
    param([string]$Location)
    if ([string]::IsNullOrWhiteSpace($Location)) { return '' }
    try {
        $raw = [Uri]::UnescapeDataString($Location)
        if ($raw -notmatch 'error=([^&]+)') { return '' }
        $value = $matches[1]

        # 有些跳转会把 error 再编码一次
        for ($i = 0; $i -lt 2 -and $value -match '%[0-9A-Fa-f]{2}'; $i++) {
            $value = [Uri]::UnescapeDataString($value)
        }

        # 门户有时把 UTF-8 字节按 Latin-1 再编一次，尝试还原
        $bytes = [Text.Encoding]::GetEncoding(28591).GetBytes($value)
        $fixed = [Text.Encoding]::UTF8.GetString($bytes)
        if ($fixed -match '[\u4e00-\u9fff]') { return $fixed }
        if ($value -match '[\u4e00-\u9fff]') { return $value }
        return $value
    } catch { }
    return ''
}

function Get-PortalOutcome {
    param([string]$Body, [string]$PortalError = '', [string]$Location = '')
    if ([string]::IsNullOrWhiteSpace($Body) -and [string]::IsNullOrWhiteSpace($PortalError)) { return 'empty' }

    $all = "$Body $PortalError $Location"
    if ($all -match 'no_session_found') { return 'no_session' }
    if ($all -match '账号密码错误|用户名或密码|密码错误|用户名不存在|账户不存在') { return 'bad_credentials' }
    if ($all -match '(?i)\berr(4|9)\b') { return 'bad_credentials' }
    if ($all -match '账号已在线|已在线') { return 'already_online' }
    if ($all -match '(?i)\berr(5|11)\b') { return 'account_disabled' }
    if ($all -match '(?i)\berr(7|13)\b') { return 'no_balance' }
    if ($all -match '(?i)\berr(6|12)\b') { return 'already_online' }
    if ($all -match '登录成功|认证成功|上线成功|注销成功') { return 'success' }
    if ($all -match 'Query\.html|switch\.php\?p=status') { return 'success' }
    return 'unknown'
}

# ---------------------------------------------------------------------------
# 无头 Edge + CDP 兜底登录
# ---------------------------------------------------------------------------
function Get-EdgePath {
    $candidates = @()
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($pf86) { $candidates += (Join-Path $pf86 'Microsoft\Edge\Application\msedge.exe') }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe') }

    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    try {
        $p = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction Stop).'(default)'
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    } catch { }
    return $null
}

function Test-PortOpen {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $Port)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Get-FreePort {
    foreach ($p in 9333..9345) {
        if (-not (Test-PortOpen $p)) { return $p }
    }
    return 9333
}

function Receive-CdpMessage {
    $buf = New-Object byte[] 65536
    $ms = New-Object System.IO.MemoryStream
    do {
        $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $buf)
        $recvTask = $script:CdpWs.ReceiveAsync($seg, [Threading.CancellationToken]::None)
        if (-not $recvTask.Wait(3000)) {
            $ms.Dispose()
            throw 'CDP 接收超时'
        }
        $res = $recvTask.Result
        if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            $ms.Dispose()
            throw 'CDP WebSocket 已关闭'
        }
        $ms.Write($buf, 0, $res.Count)
    } while (-not $res.EndOfMessage)

    $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
    $ms.Dispose()
    return $text
}

function Send-CdpRaw {
    param([string]$Method, [hashtable]$Params = @{})
    if (-not $script:CdpWs -or $script:CdpWs.State -ne [System.Net.WebSockets.WebSocketState]::Open) { return }
    $script:CdpId++
    $json = @{ id = $script:CdpId; method = $Method; params = $Params } | ConvertTo-Json -Compress -Depth 20
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $bytes)
    try {
        $script:CdpWs.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait(3000) | Out-Null
    } catch { }
}

function Send-CdpCommand {
    param([string]$Method, [hashtable]$Params = @{})

    if (-not $script:CdpWs -or $script:CdpWs.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        throw 'CDP WebSocket 未连接'
    }

    $script:CdpId++
    $id = $script:CdpId
    $json = @{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Compress -Depth 20
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $bytes)
    $script:CdpWs.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $raw = Receive-CdpMessage
        try { $obj = $raw | ConvertFrom-Json } catch { continue }

        # 页面弹窗（alert）会阻塞渲染；自动点掉，避免后续读取页面失败
        if ($obj.method -eq 'Page.javascriptDialogOpening') {
            Send-CdpRaw -Method 'Page.handleJavaScriptDialog' -Params @{ accept = $true }
            continue
        }
        if ($obj.id -eq $id) { return $obj }
    }
    throw "CDP 命令超时: $Method"
}

function Eval-CdpJs {
    param([string]$Expression, [bool]$AwaitPromise = $false)
    $r = Send-CdpCommand -Method 'Runtime.evaluate' -Params @{
        expression    = $Expression
        returnByValue = $true
        awaitPromise  = $AwaitPromise
    }
    if ($r.error) { throw "CDP 错误: $($r.error.message)" }
    if ($r.result.exceptionDetails) {
        $msg = $r.result.exceptionDetails.text
        if ($r.result.exceptionDetails.exception -and $r.result.exceptionDetails.exception.description) {
            $msg = $r.result.exceptionDetails.exception.description
        }
        return [pscustomobject]@{ __error = $msg }
    }
    if ($r.result.result -and ($r.result.result.PSObject.Properties.Name -contains 'value')) {
        return $r.result.result.value
    }
    return $null
}

function Get-CdpPageState {
    for ($i = 0; $i -lt 10; $i++) {
        try {
            $v = Eval-CdpJs '({href: location.href, text: (document.body ? document.body.innerText : "").slice(0,1500)})' $false
            if ($v -and $v.href) {
                return [pscustomobject]@{ Href = [string]$v.href; Text = [string]$v.text }
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    return [pscustomobject]@{ Href = ''; Text = '' }
}

function Get-BrowserPageUrl {
    param([int]$Port)
    try {
        $r = Invoke-HttpRequest -Url "http://127.0.0.1:$Port/json/list" -TimeoutSec 2
        $list = $r.Body | ConvertFrom-Json
        $t = $list | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
        if ($t -and $t.url) { return [string]$t.url }
    } catch { }
    return ''
}

function Close-Browser {
    param($Process)
    try { $null = Send-CdpCommand -Method 'Browser.close' } catch { }
    try { if ($script:CdpWs) { $script:CdpWs.Dispose() } } catch { }
    $script:CdpWs = $null
    Start-Sleep -Milliseconds 500

    if ($Process -and -not $Process.HasExited) {
        try { & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $Process.Id /T /F 2>$null | Out-Null } catch { }
    }
    try {
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($script:EdgeProfile) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }

    # 门户页面会把密码写进 cookie；删除专用 Edge 配置，避免密码在磁盘上多留一份
    try {
        Start-Sleep -Milliseconds 300
        if (Test-Path -LiteralPath $script:EdgeProfile) {
            Remove-Item -LiteralPath $script:EdgeProfile -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Invoke-BrowserLogin {
    param($Config, [string]$Password, [string]$StartUrl, [string]$SwitchUrl)

    $edge = Get-EdgePath
    if (-not $edge) { throw '找不到 Microsoft Edge，无法使用浏览器兜底。' }

    # 清理上次可能残留的、使用本脚本专用配置目录的 Edge 进程
    try {
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($script:EdgeProfile) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }

    if ([string]::IsNullOrWhiteSpace($StartUrl)) {
        $StartUrl = $SwitchUrl
    }

    if (-not (Test-Path -LiteralPath $script:EdgeProfile)) {
        New-Item -ItemType Directory -Force -Path $script:EdgeProfile | Out-Null
    }

    $port = Get-FreePort
    $argLine = ('--headless=new --disable-gpu --remote-debugging-port={0} --remote-allow-origins=* ' +
                '--user-data-dir="{1}" --no-first-run --no-default-browser-check --disable-extensions ' +
                '--disable-background-networking --disable-sync --no-pings --user-agent="{2}" "{3}"') -f `
                $port, $script:EdgeProfile, $script:UserAgent, $StartUrl

    Write-Log "启动无头 Edge: port=$port start=$StartUrl"
    $proc = Start-Process -FilePath $edge -ArgumentList $argLine -PassThru -WindowStyle Hidden

    $target = $null
    for ($i = 0; $i -lt 40; $i++) {
        try {
            $r = Invoke-HttpRequest -Url "http://127.0.0.1:$port/json/list" -TimeoutSec 2
            $list = $r.Body | ConvertFrom-Json
            $target = $list | Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl } | Select-Object -First 1
            if ($target) { break }
        } catch { }
        Start-Sleep -Milliseconds 500
    }

    if (-not $target) {
        Close-Browser $proc
        throw '无头 Edge 启动失败（未获取到调试目标）。'
    }

    $script:CdpWs = New-Object System.Net.WebSockets.ClientWebSocket
    $script:CdpId = 0
    try {
        $connectTask = $script:CdpWs.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None)
        if (-not $connectTask.Wait(5000)) {
            throw '连接无头 Edge 调试端口超时。'
        }
    } catch {
        Close-Browser $proc
        throw
    }

    try {
        $null = Send-CdpCommand -Method 'Runtime.enable'
        $null = Send-CdpCommand -Method 'Page.enable'

        # 登录失败时页面会 alert，弹窗会阻塞页面脚本；预先禁用 alert/confirm
        $null = Send-CdpCommand -Method 'Page.addScriptToEvaluateOnNewDocument' -Params @{
            source = 'window.alert=function(){}; window.confirm=function(){return true;}; window.prompt=function(){return null;};'
        }

        # 等待登录表单出现
        $formReady = $false
        for ($i = 0; $i -lt 40; $i++) {
            $v = $null
            try { $v = Eval-CdpJs '!!(document.form1 && document.form1.username && document.form1.password)' $false } catch { }
            if ($v -eq $true) { $formReady = $true; break }
            Start-Sleep -Milliseconds 500
        }

        $state = Get-CdpPageState

        # 起始页没有表单（例如当前已在线，外网地址没有跳转到门户），直接打开 switch.php
        if (-not $formReady -and $SwitchUrl -and $SwitchUrl -ne $StartUrl) {
            Write-Log "起始页未出现登录表单（href=$($state.Href)），改为直接打开认证地址" 'WARN'
            try { $null = Send-CdpCommand -Method 'Page.navigate' -Params @{ url = $SwitchUrl } } catch { }
            for ($i = 0; $i -lt 40; $i++) {
                $v = $null
                try { $v = Eval-CdpJs '!!(document.form1 && document.form1.username && document.form1.password)' $false } catch { }
                if ($v -eq $true) { $formReady = $true; break }
                Start-Sleep -Milliseconds 500
            }
            $state = Get-CdpPageState
        }

        if (-not $formReady) {
            Write-Log "未找到登录表单，页面 href=$($state.Href) text=$(Get-Snippet $state.Text 300)" 'WARN'
            return [pscustomobject]@{ Submitted = $false; Href = $state.Href; Text = $state.Text; PortalError = (Decode-PortalError $state.Href) }
        }

        $userJson = ConvertTo-Json -InputObject ([string]$Config.username) -Compress
        $passJson = ConvertTo-Json -InputObject ([string]$Password) -Compress
        $expr = @"
(function(){
  var f = document.form1;
  if (!f) return {ok:false, reason:'no form'};
  f.username.value = $userJson;
  f.password.value = $passJson;
  if (f.savePWD) f.savePWD.checked = true;
  f.submit();
  return {ok:true, href: location.href};
})()
"@

        $submit = $null
        try { $submit = Eval-CdpJs $expr $false } catch { Write-Log "提交表单失败: $($_.Exception.Message)" 'WARN' }
        Start-Sleep -Seconds 6

        $after = Get-CdpPageState
        if (-not $after.Href) {
            $pageUrl = Get-BrowserPageUrl $port
            if ($pageUrl) { $after.Href = $pageUrl }
        }
        Write-Log "浏览器登录后: href=$($after.Href) text=$(Get-Snippet $after.Text 300)"

        return [pscustomobject]@{
            Submitted   = [bool]($submit -and $submit.ok)
            Href        = $after.Href
            Text        = $after.Text
            PortalError = (Decode-PortalError $after.Href)
        }
    } finally {
        Close-Browser $proc
    }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
Initialize-Log

$mutex = New-Object System.Threading.Mutex($false, 'Local\CampusAutoLogin_Mutex')
$hasMutex = $false
try {
    $hasMutex = $mutex.WaitOne(0)
} catch { }

if (-not $hasMutex) {
    Write-Log '已有另一个自动登录实例在运行，本次跳过。'
    return
}

try {
    $pause = Get-Pause
    if ($pause) {
        Write-Log "处于暂停状态（原因: $($pause.reason)，恢复时间: $($pause.until)），本次跳过。" 'WARN'
        return
    }

    $cfg = Get-Config
    $password = Unprotect-Password $cfg

    $ip = Get-PrimaryIPv4
    $online = Test-IPv4Online
    $startedOnline = $online
    Write-Log "开始检查: ip=$ip online=$online user=$($cfg.username)"

    # 上次登录成功后 UU远程 重启失败时，在线状态下继续重试
    if (-not $Diagnose -and $online -and (Get-UURestartPending)) {
        Write-Log '检测到待处理的 UU远程 重启任务，正在重试...'
        if (Restart-UURemote $cfg) { Clear-UURestartPending }
    }

    if ($Diagnose) {
        Write-Log "诊断模式: config=$script:ConfigPath"
        $cookies = New-Object System.Net.CookieContainer
        $disc = Get-PortalDiscovery -Config $cfg -Cookies $cookies
        Write-Log "门户地址: $($disc.SwitchUrl) discovered=$($disc.Discovered)"

        try {
            $http = Invoke-HttpLogin -Config $cfg -Password $password -SwitchUrl $disc.SwitchUrl -Cookies $cookies
            $outcome = Get-PortalOutcome -Body $http.Body -PortalError $http.PortalError -Location $http.PostLocation
            Write-Log "HTTP 登录返回: status=$($http.StatusCode) outcome=$outcome error=$($http.PortalError) body=$(Get-Snippet $http.Body 500)"
        } catch {
            Write-Log "HTTP 登录异常: $($_.Exception.Message)" 'ERROR'
        }

        if (-not $NoBrowser) {
            try {
                $br = Invoke-BrowserLogin -Config $cfg -Password $password -StartUrl $disc.SwitchUrl -SwitchUrl $disc.SwitchUrl
                Write-Log "浏览器登录返回: submitted=$($br.Submitted) href=$($br.Href) error=$($br.PortalError) text=$(Get-Snippet $br.Text 500)"
            } catch {
                Write-Log "浏览器登录异常: $($_.Exception.Message)" 'ERROR'
            }
        }
        Write-Log '诊断结束。'
        return
    }

    if ($online -and -not $Force) {
        Clear-RetryState
        Write-Log '网络已在线，无需登录。'
        return
    }

    # 最多 3 轮；3 轮失败后停止，不再向门户提交
    if (-not $Force) {
        $state = Get-RetryState
        if ($state -and $state.stopped) {
            # 跨天自动重置：新的一天重新获得 3 轮机会
            $needReset = $false
            try {
                $lastFail = [datetime]$state.lastFailureAt
                if ($lastFail.Date -lt (Get-Date).Date) { $needReset = $true }
            } catch { $needReset = $true }
            if ($needReset) {
                Clear-RetryState
                Write-Log '停止状态来自前一天，已自动重置 3 轮重试机会。'
                $state = $null
            } else {
                return
            }
        }
        if ($state -and $state.nextAttempt) {
            try {
                if ([datetime]$state.nextAttempt -gt (Get-Date)) {
                    Write-Log "等待重试：第 $($state.rounds)/3 轮失败，下一次尝试 $($state.nextAttempt)"
                    return
                }
            } catch { }
        }

        $round = Register-LoginRound
        if ($round -eq 0) {
            Write-Log '已达到最大 3 轮登录尝试，停止自动登录，不再向门户提交。删除 retry-state.json 或重新运行 setup.cmd 可重置。' 'ERROR'
            return
        }
        Write-Log "开始第 $round/3 轮登录"
    } else {
        Write-Log '手动 -Force 模式：跳过 3 轮限制。'
    }

    $cookies = New-Object System.Net.CookieContainer
    $disc = Get-PortalDiscovery -Config $cfg -Cookies $cookies
    Write-Log "认证地址: $($disc.SwitchUrl) discovered=$($disc.Discovered)"

    $success = $false

    try {
        $http = Invoke-HttpLogin -Config $cfg -Password $password -SwitchUrl $disc.SwitchUrl -Cookies $cookies
        $outcome = Get-PortalOutcome -Body $http.Body -PortalError $http.PortalError -Location $http.PostLocation
        Write-Log "HTTP 登录: status=$($http.StatusCode) outcome=$outcome error=$($http.PortalError) body=$(Get-Snippet $http.Body 300)"

        if ($outcome -eq 'bad_credentials') {
            Clear-RetryState
            Set-Pause -Hours 6 -Reason '账号或密码错误'
            Write-Log '门户提示账号或密码错误，已暂停 6 小时以避免账号被锁。请检查配置或重新运行 setup.ps1。' 'ERROR'
            return
        }
        if ($outcome -eq 'account_disabled' -or $outcome -eq 'no_balance') {
            Clear-RetryState
            Set-Pause -Hours 6 -Reason '账号状态异常（停用/欠费）'
            Write-Log '门户提示账号状态异常（停用或欠费），已暂停 6 小时。请联系网络中心处理。' 'ERROR'
            return
        }
    } catch {
        Write-Log "HTTP 登录失败: $($_.Exception.Message)" 'WARN'
    }

    Start-Sleep -Seconds 8
    if (Test-IPv4Online) { $success = $true }

    if (-not $success -and -not $NoBrowser) {
        try {
            $br = Invoke-BrowserLogin -Config $cfg -Password $password -StartUrl $disc.SwitchUrl -SwitchUrl $disc.SwitchUrl
            $outcome2 = Get-PortalOutcome -Body $br.Text -PortalError $br.PortalError -Location $br.Href
            Write-Log "浏览器登录: submitted=$($br.Submitted) outcome=$outcome2 error=$($br.PortalError)"

            if ($outcome2 -eq 'bad_credentials') {
                Clear-RetryState
                Set-Pause -Hours 6 -Reason '账号或密码错误'
                Write-Log '门户提示账号或密码错误，已暂停 6 小时以避免账号被锁。请检查配置或重新运行 setup.ps1。' 'ERROR'
                return
            }
            if ($outcome2 -eq 'account_disabled' -or $outcome2 -eq 'no_balance') {
                Clear-RetryState
                Set-Pause -Hours 6 -Reason '账号状态异常（停用/欠费）'
                Write-Log '门户提示账号状态异常（停用或欠费），已暂停 6 小时。请联系网络中心处理。' 'ERROR'
                return
            }
        } catch {
            Write-Log "浏览器登录失败: $($_.Exception.Message)" 'WARN'
        }

        Start-Sleep -Seconds 4
        if (Test-IPv4Online) { $success = $true }
    }

    if ($success) {
        Clear-RetryState
        Write-Log '网络已恢复，自动登录成功。'

        # 校园网重新认证后 UU远程 常显示“无法连接网络”，重启客户端恢复远控
        if (-not ($Force -and $startedOnline)) {
            Start-Sleep -Seconds 5
            if (Restart-UURemote $cfg) {
                Clear-UURestartPending
            } else {
                Set-UURestartPending
                Write-Log 'UU远程 本次重启失败，已记录，后续每分钟继续重试。' 'WARN'
            }
        }
    } else {
        $state = Set-RetryFailure
        if ($state.stopped) {
            Write-Log "第 $($state.rounds)/3 轮登录失败，已达到最大 3 轮，停止自动登录，不再尝试。请手动处理，或删除 retry-state.json 后重新运行 setup.cmd 重置。" 'ERROR'
        } else {
            Write-Log "第 $($state.rounds)/3 轮登录失败，网络仍未恢复。下一次尝试 $($state.nextAttempt)。请查看日志或手动打开认证页面。" 'ERROR'
        }
        exit 1
    }
} catch {
    if (-not $Diagnose -and -not $Force -and -not $success) {
        try { $null = Set-RetryFailure } catch { }
    }
    Write-Log "脚本异常: $($_.Exception.Message)" 'ERROR'
    if (-not $Scheduled) {
        Write-Host "错误: $($_.Exception.Message)" -ForegroundColor Red
    }
    exit 1
} finally {
    try {
        if ($hasMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    } catch { }
}