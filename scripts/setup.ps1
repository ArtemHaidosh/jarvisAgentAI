# First-time setup: checks Docker, creates .env and asks for the secrets.
# Safe to re-run: values that are already filled in are not overwritten.
. "$PSScriptRoot\lib\common.ps1"

Write-Step 'Checking Docker'
Assert-DockerReady
Write-Ok 'Docker is running'

Write-Step 'Preparing .env'
if (-not (Test-Path -LiteralPath $EnvPath)) {
    Copy-Item -LiteralPath $EnvExamplePath -Destination $EnvPath
    Write-Ok '.env created from .env.example'
} else {
    Write-Ok '.env already exists, filling in only empty values'
}

$cfg = Read-DotEnv

if (-not $cfg['N8N_ENCRYPTION_KEY']) {
    Set-DotEnvValue 'N8N_ENCRYPTION_KEY' (New-EncryptionKey)
    Write-Ok 'Generated N8N_ENCRYPTION_KEY'
}
if (-not $cfg['POSTGRES_PASSWORD']) {
    Set-DotEnvValue 'POSTGRES_PASSWORD' (New-EncryptionKey)
    Write-Ok 'Generated POSTGRES_PASSWORD'
}

$prompts = [ordered]@{
    TELEGRAM_BOT_TOKEN = 'Bot token from @BotFather'
    NGROK_AUTHTOKEN    = 'ngrok authtoken (dashboard.ngrok.com -> Your Authtoken)'
    NGROK_DOMAIN       = 'ngrok static domain (dashboard.ngrok.com -> Domains), e.g. my-name.ngrok-free.app'
}
foreach ($key in $prompts.Keys) {
    if ($cfg[$key]) { continue }
    $value = (Read-Host $prompts[$key]).Trim()
    if ($key -eq 'NGROK_DOMAIN') { $value = ConvertTo-NgrokDomain $value }
    Set-DotEnvValue $key $value
}

$problems = Test-Config (Read-DotEnv)
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Fail $p }
    Write-Host '  Open .env in an editor, fix the values and run setup.ps1 again.'
    exit 1
}

Write-Step 'Checking the bot token with Telegram'
$me = Invoke-Telegram (Read-DotEnv)['TELEGRAM_BOT_TOKEN'] 'getMe'
if ($me.ok) {
    Write-Ok "Bot found: @$($me.result.username)"
} else {
    Write-Fail "Telegram rejected the token: $($me.description)"
    exit 1
}

Write-Host ''
Write-Ok 'Setup complete. Next: scripts\start.ps1'
