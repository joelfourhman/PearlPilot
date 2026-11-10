Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Backend.psm1') -Force

function Get-PPDataRoot {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PearlPilot'
}

function Initialize-PPDataRoot {
    param([string]$DataRoot=(Get-PPDataRoot))
    $root = [IO.Path]::GetFullPath($DataRoot)
    foreach ($directory in @($root, (Join-Path $root 'Logs'), (Join-Path $root 'Runtime'))) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $root
}

function Get-PPWindowsPowerShellPath {
    $command = Get-Command powershell.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    if (-not $command.Source -or -not (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
        throw 'Windows PowerShell 5.1 was not found.'
    }
    $command.Source
}

function Get-PPWindowsScriptHostPath {
    $path = Join-Path $env:SystemRoot 'System32\wscript.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Windows Script Host was not found.'
    }
    $path
}

function Get-PPConfiguration {
    param([string]$DataRoot=(Get-PPDataRoot))

    $root = Initialize-PPDataRoot -DataRoot $DataRoot
    $configPath = Join-Path $root 'config.json'
    $configuration = [pscustomobject]@{
        Configured = $false
        Wallet = ''
        WorkerName = 'pearlpilot'
        GpuList = '0'
        LockDelayMinutes = 3
        TemperatureLimitC = 82
        IdleMinutes = 0
        GamingProcesses = ''
        AutomaticMining = $true
        AutomaticUpdates = $false
        StartWithWindows = $true
        PoolUrl = 'pool.pearlhash.xyz:9000'
        PearlHashKernel = '2'
        GpuIntensity = ''
        UserStopped = $false
    }

    if (Test-Path -LiteralPath $configPath) {
        try {
            $saved = Read-PPJson $configPath
            foreach ($property in $saved.PSObject.Properties.Name) {
                $configuration | Add-Member NoteProperty $property $saved.$property -Force
            }
        } catch { throw "Cannot read saved settings at $configPath. Repair or restore this file before starting PearlPilot. $($_.Exception.Message)" }
    }

    # Migrate legacy Native/Auto preferences to the isolated backend. Preserve the
    # old executable path for process detection, but never launch it.
    $configuration | Add-Member NoteProperty Backend 'Docker' -Force
    $configuration
}

function Save-PPConfiguration {
    param([Parameter(Mandatory=$true)]$Configuration, [string]$DataRoot=(Get-PPDataRoot))

    $root = Initialize-PPDataRoot -DataRoot $DataRoot
    $path = Join-Path $root 'config.json'
    Write-PPJson $path $Configuration
}

function Write-PPLog {
    param([Parameter(Mandatory=$true)][string]$Message, [string]$DataRoot=(Get-PPDataRoot))

    $path = Join-Path $DataRoot 'Logs\PearlPilot.log'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 2MB) {
        Move-Item -LiteralPath $path -Destination "$path.old" -Force
    }
    Add-Content -LiteralPath $path -Value ('{0:o} {1}' -f [DateTime]::UtcNow, $Message) -Encoding UTF8
}

function Find-PPNvidiaSmi {
    $candidates = @()
    if ($env:ProgramFiles) {
        $candidates += Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'
    }
    $command = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $command) { $command=Get-Command nvidia-smi -ErrorAction SilentlyContinue }
    if ($command) { $candidates += $command.Source }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $null
}

function Test-PPConfiguration {
    param([Parameter(Mandatory=$true)]$Configuration, [switch]$AllowMissingTelemetry)

    $errors = @()
    # Installation readiness is diagnosed separately; no native binary is needed.
    if ([string]$Configuration.Wallet -notmatch '^prl1[0-9a-z]{20,}$') {
        $errors += 'Enter a valid-looking public PRL wallet beginning with prl1.'
    }
    if ([string]$Configuration.WorkerName -notmatch '^[A-Za-z0-9._-]{1,32}$') {
        $errors += 'Worker name must be 1-32 letters, numbers, dots, underscores, or hyphens.'
    }
    if ([string]$Configuration.GpuList -notmatch '^\d+(,\d+)*$') {
        $errors += 'GPU index must be one or more comma-separated numbers.'
    }
    if ([int]$Configuration.LockDelayMinutes -lt 0 -or [int]$Configuration.LockDelayMinutes -gt 60) {
        $errors += 'The lock delay must be between 0 and 60 minutes.'
    }
    if ([int]$Configuration.TemperatureLimitC -lt 50 -or [int]$Configuration.TemperatureLimitC -gt 95) {
        $errors += 'The temperature limit must be between 50 and 95 °C.'
    }
    if ($Configuration.PSObject.Properties['Backend']) {
        if ($Configuration.Backend -notin @('Auto','Docker')) { $errors += 'Only the isolated Docker backend is supported.' }
        if ([int]$Configuration.IdleMinutes -lt 0 -or [int]$Configuration.IdleMinutes -gt 120) { $errors += 'Idle minutes must be 0 (disabled) through 120.' }
        if ($Configuration.GamingProcesses -and $Configuration.GamingProcesses -notmatch '^[A-Za-z0-9_. -]+(,[A-Za-z0-9_. -]+)*$') { $errors += 'Gaming processes must be comma-separated process names.' }
        try { [void](Get-PPMiningArgv $Configuration) } catch { $errors += $_.Exception.Message }
    }
    if (-not $AllowMissingTelemetry -and -not (Find-PPNvidiaSmi)) {
        $errors += 'nvidia-smi.exe was not found; thermal safety cannot be enforced.'
    }

    [pscustomobject]@{ Valid=($errors.Count -eq 0); Errors=$errors }
}

function Get-PPCurrentSessionState {
    try {
        $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        $logonUi = @(Get-Process -Name LogonUI -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })
        if ($logonUi.Count -gt 0) { return 'Locked' }

        $explorer = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })
        if ($explorer.Count -gt 0 -and [Environment]::UserInteractive) { return 'Unlocked' }
    } catch { }
    'Unknown'
}

function Get-PPMiningDecision {
    param(
        [ValidateSet('Locked','Unlocked','Unknown')][string]$SessionState,
        [Nullable[DateTime]]$LockedSinceUtc,
        [DateTime]$NowUtc = [DateTime]::UtcNow,
        [int]$DelayMinutes = 3,
        [bool]$AutomaticMining = $true,
        [bool]$ManualMining = $false,
        [bool]$TelemetryAvailable = $true,
        [bool]$ThermalSafe = $true,
        [int]$IdleMinutes = 0,
        [double]$IdleSeconds = 0,
        [bool]$WorkloadBlocked = $false,
        [bool]$Suspended = $false
    )

    if ($Suspended) { return [pscustomobject]@{ ShouldMine=$false; Status='Windows suspended' } }
    if ($WorkloadBlocked) { return [pscustomobject]@{ ShouldMine=$false; Status='Gaming / configured GPU application active' } }
    if ($ManualMining) {
        if (-not $TelemetryAvailable) { return [pscustomobject]@{ ShouldMine=$false; Status='GPU telemetry unavailable' } }
        if (-not $ThermalSafe) { return [pscustomobject]@{ ShouldMine=$false; Status='Cooling down' } }
        return [pscustomobject]@{ ShouldMine=$true; Status='Manual mining' }
    }
    if (-not $AutomaticMining) { return [pscustomobject]@{ ShouldMine=$false; Status='Disabled' } }
    if (-not $TelemetryAvailable) { return [pscustomobject]@{ ShouldMine=$false; Status='GPU telemetry unavailable' } }
    if (-not $ThermalSafe) { return [pscustomobject]@{ ShouldMine=$false; Status='Cooling down' } }
    if ($SessionState -eq 'Unknown') { return [pscustomobject]@{ ShouldMine=$false; Status='Session state unknown' } }
    if ($SessionState -eq 'Unlocked') {
        if ($IdleMinutes -gt 0 -and $IdleSeconds -ge $IdleMinutes*60) { return [pscustomobject]@{ ShouldMine=$true; Status='Idle policy mining' } }
        return [pscustomobject]@{ ShouldMine=$false; Status='Idle' }
    }
    if ($null -eq $LockedSinceUtc) { return [pscustomobject]@{ ShouldMine=$false; Status='Waiting for lock time' } }

    $remaining = [Math]::Ceiling(($LockedSinceUtc.ToUniversalTime().AddMinutes($DelayMinutes) - $NowUtc.ToUniversalTime()).TotalSeconds)
    if ($remaining -gt 0) {
        $countdown = 'Locked · starts in {0}:{1:00}' -f [Math]::Floor($remaining / 60), ($remaining % 60)
        return [pscustomobject]@{ ShouldMine=$false; Status=$countdown }
    }
    [pscustomobject]@{ ShouldMine=$true; Status='Mining' }
}

function Test-PPOwnedProcess {
    param([int]$ProcessId, [DateTime]$StartedUtc)
    if (-not $ProcessId) { return $false }
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        ([Math]::Abs(($process.StartTime.ToUniversalTime() - $StartedUtc.ToUniversalTime()).TotalSeconds) -le 2)
    } catch { $false }
}

function Stop-PPOwnedProcess {
    param([int]$ProcessId, [DateTime]$StartedUtc)
    if (-not (Test-PPOwnedProcess -ProcessId $ProcessId -StartedUtc $StartedUtc)) { return $false }

    try { (Get-Process -Id $ProcessId).CloseMainWindow() | Out-Null } catch { }
    try { Wait-Process -Id $ProcessId -Timeout 1 -ErrorAction SilentlyContinue } catch { }
    if (-not (Test-PPOwnedProcess -ProcessId $ProcessId -StartedUtc $StartedUtc)) { return $true }

    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $process.Kill()
    if (-not $process.WaitForExit(5000)) {
        throw "Process $ProcessId did not stop."
    }
    $process.Dispose()
    $true
}

# Compatibility cleanup only; no native process can be launched by PearlPilot.
function Stop-PPLegacyMiner {
    param([string]$DataRoot)
    $marker=Join-Path $DataRoot 'Runtime\owned-miner.json'
    if (-not (Test-Path -LiteralPath $marker)) {return}
    $owned=Read-PPJson $marker
    [void](Stop-PPOwnedProcess -ProcessId ([int]$owned.ProcessId) -StartedUtc ([DateTime]::Parse($owned.StartedUtc)))
    Remove-Item -LiteralPath $marker -Force
}

function Test-PPOtherMinerRunning {
    param([string]$ExecutablePath, [Nullable[int]]$OwnedProcessId)
    if (-not $ExecutablePath) { return $false }
    $expected = [IO.Path]::GetFullPath($ExecutablePath)
    $expectedName = [IO.Path]::GetFileNameWithoutExtension($expected)
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($OwnedProcessId -and $process.Id -eq $OwnedProcessId.Value) { continue }
        try {
            if ($process.Path -and [IO.Path]::GetFullPath($process.Path) -eq $expected) { return $true }
        } catch { }
        if ($process.ProcessName -eq $expectedName) { return $true }
    }
    $false
}

function Get-PPGpuTemperature {
    param([string]$GpuList = '0')

    $path = Find-PPNvidiaSmi
    if (-not $path) { return [pscustomobject]@{ Available=$false; TemperatureC=$null } }
    try {
        $result = Invoke-PPCommand $path @('--query-gpu=index,name,driver_version,temperature.gpu,utilization.gpu,power.draw','--format=csv,noheader,nounits') 5
        if ($result.ExitCode -ne 0) { throw 'nvidia-smi failed.' }
        $selected = @($GpuList -split ',' | ForEach-Object { $_.Trim() })
        $temperatures = @()
        $gpus = @()
        foreach ($line in @($result.Output -split "`r?`n")) {
            $parts = @($line -split ',' | ForEach-Object { $_.Trim() })
            if ($parts.Count -eq 6 -and $selected -contains $parts[0]) {
                $value = 0.0
                if ([double]::TryParse($parts[3],[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$value)) { $temperatures += $value }
                $util=$null; $power=$null; $parsed=0.0
                if ([double]::TryParse($parts[4],[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)) { $util=$parsed }
                if ([double]::TryParse($parts[5],[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)) { $power=$parsed }
                $gpus += [pscustomobject]@{ Index=$parts[0]; Name=$parts[1]; Driver=$parts[2]; Utilization=$util; PowerWatts=$power }
            }
        }
        if ($temperatures.Count -ne $selected.Count) { throw 'Temperature unavailable for one or more configured GPUs.' }
        [pscustomobject]@{ Available=$true; TemperatureC=($temperatures | Measure-Object -Maximum).Maximum; Gpus=$gpus }
    } catch {
        [pscustomobject]@{ Available=$false; TemperatureC=$null }
    }
}

function Get-PPIdleSeconds {
    if (-not ('PearlPilot.Input' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PearlPilot {
 public static class Input {
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint size; public uint time; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
  public static double Idle() {
   var info = new LASTINPUTINFO(); info.size = (uint)Marshal.SizeOf(info);
   if (!GetLastInputInfo(ref info)) return 0;
   return unchecked((uint)Environment.TickCount - info.time) / 1000.0;
  }
 }
}
'@
    }
    [PearlPilot.Input]::Idle()
}

function Test-PPGamingProcess {
    param([string]$Names)
    foreach ($name in @($Names -split ',')) {
        $trimmed = $name.Trim() -replace '\.exe$',''
        if ($trimmed -and (Get-Process -Name $trimmed -ErrorAction SilentlyContinue)) { return $true }
    }
    $false
}

function Get-PPStartupTaskName {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -replace '[^A-Za-z0-9-]', '-'
    "PearlPilot-$sid"
}

function Enable-PPStartup {
    param([Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$AppRoot)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $launcherPath = Join-Path $AppRoot 'RunPearlPilot.vbs'
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw "PearlPilot is incomplete; missing $launcherPath"
    }
    $arguments = ConvertTo-PPArgument $launcherPath
    $action = New-ScheduledTaskAction -Execute (Get-PPWindowsScriptHostPath) -Argument $arguments -WorkingDirectory $AppRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    Register-ScheduledTask `
        -TaskName (Get-PPStartupTaskName) `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Start PearlPilot after sign-in' `
        -Force | Out-Null
}

function Disable-PPStartup {
    Unregister-ScheduledTask -TaskName (Get-PPStartupTaskName) -Confirm:$false -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function *-PP*
