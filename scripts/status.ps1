# Shows the state of the whole chain: Docker -> n8n -> ngrok -> Telegram webhook.
. "$PSScriptRoot\lib\common.ps1"

$cfg = Get-Config
$domain = $cfg['NGROK_DOMAIN']

Write-Step 'Контейнери'
Assert-DockerReady
Invoke-Compose ps

Write-Step 'n8n'
if (Test-N8nHealthy) { Write-Ok "Працює: $N8nLocalUrl" } else { Write-Fail 'Не відповідає. Запустіть scripts\start.ps1' }

Write-Step 'ngrok'
$publicUrl = Get-TunnelUrl
if (-not $publicUrl) {
    Write-Fail 'Tunnel не активний. Логи: docker compose logs ngrok'
} elseif ($publicUrl -ne "https://$domain") {
    Write-Warn "Tunnel активний, але на іншій адресі: $publicUrl (очікувалось https://$domain)"
} else {
    Write-Ok "Активний: $publicUrl"
}

Write-Step 'Telegram'
$me = Invoke-Telegram $cfg['TELEGRAM_BOT_TOKEN'] 'getMe'
if (-not $me.ok) {
    Write-Fail "Токен бота не працює: $($me.description)"
    exit 1
}
Write-Ok "Бот: @$($me.result.username)"

$info = Invoke-Telegram $cfg['TELEGRAM_BOT_TOKEN'] 'getWebhookInfo'
if (-not $info.ok) {
    Write-Fail "Не вдалося отримати webhook: $($info.description)"
    exit 1
}
$wh = $info.result
if (-not $wh.url) {
    Write-Warn 'Webhook не встановлено. Активуйте у n8n workflow з вузлом Telegram Trigger.'
} elseif ($wh.url -like "https://$domain/webhook-test/*") {
    Write-Warn "Webhook у тестовому режимі n8n: $($wh.url)"
    Write-Host '       Він працює лише поки в редакторі натиснуто "Listen for test event". Для постійної роботи активуйте workflow.'
} elseif ($wh.url -like "https://$domain/webhook/*") {
    Write-Ok "Webhook: $($wh.url)"
} else {
    Write-Warn "Webhook вказує на чужу адресу: $($wh.url)"
    Write-Host '       Деактивуйте і знову активуйте workflow у n8n, щоб він зареєструвався заново.'
}
if ($wh.pending_update_count -gt 0) { Write-Warn "Повідомлень у черзі Telegram: $($wh.pending_update_count)" }
if ($wh.last_error_message) {
    $when = [DateTimeOffset]::FromUnixTimeSeconds([long]$wh.last_error_date).LocalDateTime
    Write-Warn "Остання помилка доставки ($when): $($wh.last_error_message)"
}
