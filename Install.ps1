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
$modulePath = Join-Path $appRoot 'Core\PearlPilot.psm1'
$scriptPath = Join-Path $appRoot 'PearlPilot.ps1'
$launcherPath = Join-Path $appRoot 'RunPearlPilot.vbs'
foreach ($requiredPath in @($modulePath, $scriptPath, $launcherPath, (Join-Path $appRoot 'Config\defaults.json'), (Join-Path $appRoot 'Assets\PearlPilot.ico'))) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "PearlPilot is incomplete; missing $requiredPath"
    }
}
Import-Module $modulePath -Force
$arguments = '"' + $launcherPath + '" -Setup'
Start-Process -FilePath (Get-PPWindowsScriptHostPath) -ArgumentList $arguments -WindowStyle Hidden

Write-Host 'PearlPilot setup opened. Complete the short form to enable automatic startup.'
