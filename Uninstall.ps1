[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param([switch]$DeleteUserData)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $appRoot 'Core\PearlPilot.psm1') -Force

Disable-PPStartup
$dataRoot = Get-PPDataRoot
$escapedScript = [regex]::Escape((Join-Path $appRoot 'PearlPilot.ps1'))
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match $escapedScript } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 250

$markerPath = Join-Path $dataRoot 'Runtime\owned-miner.json'
if (Test-Path -LiteralPath $markerPath) {
    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        $startedUtc = [DateTime]::Parse([string]$marker.StartedUtc).ToUniversalTime()
        Stop-PPOwnedProcess -ProcessId ([int]$marker.ProcessId) -StartedUtc $startedUtc
    } catch { }
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
}

if ($DeleteUserData) {
    $expected = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PearlPilot'))
    $target = [IO.Path]::GetFullPath($dataRoot)
    if ($target -ne $expected) { throw "Refusing to delete unexpected data path: $target" }
    if ($PSCmdlet.ShouldProcess($target, 'Delete PearlPilot settings and logs')) {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'PearlPilot startup and owned processes removed.'
