[CmdletBinding()]
param([string]$Version='latest', [switch]$NoLaunch, [string]$DataRoot='')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT' -or [Environment]::OSVersion.Version.Build -lt 22000) {
    throw 'PearlPilot requires Windows 11.'
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'PearlPilot requires Windows PowerShell 5.1 or newer.'
}

$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($relative in @(
    'PearlPilot.ps1', 'RunPearlPilot.vbs', 'Assets\PearlPilot.ico',
    'Core\PearlPilot.psm1', 'Core\Menu.ps1', 'Core\Backend.psm1', 'Core\BackendWorker.ps1',
    'Core\Docker\Dockerfile', 'Core\Docker\cuda-probe.c', 'Core\Docker\supervisor.sh'
)) {
    $requiredPath = Join-Path $appRoot $relative
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "PearlPilot is incomplete; missing $requiredPath"
    }
}
Import-Module (Join-Path $appRoot 'Core\PearlPilot.psm1') -Force
$defaultRoot=Get-PPDataRoot
if (-not $DataRoot) {$DataRoot=$defaultRoot}
$DataRoot=[IO.Path]::GetFullPath($DataRoot)
if (-not $NoLaunch -and $DataRoot -ne [IO.Path]::GetFullPath($defaultRoot)) {
    throw 'Custom -DataRoot is supported with -NoLaunch only; the tray uses the standard per-user data directory.'
}
$DataRoot=Initialize-PPDataRoot -DataRoot $DataRoot
$identity=Get-PPBackendIdentity $DataRoot
$created=$false
$mutex=New-Object Threading.Mutex($true,"Local\PearlPilotBackend-$($identity.Owner)",[ref]$created)
if (-not $created) {$mutex.Dispose(); throw 'PearlPilot is running. Exit it from the tray before installing, or use the Backend tab in Menu.'}
try {
    $configuration=Get-PPConfiguration -DataRoot $DataRoot
    Write-Host '[1/4] Checking Docker Desktop, WSL2, NVIDIA driver and storage...'
    $hostChecks=Test-PPDockerPrerequisites $DataRoot -SkipPoolCheck
    $failed=@($hostChecks.Checks | Where-Object {-not $_.Ready -and $_.Check -ne 'Container GPU / CUDA'})
    if ($failed.Count) {throw (($failed | ForEach-Object {$_.Check+': '+$_.Detail}) -join "`n")}
    Write-Host "[2/4] Resolving $Version, verifying the official Linux download and building the image. The first build can take several minutes..."
    $candidate=Install-PPDockerWildRig $DataRoot $Version
    Assert-PPInstallationImage $identity $candidate
    Write-Host '[3/4] Validating storage and real GPU/CUDA access without mining...'
    $diagnostics=Test-PPDockerPrerequisites $DataRoot $candidate.Image -SkipPoolCheck
    if (-not $diagnostics.Ready) {throw (($diagnostics.Checks | Where-Object {-not $_.Ready} | ForEach-Object {$_.Check+': '+$_.Detail}) -join "`n")}
    $candidate.GpuValidated=$true
    Write-PPJson (Join-Path $DataRoot 'Backend\candidate.json') $candidate
    Set-PPActiveInstallation $DataRoot $candidate
    Save-PPConfiguration $configuration -DataRoot $DataRoot
    Write-Host ('[4/4] Installed Linux WildRig '+$candidate.Version+' as '+$candidate.Image)
    Write-Host ('Data and build log: '+$DataRoot)
} finally {$mutex.ReleaseMutex(); $mutex.Dispose()}

if (-not $NoLaunch) {
    $launcherPath = Join-Path $appRoot 'RunPearlPilot.vbs'
    $arguments=(ConvertTo-PPArgument $launcherPath)+' -Setup'
    Start-Process -FilePath (Get-PPWindowsScriptHostPath) -ArgumentList $arguments -WindowStyle Hidden
    Write-Host 'Settings opened. Enter your public payout address, save, then use Mine now or the automatic lock policy.'
} else {Write-Host 'Build and validation complete. No tray application or mining session was started.'}
