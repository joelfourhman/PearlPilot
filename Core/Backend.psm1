Set-StrictMode -Version 2.0

function Read-PPJson {
    param([string]$Path)
    $deadline=[DateTime]::UtcNow.AddSeconds(2)
    while ($true) {
        $stream=$null; $reader=$null
        try {
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
            return ($reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop)
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {throw}
            Start-Sleep -Milliseconds 10
        } finally {
            if ($reader) {$reader.Dispose()} elseif ($stream) {$stream.Dispose()}
        }
    }
}

function Get-PPOption {
    param($Object, [string]$Name, $Default=$null)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    $Default
}

function Test-PPFreshTimestamp {
    param([string]$Timestamp, [int]$MaxAgeSeconds=15, [DateTime]$NowUtc=[DateTime]::UtcNow)
    $parsed=[DateTime]::MinValue
    if (-not [DateTime]::TryParse($Timestamp,[Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)) {return $false}
    $age=($NowUtc.ToUniversalTime()-$parsed.ToUniversalTime()).TotalSeconds
    $age -ge -5 -and $age -le $MaxAgeSeconds
}

function Get-PPBackendDisplaySnapshot {
    param($Snapshot, [bool]$ShouldMine, [bool]$WorkerExited=$false, [DateTime]$NowUtc=[DateTime]::UtcNow)
    if ($WorkerExited -or -not (Test-PPFreshTimestamp (Get-PPOption $Snapshot 'UpdatedUtc') -NowUtc $NowUtc)) {
        return
    }

    if (-not $ShouldMine) {
        $stopping = $Snapshot.State -in @('MINING','STARTING')
        if ($stopping -or $Snapshot.Telemetry) {
            # Keep the reported state intact for callers that need the actual acknowledgement.
            $Snapshot = $Snapshot.PSObject.Copy()
            if ($stopping) { $Snapshot.State = 'STOPPING' }
            $Snapshot.Telemetry = $null
        }
    }
    $Snapshot
}

function Send-PPBackendRequest {
    param([string]$DataRoot,
        [ValidateSet('Check','Install','Diagnostics','Rollback','Retry','Benchmark')][string]$Action,
        [string]$Version='', [string]$PanelId='')
    $request=[pscustomobject]@{Action=$Action;Version=$Version;PanelId=$PanelId;RequestedUtc=[DateTime]::UtcNow.ToString('o')}
    $name='request-'+[DateTime]::UtcNow.Ticks+'-'+[guid]::NewGuid().ToString('N')+'.json'
    Write-PPJson (Join-Path $DataRoot ('Runtime\'+$name)) $request
}

function Assert-PPBackendRequest {
    param($Request, $Intent, [DateTime]$NowUtc=[DateTime]::UtcNow)
    if ((Get-PPOption $Request 'Action') -notin @('Check','Install','Diagnostics','Rollback','Retry','Benchmark')) {
        throw 'Unknown backend operation.'
    }
    if (-not (Test-PPFreshTimestamp (Get-PPOption $Request 'RequestedUtc' '') 120 $NowUtc)) {
        throw 'Backend request expired or has an invalid timestamp. Submit it again.'
    }
    if ($Request.Action -eq 'Benchmark' -and ($Intent.ShouldMine -or $Intent.Status -ne 'Backend panel open' -or
        -not (Get-PPOption $Request 'PanelId' '') -or (Get-PPOption $Request 'PanelId') -cne (Get-PPOption $Intent 'PanelId') -or
        -not (Test-PPFreshTimestamp $Intent.UpdatedUtc 15 $NowUtc))) {
        throw 'Benchmark requires a current, open backend panel with mining paused.'
    }
}

function Test-PPStopAcknowledged {
    param($Snapshot, [DateTime]$RequestedUtc)
    if (-not $Snapshot -or $Snapshot.Desired -or $Snapshot.State -notin @('STOPPED','PAUSED','NOT_CONFIGURED')) {return $false}
    $ack=Get-PPOption $Snapshot 'IntentUpdatedUtc' ''
    if (-not (Test-PPFreshTimestamp $ack)) {return $false}
    [DateTime]::Parse($ack).ToUniversalTime() -ge $RequestedUtc.ToUniversalTime()
}

function Write-PPJson {
    param([string]$Path, $Value)
    $temporary = "$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding UTF8
        $deadline=[DateTime]::UtcNow.AddSeconds(2)
        while ($true) {
            try {
                if ([IO.File]::Exists($Path)) {[IO.File]::Replace($temporary,$Path,[NullString]::Value)}
                else {[IO.File]::Move($temporary,$Path)}
                break
            } catch [IO.IOException] {
                if ([DateTime]::UtcNow -ge $deadline) {throw}
                Start-Sleep -Milliseconds 10
            }
        }
    } finally {Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
}

# No shell is involved. On .NET Framework, escape each argv element using the
# CommandLineToArgvW rules; ArgumentList is unavailable in Windows PowerShell 5.1.
function ConvertTo-PPArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
    '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-PPCommand {
    param([string]$File, [string[]]$Arguments, [int]$TimeoutSeconds=15,
        [Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $File
    $start.Arguments = (@($Arguments | ForEach-Object { ConvertTo-PPArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $process.WaitForExit(100)) {
            if ($CancellationToken.IsCancellationRequested -or [DateTime]::UtcNow -gt $deadline) {
                $process.Kill()
                $process.WaitForExit()
                throw "$File cancelled or timed out after $TimeoutSeconds seconds."
            }
        }
        [pscustomobject]@{ ExitCode=$process.ExitCode; Output=$stdout.Result; Error=$stderr.Result }
    } finally { $process.Dispose() }
}

function Invoke-PPDocker {
    param([string[]]$Arguments, [int]$TimeoutSeconds=15, [switch]$AllowFailure)
    $docker = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $docker) { throw 'DOCKER_UNAVAILABLE: Install Docker Desktop and enable its WSL2 Linux backend.' }
    try {
        $result = Invoke-PPCommand -File $docker.Source -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    } catch {
        if ($_.Exception.Message -match 'cancelled or timed out') {
            throw 'DOCKER_UNAVAILABLE: Docker Desktop did not respond. Restart Docker Desktop, then choose Retry mining controller. Detail: ' + $_.Exception.Message
        }
        throw
    }
    if (-not $AllowFailure -and $result.ExitCode -ne 0) {
        throw ('Docker failed: ' + $result.Error.Trim() + ' ' + $result.Output.Trim())
    }
    $result
}

function Get-PPBackendIdentity {
    param([string]$DataRoot)
    $normalized=[IO.Path]::GetFullPath($DataRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if ($env:OS -eq 'Windows_NT') {$normalized=$normalized.ToLowerInvariant()}
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-','').Substring(0,16).ToLowerInvariant() }
    finally { $sha.Dispose() }
    [pscustomobject]@{ Name="pearlpilot-$key"; Owner=$key; DataRoot=[IO.Path]::GetFullPath($DataRoot) }
}

function Get-PPOwnedContainer {
    param($Identity)
    $list = Invoke-PPDocker @('container','ls','-a','--filter',"name=^/$($Identity.Name)$",'--format','{{.ID}}')
    if (-not $list.Output.Trim()) { return $null }
    $items = (Invoke-PPDocker @('container','inspect',$Identity.Name)).Output | ConvertFrom-Json
    $item = @($items)[0]
    if ((Get-PPOption $item.Config.Labels 'io.pearlpilot.owner') -ne $Identity.Owner -or
        (Get-PPOption $item.Config.Labels 'io.pearlpilot.app') -ne 'wildrig') {
        throw 'Container name belongs to another resource. PearlPilot will not modify it.'
    }
    $item
}

function Stop-PPDockerMiner {
    param($Identity, [switch]$Remove)
    $container = Get-PPOwnedContainer $Identity
    if ($container) {
        if ($container.State.Running) { [void](Invoke-PPDocker @('container','stop','--time','10',$Identity.Name) -TimeoutSeconds 20) }
        if ($Remove) { [void](Invoke-PPDocker @('container','rm',$Identity.Name)) }
    }
}

function Get-PPReleaseAsset {
    param($Release)
    if ($Release.draft -or $Release.prerelease -or $Release.tag_name -notmatch '^v?\d+\.\d+\.\d+$') { throw 'Only stable official releases are supported.' }
    $version = $Release.tag_name -replace '^v',''
    $assets = @($Release.assets | Where-Object { $_.name -ceq "wildrig-multi-linux-$version.tar.gz" })
    if ($assets.Count -ne 1) { throw 'Official Linux x86_64 tar.gz asset is missing or ambiguous.' }
    $asset = $assets[0]
    $expected = 'https://github.com/andru-kun/wildrig-multi/releases/download/' + $Release.tag_name + '/' + $asset.name
    if ($asset.browser_download_url -cne $expected) { throw 'Refusing a non-official artifact URL.' }
    $digest = [string](Get-PPOption $asset 'digest' '')
    if ($digest -and $digest -notmatch '^sha256:[a-fA-F0-9]{64}$') {
        throw 'The official WildRig download has an invalid digest.'
    }
    $hash = if ($digest) { $digest.Substring(7).ToLowerInvariant() } else { '' }
    [pscustomobject]@{ Version=$version; Tag=$Release.tag_name; Name=$asset.name; Url=$expected; Sha256=$hash; Size=[long]$asset.size }
}

function Get-PPWildRigRelease {
    param([string]$CacheRoot, [string]$Version='latest', [switch]$Refresh)
    if ($Version -ne 'latest' -and $Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must be latest or an explicit stable version such as 0.51.8.' }
    [void](New-Item -ItemType Directory -Path $CacheRoot -Force)
    $path = Join-Path $CacheRoot "release-$Version.json"
    if (-not $Refresh -and (Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddHours(-6)) {
        return Get-PPReleaseAsset (Read-PPJson $path)
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $suffix = if ($Version -eq 'latest') { 'latest' } else { "tags/$Version" }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/andru-kun/wildrig-multi/releases/$suffix" -Headers @{ 'User-Agent'='PearlPilot'; Accept='application/vnd.github+json' } -TimeoutSec 30
    $asset = Get-PPReleaseAsset $release
    Write-PPJson $path $release
    $asset
}

function Test-PPAutomaticUpdateDue {
    param($Intent, $State, $Release, [string]$LastAttempt)
    ($null -ne $Release) -and ($Release.Version -ne $LastAttempt) -and
        (Get-PPOption $Intent.Configuration 'AutomaticUpdates' $false) -and
        (-not $Intent.ShouldMine) -and ($Intent.Status -in @('Idle','Disabled','Stopped manually')) -and
        $State.Reconciled -and ($State.State -in @('PAUSED','STOPPED')) -and
        (Test-PPFreshTimestamp $Intent.UpdatedUtc)
}

function Test-PPArtifact {
    param([string]$Path, $Asset)
    if ((Get-Item -LiteralPath $Path).Length -ne $Asset.Size) { throw 'WildRig archive size mismatch; download is incomplete.' }
    if ($Asset.Sha256 -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Asset.Sha256) { throw 'WildRig download checksum mismatch.' }
    $stream = [IO.File]::OpenRead($Path)
    try { if ($stream.ReadByte() -ne 31 -or $stream.ReadByte() -ne 139) { throw 'Expected gzip archive.' } }
    finally { $stream.Dispose() }
}

function Read-PPStream {
    param([IO.Stream]$Stream, [byte[]]$Buffer, [int]$Length)
    $offset = 0
    while ($offset -lt $Length) {
        $read = $Stream.Read($Buffer, $offset, $Length-$offset)
        if ($read -eq 0) { throw 'Truncated tar archive.' }
        $offset += $read
    }
}

# Deliberately supports only regular files/directories. Reject links, devices,
# extended headers, duplicate paths, Windows ADS, traversal, and archive bombs.
function Expand-PPArchive {
    param([string]$Path, [string]$Destination)
    if (Test-Path -LiteralPath $Destination) { throw 'Extraction destination must be new.' }
    [void](New-Item -ItemType Directory -Path $Destination)
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $file = [IO.File]::OpenRead($Path)
    $gzip = New-Object IO.Compression.GZipStream($file, [IO.Compression.CompressionMode]::Decompress)
    $seen = @{}
    $total = 0L
    try {
        $header = New-Object byte[] 512
        $buffer = New-Object byte[] 65536
        while ($true) {
            Read-PPStream $gzip $header 512
            if (@($header | Where-Object { $_ -ne 0 }).Count -eq 0) { break }
            $sum = 0
            for ($i=0; $i -lt 512; $i++) { if ($i -ge 148 -and $i -lt 156) { $sum += 32 } else { $sum += $header[$i] } }
            $expected = [Convert]::ToInt32([Text.Encoding]::ASCII.GetString($header,148,8).Trim([char]0,' '),8)
            if ($sum -ne $expected) { throw 'Invalid tar header checksum.' }
            $name = [Text.Encoding]::UTF8.GetString($header,0,100).TrimEnd([char]0)
            $prefix = [Text.Encoding]::UTF8.GetString($header,345,155).TrimEnd([char]0)
            if ($prefix) { $name = "$prefix/$name" }
            if ($name -match '(^[/\\]|(^|[/\\])\.\.([/\\]|$)|[:\\])' -or $name -match '[\x00-\x1f]') { throw 'Unsafe archive path.' }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $name))
            if (-not $target.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($target)) { throw 'Unsafe or duplicate archive path.' }
            $seen[$target]=$true
            if ($seen.Count -gt 4096) { throw 'Archive has too many files.' }
            $size = [Convert]::ToInt64([Text.Encoding]::ASCII.GetString($header,124,12).Trim([char]0,' '),8)
            $total += $size
            if ($size -gt 512MB -or $total -gt 1GB) { throw 'Archive exceeds extraction limit.' }
            $type = $header[156]
            if ($type -eq 53 -and $size -eq 0) { [void](New-Item -ItemType Directory -Path $target -Force) }
            elseif ($type -eq 0 -or $type -eq 48) {
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
                $output = [IO.File]::Create($target)
                try {
                    $remaining=$size
                    while ($remaining -gt 0) { $count=[int][Math]::Min($remaining,$buffer.Length); Read-PPStream $gzip $buffer $count; $output.Write($buffer,0,$count); $remaining-=$count }
                } finally { $output.Dispose() }
            } else { throw 'Archive contains unsupported links, devices, or extended entries.' }
            $padding = [int]((512-($size%512))%512)
            if ($padding) { Read-PPStream $gzip $buffer $padding }
        }
        $executables = @(Get-ChildItem -LiteralPath $Destination -Recurse -File | Where-Object { $_.Name -eq 'wildrig-multi' })
        if ($executables.Count -ne 1) { throw 'Archive must contain exactly one wildrig-multi executable.' }
        $elf = [IO.File]::OpenRead($executables[0].FullName)
        try { $bytes=New-Object byte[] 20; Read-PPStream $elf $bytes 20 } finally { $elf.Dispose() }
        if ($bytes[0] -ne 127 -or $bytes[1] -ne 69 -or $bytes[2] -ne 76 -or $bytes[3] -ne 70 -or $bytes[4] -ne 2 -or $bytes[5] -ne 1 -or $bytes[18] -ne 62 -or $bytes[19] -ne 0) { throw 'WildRig is not a Linux ELF x86_64 binary.' }
        $executables[0].FullName
    } finally { $gzip.Dispose(); $file.Dispose() }
}

function Get-PPMiningArgv {
    param($Configuration, [string]$HelpText='')
    $wallet = [string]$Configuration.Wallet
    $worker = [string]$Configuration.WorkerName
    $pool = [string](Get-PPOption $Configuration 'PoolUrl' 'pool.pearlhash.xyz:9000')
    if ($wallet -notmatch '^prl1[0-9a-z]{20,}$') { throw 'Enter a public PRL wallet beginning with prl1.' }
    if ($worker -notmatch '^[A-Za-z0-9._-]{1,32}$') { throw 'Invalid worker name.' }
    if ($pool -notmatch '^(stratum\+tcp://|stratum\+ssl://)?[A-Za-z0-9.-]+:[0-9]{1,5}$') { throw 'Pool must be host:port or stratum+tcp/ssl://host:port.' }
    $port=[int]($pool -replace '^.*:','')
    if ($port -lt 1 -or $port -gt 65535) { throw 'Invalid pool port.' }
    if ([string]$Configuration.GpuList -notmatch '^\d+(,\d+)*$') { throw 'Invalid GPU list.' }
    $kernel = [string](Get-PPOption $Configuration 'PearlHashKernel' '2')
    $intensity = [string](Get-PPOption $Configuration 'GpuIntensity' '')
    if ($kernel -notin @('','1','2')) { throw 'Kernel must be default (empty), 1, or 2.' }
    if ($intensity -and $intensity -notmatch '^([1-9]|[1-5][0-9]|6[0-4])$') { throw 'Intensity must be empty or 1-64.' }
    $args = @('--algo','pearlhash','--url',$pool,'--user',$wallet,'--worker',$worker,'--gpu-list',[string]$Configuration.GpuList,
        '--gpu-temp-limit',[string]$Configuration.TemperatureLimitC,'--gpu-temp-resume',[string]([int]$Configuration.TemperatureLimitC-10),
        '--watchdog','--print-time','10','--no-color')
    if ($kernel) {
        if ($HelpText -and $HelpText -notmatch '--pearlhash-kernel') { throw 'Installed WildRig does not advertise --pearlhash-kernel; select default kernel.' }
        $args += @('--pearlhash-kernel',$kernel)
    }
    if ($intensity) { $args += @('--gpu-intensity',$intensity) }
    if ($HelpText -and ($HelpText -notmatch 'pearlhash' -or $HelpText -notmatch '--gpu-list')) { throw 'WildRig CLI does not advertise required PearlHash/device support.' }
    $args
}

function Get-PPContainerSecurityArgs {
    # Apply the same restrictions to validation and mining. Never trust the
    # image's USER instruction or Docker defaults to provide these controls.
    @('--pull','never','--user','65532:65532','--restart','no','--init','--read-only',
        '--tmpfs','/tmp:rw,noexec,nosuid,nodev,size=128m','--cap-drop','ALL','--security-opt','no-new-privileges',
        '--pids-limit','128','--memory','4g','--memory-swap','4g','--cpus','4','--ulimit','core=0',
        '--log-driver','local','--log-opt','max-size=10m','--log-opt','max-file=3')
}

function Assert-PPInstallationImage {
    param($Identity, $Installation)
    if ($Installation.Image -notmatch '^sha256:[a-f0-9]{64}$') { throw 'Expected an immutable Docker image ID.' }
    $image=@((Invoke-PPDocker @('image','inspect',$Installation.Image)).Output | ConvertFrom-Json)[0]
    $volumes=Get-PPOption $image.Config 'Volumes'
    if ($image.Id -cne $Installation.Image -or $image.Os -ne 'linux' -or $image.Architecture -ne 'amd64' -or
        (Get-PPOption $image.Config.Labels 'io.pearlpilot.app') -ne 'wildrig' -or
        (Get-PPOption $image.Config.Labels 'io.pearlpilot.owner') -ne $Identity.Owner -or
        (Get-PPOption $image.Config.Labels 'io.pearlpilot.version') -cne $Installation.Version -or
        (Get-PPOption $image.Config.Labels 'io.pearlpilot.sha256') -cne $Installation.Sha256 -or
        (Get-PPOption $image.Config.Labels 'io.pearlpilot.security-revision') -ne '2' -or
        $image.Config.User -ne '65532:65532' -or
        (@($image.Config.Entrypoint) -join ',') -ne '/opt/pearlpilot/supervisor.sh' -or
        ($volumes -and @($volumes.PSObject.Properties | Where-Object {$_.MemberType -eq 'NoteProperty'}).Count -gt 0)) {
        throw 'Installed image does not match the approved Linux runtime policy. Rebuild it from the Backend tab in Menu.'
    }
}

function Get-PPContainerCreateArgs {
    param($Identity, [string]$Image, [string[]]$MinerArguments)
    # No restart: only the policy controller may enable mining. Loopback API only.
    @('container','create','--name',$Identity.Name,'--label','io.pearlpilot.app=wildrig','--label',"io.pearlpilot.owner=$($Identity.Owner)",
        '--gpus','all','--env','NVIDIA_DRIVER_CAPABILITIES=compute,utility') + @(Get-PPContainerSecurityArgs) + @(
        '--publish','127.0.0.1::3333','--stop-timeout','10',$Image) + $MinerArguments + @('--api-port','3333')
}

function Start-PPDockerMiner {
    param($Identity, $Configuration, $Installation)
    Assert-PPInstallationImage $Identity $Installation
    $argv = @(Get-PPMiningArgv $Configuration $Installation.Help)
    Stop-PPDockerMiner $Identity -Remove
    [void](Invoke-PPDocker (Get-PPContainerCreateArgs $Identity $Installation.Image $argv))
    [void](Invoke-PPDocker @('container','start',$Identity.Name))
    Get-PPOwnedContainer $Identity
}

function Invoke-PPImageValidation {
    param($Identity, [string]$Image, [string]$Option)
    $helper=[pscustomobject]@{Name=($Identity.Name+'-validate');Owner=$Identity.Owner}
    try {
        Stop-PPDockerMiner $helper -Remove
        Invoke-PPDocker (@('run','--rm','--name',$helper.Name,'--label','io.pearlpilot.app=wildrig',
            '--label',"io.pearlpilot.owner=$($helper.Owner)",'--network','none') +
            @(Get-PPContainerSecurityArgs) + @($Image,$Option)) -AllowFailure -TimeoutSeconds 30
    } finally {
        # Killing a timed-out docker CLI does not stop its container. Always
        # remove the owned helper, even if the miner ignores its lease/signals.
        Stop-PPDockerMiner $helper -Remove
    }
}

function Test-PPPoolConnection {
    param([string]$PoolUrl)
    $endpoint = $PoolUrl -replace '^stratum\+(tcp|ssl)://',''
    if ($endpoint -notmatch '^([A-Za-z0-9.-]+):([0-9]{1,5})$') { throw 'Invalid pool endpoint.' }
    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Matches[1], [int]$Matches[2])
        if (-not $task.Wait(5000) -or -not $client.Connected) { throw 'Pool TCP connection timed out; check DNS, firewall and pool availability.' }
    } finally { $client.Dispose() }
}

function Test-PPDockerPrerequisites {
    param([string]$DataRoot, [string]$Image='', [string]$PoolUrl='pool.pearlhash.xyz:9000', [switch]$SkipPoolCheck)
    $checks = New-Object Collections.Generic.List[object]
    $windows = $env:OS -eq 'Windows_NT'
    $checks.Add([pscustomobject]@{ Check='Host'; Ready=([Environment]::Is64BitOperatingSystem -and (-not $windows -or [Environment]::OSVersion.Version.Build -ge 22000)); Detail='Requires Windows 11 x64 (or native Linux x64 backend tools).' })
    try {
        $smi=Find-PPNvidiaSmi
        if (-not $smi) {throw 'Install the supported NVIDIA host driver; nvidia-smi is unavailable.'}
        $driver=Invoke-PPCommand $smi @('--query-gpu=name,driver_version','--format=csv,noheader') 5
        if ($driver.ExitCode -ne 0 -or -not $driver.Output.Trim()) {throw 'The NVIDIA host driver is not responding.'}
        $checks.Add([pscustomobject]@{Check='NVIDIA host driver';Ready=$true;Detail=$driver.Output.Trim()})
    } catch {$checks.Add([pscustomobject]@{Check='NVIDIA host driver';Ready=$false;Detail=$_.Exception.Message})}
    try {
        $version = (Invoke-PPDocker @('version','--format','{{json .Server}}')).Output | ConvertFrom-Json
        if ($version.Os -ne 'linux' -or $version.Arch -ne 'amd64' -or [version]$version.ApiVersion -lt [version]'1.40') { throw 'Switch Docker to Linux amd64 containers; Engine API 1.40+ is required.' }
        $info = (Invoke-PPDocker @('info','--format','{{json .}}')).Output | ConvertFrom-Json
        $checks.Add([pscustomobject]@{ Check='Docker Engine'; Ready=$true; Detail="Linux amd64, API $($version.ApiVersion)" })
        if ($windows) {
            if ($info.OperatingSystem -notmatch 'Docker Desktop' -or $info.KernelVersion -notmatch 'WSL2') { throw 'Enable Docker Desktop > Settings > General > Use the WSL 2 based engine. Remote Docker engines are not supported on Windows.' }
            $endpoint=$env:DOCKER_HOST
            if (-not $endpoint) {$endpoint=(Invoke-PPDocker @('context','inspect','--format','{{json .Endpoints.docker.Host}}')).Output | ConvertFrom-Json}
            if ($endpoint -notlike 'npipe:////./pipe/*') {throw 'Select a local Docker Desktop named-pipe context (usually desktop-linux). Remote engines cannot supply local GPU telemetry or the loopback API.'}
            $wsl = Invoke-PPCommand wsl.exe @('--status') 10
            if ($wsl.ExitCode -ne 0) { throw 'WSL is unavailable. Check wsl --status and Docker Desktop WSL2 integration.' }
            $checks.Add([pscustomobject]@{ Check='Docker Desktop / WSL2'; Ready=$true; Detail=$info.KernelVersion })
        } else {
            $checks.Add([pscustomobject]@{ Check='Native Linux'; Ready=$true; Detail='Requires host NVIDIA driver and NVIDIA Container Toolkit, separately configured by administrator.' })
        }
    } catch { $checks.Add([pscustomobject]@{ Check='Docker / WSL2'; Ready=$false; Detail=$_.Exception.Message }) }
    try {
        $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($DataRoot)))
        $checks.Add([pscustomobject]@{ Check='Host disk'; Ready=($drive.AvailableFreeSpace -ge 2GB); Detail='At least 2 GiB on the data drive; also check Docker Desktop virtual disk capacity.' })
    } catch { $checks.Add([pscustomobject]@{ Check='Host disk'; Ready=$false; Detail=$_.Exception.Message }) }
    if (-not $SkipPoolCheck) {
        try { Test-PPPoolConnection $PoolUrl; $checks.Add([pscustomobject]@{ Check='Pool TCP'; Ready=$true; Detail=$PoolUrl }) }
        catch { $checks.Add([pscustomobject]@{ Check='Pool TCP'; Ready=$false; Detail=$_.Exception.Message }) }
    }
    if ($Image) {
        try {
            # /tmp is deliberately a small tmpfs; check Docker's backing rootfs.
            $disk=Invoke-PPDocker (@('run','--rm','--network','none') + @(Get-PPContainerSecurityArgs) + @('--entrypoint','df',$Image,'-Pk','/'))
            $columns=@(($disk.Output.Trim() -split "`n" | Select-Object -Last 1) -split '\s+')
            if ($columns.Count -lt 6 -or [long]$columns[3] -lt 2MB) {throw 'Docker virtual disk needs at least 2 GiB free. Review Docker Desktop disk settings.'}
            $checks.Add([pscustomobject]@{Check='Docker disk';Ready=$true;Detail=('{0:N1} GiB available' -f ([long]$columns[3]/1MB))})
        } catch {$checks.Add([pscustomobject]@{Check='Docker disk';Ready=$false;Detail=$_.Exception.Message})}
        $identity = Get-PPBackendIdentity $DataRoot
        foreach ($probe in @(@('NVIDIA GPU','nvidia-smi'),@('NVIDIA CUDA driver API','cuda'))) {
            $name = "$($identity.Name)-probe"
            try {
                $args = @('run','--rm','--name',$name,'--label',"io.pearlpilot.owner=$($identity.Owner)",'--label','io.pearlpilot.app=wildrig',
                    '--gpus','all','--network','none','--env','NVIDIA_DRIVER_CAPABILITIES=compute,utility') + @(Get-PPContainerSecurityArgs)
                if ($probe[1] -eq 'nvidia-smi') { $args += @('--entrypoint','nvidia-smi',$Image,'--query-gpu=name,driver_version','--format=csv,noheader') }
                else { $args += @('--entrypoint','/opt/pearlpilot/cuda-probe',$Image) }
                $result = Invoke-PPDocker $args -TimeoutSeconds 30
                $detail = $result.Output + $result.Error
                if ($detail -notmatch '(?i)(NVIDIA|GeForce|RTX)') { throw "GPU_UNAVAILABLE: NVIDIA container driver initialization failed. $detail" }
                $checks.Add([pscustomobject]@{ Check=$probe[0]; Ready=$true; Detail=$detail.Trim() })
            } catch { $checks.Add([pscustomobject]@{ Check=$probe[0]; Ready=$false; Detail=$_.Exception.Message }) }
            finally {
                # Clean a timed-out probe only after checking its ownership label.
                $probeIdentity = [pscustomobject]@{ Name=$name; Owner=$identity.Owner }
                try { Stop-PPDockerMiner $probeIdentity -Remove } catch { }
            }
        }
    } else { $checks.Add([pscustomobject]@{ Check='Container GPU / CUDA'; Ready=$false; Detail='Install the backend image, then run diagnostics to verify NVIDIA runtime and CUDA driver access.' }) }
    [pscustomobject]@{ Ready=(@($checks | Where-Object { -not $_.Ready }).Count -eq 0); CheckedUtc=[DateTime]::UtcNow.ToString('o'); Checks=@($checks.ToArray()) }
}

function Install-PPDockerWildRig {
    param([string]$DataRoot, [string]$Version='latest', [switch]$UpdateOnly)
    if (-not $Version) { $Version='latest' }
    $DataRoot=[IO.Path]::GetFullPath($DataRoot)
    $cache = Join-Path $DataRoot 'Backend'
    # Explicit installations of latest must bypass the discovery cache. Resolve
    # once, then use this exact version/digest for the entire download/build.
    $asset = Get-PPWildRigRelease $cache $Version -Refresh:($Version -eq 'latest')
    if ($UpdateOnly) {
        $active = Read-PPInstallation $DataRoot
        if ($active -and [version]$asset.Version -le [version]$active.Version) { return }
    }
    $archive = Join-Path $cache $asset.Name
    if (Test-Path -LiteralPath $archive) {
        if (-not $asset.Sha256) { Remove-Item -LiteralPath $archive -Force }
        else { try { Test-PPArtifact $archive $asset } catch { Remove-Item -LiteralPath $archive -Force } }
    }
    if (-not (Test-Path -LiteralPath $archive)) {
        $partial = "$archive.partial"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $asset.Url -OutFile $partial -TimeoutSec 180 -Headers @{ 'User-Agent'='PearlPilot' }
            Test-PPArtifact $partial $asset
            Move-Item -LiteralPath $partial -Destination $archive -Force
        } finally { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
    }
    if (-not $asset.Sha256) {
        $asset.Sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $stage = Join-Path $cache ('build-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $stage)
    try {
        $distribution = Join-Path $stage 'distribution'
        $binary = Expand-PPArchive $archive $distribution
        if ((Split-Path -Parent $binary) -ne $distribution) { throw 'Unexpected archive layout: executable must be at archive root.' }
        $dockerRoot = Join-Path $PSScriptRoot 'Docker'
        $recipeHashes = foreach ($file in @('Dockerfile','cuda-probe.c','supervisor.sh')) {
            $stagedFile = Join-Path $stage $file
            Copy-Item -LiteralPath (Join-Path $dockerRoot $file) -Destination $stagedFile
            (Get-FileHash -LiteralPath $stagedFile).Hash
        }
        $recipe = $recipeHashes -join ''
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $recipeHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($recipe)))).Replace('-','').Substring(0,12).ToLowerInvariant() } finally { $sha.Dispose() }
        $identity=Get-PPBackendIdentity $DataRoot
        $tag = "pearlpilot/wildrig:$($asset.Version)-$($asset.Sha256.Substring(0,12))-$recipeHash-$($identity.Owner)"
        $build = Invoke-PPDocker @('build','--pull','--label',"io.pearlpilot.owner=$($identity.Owner)",'--build-arg',"WILDRIG_VERSION=$($asset.Version)",'--build-arg',"WILDRIG_SHA256=$($asset.Sha256)",'-t',$tag,$stage) -TimeoutSeconds 600 -AllowFailure
        $build.Output + $build.Error | Set-Content -LiteralPath (Join-Path $cache 'last-build.log') -Encoding UTF8
        if ($build.ExitCode -ne 0) { throw 'Docker build failed. See Backend/last-build.log for diagnostics.' }
        $image = @((Invoke-PPDocker @('image','inspect',$tag)).Output | ConvertFrom-Json)[0].Id
        $versionResult = Invoke-PPImageValidation $identity $image '--version'
        if ($versionResult.ExitCode -notin @(0,1)) { throw 'WildRig version command failed.' }
        $versionText = $versionResult.Output + $versionResult.Error
        if ($versionText -notmatch ('WildRig Multi\s+'+[regex]::Escape($asset.Version)+'(?:\s|$)')) { throw 'WildRig reports an unexpected version.' }
        $helpResult = Invoke-PPImageValidation $identity $image '--help'
        if ($helpResult.ExitCode -notin @(0,1)) { throw 'WildRig help command failed.' }
        $help = $helpResult.Output + $helpResult.Error
        if ($help -notmatch 'pearlhash' -or $help -notmatch '--gpu-list') { throw 'Official binary does not advertise required PearlHash CLI support.' }
        $record = [pscustomobject]@{ Version=$asset.Version; Image=$image; Tag=$tag; Sha256=$asset.Sha256; Help=$help; InstalledUtc=[DateTime]::UtcNow.ToString('o'); MiningValidated=$false; GpuValidated=$false }
        Write-PPJson (Join-Path $cache 'candidate.json') $record
        $record
    } finally {
        # stage is a fresh UUID directory, always under this backend cache.
        if ([IO.Path]::GetFullPath($stage).StartsWith([IO.Path]::GetFullPath($cache) + [IO.Path]::DirectorySeparatorChar)) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
}

function Read-PPInstallation {
    param([string]$DataRoot, [ValidateSet('active','previous','candidate')][string]$Slot='active')
    $path = Join-Path $DataRoot "Backend\$Slot.json"
    if (Test-Path -LiteralPath $path) { return (Read-PPJson $path) }
    return $null
}

function Set-PPActiveInstallation {
    param([string]$DataRoot, $Installation, [switch]$Rollback)
    $active = Read-PPInstallation $DataRoot
    if ($active -and $active.Image -eq $Installation.Image) { return }
    if ($active -and (-not $Rollback) -and $active.MiningValidated) { Write-PPJson (Join-Path $DataRoot 'Backend\previous.json') $active }
    Write-PPJson (Join-Path $DataRoot 'Backend\active.json') $Installation
}

function Remove-PPObsoleteResources {
    param([string]$DataRoot)
    $identity=Get-PPBackendIdentity $DataRoot
    $keep=@('active','previous','candidate' | ForEach-Object { $record=Read-PPInstallation $DataRoot $_; if ($record) {$record.Image} })
    $images=(Invoke-PPDocker @('image','ls','--filter',"label=io.pearlpilot.owner=$($identity.Owner)",'--filter','label=io.pearlpilot.app=wildrig','--quiet','--no-trunc')).Output -split "`r?`n"
    foreach ($id in @($images | Where-Object { $_ -and $_ -notin $keep } | Select-Object -Unique | Select-Object -First 10)) {
        # No force: Docker refuses to remove an image referenced by a container.
        [void](Invoke-PPDocker @('image','rm',$id) -AllowFailure)
    }
    $containers=(Invoke-PPDocker @('container','ls','-a','--filter',"label=io.pearlpilot.owner=$($identity.Owner)",'--filter','label=io.pearlpilot.app=wildrig','--filter','status=exited','--format','{{.Names}}')).Output -split "`r?`n"
    foreach ($name in @($containers | Where-Object { $_ -and $_ -ne $identity.Name } | Select-Object -First 10)) {
        Stop-PPDockerMiner ([pscustomobject]@{ Name=$name; Owner=$identity.Owner }) -Remove
    }
    $archives=@(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'Backend') -Filter 'wildrig-multi-linux-*.tar.gz' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 3)
    foreach ($archive in $archives) { Remove-Item -LiteralPath $archive.FullName -Force }
}

function ConvertFrom-PPMinerLog {
    param([string]$Text)
    $result = [ordered]@{ Hashrate=$null; AverageHashrate=$null; Accepted=$null; Rejected=$null; Stale=$null; PoolConnected=$null;
        LastShareUtc=$null; LastHashUtc=$null; MinerUptimeSeconds=$null; RecentErrors=@(); Warnings=@() }
    foreach ($line in @($Text -split "`r?`n")) {
        $at = $null
        if ($line -match '^(\d{4}-\d\d-\d\dT\S+)\s') { try { $at=[DateTime]::Parse($Matches[1]).ToUniversalTime() } catch { } }
        if ($line -match '(?i)(?:total speed|total hashrate|speed)\s*[:=]\s*([\d.]+)\s*([kMGT]?)H/s') {
            $factor = switch -CaseSensitive ($Matches[2]) { 'k' {1e3} 'M' {1e6} 'G' {1e9} 'T' {1e12} default {1} }
            $result.Hashrate=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)*$factor
            $result.LastHashUtc=$at
        }
        if ($line -match '(?i)accepted\s*\((\d+)/(\d+)\)') { $result.Accepted=[long]$Matches[1]; $result.Rejected=[long]$Matches[2]; $result.LastShareUtc=$at; $result.PoolConnected=$true }
        if ($line -match '(?i)Share accepted\s*\((\d+)\)') { $result.Accepted=[long]$Matches[1]; $result.LastShareUtc=$at; $result.PoolConnected=$true }
        if ($line -match '\b(10s|60s):\s+([\d.]+)\s*([kMGT]?)H/s') {
            $window=$Matches[1]; $value=[double]::Parse($Matches[2],[Globalization.CultureInfo]::InvariantCulture)
            $factor=switch -CaseSensitive ($Matches[3]) { 'k' {1e3} 'M' {1e6} 'G' {1e9} 'T' {1e12} default {1} }
            if ($window -eq '10s') { $result.Hashrate=$value*$factor; $result.LastHashUtc=$at }
            else { $result.AverageHashrate=$value*$factor }
        }
        if ($line -match '(?i)(connection lost|connection failed|failed to connect|disconnected|connection error)') { $result.PoolConnected=$false }
        if ($line -match '(?i)(clGetPlatformIDs|Failed to find OpenCL platform)') {$result.Warnings=@($result.Warnings + $line | Select-Object -Last 4)}
        elseif ($line -match '(?i)(error|failed|invalid|no devices|no platforms)') { $result.RecentErrors=@($result.RecentErrors + $line | Select-Object -Last 8) }
    }
    [pscustomobject]$result
}

function Get-PPDockerTelemetry {
    param($Identity, $Installation)
    $container = Get-PPOwnedContainer $Identity
    if (-not $container) { return $null }
    $logs = Invoke-PPDocker @('logs','--timestamps','--since',$container.State.StartedAt,'--tail','2000',$Identity.Name)
    if (Get-PPOption $Identity 'DataRoot') {
        $log=Join-Path $Identity.DataRoot 'Logs\WildRig-Docker.log'
        if ((Test-Path -LiteralPath (Split-Path -Parent $log)) -and (-not (Test-Path -LiteralPath $log) -or (Get-Item -LiteralPath $log).LastWriteTimeUtc -lt [DateTime]::UtcNow.AddSeconds(-10))) {
            $logs.Output + "`n" + $logs.Error | Set-Content -LiteralPath $log -Encoding UTF8
        }
    }
    $metrics = ConvertFrom-PPMinerLog ($logs.Output + "`n" + $logs.Error)
    if ($container.State.Running) {
        try {
            $bindings = $container.NetworkSettings.Ports.'3333/tcp'
            if (@($bindings).Count -ne 1 -or $bindings[0].HostIp -ne '127.0.0.1') { throw 'API must be bound exclusively to IPv4 loopback.' }
            $api = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/" -f [int]$bindings[0].HostPort) -TimeoutSec 3
            $native = ConvertFrom-PPWildRigApi $api
            foreach ($property in @('Hashrate','AverageHashrate','Accepted','Rejected','Stale','PoolConnected','MinerUptimeSeconds')) { $metrics.$property=$native.$property }
            if ($metrics.Hashrate -gt 0) { $metrics.LastHashUtc=[DateTime]::UtcNow }
        } catch { $metrics.RecentErrors=@($metrics.RecentErrors + ('API unavailable: ' + $_.Exception.Message) | Select-Object -Last 8) }
    }
    $metrics | Add-Member NoteProperty ContainerRunning ([bool]$container.State.Running)
    $metrics | Add-Member NoteProperty ContainerUptimeSeconds $(if ($container.State.Running) { ([DateTime]::UtcNow - [DateTime]::Parse($container.State.StartedAt).ToUniversalTime()).TotalSeconds } else { $null })
    $metrics | Add-Member NoteProperty Version $Installation.Version
    foreach ($timestamp in @('LastHashUtc','LastShareUtc')) { if ($metrics.$timestamp -is [DateTime]) {$metrics.$timestamp=$metrics.$timestamp.ToUniversalTime().ToString('o')} }
    $metrics
}

function ConvertFrom-PPWildRigApi {
    param($Api)
    if ($Api.algo -ne 'pearlhash' -or $Api.hashrate.total -isnot [array]) {
        throw 'Unexpected WildRig PearlHash API format.'
    }
    $hashrate=$null; $average=$null; $accepted=$null; $rejected=$null
    if ($Api.hashrate.total.Count -ge 2) {
        if ($null -ne $Api.hashrate.total[0]) { $hashrate=[double]$Api.hashrate.total[0] }
        if ($Api.uptime -ge 60 -and $null -ne $Api.hashrate.total[1]) { $average=[double]$Api.hashrate.total[1] }
    }
    if ($null -ne $Api.results.shares_good) { $accepted=[long]$Api.results.shares_good }
    if ($null -ne $Api.results.shares_rejected) { $rejected=[long]($Api.results.shares_rejected | Measure-Object -Sum).Sum }
    [pscustomobject]@{ Hashrate=$hashrate; AverageHashrate=$average; Accepted=$accepted; Rejected=$rejected;
        Stale=$null; MinerUptimeSeconds=$Api.uptime; PoolConnected=($Api.connection.uptime -gt 0) }
}

function New-PPControllerState {
    [pscustomobject]@{ State='STOPPED'; Desired=$false; Failures=0; NextAttemptUtc=[DateTime]::MinValue; StartedUtc=$null;
        LastError=''; Backend=''; LastTelemetry=$null; LastHealthyUtc=$null; Reconciled=$false }
}

function Invoke-PPBenchmark {
    param([string]$DataRoot, $Configuration, $Installation, [switch]$Authorized,
        [ValidateRange(30,180)][int]$Seconds=60, [scriptblock]$Cancelled={ $false }, [scriptblock]$Progress={param($Sample)})
    if (-not $Authorized) { throw 'Benchmark requires explicit user authorization.' }
    if (Test-PPOtherMinerRunning (Get-PPOption $Configuration 'WildRigPath' '') $null) { throw 'Stop native WildRig before benchmarking.' }
    $identity=Get-PPBackendIdentity $DataRoot
    $profiles=@([pscustomobject]@{Name='WildRig defaults';Kernel='';Intensity=''},
        [pscustomobject]@{Name='Configured PearlHash profile';Kernel=$Configuration.PearlHashKernel;Intensity=$Configuration.GpuIntensity})
    $results=@()
    try {
        foreach ($profile in $profiles) {
            $cfg=$Configuration | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $cfg.PearlHashKernel=$profile.Kernel; $cfg.GpuIntensity=$profile.Intensity
            [void](Get-PPMiningArgv $cfg $Installation.Help)
            [void](Start-PPDockerMiner $identity $cfg $Installation)
            $samples=@(); $last=$null
            $end=[DateTime]::UtcNow.AddSeconds($Seconds)
            while ([DateTime]::UtcNow -lt $end) {
                if (& $Cancelled) { throw 'Benchmark cancelled; mining stopped.' }
                if (Test-PPGamingProcess $cfg.GamingProcesses) { throw 'Configured gaming application detected; benchmark stopped.' }
                $gpu=Get-PPGpuTemperature $cfg.GpuList
                if (-not $gpu.Available -or $gpu.TemperatureC -ge $cfg.TemperatureLimitC) { throw 'Thermal safety stopped the benchmark.' }
                $metrics=Get-PPDockerTelemetry $identity $Installation
                if (-not $metrics -or -not $metrics.ContainerRunning) { throw 'Benchmark miner exited.' }
                [void](Invoke-PPDocker @('exec',$identity.Name,'touch','/tmp/pearlpilot.lease'))
                $last=$metrics
                if ($metrics.Hashrate -gt 0 -and @($gpu.Gpus | Where-Object {$null -eq $_.PowerWatts}).Count -eq 0) {
                    $samples += [pscustomobject]@{Hashrate=$metrics.Hashrate;PowerWatts=($gpu.Gpus | Measure-Object PowerWatts -Sum).Sum}
                }
                & $Progress $metrics
                Start-Sleep -Seconds 3
            }
            Stop-PPDockerMiner $identity -Remove
            $hash=$null; $power=$null; $efficiency=$null; $rejectRate=$null
            if ($samples.Count) {
                $hash=($samples | Measure-Object Hashrate -Average).Average; $power=($samples | Measure-Object PowerWatts -Average).Average
                if ($power -gt 0) {$efficiency=$hash/$power}
            }
            if ($last -and $null -ne $last.Accepted -and $null -ne $last.Rejected -and ($last.Accepted+$last.Rejected) -gt 0) {$rejectRate=$last.Rejected/($last.Accepted+$last.Rejected)}
            $results += [pscustomobject]@{Profile=$profile;Seconds=$Seconds;Samples=$samples.Count;AverageHashrate=$hash;AveragePowerWatts=$power;HashesPerWatt=$efficiency;
                RejectedShareRate=$rejectRate;Accepted=$(if($last){$last.Accepted}else{$null});RecentErrors=$(if($last){$last.RecentErrors}else{@()});Stable=($samples.Count -ge 3 -and $last.PoolConnected -eq $true)}
        }
        Write-PPJson (Join-Path $DataRoot 'Backend\benchmark.json') $results
        $results
    } finally { Stop-PPDockerMiner $identity -Remove }
}

function Stop-PPControllerMiner {
    param($State, [string]$DataRoot)
    Stop-PPLegacyMiner $DataRoot
    if ((Read-PPInstallation $DataRoot) -or (Test-Path -LiteralPath (Join-Path $DataRoot 'Backend\container-used'))) {
        Stop-PPDockerMiner (Get-PPBackendIdentity $DataRoot)
    }
    $State.StartedUtc=$null
    $State.LastHealthyUtc=$null
    $State.LastTelemetry=$null
}

function Invoke-PPControllerTick {
    param($State, $Intent, [string]$DataRoot, [DateTime]$NowUtc=[DateTime]::UtcNow)
    $configuration=$Intent.Configuration
    $installation=Read-PPInstallation $DataRoot
    $backend=[string](Get-PPOption $configuration 'Backend' 'Docker')
    if ($backend -eq 'Auto') { $backend='Docker' }
    $State.Desired=[bool]$Intent.ShouldMine
    # A cold-start daemon outage must obey the same backoff as a mining crash.
    # Otherwise a slow Docker startup can exhaust all retries in a few seconds.
    if (-not $State.Reconciled -and $State.Failures -gt 0) {
        if ($State.Failures -ge 6 -and $State.Desired) {$State.State='ERROR';return $State}
        if ($NowUtc -lt $State.NextAttemptUtc) {return $State}
    }
    if ($State.Backend -ne $backend -or -not $State.Reconciled) {
        # Reboot/crash reconciliation always stops an inherited miner first. Manual
        # intent is never restored; the UI must reevaluate its current policy.
        Stop-PPControllerMiner $State $DataRoot
        $State.Backend=$backend; $State.Reconciled=$true
    }
    if (-not $State.Desired) {
        Stop-PPControllerMiner $State $DataRoot
        $State.State=if ($Intent.Status -eq 'Stopped manually' -or $Intent.Status -eq 'Disabled') {'STOPPED'} else {'PAUSED'}
        return $State
    }
    if (-not $configuration.Configured) { $State.State='NOT_CONFIGURED'; return $State }
    if ($State.Failures -ge 6) { $State.State='ERROR'; return $State }
    if ($NowUtc -lt $State.NextAttemptUtc) {
        if ($State.State -notin @('DOCKER_UNAVAILABLE','GPU_UNAVAILABLE')) {$State.State='RECOVERING'}
        return $State
    }
    try {
        if ($backend -ne 'Docker') { throw 'Only the isolated Docker backend is supported; native execution is disabled.' }
        if (-not $installation) { $State.State='NOT_CONFIGURED'; $State.LastError='Install a validated Docker backend from the Backend tab in Menu.'; return $State }
        $identity=Get-PPBackendIdentity $DataRoot
        if (-not $State.StartedUtc) {
            if (Test-PPOtherMinerRunning -ExecutablePath (Get-PPOption $configuration 'WildRigPath' '') -OwnedProcessId $null) { throw 'A native WildRig process is already running. Stop it before using Docker.' }
            $State.State='STARTING'
            [void](New-Item -ItemType File -Path (Join-Path $DataRoot 'Backend\container-used') -Force)
            [void](Start-PPDockerMiner $identity $configuration $installation)
            $State.StartedUtc=$NowUtc
        }
        $metrics=Get-PPDockerTelemetry $identity $installation
        if ($metrics -and $metrics.ContainerRunning -and -not $metrics.LastShareUtc -and $State.LastTelemetry -and $metrics.Accepted -eq $State.LastTelemetry.Accepted) { $metrics.LastShareUtc=$State.LastTelemetry.LastShareUtc }
        if ($metrics -and $metrics.ContainerRunning) { [void](Invoke-PPDocker @('exec',$identity.Name,'touch','/tmp/pearlpilot.lease') -TimeoutSeconds 5) }
        $State.LastTelemetry=$metrics
        if (-not $metrics -or -not $metrics.ContainerRunning) { throw 'WildRig container exited unexpectedly.' }
        if ($metrics.Hashrate -gt 0 -and $metrics.LastHashUtc -and ($NowUtc-([DateTime]$metrics.LastHashUtc).ToUniversalTime()).TotalSeconds -lt 45 -and $metrics.PoolConnected -eq $true) {
            $State.State='MINING'
            $State.LastHealthyUtc=$NowUtc
            $State.LastError=''
            if (-not $installation.MiningValidated -and $metrics.Accepted -gt 0) {
                $installation.MiningValidated=$true
                Write-PPJson (Join-Path $DataRoot 'Backend\active.json') $installation
            }
            if (($NowUtc-$State.StartedUtc).TotalMinutes -ge 10) { $State.Failures=0; $State.LastError='' }
        } else {
            $lastHealthy=if ($State.LastHealthyUtc) {$State.LastHealthyUtc} else {$State.StartedUtc}
            if (($NowUtc-$lastHealthy).TotalSeconds -gt 120) {throw 'No recent PearlHash work or pool connectivity for 120 seconds.'}
            $State.State=if($State.LastHealthyUtc){'RECOVERING'}else{'STARTING'}
        }
    } catch {
        $failure=$_.Exception.Message
        try { Stop-PPControllerMiner $State $DataRoot } catch { $failure += ' Cleanup: ' + $_.Exception.Message }
        # Probationary update failed: restore last proven image for the next tick.
        if ($backend -eq 'Docker' -and $installation -and -not $installation.MiningValidated) {
            $previous=Read-PPInstallation $DataRoot 'previous'
            if ($previous -and $previous.MiningValidated -and $previous.Image -ne $installation.Image) {
                try {
                    Assert-PPInstallationImage (Get-PPBackendIdentity $DataRoot) $previous
                    Set-PPActiveInstallation $DataRoot $previous -Rollback
                    $failure += ' Rolled back to last known-good image.'
                } catch { $failure += ' Rollback unavailable: ' + $_.Exception.Message }
            }
        }
        Set-PPRecovery $State $failure $NowUtc
    }
    $State
}

function Set-PPRecovery {
    param($State, [string]$ErrorMessage, [DateTime]$NowUtc=[DateTime]::UtcNow)
    $State.Failures++
    $State.LastError=$ErrorMessage
    $State.State=if ($ErrorMessage -match 'GPU_UNAVAILABLE|could not select device driver|nvidia-container|CUDA initialization') {'GPU_UNAVAILABLE'} elseif ($ErrorMessage -match 'DOCKER_UNAVAILABLE|connect.*docker|docker.*connect|daemon|pipe') {'DOCKER_UNAVAILABLE'} elseif ($State.Failures -ge 6) {'ERROR'} else {'RECOVERING'}
    $State.NextAttemptUtc=$NowUtc.AddSeconds([Math]::Min(300,5*[Math]::Pow(2,$State.Failures-1)) + (Get-Random -Minimum 0 -Maximum 4))
}

Export-ModuleMember -Function *-PP*
