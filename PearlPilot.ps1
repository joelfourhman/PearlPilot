[CmdletBinding()]
param([switch]$Setup, [switch]$MineNow)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $appRoot 'Core\PearlPilot.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $appRoot 'Core\Menu.ps1')

$dataRoot = Initialize-PPDataRoot
$iconPath = Join-Path $appRoot 'Assets\PearlPilot.ico'
$script:configuration = Get-PPConfiguration
$script:exitRequested = $false
$script:sessionState = Get-PPCurrentSessionState
$script:lockedSinceUtc = if ($sessionState -eq 'Locked') { [DateTime]::UtcNow } else { $null }
$script:temperatureC = $null
$script:telemetryAvailable = $false
$script:gpuSnapshot = $null
$script:thermalSafe = $true
$script:lastGpuPollUtc = [DateTime]::MinValue
$script:lastReconcileUtc = [DateTime]::UtcNow
$script:manualMining = [bool]$MineNow
$script:miningRequested = $false
$script:menuWindow = $null
$script:requestedMenuTab = ''
$script:suspended = $false
$script:backendWorker = $null
$script:backendStatus = $null
$script:lastNotifiedVersion = ''
$script:lastIntentUtc = [DateTime]::MinValue
$script:lastLoopUtc = [DateTime]::UtcNow
$script:userStopped = [bool]$configuration.UserStopped
if ($MineNow) { $script:userStopped=$false; $configuration.UserStopped=$false; Save-PPConfiguration $configuration }
$intentPath = Join-Path $dataRoot 'Runtime\backend-intent.json'
$backendStatusPath = Join-Path $dataRoot 'Runtime\backend-status.json'

function Publish-PPIntent {
    param([bool]$ShouldMine=$false, [string]$Status='Paused')
    $panelId = if ($Status -eq 'Backend panel open' -and $script:menuWindow) { $script:menuWindow.PanelId } else { '' }
    Write-PPJson $intentPath ([pscustomobject]@{ UpdatedUtc=[DateTime]::UtcNow.ToString('o'); Configuration=$script:configuration;
        ShouldMine=($ShouldMine -and -not $script:userStopped); Status=$Status; PanelId=$panelId;
        TemperatureC=$script:temperatureC; TelemetryAvailable=$script:telemetryAvailable })
}

function Start-PPBackendWorker {
    Publish-PPIntent
    $parent=Get-Process -Id $PID
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $appRoot 'Core\BackendWorker.ps1'),
        '-ParentId',[string]$PID,'-ParentStartedUtc',$parent.StartTime.ToUniversalTime().ToString('o'),'-DataRoot',$dataRoot)
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Get-PPWindowsPowerShellPath
    $start.Arguments=(@($arguments | ForEach-Object { ConvertTo-PPArgument $_ }) -join ' ')
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $script:backendWorker=[Diagnostics.Process]::Start($start)
    if ($script:manualMining) {
        Send-PPBackendRequest $dataRoot 'Retry'
    }
}

function Show-PPTrayError {
    param([Parameter(Mandatory=$true)][string]$Action, [Parameter(Mandatory=$true)][Exception]$Exception)

    $message = "$Action failed: $($Exception.Message)"
    try { Write-PPLog $message } catch { }
    [void][Windows.Forms.MessageBox]::Show($message, 'PearlPilot', 'OK', 'Error')
}

function Stop-PPManagedMiner {
    param([string]$Reason)
    $requestedUtc=[DateTime]::UtcNow
    Publish-PPIntent -Status $Reason
    if (-not $script:backendWorker) { return }
    $deadline=[DateTime]::UtcNow.AddSeconds(25)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($script:backendWorker.HasExited) { throw 'Mining controller stopped unexpectedly. Inspect logs before restarting.' }
        try {
            $snapshot=Read-PPJson $backendStatusPath
            if (Test-PPStopAcknowledged $snapshot $requestedUtc) { return }
        } catch { }
        Start-Sleep -Milliseconds 100
    }
    throw 'Mining stop has not been confirmed. Check Docker connectivity and controller logs before continuing.'
}

function Switch-PPMining {
    try {
        $stopRequested = $script:manualMining -or $script:miningRequested
        $script:manualMining = -not $stopRequested
        $script:userStopped = $stopRequested
        $script:configuration.UserStopped = $script:userStopped
        Save-PPConfiguration $script:configuration
        if ($script:manualMining) {
            Send-PPBackendRequest $dataRoot 'Retry'
            Write-PPLog 'Manual mining enabled.'
        } else {
            Write-PPLog 'Manual mining disabled.'
            Stop-PPManagedMiner -Reason 'Stopped manually'
        }
    } catch {
        Show-PPTrayError -Action 'Manual mining' -Exception $_.Exception
    }
}

function Set-PPSessionState {
    param([string]$State, [string]$Reason)
    if ($State -eq $script:sessionState) { return }

    $script:sessionState = $State
    if ($State -eq 'Locked') {
        $script:lockedSinceUtc = [DateTime]::UtcNow
    } else {
        $script:lockedSinceUtc = $null
    }
    Write-PPLog "Session is $State ($Reason)."
}

$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -replace '[^A-Za-z0-9]', '-'
$created = $false
$mutex = New-Object Threading.Mutex($true, "Local\PearlPilot-$sid", [ref]$created)
if (-not $created) { exit 0 }
Start-PPBackendWorker

if ($Setup -or -not [bool]$configuration.Configured) {
    if (-not (Show-PPMenu -Setup)) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
        exit 0
    }
}

$notify = New-Object Windows.Forms.NotifyIcon
$appIcon = New-Object Drawing.Icon($iconPath)
$notify.Icon = $appIcon
$notify.Text = 'PearlPilot: starting'
$notify.Visible = $true

$tray = New-PPTrayPopup $appIcon
$menu = $tray.Menu

$mineNowItem = Add-PPTrayAction $menu $(if ($manualMining) { 'Stop mining' } else { 'Mine now' }) -Primary
$mineNowItem.Add_Click({ Switch-PPMining })
$menuItem = Add-PPTrayAction $menu 'Open Menu'
$menuItem.Add_Click({ $script:requestedMenuTab = 'Statistics' })

$automaticItem = Add-PPTrayAction $menu 'Automatic mining'
$automaticItem.Checked = [bool]$configuration.AutomaticMining
$automaticItem.Add_Click({
    $previous = [bool]$configuration.AutomaticMining
    try {
        $script:configuration.AutomaticMining = -not $previous
        Save-PPConfiguration -Configuration $configuration
        $automaticItem.Checked = [bool]$configuration.AutomaticMining
        if ($configuration.AutomaticMining) {
            $script:userStopped=$false; $configuration.UserStopped=$false; Save-PPConfiguration $configuration
        }
    } catch {
        $script:configuration.AutomaticMining = $previous
        $automaticItem.Checked = $previous
        Show-PPTrayError -Action 'Saving automatic-mining preference' -Exception $_.Exception
    }
})

$detailsItem = Add-PPTrayAction $menu 'View backend details'
$detailsItem.Available = $false
$detailsItem.Add_Click({ $script:requestedMenuTab = 'Backend' })
$retryItem = Add-PPTrayAction $menu 'Retry mining controller'
$retryItem.Available = $false
$retryItem.Add_Click({
    try {
        Send-PPBackendRequest $dataRoot 'Retry'
        Write-PPLog 'Mining controller retry requested.'
    } catch { Show-PPTrayError -Action 'Retrying mining controller' -Exception $_.Exception }
})
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))

$exitItem = Add-PPTrayAction $menu 'Exit PearlPilot'
$exitItem.Add_Click({ $script:exitRequested = $true })

$notify.ContextMenuStrip = $menu
$notify.Add_DoubleClick({ $menuItem.PerformClick() })
$notify.Add_BalloonTipClicked({ $script:requestedMenuTab = 'Backend' })

try {
    Register-ObjectEvent `
        -InputObject ([Microsoft.Win32.SystemEvents]) `
        -EventName SessionSwitch `
        -SourceIdentifier 'PearlPilot.Session' | Out-Null
    Register-ObjectEvent `
        -InputObject ([Microsoft.Win32.SystemEvents]) `
        -EventName PowerModeChanged `
        -SourceIdentifier 'PearlPilot.Power' | Out-Null
    Write-PPLog 'PearlPilot started.'
    if ($manualMining) { Write-PPLog 'Manual mining enabled at launch.' }

    $lastMenuTab = ''
    while (-not $exitRequested) {
        [Windows.Forms.Application]::DoEvents()

        if ($script:menuWindow -and $script:menuWindow.Form.IsDisposed) {
            if ($script:menuWindow.Form.Tag) {
                $script:lockedSinceUtc = if ($sessionState -eq 'Locked') { [DateTime]::UtcNow } else { $null }
                $script:lastGpuPollUtc = [DateTime]::MinValue
                $automaticItem.Checked = [bool]$configuration.AutomaticMining
            }
            $script:menuWindow = $null
        }
        if ($script:requestedMenuTab -and -not $exitRequested) {
            $initialTab = $script:requestedMenuTab
            $script:requestedMenuTab = ''
            try { Show-PPMenu -InitialTab $initialTab }
            catch { Show-PPTrayError -Action 'Opening Menu' -Exception $_.Exception }
        }
        $menuTab = if ($script:menuWindow) { $script:menuWindow.SelectedPage } else { '' }

        foreach ($event in @(Get-Event -SourceIdentifier 'PearlPilot.Session' -ErrorAction SilentlyContinue)) {
            $reason = [string]$event.SourceEventArgs.Reason
            if ($reason -eq 'SessionLock') { Set-PPSessionState -State Locked -Reason $reason }
            if ($reason -eq 'SessionUnlock') { Set-PPSessionState -State Unlocked -Reason $reason }
            Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
        }
        foreach ($event in @(Get-Event -SourceIdentifier 'PearlPilot.Power' -ErrorAction SilentlyContinue)) {
            $mode = [string]$event.SourceEventArgs.Mode
            if ($mode -eq 'Suspend') { $script:suspended=$true; Set-PPSessionState -State Unknown -Reason Suspend }
            if ($mode -eq 'Resume') { $script:suspended=$false; $script:lockedSinceUtc=$null; Set-PPSessionState -State (Get-PPCurrentSessionState) -Reason Resume }
            Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
        }

        $now = [DateTime]::UtcNow
        if (($now-$script:lastLoopUtc).TotalSeconds -gt 20) {
            $script:sessionState='Unknown'; $script:lockedSinceUtc=$null
            Set-PPSessionState -State (Get-PPCurrentSessionState) -Reason 'Resume or supervision gap'
            $script:lastGpuPollUtc=[DateTime]::MinValue
        }
        $script:lastLoopUtc=$now
        if (($now - $lastReconcileUtc).TotalSeconds -ge 30) {
            Set-PPSessionState -State (Get-PPCurrentSessionState) -Reason Reconciliation
            $script:lastReconcileUtc = $now
        }

        if (($now - $lastGpuPollUtc).TotalSeconds -ge 10) {
            $gpu = Get-PPGpuTemperature -GpuList ([string]$configuration.GpuList)
            $script:gpuSnapshot = $gpu
            $script:telemetryAvailable = [bool]$gpu.Available
            $script:temperatureC = $gpu.TemperatureC
            if ($gpu.Available) {
                if ([int]$gpu.TemperatureC -ge [int]$configuration.TemperatureLimitC) { $script:thermalSafe = $false }
                $resumeTemperature = [int]$configuration.TemperatureLimitC - 10
                if (-not $thermalSafe -and [int]$gpu.TemperatureC -le $resumeTemperature) {
                    $script:thermalSafe = $true
                }
            }
            $script:lastGpuPollUtc = $now
        }

        $decision = Get-PPMiningDecision `
            -SessionState $sessionState `
            -LockedSinceUtc $lockedSinceUtc `
            -NowUtc $now `
            -DelayMinutes ([int]$configuration.LockDelayMinutes) `
            -AutomaticMining ([bool]$configuration.AutomaticMining) `
            -ManualMining $manualMining `
            -TelemetryAvailable $telemetryAvailable `
            -ThermalSafe $thermalSafe `
            -IdleMinutes ([int]$configuration.IdleMinutes) `
            -IdleSeconds (Get-PPIdleSeconds) `
            -WorkloadBlocked (Test-PPGamingProcess $configuration.GamingProcesses) `
            -Suspended $suspended

        if ($script:userStopped) { $decision=[pscustomobject]@{ ShouldMine=$false; Status='Stopped manually' } }
        if ($menuTab -eq 'Settings') { $decision=[pscustomobject]@{ ShouldMine=$false; Status='Settings open' } }
        if ($menuTab -eq 'Backend') { $decision=[pscustomobject]@{ ShouldMine=$false; Status='Backend panel open' } }
        $workerExited=$script:backendWorker.HasExited
        if ($workerExited) {
            $decision=[pscustomobject]@{ ShouldMine=$false; Status='ERROR: Mining controller exited; restart PearlPilot' }
        }
        $script:miningRequested=$decision.ShouldMine
        if (($now-$script:lastIntentUtc).TotalSeconds -ge 1 -or $menuTab -ne $lastMenuTab) {
            Publish-PPIntent -ShouldMine $script:miningRequested -Status $decision.Status
            $script:lastIntentUtc=$now
            $lastMenuTab=$menuTab
            try { $script:backendStatus=Read-PPJson $backendStatusPath } catch { }
            if ($menuTab -eq 'Backend') {
                if ($workerExited) { Update-PPBackendPage $script:menuWindow.Backend $null $decision.Status }
                else { Update-PPBackendPage $script:menuWindow.Backend $script:backendStatus 'Waiting for the mining controller.' }
            }
            if ($script:backendStatus -and $script:backendStatus.Installed -and $script:backendStatus.Available) {
                $release=$script:backendStatus.Available
                $newVersion=$release.Version
                if ([version]$newVersion -gt [version]$script:backendStatus.Installed.Version -and $newVersion -ne $script:lastNotifiedVersion) {
                    $title='WildRig update available'
                    $message="WildRig $newVersion is available. Click here, then choose Update."
                    $notify.ShowBalloonTip(5000,$title,$message,[Windows.Forms.ToolTipIcon]::Info)
                    $script:lastNotifiedVersion=$newVersion
                }
            }
        }
        $displaySnapshot=Get-PPBackendDisplaySnapshot $script:backendStatus $script:miningRequested $workerExited
        $status = Get-PPTrayStatus $displaySnapshot $decision.Status $temperatureC $workerExited
        Set-PPMenuText $tray.Status $status.Title
        Set-PPMenuText $tray.Detail $status.Detail
        $tone = if ($status.HasIssue) { 'Warning' } elseif ($status.Mining) { 'Accent' } else { 'RailText' }
        $tray.Status.ForeColor = $script:menuColors[$tone]
        if ($detailsItem.Available -ne $status.HasIssue) { $detailsItem.Available = $status.HasIssue }
        if ($retryItem.Available -ne $status.CanRetry) { $retryItem.Available = $status.CanRetry }
        $automaticItem.Text = if ($automaticItem.Checked) { 'Automatic mining · On' } else { 'Automatic mining · Off' }
        $miningAction = if ($manualMining -or $script:miningRequested) { 'Stop mining' } else { 'Mine now' }
        Set-PPMenuText $mineNowItem $miningAction
        $mineNowItem.Enabled = -not $workerExited
        if ($menuTab -eq 'Statistics') {
            Set-PPMenuText $script:menuWindow.Statistics.MineButton $miningAction
            $script:menuWindow.Statistics.MineButton.Enabled = -not $workerExited
            $unavailable = if ($workerExited) { $decision.Status } else { 'Waiting for the mining controller' }
            Update-PPStatisticsPage $script:menuWindow.Statistics $displaySnapshot $script:gpuSnapshot $decision.Status $unavailable
        }
        $tip = 'PearlPilot · ' + $status.Title
        $notify.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
        Start-Sleep -Milliseconds 100
    }
} catch {
    Write-PPLog ('Fatal error: ' + $_.Exception.ToString())
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'PearlPilot stopped', 'OK', 'Error')
} finally {
    try { Stop-PPManagedMiner -Reason 'PearlPilot exited' } catch { Write-PPLog $_.Exception.Message }
    if ($script:menuWindow) { $script:menuWindow.Form.Dispose() }
    Unregister-Event -SourceIdentifier 'PearlPilot.Session' -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier 'PearlPilot.Power' -ErrorAction SilentlyContinue
    $notify.Visible = $false
    $notify.Dispose()
    $menu.Dispose()
    $appIcon.Dispose()
    try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch { }
    Write-PPLog 'PearlPilot stopped.'
}
