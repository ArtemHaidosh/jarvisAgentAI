# First-time setup: checks Docker, creates .env and asks for the secrets.
# Safe to re-run: values that are already filled in are not overwritten.
. "$PSScriptRoot\lib\common.ps1"

Write-Step 'Перевіряю Docker'
Assert-DockerReady
Write-Ok 'Docker запущений'

Write-Step 'Готую файл .env'
if (-not (Test-Path -LiteralPath $EnvPath)) {
    Copy-Item -LiteralPath $EnvExamplePath -Destination $EnvPath
    Write-Ok '.env створено з .env.example'
} else {
    Write-Ok '.env уже існує, доповнюю лише порожні значення'
}

$cfg = Read-DotEnv

if (-not $cfg['N8N_ENCRYPTION_KEY']) {
    Set-DotEnvValue 'N8N_ENCRYPTION_KEY' (New-EncryptionKey)
    Write-Ok 'Згенеровано N8N_ENCRYPTION_KEY'
}

$prompts = [ordered]@{
    TELEGRAM_BOT_TOKEN = 'Токен бота від @BotFather'
    NGROK_AUTHTOKEN    = 'ngrok authtoken (dashboard.ngrok.com -> Your Authtoken)'
    NGROK_DOMAIN       = 'Статичний домен ngrok (dashboard.ngrok.com -> Domains), напр. my-name.ngrok-free.app'
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
    Write-Host '  Відкрийте .env у редакторі, виправте значення і запустіть setup.ps1 знову.'
    exit 1
}

Write-Step 'Перевіряю токен бота в Telegram'
$me = Invoke-Telegram (Read-DotEnv)['TELEGRAM_BOT_TOKEN'] 'getMe'
if ($me.ok) {
    Write-Ok "Бот знайдено: @$($me.result.username)"
} else {
    Write-Fail "Telegram не прийняв токен: $($me.description)"
    exit 1
}

Write-Host ''
Write-Ok 'Налаштування завершено. Далі: scripts\start.ps1'
