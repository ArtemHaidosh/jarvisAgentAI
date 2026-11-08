# Shows the state of the whole chain: Docker -> n8n -> ngrok -> Telegram webhook.
. "$PSScriptRoot\lib\common.ps1"

$cfg = Get-Config
$domain = $cfg['NGROK_DOMAIN']

Write-Step 'Containers'
Assert-DockerReady
Invoke-Compose ps

Write-Step 'n8n'
if (Test-N8nHealthy) { Write-Ok "Running: $N8nLocalUrl" } else { Write-Fail 'Not responding. Run scripts\start.ps1' }

Write-Step 'ngrok'
$publicUrl = Get-TunnelUrl
if (-not $publicUrl) {
    Write-Fail 'Tunnel is not up. Logs: docker compose logs ngrok'
} elseif ($publicUrl -ne "https://$domain") {
    Write-Warn "Tunnel is up but on a different URL: $publicUrl (expected https://$domain)"
} else {
    Write-Ok "Up: $publicUrl"
}

Write-Step 'Telegram'
$me = Invoke-Telegram $cfg['TELEGRAM_BOT_TOKEN'] 'getMe'
if (-not $me.ok) {
    Write-Fail "Bot token does not work: $($me.description)"
    exit 1
}
Write-Ok "Bot: @$($me.result.username)"

$info = Invoke-Telegram $cfg['TELEGRAM_BOT_TOKEN'] 'getWebhookInfo'
if (-not $info.ok) {
    Write-Fail "Could not fetch webhook info: $($info.description)"
    exit 1
}
$wh = $info.result
if (-not $wh.url) {
    Write-Warn 'Webhook is not set. Activate a workflow with a Telegram Trigger node in n8n.'
} elseif ($wh.url -like "https://$domain/webhook-test/*") {
    Write-Warn "Webhook is in n8n test mode: $($wh.url)"
    Write-Host '       It only works while "Listen for test event" is pressed in the editor. Activate the workflow for permanent use.'
} elseif ($wh.url -like "https://$domain/webhook/*") {
    Write-Ok "Webhook: $($wh.url)"
} else {
    Write-Warn "Webhook points to a foreign URL: $($wh.url)"
    Write-Host '       Deactivate and re-activate the workflow in n8n so it registers again.'
}
if ($wh.pending_update_count -gt 0) { Write-Warn "Updates queued in Telegram: $($wh.pending_update_count)" }
if ($wh.last_error_message) {
    $when = [DateTimeOffset]::FromUnixTimeSeconds([long]$wh.last_error_date).LocalDateTime
    Write-Warn "Last delivery error ($when): $($wh.last_error_message)"
}
