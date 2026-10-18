Set-StrictMode -Version 2.0

function Get-PPDataRoot {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PearlPilot'
}

function Initialize-PPDataRoot {
    $root = Get-PPDataRoot
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
    param([Parameter(Mandatory=$true)][string]$DefaultsPath)

    $root = Initialize-PPDataRoot
    $configPath = Join-Path $root 'config.json'
    $configuration = Get-Content -LiteralPath $DefaultsPath -Raw | ConvertFrom-Json

    if (Test-Path -LiteralPath $configPath) {
        try {
            $saved = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            foreach ($property in $configuration.PSObject.Properties.Name) {
                if ($saved.PSObject.Properties[$property]) {
                    $configuration.$property = $saved.$property
                }
            }
        } catch { }
    }

    $configuration
}

function Save-PPConfiguration {
    param([Parameter(Mandatory=$true)]$Configuration)

    $root = Initialize-PPDataRoot
    $path = Join-Path $root 'config.json'
    $temporary = "$path.tmp"
    $Configuration | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Write-PPLog {
    param([Parameter(Mandatory=$true)][string]$Message)

    $path = Join-Path (Initialize-PPDataRoot) 'Logs\PearlPilot.log'
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
    if ($command) { $candidates += $command.Source }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $null
}

function Get-PPGpuPowerLimit {
    param([Parameter(Mandatory=$true)][ValidateRange(0, 128)][int]$GpuIndex)

    $nvidiaSmi = Find-PPNvidiaSmi
    if (-not $nvidiaSmi) { throw 'nvidia-smi.exe was not found.' }

    $query = 'index,power.limit,power.default_limit,power.min_limit,power.max_limit'
    $output = @(& $nvidiaSmi "--id=$GpuIndex" "--query-gpu=$query" '--format=csv,noheader,nounits' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read GPU $GpuIndex power limits: $($output -join ' ')"
    }

    $row = @($output | Where-Object { [string]$_ -match '^\s*\d+\s*,' } | Select-Object -First 1)
    if ($row.Count -ne 1) { throw "GPU $GpuIndex did not return usable power-limit data." }

    $columns = @(([string]$row[0]).Split(',') | ForEach-Object { $_.Trim() })
    if ($columns.Count -ne 5 -or [int]$columns[0] -ne $GpuIndex) {
        throw "GPU $GpuIndex returned unexpected power-limit data."
    }

    $values = @()
    foreach ($column in $columns[1..4]) {
        $value = 0.0
        if (-not [double]::TryParse(
            $column,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$value
        )) {
            throw "GPU $GpuIndex returned an unsupported power-limit value."
        }
        $values += $value
    }

    [pscustomobject]@{
        GpuIndex = $GpuIndex
        CurrentLimitW = $values[0]
        DefaultLimitW = $values[1]
        MinimumLimitW = $values[2]
        MaximumLimitW = $values[3]
    }
}

function Get-PPPowerLimitTarget {
    param(
        [Parameter(Mandatory=$true)][double]$DefaultLimitW,
        [Parameter(Mandatory=$true)][double]$MinimumLimitW,
        [Parameter(Mandatory=$true)][double]$MaximumLimitW,
        [Parameter(Mandatory=$true)][ValidateRange(1, 100)][int]$Percent
    )

    if ($MinimumLimitW -gt $MaximumLimitW) { throw 'The GPU power-limit range is invalid.' }
    $requested = [Math]::Round($DefaultLimitW * ($Percent / 100.0), 0, [MidpointRounding]::AwayFromZero)
    [Math]::Min($MaximumLimitW, [Math]::Max($MinimumLimitW, $requested))
}

function Set-PPGpuPowerLimit {
    param(
        [Parameter(Mandatory=$true)][ValidateRange(0, 128)][int]$GpuIndex,
        [Parameter(Mandatory=$true)][ValidateRange(1, 2000)][double]$LimitW
    )

    $nvidiaSmi = Find-PPNvidiaSmi
    if (-not $nvidiaSmi) { throw 'nvidia-smi.exe was not found.' }

    $limit = $LimitW.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
    try {
        $process = Start-Process `
            -FilePath $nvidiaSmi `
            -ArgumentList @("--id=$GpuIndex", "--power-limit=$limit") `
            -Verb RunAs `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
    } catch [ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -eq 1223) {
            throw 'Administrator approval was canceled; the GPU power limit was not changed.'
        }
        throw
    }

    if ($process.ExitCode -ne 0) {
        throw "NVIDIA rejected the $limit W power limit for GPU $GpuIndex."
    }
}

function Test-PPConfiguration {
    param([Parameter(Mandatory=$true)]$Configuration, [switch]$AllowMissingMiner, [switch]$AllowMissingTelemetry)

    $errors = @()
    if (-not $Configuration.WildRigPath) {
        $errors += 'Choose the WildRig executable.'
    } elseif (-not $AllowMissingMiner -and -not (Test-Path -LiteralPath $Configuration.WildRigPath -PathType Leaf)) {
        $errors += 'The WildRig executable was not found.'
    }
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
        [bool]$ThermalSafe = $true
    )

    if ($ManualMining) {
        if (-not $TelemetryAvailable) { return [pscustomobject]@{ ShouldMine=$false; Status='GPU telemetry unavailable' } }
        if (-not $ThermalSafe) { return [pscustomobject]@{ ShouldMine=$false; Status='Cooling down' } }
        return [pscustomobject]@{ ShouldMine=$true; Status='Manual mining' }
    }
    if (-not $AutomaticMining) { return [pscustomobject]@{ ShouldMine=$false; Status='Disabled' } }
    if (-not $TelemetryAvailable) { return [pscustomobject]@{ ShouldMine=$false; Status='GPU telemetry unavailable' } }
    if (-not $ThermalSafe) { return [pscustomobject]@{ ShouldMine=$false; Status='Cooling down' } }
    if ($SessionState -eq 'Unknown') { return [pscustomobject]@{ ShouldMine=$false; Status='Session state unknown' } }
    if ($SessionState -eq 'Unlocked') { return [pscustomobject]@{ ShouldMine=$false; Status='Idle' } }
    if ($null -eq $LockedSinceUtc) { return [pscustomobject]@{ ShouldMine=$false; Status='Waiting for lock time' } }

    $remaining = [Math]::Ceiling(($LockedSinceUtc.ToUniversalTime().AddMinutes($DelayMinutes) - $NowUtc.ToUniversalTime()).TotalSeconds)
    if ($remaining -gt 0) {
        $countdown = 'Locked · starts in {0}:{1:00}' -f [Math]::Floor($remaining / 60), ($remaining % 60)
        return [pscustomobject]@{ ShouldMine=$false; Status=$countdown }
    }
    [pscustomobject]@{ ShouldMine=$true; Status='Mining' }
}

function ConvertTo-PPQuotedArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-PPMinerArguments {
    param([Parameter(Mandatory=$true)]$Configuration, [Parameter(Mandatory=$true)][string]$LogPath)

    $resumeTemperature = [Math]::Max(40, [int]$Configuration.TemperatureLimitC - 10)
    $arguments = @(
        '--algo', 'pearlhash',
        '--url', 'pool.pearlhash.xyz:9000',
        '--user', [string]$Configuration.Wallet,
        '--worker', [string]$Configuration.WorkerName,
        '--gpu-list', [string]$Configuration.GpuList,
        '--gpu-temp-limit', [string]$Configuration.TemperatureLimitC,
        '--gpu-temp-resume', [string]$resumeTemperature,
        '--watchdog',
        '--print-time', '10',
        '--no-color',
        '--log-file', $LogPath
    )
    (@($arguments | ForEach-Object { ConvertTo-PPQuotedArgument ([string]$_) }) -join ' ')
}

function Start-PPMiner {
    param(
        [Parameter(Mandatory=$true)]$Configuration,
        [Parameter(Mandatory=$true)][string]$LogPath,
        [string]$MockMinerPath
    )

    $validation = Test-PPConfiguration `
        -Configuration $Configuration `
        -AllowMissingMiner:([bool]$MockMinerPath) `
        -AllowMissingTelemetry:([bool]$MockMinerPath)
    if (-not $validation.Valid) { throw ($validation.Errors -join ' ') }

    $start = New-Object Diagnostics.ProcessStartInfo
    if ($MockMinerPath) {
        $start.FileName = Get-PPWindowsPowerShellPath
        $mockPath = ConvertTo-PPQuotedArgument $MockMinerPath
        $mockLog = ConvertTo-PPQuotedArgument $LogPath
        $start.Arguments = "-NoProfile -ExecutionPolicy Bypass -File $mockPath -LogPath $mockLog"
    } else {
        $start.FileName = [string]$Configuration.WildRigPath
        $start.Arguments = Get-PPMinerArguments -Configuration $Configuration -LogPath $LogPath
    }
    $start.WorkingDirectory = Split-Path -Parent $start.FileName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'WildRig did not start.' }
    $process
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

    try { $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop) } catch { $allProcesses = @() }
    $children = @($allProcesses | Where-Object { $_.ParentProcessId -eq $ProcessId } | ForEach-Object { [int]$_.ProcessId })
    foreach ($child in $children) { Stop-Process -Id $child -Force -ErrorAction SilentlyContinue }
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $process.Kill()
    if (-not $process.WaitForExit(5000)) {
        throw "Process $ProcessId did not stop."
    }
    $process.Dispose()
    $true
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
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $path
        $start.Arguments = '--query-gpu=index,temperature.gpu --format=csv,noheader,nounits'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $process = [Diagnostics.Process]::Start($start)
        if (-not $process.WaitForExit(5000)) { $process.Kill(); throw 'nvidia-smi timed out.' }

        $selected = @($GpuList -split ',' | ForEach-Object { $_.Trim() })
        $temperatures = @()
        foreach ($line in @($process.StandardOutput.ReadToEnd() -split "`r?`n")) {
            $parts = @($line -split ',' | ForEach-Object { $_.Trim() })
            if ($parts.Count -eq 2 -and $selected -contains $parts[0]) {
                $value = 0
                if ([int]::TryParse($parts[1], [ref]$value)) { $temperatures += $value }
            }
        }
        if (-not $temperatures.Count) { throw 'The configured GPU was not returned.' }
        [pscustomobject]@{ Available=$true; TemperatureC=($temperatures | Measure-Object -Maximum).Maximum }
    } catch {
        [pscustomobject]@{ Available=$false; TemperatureC=$null }
    }
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
    $arguments = ConvertTo-PPQuotedArgument $launcherPath
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

Export-ModuleMember -Function @(
    'Get-PPDataRoot',
    'Initialize-PPDataRoot',
    'Get-PPWindowsPowerShellPath',
    'Get-PPWindowsScriptHostPath',
    'Get-PPConfiguration',
    'Save-PPConfiguration',
    'Write-PPLog',
    'Find-PPNvidiaSmi',
    'Get-PPGpuPowerLimit',
    'Get-PPPowerLimitTarget',
    'Set-PPGpuPowerLimit',
    'Test-PPConfiguration',
    'Get-PPCurrentSessionState',
    'Get-PPMiningDecision',
    'Get-PPMinerArguments',
    'Start-PPMiner',
    'Test-PPOwnedProcess',
    'Stop-PPOwnedProcess',
    'Test-PPOtherMinerRunning',
    'Get-PPGpuTemperature',
    'Get-PPStartupTaskName',
    'Enable-PPStartup',
    'Disable-PPStartup'
)
