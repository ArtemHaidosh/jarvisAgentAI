# Stops the containers. n8n data (workflows, credentials) stays in the volume.
. "$PSScriptRoot\lib\common.ps1"

Assert-DockerReady
Write-Step 'Stopping n8n and ngrok'
Invoke-Compose down
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Ok 'Stopped. Your workflows are kept; start again with scripts\start.ps1'
