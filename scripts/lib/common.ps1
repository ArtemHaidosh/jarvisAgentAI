# Shared helpers for the scripts. Load with: . "$PSScriptRoot\lib\common.ps1"
# Works with Windows PowerShell 5.1 and PowerShell 7.

$script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:EnvPath = Join-Path $RepoRoot '.env'
$script:EnvExamplePath = Join-Path $RepoRoot '.env.example'
$script:ComposeFile = Join-Path $RepoRoot 'docker-compose.yml'
$script:N8nLocalUrl = 'http://localhost:5678'
$script:NgrokApiUrl = 'http://localhost:4040/api/tunnels'

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  [!]  $Text" -ForegroundColor Yellow }
function Write-Fail([string]$Text) { Write-Host "  [X]  $Text" -ForegroundColor Red }

# --- .env -------------------------------------------------------------------

function Read-DotEnv([string]$Path = $EnvPath) {
    $vars = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $vars }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $vars[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    return $vars
}

# Sets (or appends) a single KEY=value line, keeping comments. Writes UTF-8 without BOM,
# which is what docker compose expects for .env.
function Set-DotEnvValue([string]$Key, [string]$Value, [string]$Path = $EnvPath) {
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") {
            $lines[$i] = "$Key=$Value"
            $found = $true
        }
    }
    if (-not $found) { $lines += "$Key=$Value" }
    [IO.File]::WriteAllLines($Path, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
}

function New-EncryptionKey {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function ConvertTo-NgrokDomain([string]$Value) {
    return $Value.Trim() -replace '^https?://', '' -replace '/+$', ''
}

# Returns a list of config problems (empty when everything is fine).
function Test-Config($Cfg) {
    $problems = @()
    if ($Cfg['TELEGRAM_BOT_TOKEN'] -notmatch '^\d+:[A-Za-z0-9_-]{30,}$') {
        $problems += 'TELEGRAM_BOT_TOKEN is empty or malformed (expected 123456789:AA...)'
    }
    if ([string]::IsNullOrWhiteSpace($Cfg['NGROK_AUTHTOKEN']) -or $Cfg['NGROK_AUTHTOKEN'] -match '\s') {
        $problems += 'NGROK_AUTHTOKEN is empty or contains spaces'
    }
    if ($Cfg['NGROK_DOMAIN'] -notmatch '^[a-z0-9-]+(\.[a-z0-9-]+)+$') {
        $problems += 'NGROK_DOMAIN is empty or invalid (expected something like my-name.ngrok-free.app)'
    }
    if ($Cfg['N8N_ENCRYPTION_KEY'] -notmatch '^\S{16,}$') {
        $problems += 'N8N_ENCRYPTION_KEY is empty (scripts\setup.ps1 generates it)'
    }
    return ,$problems
}

# Reads .env and stops the script with a clear message if anything is missing.
function Get-Config {
    if (-not (Test-Path -LiteralPath $EnvPath)) {
        Write-Fail '.env not found. Run scripts\setup.ps1 first.'
        exit 1
    }
    $cfg = Read-DotEnv
    $problems = Test-Config $cfg
    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { Write-Fail $p }
        Write-Host '  Fix .env by hand or run scripts\setup.ps1 again.'
        exit 1
    }
    return $cfg
}

# --- Docker -------------------------------------------------------------------

function Assert-DockerReady {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Fail 'Docker is not installed. Install Docker Desktop: https://www.docker.com/products/docker-desktop/'
        exit 1
    }
    $null = & docker info --format '{{.ServerVersion}}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'Docker is installed but not running. Open Docker Desktop and wait for "Engine running".'
        exit 1
    }
}

function Invoke-Compose {
    & docker compose -f $ComposeFile @args
}

# --- HTTP -------------------------------------------------------------------

# HTTP request that does not throw on 4xx/5xx: returns Status and Body.
function Invoke-Http([string]$Uri, [hashtable]$Headers = @{}, [int]$TimeoutSec = 10) {
    $params = @{ Uri = $Uri; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = $TimeoutSec }
    if ($PSVersionTable.PSVersion.Major -ge 7) { $params['SkipHttpErrorCheck'] = $true }
    try {
        $r = Invoke-WebRequest @params
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = [string]$r.Content }
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { return [pscustomobject]@{ Status = 0; Body = $_.Exception.Message } }
        $reader = New-Object IO.StreamReader($resp.GetResponseStream())
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $reader.ReadToEnd() }
    } catch {
        return [pscustomobject]@{ Status = 0; Body = $_.Exception.Message }
    }
}

function Test-N8nHealthy {
    return (Invoke-Http "$N8nLocalUrl/healthz" -TimeoutSec 3).Status -eq 200
}

# Public https URL of the tunnel, or $null if ngrok is not up yet.
function Get-TunnelUrl {
    try {
        $data = Invoke-RestMethod -Uri $NgrokApiUrl -TimeoutSec 3
        $t = $data.tunnels | Where-Object { $_.public_url -like 'https://*' } | Select-Object -First 1
        if ($t) { return $t.public_url }
    } catch { }
    return $null
}

function Wait-Until([string]$What, [scriptblock]$Condition, [int]$TimeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Seconds 2
    }
    Write-Fail "$What did not respond within $TimeoutSec s"
    return $false
}

# --- Telegram ---------------------------------------------------------------

# Calls a Bot API method. The token never ends up in the output.
function Invoke-Telegram([string]$Token, [string]$Method) {
    try {
        return Invoke-RestMethod -Uri "https://api.telegram.org/bot$Token/$Method" -TimeoutSec 10
    } catch {
        $msg = $_.Exception.Message
        if ($Token) { $msg = $msg.Replace($Token, '***') }
        return [pscustomobject]@{ ok = $false; description = $msg }
    }
}
