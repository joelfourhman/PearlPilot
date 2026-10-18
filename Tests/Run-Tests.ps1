Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
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

$testRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $testRoot
Import-Module (Join-Path $root 'Core\PearlPilot.psm1') -Force

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
    WildRigPath = 'mock.exe'
    Wallet = 'prl1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
    WorkerName = 'test'
    GpuList = '0'
    LockDelayMinutes = 3
    TemperatureLimitC = 82
    AutomaticMining = $automatic
    StartWithWindows = $false
}

Test-Case 'WildRig arguments contain only the lean managed configuration' {
    $arguments = Get-PPMinerArguments -Configuration $configuration -LogPath 'miner.log'
    Assert-True ($arguments -match '--algo pearlhash')
    Assert-True ($arguments -match '--url pool\.pearlhash\.xyz:9000')
    Assert-True ($arguments -match '--worker test')
    Assert-False ($arguments -match '--api-worker-id')
    Assert-True ($arguments -match '--gpu-temp-limit 82')
}

Test-Case 'Mock miner lifecycle uses exact process ownership' {
    $output = Join-Path $testRoot '.test-output'
    if (-not (Test-Path -LiteralPath $output)) { [void](New-Item -ItemType Directory -Path $output) }
    $logPath = Join-Path $output 'mock.log'
    $process = $null
    try {
        $process = Start-PPMiner -Configuration $configuration -LogPath $logPath -MockMinerPath (Join-Path $testRoot 'MockMiner.ps1')
        $started = $process.StartTime.ToUniversalTime()
        Assert-True (Test-PPOwnedProcess -ProcessId $process.Id -StartedUtc $started)
        Stop-PPOwnedProcess -ProcessId $process.Id -StartedUtc $started
        Start-Sleep -Milliseconds 250
        Assert-False ([bool](Get-Process -Id $process.Id -ErrorAction SilentlyContinue))
    } finally {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $output -Recurse -Force -ErrorAction SilentlyContinue
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

Write-Host ''
Write-Host "Result: $passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
