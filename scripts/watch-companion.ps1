$ErrorActionPreference = "Stop"
$server = Join-Path (Split-Path $PSScriptRoot -Parent) "server"
Set-Location $server
Write-Host "Watching 问象 companion. Ctrl+C to stop."
npm run keep
