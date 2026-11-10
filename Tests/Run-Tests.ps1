[CmdletBinding()]
param([switch]$SkipTests)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$testRoot = $PSScriptRoot
$root = Split-Path -Parent $testRoot

# Parse project sources without scanning local downloads or test output.
$sources = @(Get-ChildItem -LiteralPath $root -File -Filter '*.ps1')
foreach ($directory in @('Core','Tests')) {
    $sources += @(Get-ChildItem -LiteralPath (Join-Path $root $directory) -File |
        Where-Object { $_.Extension -in @('.ps1','.psm1') })
}
$errors = foreach ($source in $sources) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($source.FullName,[ref]$tokens,[ref]$parseErrors)
    $parseErrors
}
if ($errors) {
    $errors | Format-List
    throw "$(@($errors).Count) PowerShell syntax errors."
}
Write-Host ('Parsed {0} project source files without errors.' -f $sources.Count)

Import-Module (Join-Path $root 'Core\PearlPilot.psm1') -Force
if ($SkipTests) { return }

$script:passed = 0
$script:failed = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:passed++
        Write-Host "PASS  $Name" -ForegroundColor Green
    } catch {
        $script:failed++
        Write-Host "FAIL  $Name — $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message='Expected true.')
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([bool]$Condition, [string]$Message='Expected false.')
    if ($Condition) { throw $Message }
}

$automatic = $true
$now = [DateTime]::UtcNow

Test-Case 'Unlocked workstations never mine' {
    $decision = Get-PPMiningDecision -SessionState Unlocked -LockedSinceUtc $null -NowUtc $now
    Assert-False $decision.ShouldMine
}

Test-Case 'A new lock waits for the configured delay' {
    $decision = Get-PPMiningDecision -SessionState Locked -LockedSinceUtc $now -NowUtc $now -DelayMinutes 3
    Assert-False $decision.ShouldMine
    Assert-True ($decision.Status -match 'starts in')
}

Test-Case 'A sustained lock permits mining' {
    $decision = Get-PPMiningDecision -SessionState Locked -LockedSinceUtc $now.AddMinutes(-3) -NowUtc $now -DelayMinutes 3
    Assert-True $decision.ShouldMine
}

Test-Case 'Manual mining overrides the unlocked state' {
    $decision = Get-PPMiningDecision -SessionState Unlocked -LockedSinceUtc $null -NowUtc $now -AutomaticMining $false -ManualMining $true
    Assert-True $decision.ShouldMine
    Assert-True ($decision.Status -eq 'Manual mining')
}

Test-Case 'Manual mining still fails closed without telemetry' {
    $decision = Get-PPMiningDecision -SessionState Unlocked -LockedSinceUtc $null -NowUtc $now -ManualMining $true -TelemetryAvailable $false
    Assert-False $decision.ShouldMine
}

Test-Case 'Manual mining still obeys thermal protection' {
    $decision = Get-PPMiningDecision -SessionState Unlocked -LockedSinceUtc $null -NowUtc $now -ManualMining $true -ThermalSafe $false
    Assert-False $decision.ShouldMine
}

Test-Case 'Missing GPU telemetry fails closed' {
    $decision = Get-PPMiningDecision -SessionState Locked -LockedSinceUtc $now.AddMinutes(-3) -NowUtc $now -TelemetryAvailable $false
    Assert-False $decision.ShouldMine
}

Test-Case 'Thermal protection stops mining' {
    $decision = Get-PPMiningDecision -SessionState Locked -LockedSinceUtc $now.AddMinutes(-3) -NowUtc $now -ThermalSafe $false
    Assert-False $decision.ShouldMine
}

$configuration = [pscustomobject]@{
    Configured = $true
    Backend = 'Docker'
    PoolUrl = 'pool.pearlhash.xyz:9000'
    WildRigVersion = '0.51.8'
    PearlHashKernel = '2'
    GpuIntensity = ''
    IdleMinutes = 0
    GamingProcesses = ''
    Wallet = 'prl1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
    WorkerName = 'test'
    GpuList = '0'
    LockDelayMinutes = 3
    TemperatureLimitC = 82
    AutomaticMining = $automatic
    StartWithWindows = $false
}

Test-Case 'WildRig arguments contain only the lean managed configuration' {
    $arguments = @(Get-PPMiningArgv $configuration)
    Assert-True ($arguments[$arguments.IndexOf('--algo')+1] -eq 'pearlhash')
    Assert-True ($arguments[$arguments.IndexOf('--pearlhash-kernel')+1] -eq '2')
    Assert-True ($arguments[$arguments.IndexOf('--url')+1] -eq $configuration.PoolUrl)
    Assert-True ($arguments[$arguments.IndexOf('--worker')+1] -eq 'test')
    Assert-False ($arguments -contains '--api-worker-id')
    Assert-True ($arguments[$arguments.IndexOf('--gpu-temp-limit')+1] -eq '82')
}

Test-Case 'Configuration accepts a safe worker and GPU list' {
    $validation = Test-PPConfiguration -Configuration $configuration -AllowMissingTelemetry
    Assert-True $validation.Valid ($validation.Errors -join '; ')
}

Test-Case 'Configuration rejects unsafe worker names' {
    $candidate = $configuration | ConvertTo-Json | ConvertFrom-Json
    $candidate.WorkerName = 'worker name & command'
    $validation = Test-PPConfiguration -Configuration $candidate -AllowMissingTelemetry
    Assert-False $validation.Valid
}

Test-Case 'Configuration rejects malformed GPU lists' {
    $candidate = $configuration | ConvertTo-Json | ConvertFrom-Json
    $candidate.GpuList = '0, one'
    $validation = Test-PPConfiguration -Configuration $candidate -AllowMissingTelemetry
    Assert-False $validation.Valid
}

Test-Case 'Windows PowerShell launcher is available' {
    $path = Get-PPWindowsPowerShellPath
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf)
    Assert-True ([IO.Path]::GetFileName($path) -eq 'powershell.exe')
}

Test-Case 'Hidden launcher uses Windows Script Host without a visible window' {
    $hostPath = Get-PPWindowsScriptHostPath
    Assert-True (Test-Path -LiteralPath $hostPath -PathType Leaf)
    Assert-True ([IO.Path]::GetFileName($hostPath) -eq 'wscript.exe')

    $launcherPath = Join-Path $root 'RunPearlPilot.vbs'
    Assert-True (Test-Path -LiteralPath $launcherPath -PathType Leaf)
    $launcher = Get-Content -LiteralPath $launcherPath -Raw
    Assert-True ($launcher -match 'shell\.Run\(command, 0, True\)')
}

Test-Case 'Duplicate process detection catches the configured executable' {
    $currentProcess = Get-Process -Id $PID
    Assert-True (Test-PPOtherMinerRunning -ExecutablePath $currentProcess.Path -OwnedProcessId $null)
}

Test-Case 'Process ownership refuses a mismatched start time and stops the owned process' {
    $process = $null
    try {
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=Get-PPWindowsPowerShellPath
        $start.Arguments='-NoProfile -Command "Start-Sleep -Seconds 60"'
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $process=[Diagnostics.Process]::Start($start)
        $started = $process.StartTime.ToUniversalTime()
        Assert-False (Stop-PPOwnedProcess -ProcessId $process.Id -StartedUtc $started.AddMinutes(-1))
        Assert-True (Test-PPOwnedProcess -ProcessId $process.Id -StartedUtc $started)
        Assert-True (Stop-PPOwnedProcess -ProcessId $process.Id -StartedUtc $started)
        Start-Sleep -Milliseconds 250
        Assert-False ([bool](Get-Process -Id $process.Id -ErrorAction SilentlyContinue))
    } finally {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        if ($process) {$process.Dispose()}
    }
}

Test-Case 'Startup task identity is stable and user scoped' {
    $first = Get-PPStartupTaskName
    $second = Get-PPStartupTaskName
    Assert-True ($first -eq $second)
    Assert-True ($first -like 'PearlPilot-S-*')
}

Test-Case 'Tray icon is a valid Windows icon' {
    Add-Type -AssemblyName System.Drawing
    $iconPath = Join-Path $root 'Assets\PearlPilot.ico'
    Assert-True (Test-Path -LiteralPath $iconPath -PathType Leaf)
    $icon = New-Object Drawing.Icon($iconPath)
    try {
        Assert-True ($icon.Width -ge 16)
        Assert-True ($icon.Height -ge 16)
    } finally {
        $icon.Dispose()
    }
}

Test-Case 'Project documentation has one README entry point' {
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'README.md'))
    Assert-False (Test-Path -LiteralPath (Join-Path $root 'docs\docker-backend.md'))
    Assert-False (Test-Path -LiteralPath (Join-Path $root 'docs\security.md'))
}

Test-Case 'Local tools and miner binaries stay outside Git' {
    $ignore = Get-Content -LiteralPath (Join-Path $root '.gitignore')
    Assert-True ($ignore -contains '.local/')
}
Test-Case 'Uninstall WhatIf previews deletion without touching the running application' {
    $result=Invoke-PPCommand (Get-PPWindowsPowerShellPath) @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'Uninstall.ps1'),'-DeleteUserData','-WhatIf')
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'Stop PearlPilot') $result.Error
}

Write-Host ''
. (Join-Path $testRoot 'Backend.Tests.ps1')
Write-Host "Result: $passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
