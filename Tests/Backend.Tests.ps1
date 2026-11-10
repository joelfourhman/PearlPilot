# Sourced by the dependency-free Windows PowerShell 5.1 suite.
Import-Module (Join-Path $root 'Core\Backend.psm1') -Force
$backendModule=Get-Module Backend
$backendOutput=Join-Path $testRoot ('.test-output\backend-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $backendOutput -Force)
[void](New-Item -ItemType Directory -Path (Join-Path $backendOutput 'Backend') -Force)
[void](New-Item -ItemType Directory -Path (Join-Path $backendOutput 'Runtime') -Force)
& $backendModule {param($Path) $script:testData=$Path} $backendOutput

function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern='.')
    try { & $Body } catch { Assert-True ($_.Exception.Message -match $Pattern) $_.Exception.Message; return }
    throw 'Expected failure.'
}

function New-TestRelease {
    [pscustomobject]@{ tag_name='0.51.8'; draft=$false; prerelease=$false; assets=@(
        [pscustomobject]@{ name='wildrig-multi-hiveos-0.51.8.tar.gz'; size=100; digest=('sha256:'+'a'*64); browser_download_url='https://github.com/andru-kun/wildrig-multi/releases/download/0.51.8/wildrig-multi-hiveos-0.51.8.tar.gz' },
        [pscustomobject]@{ name='wildrig-multi-linux-0.51.8.tar.gz'; size=100; digest=('sha256:'+'b'*64); browser_download_url='https://github.com/andru-kun/wildrig-multi/releases/download/0.51.8/wildrig-multi-linux-0.51.8.tar.gz' }) }
}

function New-TestArchive {
    param([string]$Path, [string]$Name='wildrig-multi', [byte]$Type=48, [switch]$Truncated)
    $header=New-Object byte[] 512
    [Text.Encoding]::ASCII.GetBytes($Name).CopyTo($header,0)
    $elf=New-Object byte[] 20
    $elf[0]=127; $elf[1]=69; $elf[2]=76; $elf[3]=70; $elf[4]=2; $elf[5]=1; $elf[18]=62
    [Text.Encoding]::ASCII.GetBytes('00000000024'+[char]0).CopyTo($header,124)
    $header[156]=$Type
    for ($i=148; $i -lt 156; $i++) {$header[$i]=32}
    $sum=($header | Measure-Object -Sum).Sum
    [Text.Encoding]::ASCII.GetBytes(([Convert]::ToString([int]$sum,8).PadLeft(6,'0')+[char]0+' ')).CopyTo($header,148)
    $file=[IO.File]::Create($Path)
    $gzip=New-Object IO.Compression.GZipStream($file,[IO.Compression.CompressionMode]::Compress)
    try {
        $gzip.Write($header,0,512)
        if (-not $Truncated) { $gzip.Write($elf,0,20); $padding=New-Object byte[] 1516; $gzip.Write($padding,0,1516) }
    } finally { $gzip.Dispose(); $file.Dispose() }
}

Test-Case 'Official release selects Linux, never HiveOS or Windows' {
    $asset=Get-PPReleaseAsset (New-TestRelease)
    Assert-True ($asset.Version -eq '0.51.8' -and $asset.Name -eq 'wildrig-multi-linux-0.51.8.tar.gz')
}
Test-Case 'Prereleases and unofficial assets fail closed' {
    $release=New-TestRelease; $release.prerelease=$true
    Assert-Throws { Get-PPReleaseAsset $release } 'stable'
    $release=New-TestRelease; $release.assets[1].digest=$null
    Assert-True (-not (Get-PPReleaseAsset $release).Sha256)
    $release=New-TestRelease; $release.assets[1].browser_download_url='https://mirror.invalid/miner.tar.gz'
    Assert-Throws { Get-PPReleaseAsset $release } 'non-official'
}
Test-Case 'Explicit version pins are validated before any HTTP request' {
    Assert-Throws { Get-PPWildRigRelease $backendOutput '../latest' } 'Version must'
}
Test-Case 'Release cache prevents repeated GitHub requests' {
    Write-PPJson (Join-Path $backendOutput 'release-latest.json') (New-TestRelease)
    $asset=Get-PPWildRigRelease $backendOutput
    Assert-True ($asset.Version -eq '0.51.8')
}
Test-Case 'Update skips releases that are already installed or older' {
    $target=Join-Path $backendOutput 'update-current'
    $cache=Join-Path $target 'Backend'
    [void][IO.Directory]::CreateDirectory($cache)
    Write-PPJson (Join-Path $cache 'release-0.51.8.json') (New-TestRelease)
    foreach ($version in @('0.51.8','0.52.1')) {
        Write-PPJson (Join-Path $cache 'active.json') ([pscustomobject]@{Version=$version})
        Assert-True ($null -eq (Install-PPDockerWildRig $target '0.51.8' -UpdateOnly))
    }
}
Test-Case 'Explicit latest installation refreshes upstream metadata before downloading' {
    $result=& $backendModule {
        $original=(Get-Command Get-PPWildRigRelease).ScriptBlock
        try {
            $script:requestedVersion=''; $script:refreshed=$false
            function script:Get-PPWildRigRelease {
                param($CacheRoot,$Version,[switch]$Refresh)
                $script:requestedVersion=$Version; $script:refreshed=[bool]$Refresh
                throw 'Stopped after release lookup'
            }
            $message=''
            try {Install-PPDockerWildRig $script:testData} catch {$message=$_.Exception.Message}
            [pscustomobject]@{Version=$script:requestedVersion;Refreshed=$script:refreshed;Error=$message}
        } finally {Set-Item Function:script:Get-PPWildRigRelease $original}
    }
    Assert-True ($result.Version -eq 'latest' -and $result.Refreshed -and $result.Error -match 'Stopped after release lookup')
}
Test-Case 'Archive verification checks size, SHA256, gzip, and safe ELF extraction' {
    $path=Join-Path $backendOutput 'valid.tar.gz'; New-TestArchive $path
    $asset=[pscustomobject]@{ Size=(Get-Item $path).Length; Sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    Test-PPArtifact $path $asset
    $destination=Join-Path $backendOutput ([guid]::NewGuid().ToString())
    $binary=Expand-PPArchive $path $destination
    Assert-True (Test-Path -LiteralPath $binary)
    $asset.Sha256='0'*64
    Assert-Throws { Test-PPArtifact $path $asset } 'checksum mismatch'
    $asset.Sha256=''
    Test-PPArtifact $path $asset
    $asset.Size=1
    Assert-Throws { Test-PPArtifact $path $asset } 'size mismatch'
}
Test-Case 'A cold install downloads and checks the archive before staging Docker' {
    $target=Join-Path $backendOutput 'cold-install'
    $cache=Join-Path $target 'Backend'
    [void][IO.Directory]::CreateDirectory($cache)
    $fixture=Join-Path $target 'fixture.tar.gz'
    New-TestArchive $fixture
    $release=New-TestRelease
    $release.assets[1].size=(Get-Item -LiteralPath $fixture).Length
    $release.assets[1].digest=$null
    Write-PPJson (Join-Path $cache 'release-0.51.8.json') $release
    & $backendModule {
        param($Target)
        $docker=(Get-Command Invoke-PPDocker).ScriptBlock
        try {
            function script:Invoke-WebRequest {
                param([switch]$UseBasicParsing,$Uri,$OutFile,$TimeoutSec,$Headers)
                Copy-Item -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $OutFile)) 'fixture.tar.gz') -Destination $OutFile
            }
            function script:Invoke-PPDocker {
                param($Arguments,$TimeoutSeconds,[switch]$AllowFailure)
                if ($Arguments[0] -ne 'build' -or ($Arguments -join ' ') -notmatch 'WILDRIG_SHA256=[a-f0-9]{64}') {
                    throw 'Unexpected build arguments.'
                }
                throw 'Reached Docker build with a verified archive.'
            }
            try { Install-PPDockerWildRig $Target '0.51.8'; throw 'Expected to stage Docker build.' }
            catch { if ($_.Exception.Message -ne 'Reached Docker build with a verified archive.') { throw } }
        } finally {
            Remove-Item Function:script:Invoke-WebRequest
            Set-Item Function:script:Invoke-PPDocker $docker
        }
    } $target
}
Test-Case 'Archives reject traversal, absolute paths, ADS, symlinks and truncation' {
    foreach ($name in @('../escape','/absolute','C:/evil','dir/../../evil','file:stream')) {
        $path=Join-Path $backendOutput 'bad.tar.gz'; New-TestArchive $path $name
        Assert-Throws { Expand-PPArchive $path (Join-Path $backendOutput ([guid]::NewGuid().ToString())) } 'Unsafe'
    }
    New-TestArchive $path 'wildrig-multi' 50
    Assert-Throws { Expand-PPArchive $path (Join-Path $backendOutput ([guid]::NewGuid().ToString())) } 'unsupported'
    New-TestArchive $path -Truncated
    Assert-Throws { Expand-PPArchive $path (Join-Path $backendOutput ([guid]::NewGuid().ToString())) } 'Truncated'
}
Test-Case 'Wallet and pool values remain separate validated argv elements' {
    $cfg=$configuration | ConvertTo-Json | ConvertFrom-Json
    $cfg.PoolUrl='stratum+tcp://pool.pearlhash.xyz:9000'
    $args=@(Get-PPMiningArgv $cfg)
    Assert-True ($args[$args.IndexOf('--user')+1] -eq $cfg.Wallet)
    Assert-True ($args[$args.IndexOf('--url')+1] -eq $cfg.PoolUrl)
    $cfg.Wallet='prl1$(Start-Process bad)'
    Assert-Throws { Get-PPMiningArgv $cfg } 'wallet'
    $cfg.Wallet=$configuration.Wallet; $cfg.PoolUrl='pool:9000 --privileged'
    Assert-Throws { Get-PPMiningArgv $cfg } 'Pool'
}
Test-Case 'Kernel flags are checked against the actual installed help' {
    Assert-Throws { Get-PPMiningArgv $configuration '--algo pearlhash --gpu-list' } 'does not advertise'
    $cfg=$configuration | ConvertTo-Json | ConvertFrom-Json
    $cfg.PearlHashKernel=''
    Assert-True (@(Get-PPMiningArgv $cfg '--algo pearlhash --gpu-list') -notcontains '--pearlhash-kernel')
}
Test-Case 'Docker create has GPU access, ownership, loopback API and security limits' {
    $identity=Get-PPBackendIdentity $backendOutput
    $args=Get-PPContainerCreateArgs $identity 'sha256:test' @('--user','wallet')
    foreach ($flag in @('--gpus','--read-only','--cap-drop','--security-opt','--pids-limit','--memory','--cpus','127.0.0.1::3333')) { Assert-True ($args -contains $flag) $flag }
    Assert-True ($args[$args.IndexOf('--restart')+1] -eq 'no')
    Assert-True ($args[$args.IndexOf('--user')+1] -eq '65532:65532')
    Assert-True ($args[$args.IndexOf('--pull')+1] -eq 'never')
    Assert-True ($args -contains '/tmp:rw,noexec,nosuid,nodev,size=128m')
    Assert-False ($args -contains '--privileged')
    Assert-False (($args -join ' ') -match 'docker.sock')
}
Test-Case 'Equivalent data-root spellings cannot create competing controller identities' {
    $absolute=[IO.Path]::GetFullPath($backendOutput)
    $first=Get-PPBackendIdentity $absolute
    $second=Get-PPBackendIdentity ($absolute.ToUpperInvariant()+'\')
    Assert-True ($first.Name -eq $second.Name -and $first.Owner -eq $second.Owner)
}
Test-Case 'Native API fixture normalizes real hashrate, shares and uptime' {
    $api=Get-Content (Join-Path $testRoot 'Fixtures\wildrig-0.51.8-api.json') -Raw | ConvertFrom-Json
    $metrics=ConvertFrom-PPWildRigApi $api
    Assert-True ($metrics.Hashrate -gt 1e14)
    Assert-True ($metrics.Accepted -ge 2 -and $metrics.Rejected -eq 0)
    Assert-True ($metrics.PoolConnected -and $metrics.MinerUptimeSeconds -gt 0)
    Assert-True ($null -eq $metrics.Stale)
    $api.uptime=10
    Assert-True ($null -eq (ConvertFrom-PPWildRigApi $api).AverageHashrate)
}
Test-Case 'Real log format supports TH/s, 60s averages and share timestamps' {
    $text=Get-Content (Join-Path $testRoot 'Fixtures\wildrig-0.51.8.log') -Raw
    $metrics=ConvertFrom-PPMinerLog $text
    Assert-True ($metrics.Hashrate -gt 1e14 -and $metrics.AverageHashrate -gt 1e14)
    Assert-True ($metrics.Accepted -ge 2 -and $metrics.LastShareUtc -ne $null)
    $unknown=ConvertFrom-PPMinerLog 'unrecognized output'
    Assert-True ($null -eq $unknown.Hashrate -and $null -eq $unknown.Accepted)
}
Test-Case 'Idle and gaming policies preserve thermal safety and manual override rules' {
    Assert-True (Get-PPMiningDecision -SessionState Unlocked -IdleMinutes 5 -IdleSeconds 301).ShouldMine
    Assert-False (Get-PPMiningDecision -SessionState Unlocked -IdleMinutes 5 -IdleSeconds 299).ShouldMine
    Assert-False (Get-PPMiningDecision -SessionState Locked -ManualMining $true -WorkloadBlocked $true).ShouldMine
    Assert-False (Get-PPMiningDecision -SessionState Locked -ManualMining $true -Suspended $true).ShouldMine
}
Test-Case 'Recovery is bounded and uses exponential backoff' {
    $state=New-PPControllerState
    Set-PPRecovery $state 'Unexpected exit' $now
    Assert-True (($state.NextAttemptUtc-$now).TotalSeconds -ge 5)
    for ($i=0; $i -lt 5; $i++) { Set-PPRecovery $state 'Unexpected exit' $now }
    Assert-True ($state.Failures -eq 6 -and $state.State -eq 'ERROR')
    Set-PPRecovery $state 'DOCKER_UNAVAILABLE: daemon stopped' $now
    Assert-True ($state.State -eq 'DOCKER_UNAVAILABLE')
}
Test-Case 'Safe subprocess argv round-trips spaces, quotes and shell metacharacters' {
    $echo=Join-Path $backendOutput 'echo.ps1'
    'param([string]$Value) [Console]::WriteLine($Value)' | Set-Content -LiteralPath $echo
    $value='wallet-like text; $(not-a-command) & "quoted" C:\trailing path\'
    $result=Invoke-PPCommand (Get-PPWindowsPowerShellPath) @('-NoProfile','-ExecutionPolicy','Bypass','-File',$echo,'-Value',$value)
    Assert-True ($result.ExitCode -eq 0 -and $result.Output.TrimEnd("`r","`n") -ceq $value)
    Assert-True ((ConvertTo-PPArgument '--status') -ceq '--status')
}
Test-Case 'Subprocess deadlines stop hung child processes' {
    Assert-Throws { Invoke-PPCommand (Get-PPWindowsPowerShellPath) @('-NoProfile','-Command','Start-Sleep -Seconds 10') -TimeoutSeconds 1 } 'timed out'
}
Test-Case 'Atomic JSON replacement tolerates a concurrent Windows reader' {
    Add-Type -TypeDefinition @'
namespace PearlPilot.Tests {
 public static class LockedFile {
  public static void ReleaseLater(System.IDisposable stream) {
   System.Threading.ThreadPool.QueueUserWorkItem(state => {
    System.Threading.Thread.Sleep(150); ((System.IDisposable)state).Dispose();
   }, stream);
  }
 }
}
'@
    $path=Join-Path $backendOutput 'atomic.json'
    Write-PPJson $path ([pscustomobject]@{Generation=1})
    $reader=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        [PearlPilot.Tests.LockedFile]::ReleaseLater($reader)
        Write-PPJson $path ([pscustomobject]@{Generation=2})
        Assert-True ((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Generation -eq 2)
        Assert-True (@(Get-ChildItem -LiteralPath $backendOutput -Filter 'atomic.json.*.tmp').Count -eq 0)
        $writer=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {
            [PearlPilot.Tests.LockedFile]::ReleaseLater($writer)
            Assert-True ((Read-PPJson $path).Generation -eq 2)
        } finally {$writer.Dispose()}
    } finally {$reader.Dispose()}
}
Test-Case 'New WildRig versions use compatible telemetry and preserve missing metrics' {
    $api=Get-Content (Join-Path $testRoot 'Fixtures\wildrig-0.51.8-api.json') -Raw | ConvertFrom-Json
    $api.hashrate.total[0]=$null
    Assert-True ($null -eq (ConvertFrom-PPWildRigApi $api).Hashrate)
    $api.version='0.52.1'
    Assert-True ((ConvertFrom-PPWildRigApi $api).PoolConnected)
    $api.algo='unsupported'
    Assert-Throws { ConvertFrom-PPWildRigApi $api } 'Unexpected'
    Assert-True ((ConvertFrom-PPMinerLog 'speed: 400 TH/s').Hashrate -eq 400e12)
}
Test-Case 'WildRig 0.51.9 hardware fixtures preserve API and log health metrics' {
    $api=Get-Content (Join-Path $testRoot 'Fixtures\wildrig-0.51.9-api.json') -Raw | ConvertFrom-Json
    $metrics=ConvertFrom-PPWildRigApi $api
    Assert-True ($api.version -eq '0.51.9' -and $metrics.Hashrate -gt 0 -and $metrics.AverageHashrate -gt 0)
    Assert-True ($metrics.Accepted -eq $api.results.shares_good -and $metrics.PoolConnected -and $metrics.MinerUptimeSeconds -ge 60)
    $text=Get-Content (Join-Path $testRoot 'Fixtures\wildrig-0.51.9.log') -Raw
    $logs=ConvertFrom-PPMinerLog $text
    Assert-True ($logs.Hashrate -gt 0 -and $logs.AverageHashrate -gt 0)
    Assert-True ($logs.LastHashUtc -ne $null)
    if ($metrics.Accepted -gt 0) {Assert-True ($logs.Accepted -gt 0 -and $logs.LastShareUtc -ne $null)}
    else {Assert-True ($null -eq $logs.Accepted -and $null -eq $logs.LastShareUtc)}
    Assert-True ($logs.RecentErrors.Count -eq 0)
}
Test-Case 'Benchmark cannot run without explicit authorization' {
    Assert-Throws { Invoke-PPBenchmark $backendOutput $configuration $null } 'authorization'
}
Test-Case 'Heartbeats reject malformed, expired and future timestamps' {
    Assert-True (Test-PPFreshTimestamp $now.ToString('o') 15 $now)
    Assert-False (Test-PPFreshTimestamp 'not-a-date' 15 $now)
    Assert-False (Test-PPFreshTimestamp $now.AddSeconds(-16).ToString('o') 15 $now)
    Assert-False (Test-PPFreshTimestamp $now.AddMinutes(1).ToString('o') 15 $now)
}
Test-Case 'Unlock shows stopping until the worker confirms the automatic pause' {
    $snapshot=[pscustomobject]@{UpdatedUtc=$now.ToString('o');State='MINING';Telemetry=[pscustomobject]@{Hashrate=400e12}}
    $manual=Get-PPMiningDecision -SessionState Unlocked -ManualMining $true -NowUtc $now
    $display=Get-PPBackendDisplaySnapshot $snapshot $manual.ShouldMine -NowUtc $now
    Assert-True ($display.State -eq 'MINING' -and $display.Telemetry.Hashrate -eq 400e12)

    $automatic=Get-PPMiningDecision -SessionState Unlocked -NowUtc $now
    $display=Get-PPBackendDisplaySnapshot $snapshot $automatic.ShouldMine -NowUtc $now
    Assert-True ($display.State -eq 'STOPPING' -and $null -eq $display.Telemetry)
    Assert-True ($snapshot.State -eq 'MINING' -and $null -ne $snapshot.Telemetry)

    $snapshot.State='PAUSED'
    $snapshot.Telemetry=$null
    $display=Get-PPBackendDisplaySnapshot $snapshot $automatic.ShouldMine -NowUtc $now
    Assert-True ($display.State -eq 'PAUSED')
}
Test-Case 'Expired snapshots and exited workers cannot report live mining' {
    $snapshot=[pscustomobject]@{UpdatedUtc=$now.AddSeconds(-16).ToString('o');State='MINING'}
    Assert-True ($null -eq (Get-PPBackendDisplaySnapshot $snapshot $true -NowUtc $now))
    $snapshot.UpdatedUtc=$now.ToString('o')
    Assert-True ($null -eq (Get-PPBackendDisplaySnapshot $snapshot $true -WorkerExited $true -NowUtc $now))
}
Test-Case 'Stop confirmation requires acknowledgement of the current stop intent' {
    $at=[DateTime]::UtcNow
    $snapshot=[pscustomobject]@{Desired=$false;State='STOPPED';IntentUpdatedUtc=$at.AddSeconds(-1).ToString('o')}
    Assert-False (Test-PPStopAcknowledged $snapshot $at)
    $snapshot.IntentUpdatedUtc=$at.ToString('o')
    Assert-True (Test-PPStopAcknowledged $snapshot $at)
    $snapshot.State='UPDATING'
    Assert-False (Test-PPStopAcknowledged $snapshot $at)
    $snapshot.State='STOPPED'; $snapshot.Desired=$true
    Assert-False (Test-PPStopAcknowledged $snapshot $at)
}
Test-Case 'Requests are unique, timestamped, bounded and tied to the authorizing panel' {
    Send-PPBackendRequest $backendOutput 'Retry'
    Send-PPBackendRequest $backendOutput 'Retry'
    $files=@(Get-ChildItem (Join-Path $backendOutput 'Runtime') -Filter 'request-*.json')
    Assert-True ($files.Count -eq 2)
    $request=Read-PPJson $files[0].FullName
    $intent=[pscustomobject]@{ShouldMine=$false;Status='Backend panel open';PanelId='current-panel';UpdatedUtc=[DateTime]::UtcNow.ToString('o')}
    Assert-PPBackendRequest $request $intent
    $request.RequestedUtc=[DateTime]::UtcNow.AddMinutes(-3).ToString('o')
    Assert-Throws {Assert-PPBackendRequest $request $intent} 'expired'
    $request.RequestedUtc=[DateTime]::UtcNow.ToString('o'); $request.Action='Benchmark'; $request.PanelId='old-panel'
    Assert-Throws {Assert-PPBackendRequest $request $intent} 'current, open backend panel'
    $request.PanelId=$intent.PanelId
    Assert-PPBackendRequest $request $intent
    $intent.ShouldMine=$true
    Assert-Throws {Assert-PPBackendRequest $request $intent} 'mining paused'
}
Test-Case 'Installation metadata cannot escape its supported slots' {
    Assert-Throws {Read-PPInstallation $backendOutput '..\config'} 'ValidateSet|does not belong'
}

$coreModule=Get-Module PearlPilot
Test-Case 'Configuration migration preserves existing and unknown preferences' {
    $savedDataRoot=& $coreModule { (Get-Command Get-PPDataRoot).ScriptBlock }
    try {
        & $coreModule {param($Path) $script:fixtureDataRoot=$Path; function script:Get-PPDataRoot {$script:fixtureDataRoot} } (Join-Path $backendOutput 'config')
        $configRoot=Initialize-PPDataRoot
        Write-PPJson (Join-Path $configRoot 'config.json') ([pscustomobject]@{Backend='Native';WildRigVersion='latest';Wallet=$configuration.Wallet;WorkerName='saved-worker';UserStopped=$true;CustomSetting=[pscustomobject]@{Nested='keep'}})
        $merged=Get-PPConfiguration
        Assert-True ($merged.WorkerName -eq 'saved-worker' -and $merged.UserStopped -and $merged.Backend -eq 'Docker')
        Assert-True ($merged.WildRigVersion -eq 'latest' -and -not $merged.AutomaticUpdates)
        Save-PPConfiguration $merged
        $saved=Get-Content (Join-Path $configRoot 'config.json') -Raw | ConvertFrom-Json
        Assert-True ($saved.CustomSetting.Nested -eq 'keep')
        '{broken-json' | Set-Content -LiteralPath (Join-Path $configRoot 'config.json')
        Assert-Throws {Get-PPConfiguration} 'Cannot read saved settings'
    } finally { & $coreModule {param($Body) Set-Item Function:script:Get-PPDataRoot $Body} $savedDataRoot }
}
Test-Case 'An isolated first installation can save settings without a preexisting wallet or cache' {
    $fresh=Join-Path $backendOutput 'empty-install'
    $cfg=Get-PPConfiguration -DataRoot $fresh
    Assert-False $cfg.Configured
    Assert-True ($cfg.Wallet -eq '' -and $cfg.Backend -eq 'Docker')
    Assert-False $cfg.AutomaticUpdates
    $cfg.AutomaticUpdates=$true
    Save-PPConfiguration $cfg -DataRoot $fresh
    $saved=Get-PPConfiguration -DataRoot $fresh
    Assert-True $saved.AutomaticUpdates
    Assert-False (Test-Path -LiteralPath (Join-Path $fresh 'Backend\active.json'))
}

Test-Case 'Automatic updates wait for fresh idle policy and skip a previously attempted release' {
    $intent=[pscustomobject]@{Configuration=[pscustomobject]@{AutomaticUpdates=$false}; ShouldMine=$false; Status='Idle'; UpdatedUtc=[DateTime]::UtcNow.ToString('o')}
    $state=New-PPControllerState
    $state.Reconciled=$true
    $release=[pscustomobject]@{Version='0.52.1'}
    Assert-False (Test-PPAutomaticUpdateDue $intent $state $release '')
    $intent.Configuration.AutomaticUpdates=$true
    Assert-True (Test-PPAutomaticUpdateDue $intent $state $release '')
    Assert-False (Test-PPAutomaticUpdateDue $intent $state $release $release.Version)
    $intent.ShouldMine=$true
    Assert-False (Test-PPAutomaticUpdateDue $intent $state $release '')
    $intent.ShouldMine=$false
    $intent.Status='Backend panel open'
    Assert-False (Test-PPAutomaticUpdateDue $intent $state $release '')
    $intent.Status='Idle'
    $intent.UpdatedUtc=[DateTime]::UtcNow.AddMinutes(-1).ToString('o')
    Assert-False (Test-PPAutomaticUpdateDue $intent $state $release '')
}

Test-Case 'Real worker IPC handles startup, unconfigured intent, stop and stale heartbeat' {
    $workerRoot=Join-Path $backendOutput 'worker'
    foreach ($directory in @('Runtime','Logs','Backend')) {[void](New-Item -ItemType Directory -Path (Join-Path $workerRoot $directory) -Force)}
    Write-PPJson (Join-Path $workerRoot 'Backend\release-latest.json') (New-TestRelease)
    $cfg=Get-PPConfiguration -DataRoot $workerRoot
    $cfg.Configured=$true
    $intentFile=Join-Path $workerRoot 'Runtime\backend-intent.json'
    $statusFile=Join-Path $workerRoot 'Runtime\backend-status.json'
    $intent=[pscustomobject]@{Configuration=$cfg;ShouldMine=$true;Status='Manual mining';UpdatedUtc=[DateTime]::UtcNow.ToString('o');TemperatureC=71;TelemetryAvailable=$true}
    Write-PPJson $intentFile $intent
    $parent=Get-Process -Id $PID
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Get-PPWindowsPowerShellPath
    $start.Arguments=(@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'Core\BackendWorker.ps1'),'-ParentId',[string]$PID,'-ParentStartedUtc',$parent.StartTime.ToUniversalTime().ToString('o'),'-DataRoot',$workerRoot) | ForEach-Object {ConvertTo-PPArgument $_}) -join ' '
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($start)
    try {
        foreach ($expected in @('NOT_CONFIGURED','STOPPED','PAUSED')) {
            if ($expected -eq 'STOPPED') {$intent.ShouldMine=$false; $intent.Status='Stopped manually'; $intent.UpdatedUtc=[DateTime]::UtcNow.ToString('o'); Write-PPJson $intentFile $intent}
            if ($expected -eq 'PAUSED') {$intent.ShouldMine=$true; $intent.Status='Old permission'; $intent.UpdatedUtc=[DateTime]::UtcNow.AddMinutes(-1).ToString('o'); Write-PPJson $intentFile $intent}
            $deadline=[DateTime]::UtcNow.AddSeconds(10); $matched=$false
            do {
                if (Test-Path -LiteralPath $statusFile) {
                    try { $snapshot=Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json; $matched=$snapshot.State -eq $expected } catch { }
                }
                if (-not $matched) {Start-Sleep -Milliseconds 100}
            } while (-not $matched -and [DateTime]::UtcNow -lt $deadline -and -not $process.HasExited)
            Assert-True $matched "Worker did not reach $expected."
            if ($expected -eq 'STOPPED') {Assert-True (Test-PPStopAcknowledged $snapshot ([DateTime]::Parse($intent.UpdatedUtc)))}
        }
        Assert-False $snapshot.Desired
        Assert-True ($snapshot.PolicyStatus -eq 'Controller heartbeat expired' -and $snapshot.TemperatureC -eq 71 -and $snapshot.TelemetryAvailable)
        $workerLog=Get-Content (Join-Path $workerRoot 'Logs\PearlPilot.log') -Raw
        Assert-True ($workerLog -match 'Policy: Controller heartbeat expired; GPU temperature: 71 C; telemetry available: True')
        Assert-True ($null -eq $snapshot.Installed)
        Assert-True (Test-Path -LiteralPath (Join-Path $workerRoot 'Runtime\backend-recovery.json'))
        $malformed=Join-Path $workerRoot 'Runtime\request-000-invalid.json'
        '{broken' | Set-Content -LiteralPath $malformed
        Send-PPBackendRequest $workerRoot 'Retry'
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        do {
            $remaining=@(Get-ChildItem (Join-Path $workerRoot 'Runtime') -Filter 'request-*.json')
            if ($remaining.Count) {Start-Sleep -Milliseconds 100}
        } while ($remaining.Count -and [DateTime]::UtcNow -lt $deadline -and -not $process.HasExited)
        Assert-True ($remaining.Count -eq 0 -and -not $process.HasExited) 'Malformed request blocked worker supervision.'
    } finally {if (-not $process.HasExited) {$process.Kill();$process.WaitForExit()};$process.Dispose()}
}

$originals=& $backendModule {
    $saved=@{}
    foreach ($name in @('Invoke-PPDocker','Invoke-PPCommand','Test-PPPoolConnection','Read-PPInstallation','Stop-PPControllerMiner','Start-PPDockerMiner','Get-PPDockerTelemetry','Set-PPActiveInstallation','Assert-PPInstallationImage')) { $saved[$name]=(Get-Command $name).ScriptBlock }
    $saved
}
try {
    Test-Case 'Docker command timeouts identify the unavailable engine and explain recovery' {
        $result=& $backendModule {
            $commandBody=(Get-Command Invoke-PPCommand).ScriptBlock
            try {
                function script:Invoke-PPCommand {param($File,$Arguments,$TimeoutSeconds) throw "$File cancelled or timed out after $TimeoutSeconds seconds."}
                $message=''
                try {Invoke-PPDocker @('info')} catch {$message=$_.Exception.Message}
                $state=New-PPControllerState
                Set-PPRecovery $state $message
                [pscustomobject]@{Message=$message;State=$state.State}
            } finally {Set-Item Function:script:Invoke-PPCommand $commandBody}
        }
        Assert-True ($result.State -eq 'DOCKER_UNAVAILABLE' -and $result.Message -match 'Restart Docker Desktop.*Retry mining controller')
    }
    Test-Case 'Offline validation cleans up its container even when Docker times out' {
        $result=& $backendModule {
            $stopBody=(Get-Command Stop-PPDockerMiner).ScriptBlock
            try {
                $script:validationStops=0; $script:validationArgs=@()
                function script:Stop-PPDockerMiner {param($Identity,[switch]$Remove) $script:validationStops++}
                function script:Invoke-PPDocker {param($Arguments,$TimeoutSeconds,[switch]$AllowFailure) $script:validationArgs=$Arguments; throw 'validation timeout'}
                $message=''
                try {Invoke-PPImageValidation (Get-PPBackendIdentity $script:testData) 'sha256:test' '--help'} catch {$message=$_.Exception.Message}
                [pscustomobject]@{Stops=$script:validationStops;Args=$script:validationArgs;Message=$message}
            } finally {Set-Item Function:script:Stop-PPDockerMiner $stopBody}
        }
        Assert-True ($result.Stops -eq 2 -and $result.Message -match 'timeout')
        Assert-True ($result.Args[$result.Args.IndexOf('--network')+1] -eq 'none')
        Assert-False ($result.Args -contains '--gpus')
        Assert-True ($result.Args -contains '--read-only' -and $result.Args -contains '65532:65532')
    }
    Test-Case 'Image validation rejects old policies, wrong owners and mutable tags' {
        $result=& $backendModule {
            $identity=Get-PPBackendIdentity $script:testData
            $digest='a'*64
            $record=[pscustomobject]@{Version='0.51.8';Sha256=$digest;Image=('sha256:'+'a'*64)}
            $script:mockImage=[pscustomobject]@{Id=$record.Image;Os='linux';Architecture='amd64';Config=[pscustomobject]@{
                User='65532:65532';Entrypoint=@('/opt/pearlpilot/supervisor.sh');Volumes=$null;Labels=[pscustomobject]@{
                    'io.pearlpilot.app'='wildrig';'io.pearlpilot.owner'=$identity.Owner;'io.pearlpilot.version'='0.51.8';
                    'io.pearlpilot.sha256'=$digest;'io.pearlpilot.security-revision'='2'}}}
            function script:Invoke-PPDocker {param($Arguments) [pscustomobject]@{Output=($script:mockImage | ConvertTo-Json -Depth 10)}}
            Assert-PPInstallationImage $identity $record
            $failures=0
            foreach ($change in @('policy','owner','tag','volume')) {
                $script:mockImage.Config.Labels.'io.pearlpilot.security-revision'='2'
                $script:mockImage.Config.Labels.'io.pearlpilot.owner'=$identity.Owner
                $record.Image=$script:mockImage.Id
                $script:mockImage.Config.Volumes=$null
                switch ($change) {
                    'policy' {$script:mockImage.Config.Labels.'io.pearlpilot.security-revision'='1'}
                    'owner' {$script:mockImage.Config.Labels.'io.pearlpilot.owner'='someone-else'}
                    'tag' {$record.Image='pearlpilot/wildrig:latest'}
                    'volume' {$script:mockImage.Config.Volumes=[pscustomobject]@{'/host'=[pscustomobject]@{}}}
                }
                try {Assert-PPInstallationImage $identity $record} catch {$failures++}
            }
            $failures
        }
        Assert-True ($result -eq 4)
    }
    Test-Case 'Docker ownership prevents touching an unrelated container' {
        & $backendModule {
            function script:Invoke-PPDocker { param($Arguments) if ($Arguments[1] -eq 'ls') { [pscustomobject]@{Output='abc'} } else { [pscustomobject]@{Output='[{"Config":{"Labels":{"io.pearlpilot.owner":"other","io.pearlpilot.app":"wildrig"}}}]'} } }
            try { Get-PPOwnedContainer ([pscustomobject]@{Name='test';Owner='mine'}); throw 'Unexpected ownership acceptance' }
            catch { if ($_.Exception.Message -notmatch 'belongs to another') {throw} }
        }
    }
    Test-Case 'GPU preflight reports actual CUDA initialization failure separately' {
        $result=& $backendModule {
            function script:Invoke-PPCommand {param($File,$Arguments,$TimeoutSeconds) [pscustomobject]@{ExitCode=0;Output='NVIDIA GeForce RTX 5090, 621.01';Error=''} }
            function script:Test-PPPoolConnection {param($PoolUrl) throw 'Test pool is offline.'}
            function script:Invoke-PPDocker {
                param($Arguments,$TimeoutSeconds)
                $output=''
                if ($Arguments[0] -eq 'version') {$output='{"Os":"linux","Arch":"amd64","ApiVersion":"1.55"}'}
                elseif ($Arguments[0] -eq 'info') {$output='{"OperatingSystem":"Docker Desktop","KernelVersion":"test-WSL2"}'}
                elseif ($Arguments[0] -eq 'context') {$output='"npipe:////./pipe/dockerDesktopLinuxEngine"'}
                elseif ($Arguments -contains '/opt/pearlpilot/cuda-probe') {throw 'CUDA initialization failed, code=100, devices=0'}
                elseif ($Arguments -contains 'df') {$output="Filesystem 1024-blocks Used Available Capacity Mounted`n/dev/test 20000000 1 19000000 1% /"}
                elseif ($Arguments -contains 'nvidia-smi') {$output='NVIDIA GeForce RTX 5090, 621.01'}
                [pscustomobject]@{ExitCode=0;Output=$output;Error=''}
            }
            [pscustomobject]@{
                Install = Test-PPDockerPrerequisites $script:testData 'sha256:test' -SkipPoolCheck
                Diagnostics = Test-PPDockerPrerequisites $script:testData 'sha256:test'
            }
        }
        Assert-False $result.Install.Ready
        Assert-False ($result.Install.Checks.Check -contains 'Pool TCP')
        Assert-True (@($result.Diagnostics.Checks | Where-Object { $_.Check -eq 'Pool TCP' -and -not $_.Ready }).Count -eq 1)
        $failed=@($result.Install.Checks | Where-Object {-not $_.Ready -and $_.Check -eq 'NVIDIA CUDA driver API'})
        Assert-True ($failed.Count -eq 1 -and $failed[0].Detail -match 'CUDA initialization failed')
    }
    Test-Case 'Serialized start/stop and manual-stop reconciliation do not restart mining' {
        $result=& $backendModule {
            $script:fakeCalls=New-Object Collections.Generic.List[string]
            $script:fakeInstall=[pscustomobject]@{Version='0.51.8';Image='sha256:test';MiningValidated=$true;Help='--algo pearlhash --gpu-list --pearlhash-kernel'}
            function script:Read-PPInstallation {param($DataRoot,$Slot='active') if($Slot -eq 'active') {$script:fakeInstall} }
            function script:Stop-PPControllerMiner {param($State,$DataRoot) $script:fakeCalls.Add('stop'); $State.StartedUtc=$null }
            function script:Start-PPDockerMiner {param($Identity,$Configuration,$Installation) $script:fakeCalls.Add('start') }
            function script:Invoke-PPDocker {param($Arguments,$TimeoutSeconds) [pscustomobject]@{Output='';Error='';ExitCode=0} }
            function script:Get-PPDockerTelemetry {param($Identity,$Installation) [pscustomobject]@{ContainerRunning=$true;Hashrate=4e14;LastHashUtc=[DateTime]::UtcNow.ToString('o');LastShareUtc=$null;PoolConnected=$true;Accepted=2} }
            $state=New-PPControllerState
            $cfg=[pscustomobject]@{Backend='Docker';Configured=$true;WildRigPath=''}
            $intent=[pscustomobject]@{ShouldMine=$true;Status='Manual mining';Configuration=$cfg}
            [void](Invoke-PPControllerTick $state $intent $script:testData)
            $miningState=$state.State
            $intent.ShouldMine=$false; $intent.Status='Stopped manually'
            [void](Invoke-PPControllerTick $state $intent $script:testData)
            [void](Invoke-PPControllerTick $state $intent $script:testData)
            [pscustomobject]@{State=$state.State;FirstState=$miningState;Calls=@($script:fakeCalls.ToArray())}
        }
        Assert-True ($result.State -eq 'STOPPED')
        Assert-True ($result.FirstState -eq 'MINING')
        Assert-True (@($result.Calls | Where-Object {$_ -eq 'start'}).Count -eq 1)
    }
    Test-Case 'Legacy Auto never falls back when a Docker image is missing' {
        $result=& $backendModule {
            $readBody=(Get-Command Read-PPInstallation).ScriptBlock
            try {
                function script:Read-PPInstallation {param($DataRoot,$Slot='active') $null}
                $state=New-PPControllerState
                $intent=[pscustomobject]@{ShouldMine=$true;Status='Mining';Configuration=[pscustomobject]@{Backend='Auto';Configured=$true;WildRigPath='unused.exe'}}
                [void](Invoke-PPControllerTick $state $intent $script:testData)
                $state
            } finally {Set-Item Function:script:Read-PPInstallation $readBody}
        }
        Assert-True ($result.Backend -eq 'Docker' -and $result.State -eq 'NOT_CONFIGURED')
    }
    Test-Case 'Worker rejects explicit Native intent without launching a host miner' {
        $result=& $backendModule {
            $state=New-PPControllerState
            $intent=[pscustomobject]@{ShouldMine=$true;Status='Mining';Configuration=[pscustomobject]@{Backend='Native';Configured=$true;WildRigPath='unused.exe'}}
            [void](Invoke-PPControllerTick $state $intent $script:testData)
            $state
        }
        Assert-True ($result.LastError -match 'native execution is disabled' -and $result.Failures -eq 1)
    }
    Test-Case 'A crashed update rolls back to the last mining-validated image' {
        $result=& $backendModule {
            $script:fakeInstall.MiningValidated=$false
            function script:Get-PPDockerTelemetry {param($Identity,$Installation) [pscustomobject]@{ContainerRunning=$false} }
            function script:Read-PPInstallation {param($DataRoot,$Slot='active') if ($Slot -eq 'previous') {[pscustomobject]@{Image='sha256:good';MiningValidated=$true}} else {$script:fakeInstall} }
            function script:Set-PPActiveInstallation {param($DataRoot,$Installation,[switch]$Rollback) $script:rolledBack=$Installation.Image }
            function script:Assert-PPInstallationImage {param($Identity,$Installation)}
            $state=New-PPControllerState
            $intent=[pscustomobject]@{ShouldMine=$true;Status='Mining';Configuration=[pscustomobject]@{Backend='Docker';Configured=$true;WildRigPath=''}}
            [void](Invoke-PPControllerTick $state $intent $script:testData)
            [pscustomobject]@{Image=$script:rolledBack;State=$state.State;Failures=$state.Failures}
        }
        Assert-True ($result.Image -eq 'sha256:good' -and $result.Failures -eq 1)
    }
    Test-Case 'Automatic rollback rejects a previous image that fails validation' {
        $result=& $backendModule {
            $script:rolledBack=$null
            function script:Assert-PPInstallationImage {param($Identity,$Installation) throw 'Previous image is not approved'}
            $state=New-PPControllerState
            $intent=[pscustomobject]@{ShouldMine=$true;Status='Mining';Configuration=[pscustomobject]@{Backend='Docker';Configured=$true}}
            [void](Invoke-PPControllerTick $state $intent $script:testData)
            [pscustomobject]@{Image=$script:rolledBack;Error=$state.LastError}
        }
        Assert-True ($null -eq $result.Image -and $result.Error -match 'Rollback unavailable.*not approved')
    }
    Test-Case 'Daemon failure is recoverable and does not start a second miner' {
        $result=& $backendModule {
            function script:Read-PPInstallation {param($DataRoot,$Slot='active') if($Slot -eq 'active') {$script:fakeInstall} }
            function script:Start-PPDockerMiner {param($Identity,$Configuration,$Installation) throw 'DOCKER_UNAVAILABLE: daemon offline' }
            $state=New-PPControllerState
            $intent=[pscustomobject]@{ShouldMine=$true;Status='Mining';Configuration=[pscustomobject]@{Backend='Docker';Configured=$true;WildRigPath=''}}
            [void](Invoke-PPControllerTick $state $intent $script:testData)
            [void](Invoke-PPControllerTick $state $intent $script:testData)
            $state
        }
        Assert-True ($result.State -eq 'DOCKER_UNAVAILABLE' -and $result.Failures -eq 1)
    }
    Test-Case 'Reboot reconciliation respects backoff while Docker is starting' {
        $result=& $backendModule {
            $script:stopAttempts=0
            function script:Stop-PPControllerMiner {param($State,$DataRoot) $script:stopAttempts++; throw 'DOCKER_UNAVAILABLE: startup' }
            $state=New-PPControllerState
            $intent=[pscustomobject]@{ShouldMine=$true;Status='Automatic policy';Configuration=[pscustomobject]@{Backend='Docker';Configured=$true;WildRigPath=''}}
            $now=[DateTime]::UtcNow
            try {[void](Invoke-PPControllerTick $state $intent $script:testData $now)} catch {Set-PPRecovery $state $_.Exception.Message $now}
            [void](Invoke-PPControllerTick $state $intent $script:testData $now.AddSeconds(1))
            [pscustomobject]@{Attempts=$script:stopAttempts;Failures=$state.Failures}
        }
        Assert-True ($result.Attempts -eq 1 -and $result.Failures -eq 1)
    }
} finally {
    & $backendModule {param($Saved) foreach ($name in $Saved.Keys) {Set-Item -Path "Function:script:$name" -Value $Saved[$name]} } $originals
    # This test-only directory is resolved and constrained before recursive cleanup.
    $absolute=[IO.Path]::GetFullPath($backendOutput)
    if ($absolute.StartsWith([IO.Path]::GetFullPath((Join-Path $testRoot '.test-output'))+[IO.Path]::DirectorySeparatorChar)) { Remove-Item -LiteralPath $absolute -Recurse -Force }
}
