[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT' -or [Environment]::OSVersion.Version.Build -lt 22000) {
    throw 'PearlPilot requires Windows 11.'
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'PearlPilot requires Windows PowerShell 5.1 or newer.'
}

$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $appRoot 'PearlPilot.ps1'
$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '" -Setup'
Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WindowStyle Hidden

Write-Host 'PearlPilot setup opened. Complete the short form to enable automatic startup.'
