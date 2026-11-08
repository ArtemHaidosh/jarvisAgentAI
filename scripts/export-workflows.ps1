# Exports all n8n workflows into workflows\ (one JSON file each) so they can go into git.
# Personal and runtime data is stripped (see scripts\lib\sanitize-workflows.js);
# credentials are referenced by id only, their secrets never leave n8n.
. "$PSScriptRoot\lib\common.ps1"

$cfg = Get-Config
Assert-DockerReady
$outDir = Join-Path $RepoRoot 'workflows'
$tmp = "/tmp/jarvis-export-$PID"

Write-Step 'Exporting workflows from n8n'
Invoke-Compose exec -T n8n sh -c "mkdir -p $tmp/raw $tmp/clean && n8n export:workflow --backup --output=$tmp/raw/ >/dev/null"
if ($LASTEXITCODE -ne 0) { Write-Fail 'n8n export failed (is n8n running? are there any workflows?)'; exit 1 }

# Piped straight into docker: a PowerShell function (Invoke-Compose) would not forward stdin
Get-Content -Raw (Join-Path $PSScriptRoot 'lib\sanitize-workflows.js') |
    & docker compose -f $ComposeFile exec -T n8n node - "$tmp/raw" "$tmp/clean"
if ($LASTEXITCODE -ne 0) { Write-Fail 'Sanitizing failed'; exit 1 }

# Replace the folder contents, so workflows deleted in n8n disappear from git too
New-Item -ItemType Directory -Force $outDir | Out-Null
Get-ChildItem -Path $outDir -Filter *.json | Remove-Item
Invoke-Compose cp "n8n:$tmp/clean/." $outDir
$copied = $LASTEXITCODE
Invoke-Compose exec -T n8n rm -rf $tmp
if ($copied -ne 0) { Write-Fail 'Copying files out of the container failed'; exit 1 }

# Values from .env must never end up in the export
$private = 'TELEGRAM_OWNER_ID', 'TELEGRAM_BOT_TOKEN', 'NGROK_AUTHTOKEN', 'NGROK_DOMAIN', 'N8N_ENCRYPTION_KEY', 'POSTGRES_PASSWORD'
$leaks = foreach ($f in Get-ChildItem -Path $outDir -Filter *.json) {
    $text = [IO.File]::ReadAllText($f.FullName)
    foreach ($k in $private) { if ($cfg[$k] -and $text.Contains($cfg[$k])) { "$($f.Name) contains $k" } }
}
if ($leaks) {
    foreach ($l in $leaks) { Write-Fail $l }
    Write-Host '  Replace the value in n8n with an expression, e.g. {{ $env.TELEGRAM_OWNER_ID }}, and export again.'
    Write-Host '  Do not commit workflows\ until this is fixed.'
    exit 1
}
Write-Ok "Exported to workflows\ ($(@(Get-ChildItem -Path $outDir -Filter *.json).Count) files), no private values found"
