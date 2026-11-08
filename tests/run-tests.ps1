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
        if ($LASTEXITCODE -ne 0) { throw 'git недоступний або це не git-репозиторій' }
        return $files | Sort-Object -Unique | ForEach-Object { Join-Path $RepoRoot $_ } | Where-Object { Test-Path -LiteralPath $_ }
    } finally { Pop-Location }
}

$secretKeys = 'TELEGRAM_BOT_TOKEN', 'NGROK_AUTHTOKEN', 'N8N_ENCRYPTION_KEY'

Write-Step 'Статичні перевірки'

Check 'Усі файли пакета на місці' {
    $required = 'docker-compose.yml', '.env.example', '.gitignore', 'config\ngrok-policy.yml', 'README.md',
                'docs\troubleshooting.md', 'scripts\setup.ps1', 'scripts\start.ps1', 'scripts\stop.ps1',
                'scripts\status.ps1', 'scripts\lib\common.ps1'
    $missing = $required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_)) }
    Assert ($missing.Count -eq 0) "бракує: $($missing -join ', ')"
}

Check '.env ігнорується git' {
    Push-Location $RepoRoot
    try { & git check-ignore -q .env 2>$null; $code = $LASTEXITCODE } finally { Pop-Location }
    Assert ($code -eq 0) '.env не потрапляє під .gitignore'
}

Check '.env.example описує всі змінні з docker-compose.yml' {
    $used = [regex]::Matches((Get-Content -Raw $ComposeFile), '\$\{([A-Z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $declared = (Read-DotEnv $EnvExamplePath).Keys
    $missing = $used | Where-Object { $declared -notcontains $_ }
    Assert ($missing.Count -eq 0) "не описані: $($missing -join ', ')"
}

Check '.env.example не містить секретів' {
    $example = Read-DotEnv $EnvExamplePath
    $filled = $secretKeys | Where-Object { $example[$_] }
    Assert ($filled.Count -eq 0) "заповнені значення: $($filled -join ', ')"
}

Check 'docker-compose.yml валідний' {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Skip 'docker не встановлено' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "jarvis-test-$PID.env"
    $dummy = "TELEGRAM_BOT_TOKEN=123456789:test`nNGROK_AUTHTOKEN=test`nNGROK_DOMAIN=example.ngrok-free.app`nN8N_ENCRYPTION_KEY=test`n"
    [IO.File]::WriteAllText($tmp, $dummy)
    try {
        $json = & docker compose -f $ComposeFile --env-file $tmp config --format json 2>&1
        Assert ($LASTEXITCODE -eq 0) "docker compose config: $json"
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    $config = ($json -join "`n") | ConvertFrom-Json
    $public = foreach ($svc in $config.services.PSObject.Properties) {
        foreach ($p in @($svc.Value.ports)) { if ($p -and $p.host_ip -ne '127.0.0.1') { "$($svc.Name):$($p.published)" } }
    }
    Assert (@($public).Count -eq 0) "порти відкриті не лише для localhost: $($public -join ', ')"
    'порти прив''язані лише до 127.0.0.1'
}

Check 'PowerShell-скрипти без синтаксичних помилок' {
    $bad = foreach ($f in Get-ChildItem -Path $RepoRoot -Filter *.ps1 -Recurse) {
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
        if ($errors) { "$($f.Name): $($errors[0].Message)" }
    }
    Assert (@($bad).Count -eq 0) ($bad -join '; ')
}

Check 'PowerShell-скрипти збережені в UTF-8 з BOM (інакше PowerShell 5.1 ламає кирилицю)' {
    $bad = Get-ChildItem -Path $RepoRoot -Filter *.ps1 -Recurse | Where-Object {
        $b = [IO.File]::ReadAllBytes($_.FullName)
        -not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    } | ForEach-Object { $_.Name }
    Assert (@($bad).Count -eq 0) "без BOM: $($bad -join ', ')"
}

Check 'У файлах для git немає секретів' {
    $files = Get-RepoFiles
    $local = Read-DotEnv
    $values = $secretKeys | ForEach-Object { $local[$_] } | Where-Object { $_ -and $_.Length -ge 8 }
    $leaks = foreach ($f in $files) {
        $text = [IO.File]::ReadAllText($f)
        if ($text -match '\b\d{8,10}:[A-Za-z0-9_-]{35}\b') { "$f (схоже на токен Telegram)" }
        foreach ($v in $values) { if ($text.Contains($v)) { "$f (значення з .env)" } }
    }
    Assert (@($leaks).Count -eq 0) ($leaks -join '; ')
    "перевірено файлів: $(@($files).Count)"
}

if ($Smoke) {
    Write-Step 'Перевірки живої системи'
    $cfg = Get-Config
    $domain = $cfg['NGROK_DOMAIN']
    # ngrok free shows browsers an interstitial warning page; this header skips it
    $ngrokHeaders = @{ 'ngrok-skip-browser-warning' = '1' }

    Check 'n8n відповідає локально' {
        Assert (Test-N8nHealthy) "$N8nLocalUrl/healthz не відповідає"
    }

    Check 'ngrok tunnel активний на вашому домені' {
        $url = Get-TunnelUrl
        Assert ([bool]$url) 'tunnel не знайдено (http://localhost:4040)'
        Assert ($url -eq "https://$domain") "адреса $url замість https://$domain"
    }

    Check 'Редактор n8n закритий з інтернету' {
        $r = Invoke-Http "https://$domain/healthz" -Headers $ngrokHeaders
        Assert ($r.Status -eq 404 -and $r.Body -notmatch 'ok') "очікувався 404 від ngrok, отримано $($r.Status)"
    }

    Check 'Webhook-шлях доходить до n8n через tunnel' {
        $r = Invoke-Http "https://$domain/webhook/jarvis-smoke-test" -Headers $ngrokHeaders
        Assert ($r.Body -match 'webhook') "відповідь не від n8n: $($r.Status) $($r.Body)"
    }

    Check 'Токен бота дійсний' {
        $me = Invoke-Telegram $cfg['TELEGRAM_BOT_TOKEN'] 'getMe'
        Assert ([bool]$me.ok) $me.description
        "@$($me.result.username)"
    }

    Check 'Telegram надсилає webhook на ваш домен' {
        $info = Invoke-Telegram $cfg['TELEGRAM_BOT_TOKEN'] 'getWebhookInfo'
        Assert ([bool]$info.ok) $info.description
        $wh = $info.result
        if (-not $wh.url) { Skip 'webhook ще не встановлено: активуйте workflow з Telegram Trigger' }
        Assert ($wh.url -like "https://$domain/webhook*") "webhook вказує на $($wh.url)"
        Assert (-not $wh.last_error_message) "остання помилка доставки: $($wh.last_error_message)"
        $wh.url
    }
}

Write-Host ''
$color = if ($failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "Пройдено: $passed  Провалено: $failed  Пропущено: $skipped" -ForegroundColor $color
exit ([int]($failed -gt 0))
