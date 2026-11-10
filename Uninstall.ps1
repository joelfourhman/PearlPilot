[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param([switch]$DeleteUserData)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $appRoot 'Core\PearlPilot.psm1') -Force

$dataRoot = Get-PPDataRoot
$action='Stop PearlPilot and remove its sign-in startup and owned container'
if ($DeleteUserData) {$action+='; delete its settings and logs'}
if (-not $PSCmdlet.ShouldProcess($dataRoot,$action)) {return}
Disable-PPStartup
$escapedScript = [regex]::Escape((Join-Path $appRoot 'PearlPilot.ps1'))
$applicationProcesses=@(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match $escapedScript })
$applicationProcesses |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$workerScript=[regex]::Escape((Join-Path $appRoot 'Core\BackendWorker.ps1'))
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match $workerScript -and $_.ParentProcessId -in @($applicationProcesses | ForEach-Object {$_.ProcessId}) } |
    ForEach-Object {Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
Start-Sleep -Milliseconds 250

Stop-PPLegacyMiner $dataRoot

if ((Read-PPInstallation $dataRoot) -or (Test-Path -LiteralPath (Join-Path $dataRoot 'Backend\container-used'))) {
    Stop-PPDockerMiner (Get-PPBackendIdentity $dataRoot) -Remove
}

if ($DeleteUserData) {
    $expected = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PearlPilot'))
    $target = [IO.Path]::GetFullPath($dataRoot)
    if ($target -ne $expected) { throw "Refusing to delete unexpected data path: $target" }
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
}

Write-Host 'PearlPilot startup and owned processes removed.'
