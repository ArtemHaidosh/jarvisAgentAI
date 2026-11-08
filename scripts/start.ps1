# Starts n8n and ngrok and waits until both are ready.
. "$PSScriptRoot\lib\common.ps1"

$cfg = Get-Config
Assert-DockerReady

Write-Step 'Starting n8n and ngrok (the first run downloads images and may take a few minutes)'
Invoke-Compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Fail 'docker compose failed to start the containers. See the error above or docs\troubleshooting.md'
    exit 1
}

Write-Step 'Waiting for n8n'
if (-not (Wait-Until 'n8n' { Test-N8nHealthy } -TimeoutSec 120)) {
    Write-Host '  Logs: docker compose logs n8n'
    exit 1
}
Write-Ok 'n8n is up'

Write-Step 'Waiting for the ngrok tunnel'
if (-not (Wait-Until 'ngrok' { Get-TunnelUrl } -TimeoutSec 60)) {
    Write-Host '  Logs: docker compose logs ngrok'
    exit 1
}
$publicUrl = Get-TunnelUrl
Write-Ok "Tunnel is up: $publicUrl"
if ($publicUrl -ne "https://$($cfg['NGROK_DOMAIN'])") {
    Write-Warn "Tunnel URL does not match NGROK_DOMAIN=$($cfg['NGROK_DOMAIN'])"
}

Write-Host ''
Write-Host "  n8n editor:          $N8nLocalUrl" -ForegroundColor White
Write-Host "  Public webhooks:     $publicUrl/webhook/..." -ForegroundColor White
Write-Host "  Request inspector:   http://localhost:4040" -ForegroundColor White
Write-Host ''
Write-Host '  Check status: scripts\status.ps1    Stop: scripts\stop.ps1'
