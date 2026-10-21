# One-time per-user setup: lets the "Connect TFS" button on the website start Start-RanorexDeliveryEmailGenerator.ps1.
# Registers the ranorex-tfs:// URL protocol under HKCU (no admin rights needed) using the folder this script lives in.
param([switch]$Unregister)

$ErrorActionPreference = 'Stop'

$protocolKey = 'HKCU:\Software\Classes\ranorex-tfs'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValueName = 'RanorexTfsConnector'
$serviceScript = Join-Path $PSScriptRoot 'Start-RanorexDeliveryEmailGenerator.ps1'

if ($Unregister) {
    if (Test-Path $protocolKey) { Remove-Item -Path $protocolKey -Recurse -Force }
    Remove-ItemProperty -Path $runKey -Name $runValueName -ErrorAction SilentlyContinue
    Write-Host 'ranorex-tfs:// protocol and auto-start removed.'
    return
}

if (-not (Test-Path $serviceScript)) {
    throw "Start-RanorexDeliveryEmailGenerator.ps1 not found next to this script: $serviceScript"
}

# The URL argument (%1) is deliberately not forwarded, so a web page cannot inject parameters.
$command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$serviceScript`" -NoBrowser"

New-Item -Path "$protocolKey\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path $protocolKey -Name '(default)' -Value 'URL:Ranorex TFS Connector'
Set-ItemProperty -Path $protocolKey -Name 'URL Protocol' -Value ''
Set-ItemProperty -Path "$protocolKey\shell\open\command" -Name '(default)' -Value $command

# Start the service at every logon so the website button only has to connect to it.
Set-ItemProperty -Path $runKey -Name $runValueName -Value $command

# Start it now so the button works immediately, without logging off.
try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:8768/ping' -TimeoutSec 2 | Out-Null
} catch {
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Minimized', '-File', "`"$serviceScript`"", '-NoBrowser'
}

Write-Host "Registered ranorex-tfs:// for user $env:USERNAME -> $serviceScript"
Write-Host 'You can now use the "Connect TFS" button on the website.'
