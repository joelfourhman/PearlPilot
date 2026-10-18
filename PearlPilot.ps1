[CmdletBinding()]
param([switch]$Setup)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $appRoot 'Core\PearlPilot.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$dataRoot = Initialize-PPDataRoot
$defaultsPath = Join-Path $appRoot 'Config\defaults.json'
$iconPath = Join-Path $appRoot 'Assets\PearlPilot.ico'
$markerPath = Join-Path $dataRoot 'Runtime\owned-miner.json'
$minerLogPath = Join-Path $dataRoot 'Logs\WildRig.log'
$script:configuration = Get-PPConfiguration -DefaultsPath $defaultsPath
$script:exitRequested = $false
$script:minerPid = $null
$script:minerStartedUtc = $null
$script:sessionState = Get-PPCurrentSessionState
$script:lockedSinceUtc = if ($sessionState -eq 'Locked') { [DateTime]::UtcNow } else { $null }
$script:temperatureC = $null
$script:telemetryAvailable = $false
$script:thermalSafe = $true
$script:lastGpuPollUtc = [DateTime]::MinValue
$script:lastReconcileUtc = [DateTime]::UtcNow
$script:nextStartUtc = [DateTime]::MinValue
$script:crashTimes = @()
$script:blockedForCurrentLock = $false

function Show-PPSettings {
    param([Parameter(Mandatory=$true)][string]$AppRoot)

    $form = New-Object Windows.Forms.Form
    $form.Text = 'PearlPilot Settings'
    $form.Width = 600
    $form.Height = 500
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = [Drawing.Color]::FromArgb(25, 28, 34)
    $form.ForeColor = [Drawing.Color]::White
    $form.Font = New-Object Drawing.Font('Segoe UI', 9)

    $title = New-Object Windows.Forms.Label
    $title.Text = 'Lock → wait → mine. Unlock → stop.'
    $title.Left = 24
    $title.Top = 20
    $title.Width = 540
    $title.Height = 32
    $title.Font = New-Object Drawing.Font('Segoe UI Semibold', 15)
    $form.Controls.Add($title)

    $fieldValues = @(
        @('WildRig executable', [string]$configuration.WildRigPath),
        @('Public PRL wallet', [string]$configuration.Wallet),
        @('Worker name', [string]$configuration.WorkerName),
        @('GPU index', [string]$configuration.GpuList),
        @('Wait after lock (minutes)', [string]$configuration.LockDelayMinutes),
        @('Stop temperature (°C)', [string]$configuration.TemperatureLimitC)
    )
    $fields = @()
    $top = 75
    foreach ($entry in $fieldValues) {
        $label = New-Object Windows.Forms.Label
        $label.Text = $entry[0]
        $label.Left = 24
        $label.Top = $top + 3
        $label.Width = 195

        $box = New-Object Windows.Forms.TextBox
        $box.Text = $entry[1]
        $box.Left = 220
        $box.Top = $top
        $box.Width = 330
        $box.BackColor = [Drawing.Color]::FromArgb(42, 46, 55)
        $box.ForeColor = [Drawing.Color]::White
        $box.BorderStyle = 'FixedSingle'

        $form.Controls.Add($label)
        $form.Controls.Add($box)
        $fields += $box
        $top += 41
    }

    $browse = New-Object Windows.Forms.Button
    $browse.Text = 'Browse…'
    $browse.Left = 475
    $browse.Top = 73
    $browse.Width = 75
    $browse.Height = 26
    $browse.Add_Click({
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Filter = 'WildRig (wildrig*.exe)|wildrig*.exe|Executable files (*.exe)|*.exe'
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            $fields[0].Text = $dialog.FileName
        }
    }.GetNewClosure())
    $form.Controls.Add($browse)
    $fields[0].Width = 245

    $automatic = New-Object Windows.Forms.CheckBox
    $automatic.Text = 'Mine automatically while Windows is locked'
    $automatic.Left = 220
    $automatic.Top = $top
    $automatic.Width = 330
    $automatic.Checked = [bool]$configuration.AutomaticMining
    $form.Controls.Add($automatic)

    $startup = New-Object Windows.Forms.CheckBox
    $startup.Text = 'Start PearlPilot when I sign in'
    $startup.Left = 220
    $startup.Top = $top + 30
    $startup.Width = 330
    $startup.Checked = [bool]$configuration.StartWithWindows
    $form.Controls.Add($startup)

    $note = New-Object Windows.Forms.Label
    $note.Text = 'PearlPilot refuses to mine if it cannot read the lock state or NVIDIA temperature.'
    $note.Left = 24
    $note.Top = $top + 58
    $note.Width = 530
    $note.Height = 34
    $note.ForeColor = [Drawing.Color]::Silver
    $form.Controls.Add($note)

    $save = New-Object Windows.Forms.Button
    $save.Text = 'Save'
    $save.Left = 445
    $save.Top = $top + 96
    $save.Width = 105
    $save.Height = 34
    $save.BackColor = [Drawing.Color]::FromArgb(0, 120, 215)
    $save.FlatStyle = 'Flat'
    $save.ForeColor = [Drawing.Color]::White
    $save.Add_Click({
        try {
            $delay = 0
            $limit = 0
            if (-not [int]::TryParse($fields[4].Text, [ref]$delay)) { throw 'Lock delay must be a whole number.' }
            if (-not [int]::TryParse($fields[5].Text, [ref]$limit)) { throw 'Temperature limit must be a whole number.' }

            $candidate = [pscustomobject][ordered]@{
                Configured = $true
                WildRigPath = $fields[0].Text.Trim()
                Wallet = $fields[1].Text.Trim()
                WorkerName = $fields[2].Text.Trim()
                GpuList = $fields[3].Text.Trim()
                LockDelayMinutes = $delay
                TemperatureLimitC = $limit
                AutomaticMining = $automatic.Checked
                StartWithWindows = $startup.Checked
            }
            $validation = Test-PPConfiguration -Configuration $candidate
            if (-not $validation.Valid) { throw ($validation.Errors -join "`n") }

            Save-PPConfiguration -Configuration $candidate
            if ($candidate.StartWithWindows) { Enable-PPStartup -AppRoot $AppRoot } else { Disable-PPStartup }
            $script:configuration = $candidate
            $form.Tag = $true
            $form.Close()
        } catch {
            [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot save settings', 'OK', 'Error')
        }
    }.GetNewClosure())
    $form.Controls.Add($save)

    [void]$form.ShowDialog()
    [bool]$form.Tag
}

function Save-PPMinerMarker {
    [pscustomobject]@{
        ProcessId = $script:minerPid
        StartedUtc = $script:minerStartedUtc.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding UTF8
}

function Clear-PPMinerMarker {
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
}

function Test-PPMinerRunning {
    if (-not $script:minerPid -or -not $script:minerStartedUtc) { return $false }
    Test-PPOwnedProcess -ProcessId $script:minerPid -StartedUtc $script:minerStartedUtc
}

function Start-PPManagedMiner {
    if (Test-PPOtherMinerRunning -ExecutablePath ([string]$configuration.WildRigPath) -OwnedProcessId $null) {
        throw 'WildRig is already running outside PearlPilot.'
    }
    $process = Start-PPMiner -Configuration $configuration -LogPath $minerLogPath
    $script:minerPid = $process.Id
    $script:minerStartedUtc = $process.StartTime.ToUniversalTime()
    Save-PPMinerMarker
    Write-PPLog "Started WildRig PID $minerPid."
}

function Stop-PPManagedMiner {
    param([string]$Reason)
    if ($script:minerPid -and $script:minerStartedUtc) {
        Stop-PPOwnedProcess -ProcessId $script:minerPid -StartedUtc $script:minerStartedUtc
        Write-PPLog "Stopped WildRig: $Reason"
    }
    $script:minerPid = $null
    $script:minerStartedUtc = $null
    Clear-PPMinerMarker
}

function Restore-PPManagedMiner {
    if (-not (Test-Path -LiteralPath $markerPath)) { return }
    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        $started = [DateTime]::Parse([string]$marker.StartedUtc).ToUniversalTime()
        if (Test-PPOwnedProcess -ProcessId ([int]$marker.ProcessId) -StartedUtc $started) {
            $script:minerPid = [int]$marker.ProcessId
            $script:minerStartedUtc = $started
            Write-PPLog "Reattached to WildRig PID $minerPid."
        } else {
            Clear-PPMinerMarker
        }
    } catch {
        Clear-PPMinerMarker
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
        $script:blockedForCurrentLock = $false
        $script:crashTimes = @()
    }
    Write-PPLog "Session is $State ($Reason)."
}

$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -replace '[^A-Za-z0-9]', '-'
$created = $false
$mutex = New-Object Threading.Mutex($true, "Local\PearlPilot-$sid", [ref]$created)
if (-not $created) { exit 0 }

if ($Setup -or -not [bool]$configuration.Configured) {
    if (-not (Show-PPSettings -AppRoot $appRoot)) {
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

$menu = New-Object Windows.Forms.ContextMenuStrip
$statusItem = New-Object Windows.Forms.ToolStripMenuItem 'Status: starting'
$statusItem.Enabled = $false
[void]$menu.Items.Add($statusItem)
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))

$automaticItem = New-Object Windows.Forms.ToolStripMenuItem 'Automatic mining'
$automaticItem.Checked = [bool]$configuration.AutomaticMining
$automaticItem.Add_Click({
    $script:configuration.AutomaticMining = -not [bool]$configuration.AutomaticMining
    $automaticItem.Checked = [bool]$configuration.AutomaticMining
    Save-PPConfiguration -Configuration $configuration
})
[void]$menu.Items.Add($automaticItem)

$settingsItem = New-Object Windows.Forms.ToolStripMenuItem 'Settings…'
$settingsItem.Add_Click({
    if (Show-PPSettings -AppRoot $appRoot) {
        Stop-PPManagedMiner -Reason 'Settings changed'
        $script:lockedSinceUtc = if ($sessionState -eq 'Locked') { [DateTime]::UtcNow } else { $null }
        $automaticItem.Checked = [bool]$configuration.AutomaticMining
    }
})
[void]$menu.Items.Add($settingsItem)

$logsItem = New-Object Windows.Forms.ToolStripMenuItem 'Open logs'
$logsItem.Add_Click({ Start-Process explorer.exe -ArgumentList (Join-Path $dataRoot 'Logs') })
[void]$menu.Items.Add($logsItem)
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))

$exitItem = New-Object Windows.Forms.ToolStripMenuItem 'Exit PearlPilot'
$exitItem.Add_Click({ $script:exitRequested = $true })
[void]$menu.Items.Add($exitItem)

$notify.ContextMenuStrip = $menu
$notify.Add_DoubleClick({ $settingsItem.PerformClick() })

try {
    Register-ObjectEvent `
        -InputObject ([Microsoft.Win32.SystemEvents]) `
        -EventName SessionSwitch `
        -SourceIdentifier 'PearlPilot.Session' | Out-Null
    Register-ObjectEvent `
        -InputObject ([Microsoft.Win32.SystemEvents]) `
        -EventName PowerModeChanged `
        -SourceIdentifier 'PearlPilot.Power' | Out-Null
    Restore-PPManagedMiner
    Write-PPLog 'PearlPilot started.'

    while (-not $exitRequested) {
        [Windows.Forms.Application]::DoEvents()

        foreach ($event in @(Get-Event -SourceIdentifier 'PearlPilot.Session' -ErrorAction SilentlyContinue)) {
            $reason = [string]$event.SourceEventArgs.Reason
            if ($reason -eq 'SessionLock') { Set-PPSessionState -State Locked -Reason $reason }
            if ($reason -eq 'SessionUnlock') { Set-PPSessionState -State Unlocked -Reason $reason }
            Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
        }
        foreach ($event in @(Get-Event -SourceIdentifier 'PearlPilot.Power' -ErrorAction SilentlyContinue)) {
            $mode = [string]$event.SourceEventArgs.Mode
            if ($mode -eq 'Suspend') { Set-PPSessionState -State Unknown -Reason Suspend }
            if ($mode -eq 'Resume') { Set-PPSessionState -State (Get-PPCurrentSessionState) -Reason Resume }
            Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
        }

        $now = [DateTime]::UtcNow
        if (($now - $lastReconcileUtc).TotalSeconds -ge 30) {
            Set-PPSessionState -State (Get-PPCurrentSessionState) -Reason Reconciliation
            $script:lastReconcileUtc = $now
        }

        if (($now - $lastGpuPollUtc).TotalSeconds -ge 10) {
            $gpu = Get-PPGpuTemperature -GpuList ([string]$configuration.GpuList)
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
            -TelemetryAvailable $telemetryAvailable `
            -ThermalSafe $thermalSafe
        if ($blockedForCurrentLock) {
            $decision = [pscustomobject]@{ ShouldMine=$false; Status='Stopped after repeated crashes' }
        }

        $running = Test-PPMinerRunning
        if ($script:minerPid -and -not $running) {
            Write-PPLog 'WildRig exited unexpectedly.'
            $script:minerPid = $null
            $script:minerStartedUtc = $null
            Clear-PPMinerMarker
            $script:crashTimes = @($crashTimes | Where-Object { $_ -ge $now.AddHours(-1) }) + $now
            if ($crashTimes.Count -gt 5) {
                $script:blockedForCurrentLock = $true
            } else {
                $script:nextStartUtc = $now.AddSeconds(10)
            }
        } elseif ($running -and -not $decision.ShouldMine) {
            Stop-PPManagedMiner -Reason $decision.Status
            $running = $false
        } elseif (-not $running -and $decision.ShouldMine -and $now -ge $nextStartUtc) {
            try {
                Start-PPManagedMiner
                $running = $true
            } catch {
                Write-PPLog ('Could not start WildRig: ' + $_.Exception.Message)
                $decision = [pscustomobject]@{ ShouldMine=$false; Status=$_.Exception.Message }
                $script:nextStartUtc = $now.AddSeconds(10)
            }
        }

        $displayStatus = if ($running) { 'Mining' } else { [string]$decision.Status }
        if ($temperatureC -ne $null) { $displayStatus += " · $temperatureC°C" }
        $statusItem.Text = 'Status: ' + $displayStatus
        $tip = 'PearlPilot: ' + $displayStatus
        $notify.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
        Start-Sleep -Milliseconds 100
    }
} catch {
    Write-PPLog ('Fatal error: ' + $_.Exception.ToString())
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'PearlPilot stopped', 'OK', 'Error')
} finally {
    Stop-PPManagedMiner -Reason 'PearlPilot exited'
    Unregister-Event -SourceIdentifier 'PearlPilot.Session' -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier 'PearlPilot.Power' -ErrorAction SilentlyContinue
    $notify.Visible = $false
    $notify.Dispose()
    $appIcon.Dispose()
    try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch { }
    Write-PPLog 'PearlPilot stopped.'
}
