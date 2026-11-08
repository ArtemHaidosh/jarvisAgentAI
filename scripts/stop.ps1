# Stops the containers. n8n data (workflows, credentials) stays in the volume.
. "$PSScriptRoot\lib\common.ps1"

Assert-DockerReady
Write-Step 'Зупиняю n8n і ngrok'
Invoke-Compose down
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Ok 'Зупинено. Ваші workflow збережені, наступний запуск: scripts\start.ps1'
