[CmdletBinding()]
param([switch]$Install, [string]$Version='', [switch]$AuthorizeMining,
    [ValidateRange(30,180)][int]$Seconds=60, [string]$DataRoot='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Core\PearlPilot.psm1') -Force
if (-not $DataRoot) { $DataRoot=Initialize-PPDataRoot }
$DataRoot=[IO.Path]::GetFullPath($DataRoot)
foreach ($folder in @($DataRoot,(Join-Path $DataRoot 'Runtime'),(Join-Path $DataRoot 'Logs'))) { [void](New-Item -ItemType Directory -Path $folder -Force) }
$identity=Get-PPBackendIdentity $DataRoot
$created=$false
$mutex=New-Object Threading.Mutex($true,"Local\PearlPilotBackend-$($identity.Owner)",[ref]$created)
if (-not $created) { $mutex.Dispose(); throw 'Exit PearlPilot before running the independent smoke test.' }
$evidence=[ordered]@{ TestedUtc=[DateTime]::UtcNow.ToString('o'); Version=$null; Preflight=$null; MiningAuthorized=[bool]$AuthorizeMining;
    MiningValidated=$false; Telemetry=$null; Gpu=$null; StopConfirmed=$false; StopExitCode=$null; Error=$null }
try {
    $configuration=Get-PPConfiguration
    [void](Get-PPMiningArgv $configuration)
    if ($Install) { $installation=Install-PPDockerWildRig $DataRoot $Version }
    else { $installation=Read-PPInstallation $DataRoot; if (-not $installation) {$installation=Read-PPInstallation $DataRoot 'candidate'} }
    if (-not $installation) { throw 'Install the official backend first from the Backend tab in Menu, or use -Install.' }
    $evidence.Version=$installation.Version
    $evidence.Preflight=Test-PPDockerPrerequisites $DataRoot $installation.Image $configuration.PoolUrl
    if (-not $evidence.Preflight.Ready) { throw (($evidence.Preflight.Checks | Where-Object {-not $_.Ready} | ForEach-Object {$_.Detail}) -join "`n") }
    $installation | Add-Member NoteProperty GpuValidated $true -Force
    if (-not $AuthorizeMining) {
        if ($Install) {Set-PPActiveInstallation $DataRoot $installation}
        Write-Host 'Prerequisites and CUDA visibility passed. Mining was not authorized or tested.'; return
    }
    if (Test-PPOtherMinerRunning (Get-PPOption $configuration 'WildRigPath' '') $null) { throw 'Stop the existing native WildRig instance before testing Docker.' }
    $validation=Test-PPConfiguration $configuration
    if (-not $validation.Valid) { throw ($validation.Errors -join '; ') }
    [void](Start-PPDockerMiner $identity $configuration $installation)
    $end=[DateTime]::UtcNow.AddSeconds($Seconds)
    $hashing=$false; $utilized=$false; $shared=$false
    while ([DateTime]::UtcNow -lt $end) {
        $gpu=Get-PPGpuTemperature $configuration.GpuList
        if (-not $gpu.Available -or $gpu.TemperatureC -ge $configuration.TemperatureLimitC) { throw 'Thermal safety stopped the smoke test.' }
        $telemetry=Get-PPDockerTelemetry $identity $installation
        if (-not $telemetry -or -not $telemetry.ContainerRunning) { throw 'Miner exited during smoke test.' }
        [void](Invoke-PPDocker @('exec',$identity.Name,'touch','/tmp/pearlpilot.lease'))
        $evidence.Telemetry=$telemetry; $evidence.Gpu=$gpu
        if ($telemetry.Hashrate -gt 0 -and $telemetry.PoolConnected -eq $true) { $hashing=$true }
        if (@($gpu.Gpus | Where-Object {$null -ne $_.Utilization -and $_.Utilization -gt 20}).Count) { $utilized=$true }
        if ($telemetry.Accepted -gt 0) { $shared=$true }
        Start-Sleep -Seconds 3
    }
    if (-not ($hashing -and $utilized -and $shared)) { throw 'Mining acceptance failed: requires positive hashrate, pool connectivity, GPU utilization, and an accepted share. A short session may not find a share; inspect evidence.' }
    $evidence.MiningValidated=$true
    $installation.MiningValidated=$true
    Set-PPActiveInstallation $DataRoot $installation
} catch { $evidence.Error=$_.Exception.Message; throw }
finally {
    try {
        Stop-PPDockerMiner $identity
        $stopped=Get-PPOwnedContainer $identity
        if ($stopped) { $evidence.StopExitCode=$stopped.State.ExitCode }
        Stop-PPDockerMiner $identity -Remove
        $evidence.StopConfirmed=($null -eq (Get-PPOwnedContainer $identity))
    } catch { $evidence.StopConfirmed=$false; if (-not $evidence.Error) { $evidence.Error=$_.Exception.Message } }
    Write-PPJson (Join-Path $DataRoot 'smoke-result.json') $evidence
    $mutex.ReleaseMutex(); $mutex.Dispose()
    $evidence | ConvertTo-Json -Depth 12
    if (-not $evidence.StopConfirmed) { throw 'Container cleanup could not be confirmed. See smoke-result.json.' }
}
