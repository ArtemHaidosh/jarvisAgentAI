# Package checks.
#   tests\run-tests.ps1          static checks (Docker does not need to be running)
#   tests\run-tests.ps1 -Smoke   plus live-system checks (after scripts\start.ps1)
param([switch]$Smoke)

. "$PSScriptRoot\..\scripts\lib\common.ps1"

$script:passed = 0; $script:failed = 0; $script:skipped = 0

function Check([string]$Name, [scriptblock]$Body) {
    try {
        $note = & $Body
        Write-Host "  [OK]   $Name" -ForegroundColor Green
        if ($note) { Write-Host "         $note" -ForegroundColor DarkGray }
        $script:passed++
    } catch {
        $msg = $_.Exception.Message
        if ($msg -like 'SKIP:*') {
            Write-Host "  [SKIP] $Name - $($msg.Substring(5))" -ForegroundColor Yellow
            $script:skipped++
        } else {
            Write-Host "  [FAIL] $Name - $msg" -ForegroundColor Red
            $script:failed++
        }
    }
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Skip([string]$Reason) { throw "SKIP:$Reason" }

# Files that would go into git (tracked + untracked, excluding ignored).
function Get-RepoFiles {
    Push-Location $RepoRoot
    try {
        $files = & git ls-files --cached --others --exclude-standard 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'git is unavailable or this is not a git repository' }
        return $files | Sort-Object -Unique | ForEach-Object { Join-Path $RepoRoot $_ } | Where-Object { Test-Path -LiteralPath $_ }
    } finally { Pop-Location }
}

$secretKeys = 'TELEGRAM_BOT_TOKEN', 'NGROK_AUTHTOKEN', 'N8N_ENCRYPTION_KEY', 'POSTGRES_PASSWORD'
# Not secrets, but personal: must not appear in a public repo either
$privateKeys = $secretKeys + 'TELEGRAM_OWNER_ID', 'NGROK_DOMAIN'

Write-Step 'Static checks'

Check 'All package files are present' {
    $required = 'docker-compose.yml', '.env.example', '.gitignore', 'config\ngrok-policy.yml', 'README.md',
                'docs\troubleshooting.md', 'scripts\setup.ps1', 'scripts\start.ps1', 'scripts\stop.ps1',
                'scripts\status.ps1', 'scripts\lib\common.ps1', 'scripts\export-workflows.ps1',
                'scripts\import-workflows.ps1', 'scripts\lib\sanitize-workflows.js'
    $missing = $required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_)) }
    Assert ($missing.Count -eq 0) "missing: $($missing -join ', ')"
}

Check '.env is ignored by git' {
    Push-Location $RepoRoot
    try { & git check-ignore -q .env 2>$null; $code = $LASTEXITCODE } finally { Pop-Location }
    Assert ($code -eq 0) '.env is not covered by .gitignore'
}

Check '.env.example declares every variable used in docker-compose.yml' {
    $used = [regex]::Matches((Get-Content -Raw $ComposeFile), '\$\{([A-Z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $declared = (Read-DotEnv $EnvExamplePath).Keys
    $missing = $used | Where-Object { $declared -notcontains $_ }
    Assert ($missing.Count -eq 0) "not declared: $($missing -join ', ')"
}

Check '.env.example contains no secrets' {
    $example = Read-DotEnv $EnvExamplePath
    $filled = $privateKeys | Where-Object { $example[$_] }
    Assert ($filled.Count -eq 0) "filled-in values: $($filled -join ', ')"
}

Check 'docker-compose.yml is valid' {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Skip 'docker is not installed' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "jarvis-test-$PID.env"
    $dummy = "TELEGRAM_BOT_TOKEN=123456789:test`nNGROK_AUTHTOKEN=test`nNGROK_DOMAIN=example.ngrok-free.app`nN8N_ENCRYPTION_KEY=test`nPOSTGRES_PASSWORD=test`nTELEGRAM_OWNER_ID=1`n"
    [IO.File]::WriteAllText($tmp, $dummy)
    try {
        $json = & docker compose -f $ComposeFile --env-file $tmp config --format json 2>&1
        Assert ($LASTEXITCODE -eq 0) "docker compose config: $json"
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    $config = ($json -join "`n") | ConvertFrom-Json
    $public = foreach ($svc in $config.services.PSObject.Properties) {
        foreach ($p in @($svc.Value.ports)) { if ($p -and $p.host_ip -ne '127.0.0.1') { "$($svc.Name):$($p.published)" } }
    }
    Assert (@($public).Count -eq 0) "ports exposed beyond localhost: $($public -join ', ')"
    'ports are bound to 127.0.0.1 only'
}

Check 'PowerShell scripts have no syntax errors' {
    $bad = foreach ($f in Get-ChildItem -Path $RepoRoot -Filter *.ps1 -Recurse) {
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
        if ($errors) { "$($f.Name): $($errors[0].Message)" }
    }
    Assert (@($bad).Count -eq 0) ($bad -join '; ')
}

Check 'Non-ASCII PowerShell scripts are saved as UTF-8 with BOM (PowerShell 5.1 needs it)' {
    $bad = Get-ChildItem -Path $RepoRoot -Filter *.ps1 -Recurse | Where-Object {
        $b = [IO.File]::ReadAllBytes($_.FullName)
        $hasBom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
        $nonAscii = @($b | Where-Object { $_ -gt 0x7F }).Count -gt 0
        $nonAscii -and -not $hasBom
    } | ForEach-Object { $_.Name }
    Assert (@($bad).Count -eq 0) "non-ASCII without BOM: $($bad -join ', ')"
}

Check 'No secrets in files that go into git' {
    $files = Get-RepoFiles
    $local = Read-DotEnv
    $leaks = foreach ($f in $files) {
        $text = [IO.File]::ReadAllText($f)
        if ($text -match '\b\d{8,10}:[A-Za-z0-9_-]{35}\b') { "$f (looks like a Telegram token)" }
        if ($text -match 'sk-ant-[A-Za-z0-9_-]{20,}') { "$f (looks like an Anthropic API key)" }
        foreach ($k in $privateKeys) {
            $v = $local[$k]
            if ($v -and $v.Length -ge 5 -and $text.Contains($v)) { "$f (contains $k from .env)" }
        }
    }
    Assert (@($leaks).Count -eq 0) ($leaks -join '; ')
    "files checked: $(@($files).Count)"
}

Check 'Exported workflows hold no personal or runtime data' {
    $files = @(Get-ChildItem -Path (Join-Path $RepoRoot 'workflows') -Filter *.json -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Skip 'no workflows exported yet (scripts\export-workflows.ps1)' }
    $allowed = 'id', 'name', 'nodes', 'connections', 'settings'
    $bad = foreach ($f in $files) {
        $wf = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
        $extra = $wf.PSObject.Properties.Name | Where-Object { $allowed -notcontains $_ }
        if ($extra) { "$($f.Name): $($extra -join ', ')" }
    }
    Assert (@($bad).Count -eq 0) "unexpected fields (re-export with scripts\export-workflows.ps1): $($bad -join '; ')"
    "workflows checked: $($files.Count)"
}

if ($Smoke) {
    Write-Step 'Live-system checks'
    $cfg = Get-Config
    $domain = $cfg['NGROK_DOMAIN']
    # ngrok free shows browsers an interstitial warning page; this header skips it
    $ngrokHeaders = @{ 'ngrok-skip-browser-warning' = '1' }

    Check 'n8n responds locally' {
        Assert (Test-N8nHealthy) "$N8nLocalUrl/healthz is not responding"
    }

    Check 'Postgres accepts connections' {
        Assert (Test-PostgresReady) 'pg_isready failed (docker compose logs postgres)'
    }

    Check 'ngrok tunnel is up on your domain' {
        $url = Get-TunnelUrl
        Assert ([bool]$url) 'no tunnel found (http://localhost:4040)'
        Assert ($url -eq "https://$domain") "got $url instead of https://$domain"
    }

    Check 'n8n editor is not reachable from the internet' {
        $r = Invoke-Http "https://$domain/healthz" -Headers $ngrokHeaders
        Assert ($r.Status -eq 404 -and $r.Body -notmatch 'ok') "expected a 404 from ngrok, got $($r.Status)"
    }

    Check 'Webhook path reaches n8n through the tunnel' {
        $r = Invoke-Http "https://$domain/webhook/jarvis-smoke-test" -Headers $ngrokHeaders
        Assert ($r.Body -match 'webhook') "response is not from n8n: $($r.Status) $($r.Body)"
    }

    Check 'Bot token is valid' {
        $me = Invoke-Telegram $cfg['TELEGRAM_BOT_TOKEN'] 'getMe'
        Assert ([bool]$me.ok) $me.description
        "@$($me.result.username)"
    }

    Check 'Telegram delivers the webhook to your domain' {
        $info = Invoke-Telegram $cfg['TELEGRAM_BOT_TOKEN'] 'getWebhookInfo'
        Assert ([bool]$info.ok) $info.description
        $wh = $info.result
        if (-not $wh.url) { Skip 'webhook not set yet: activate a workflow with a Telegram Trigger' }
        Assert ($wh.url -like "https://$domain/webhook*") "webhook points to $($wh.url)"
        Assert (-not $wh.last_error_message) "last delivery error: $($wh.last_error_message)"
        $wh.url
    }
}

Write-Host ''
$color = if ($failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "Passed: $passed  Failed: $failed  Skipped: $skipped" -ForegroundColor $color
exit ([int]($failed -gt 0))
