# Starts n8n and ngrok and waits until both are ready.
. "$PSScriptRoot\lib\common.ps1"

$cfg = Get-Config
Assert-DockerReady

Write-Step 'Запускаю n8n і ngrok (перший запуск завантажує образи, це може зайняти кілька хвилин)'
Invoke-Compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Fail 'docker compose не зміг запустити контейнери. Подивіться помилку вище або docs\troubleshooting.md'
    exit 1
}

Write-Step 'Чекаю на n8n'
if (-not (Wait-Until 'n8n' { Test-N8nHealthy } -TimeoutSec 120)) {
    Write-Host '  Логи: docker compose logs n8n'
    exit 1
}
Write-Ok 'n8n працює'

Write-Step 'Чекаю на ngrok tunnel'
if (-not (Wait-Until 'ngrok' { Get-TunnelUrl } -TimeoutSec 60)) {
    Write-Host '  Логи: docker compose logs ngrok'
    exit 1
}
$publicUrl = Get-TunnelUrl
Write-Ok "Tunnel активний: $publicUrl"
if ($publicUrl -ne "https://$($cfg['NGROK_DOMAIN'])") {
    Write-Warn "Адреса тунелю не збігається з NGROK_DOMAIN=$($cfg['NGROK_DOMAIN'])"
}

Write-Host ''
Write-Host "  Редактор n8n:        $N8nLocalUrl" -ForegroundColor White
Write-Host "  Публічні webhook:    $publicUrl/webhook/..." -ForegroundColor White
Write-Host "  Інспектор запитів:   http://localhost:4040" -ForegroundColor White
Write-Host ''
Write-Host '  Перевірити стан: scripts\status.ps1    Зупинити: scripts\stop.ps1'
