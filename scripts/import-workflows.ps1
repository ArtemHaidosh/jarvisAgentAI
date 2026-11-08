# Imports workflows\*.json into n8n (restore from git, or set up on a new machine).
# A workflow with the same id is overwritten. Imported workflows are inactive:
# select credentials where needed and press Publish in the editor.
. "$PSScriptRoot\lib\common.ps1"

$null = Get-Config
Assert-DockerReady
$srcDir = Join-Path $RepoRoot 'workflows'
if (-not (Get-ChildItem -Path $srcDir -Filter *.json -ErrorAction SilentlyContinue)) {
    Write-Fail 'No workflows\*.json to import'
    exit 1
}
$tmp = "/tmp/jarvis-import-$PID"

Write-Step 'Importing workflows into n8n'
Invoke-Compose exec -T n8n mkdir -p $tmp
Invoke-Compose cp "$srcDir\." "n8n:$tmp/"
Invoke-Compose exec -T n8n n8n import:workflow --separate "--input=$tmp"
$code = $LASTEXITCODE
Invoke-Compose exec -T -u root n8n rm -rf $tmp
if ($code -ne 0) { Write-Fail 'n8n import failed, see the error above'; exit 1 }
Write-Ok 'Imported. Open n8n, check credentials and Publish the workflows you need.'
