[CmdletBinding()]
param([Parameter(Mandatory=$true)][int]$ParentId, [Parameter(Mandatory=$true)][string]$ParentStartedUtc,
    [Parameter(Mandatory=$true)][string]$DataRoot)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'PearlPilot.psm1') -Force
$identity=Get-PPBackendIdentity $DataRoot
$created=$false
$mutex=New-Object Threading.Mutex($true,"Local\PearlPilotBackend-$($identity.Owner)",[ref]$created)
if (-not $created) { $mutex.Dispose(); exit 1 }
$runtime=Join-Path $DataRoot 'Runtime'
$statusPath=Join-Path $runtime 'backend-status.json'
$intentPath=Join-Path $runtime 'backend-intent.json'
$state=New-PPControllerState
$lastAutomaticVersion=''
$recoveryPath=Join-Path $runtime 'backend-recovery.json'
if (Test-Path -LiteralPath $recoveryPath) {
    try {
        $saved=Get-Content -LiteralPath $recoveryPath -Raw | ConvertFrom-Json
        $state.Failures=[int]$saved.Failures; $state.NextAttemptUtc=[DateTime]::Parse($saved.NextAttemptUtc).ToUniversalTime(); $state.LastError=$saved.Error
        $lastAutomaticVersion=[string](Get-PPOption $saved 'AutomaticVersion' '')
    } catch { }
}
$operation=$null
$diagnostics=$null
$available=$null
$nextVersionCheck=[DateTime]::UtcNow
$lastPublishedState=''
$lastPublishedError=''
$lastPublishedPolicy=''
$intent=$null
function Publish-Status {
    $policy=[string](Get-PPOption $intent 'Status' '')
    if ($state.State -ne $script:lastPublishedState -or $state.LastError -ne $script:lastPublishedError -or $policy -ne $script:lastPublishedPolicy) {
        Write-PPLog -DataRoot $DataRoot -Message ('Backend {0}/{1}: {2} Policy: {3}; GPU temperature: {4} C; telemetry available: {5}' -f $state.Backend,$state.State,$state.LastError,$policy,(Get-PPOption $intent 'TemperatureC'),(Get-PPOption $intent 'TelemetryAvailable'))
        $script:lastPublishedState=$state.State; $script:lastPublishedError=$state.LastError
        $script:lastPublishedPolicy=$policy
    }
    Write-PPJson $recoveryPath ([pscustomobject]@{ Failures=$state.Failures; NextAttemptUtc=$state.NextAttemptUtc.ToString('o'); Error=$state.LastError; AutomaticVersion=$lastAutomaticVersion })
    $installed=Read-PPInstallation $DataRoot
    Write-PPJson $statusPath ([pscustomobject]@{ UpdatedUtc=[DateTime]::UtcNow.ToString('o'); State=$state.State; Backend=$state.Backend;
        Desired=$state.Desired; Error=$state.LastError; Failures=$state.Failures; NextAttemptUtc=$state.NextAttemptUtc.ToString('o');
        IntentUpdatedUtc=(Get-PPOption $intent 'UpdatedUtc');
        PolicyStatus=$policy; TemperatureC=(Get-PPOption $intent 'TemperatureC'); TelemetryAvailable=(Get-PPOption $intent 'TelemetryAvailable');
        Telemetry=$state.LastTelemetry; Installed=$installed; Available=$available; Operation=$operation; Diagnostics=$diagnostics })
}
try {
    while (Test-PPOwnedProcess -ProcessId $ParentId -StartedUtc ([DateTime]::Parse($ParentStartedUtc))) {
        try {
            if (-not (Test-Path -LiteralPath $intentPath)) { Start-Sleep -Milliseconds 200; continue }
            $intent=Read-PPJson $intentPath
            $fresh=Test-PPFreshTimestamp $intent.UpdatedUtc
            if (-not $fresh) { $intent.ShouldMine=$false; $intent.Status='Controller heartbeat expired' }
            $request=$null
            $requests=@(Get-ChildItem -LiteralPath $runtime -Filter 'request-*.json' | Sort-Object Name)
            if ($requests.Count) {
                # Consume malformed requests too, so one broken file cannot
                # permanently block lifecycle supervision or the request queue.
                try { $request=Read-PPJson $requests[0].FullName }
                finally { Remove-Item -LiteralPath $requests[0].FullName -Force }
            } elseif (Test-PPAutomaticUpdateDue $intent $state $available $lastAutomaticVersion) {
                $installed=Read-PPInstallation $DataRoot
                if ($installed -and [version]$available.Version -gt [version]$installed.Version) {
                    $lastAutomaticVersion=$available.Version
                    $request=[pscustomobject]@{Action='Install'; Version=$available.Version; RequestedUtc=[DateTime]::UtcNow.ToString('o')}
                }
            }
            if ($request) {
                Assert-PPBackendRequest $request $intent
                if ($intent.ShouldMine -and $request.Action -in @('Install','Rollback')) {
                    $state.LastError='Stop mining before installing or rolling back a version.'; Publish-Status; continue
                }
                Stop-PPControllerMiner $state $DataRoot
                $state.State='UPDATING'; $state.Desired=$false; $operation=$request.Action; $state.LastError=''
                Publish-Status
                try {
                    switch ($request.Action) {
                        'Check' {
                            $available=Get-PPWildRigRelease (Join-Path $DataRoot 'Backend') -Refresh
                            $nextVersionCheck=[DateTime]::UtcNow.AddHours(6)
                        }
                        'Diagnostics' {
                            $installed=Read-PPInstallation $DataRoot
                            if (-not $installed) { $installed=Read-PPInstallation $DataRoot 'candidate' }
                            $image=if ($installed) {$installed.Image} else {''}
                            $diagnostics=Test-PPDockerPrerequisites $DataRoot $image $intent.Configuration.PoolUrl
                        }
                        'Install' {
                            $candidate=Install-PPDockerWildRig $DataRoot ([string]$request.Version) -UpdateOnly
                            if (-not $candidate) { break }
                            $diagnostics=Test-PPDockerPrerequisites $DataRoot $candidate.Image -SkipPoolCheck
                            if (-not $diagnostics.Ready) { throw (($diagnostics.Checks | Where-Object { -not $_.Ready } | ForEach-Object { $_.Detail }) -join "`n") }
                            $candidate.GpuValidated=$true
                            Set-PPActiveInstallation $DataRoot $candidate
                            try { Remove-PPObsoleteResources $DataRoot }
                            catch {
                                try { Write-PPLog -DataRoot $DataRoot -Message "WildRig $($candidate.Version) installed. Old resource cleanup failed: $($_.Exception.Message)" }
                                catch { }
                            }
                        }
                        'Rollback' {
                            $previous=Read-PPInstallation $DataRoot 'previous'
                            if (-not $previous -or -not $previous.MiningValidated) { throw 'No previously validated mining image is available.' }
                            Assert-PPInstallationImage $identity $previous
                            $lastAutomaticVersion=[string](Get-PPOption (Read-PPInstallation $DataRoot) 'Version' '')
                            Set-PPActiveInstallation $DataRoot $previous -Rollback
                        }
                        'Retry' { }
                        'Benchmark' {
                            $benchmarkPanelId=$intent.PanelId
                            $installed=Read-PPInstallation $DataRoot
                            if (-not $installed) {throw 'Install a validated backend before benchmarking.'}
                            [void](Invoke-PPBenchmark $DataRoot $intent.Configuration $installed -Authorized -Cancelled {
                                if (-not (Test-PPOwnedProcess -ProcessId $ParentId -StartedUtc ([DateTime]::Parse($ParentStartedUtc)))) {return $true}
                                $current=Read-PPJson $intentPath
                                (($current.Status -ne 'Backend panel open') -or $current.ShouldMine -or
                                    (Get-PPOption $current 'PanelId') -cne $benchmarkPanelId -or -not (Test-PPFreshTimestamp $current.UpdatedUtc))
                            } -Progress {param($Sample) $state.LastTelemetry=$Sample; Publish-Status})
                        }
                        default { throw 'Unknown backend operation.' }
                    }
                    $state.Failures=0; $state.NextAttemptUtc=[DateTime]::MinValue; $state.State='STOPPED'
                } catch { $state.LastError=$_.Exception.Message; $state.State='ERROR' }
                $operation=$null
                Publish-Status
                # Never act on pre-operation policy/configuration after a long build.
                continue
            }
            $state=Invoke-PPControllerTick $state $intent $DataRoot
            Publish-Status
            if ($fresh -and -not $intent.ShouldMine -and [DateTime]::UtcNow -ge $nextVersionCheck) {
                $nextVersionCheck=[DateTime]::UtcNow.AddHours(6)
                try { $available=Get-PPWildRigRelease (Join-Path $DataRoot 'Backend') } catch { }
                Publish-Status
            }
        } catch {
            Set-PPRecovery $state $_.Exception.Message
            try { Publish-Status } catch { }
        }
        Start-Sleep -Seconds 2
    }
} finally {
    try { Stop-PPControllerMiner $state $DataRoot; $state.State='STOPPED'; Publish-Status } catch { }
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
