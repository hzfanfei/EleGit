$ErrorActionPreference = "Stop"
$server = Join-Path (Split-Path $PSScriptRoot -Parent) "server"
Set-Location $server
Write-Host "Dev mode: companion auto-reloads on server code changes. Ctrl+C to stop."
npm run dev
