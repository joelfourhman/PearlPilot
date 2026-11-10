$script:menuColors = @{}
$palette = @{
    Canvas='#EDF3F8'; Surface='#FFFFFF'; Rail='#112538'; RailActive='#24485C'
    RailText='#EAF4F8'; RailMuted='#9EB8CB'; Text='#183247'; Muted='#51697D'
    Border='#D5E1EA'; Input='#F5F8FB'; Accent='#087869'; AccentSoft='#DDF5EE'
    Hover='#E1EEF3'; Warning='#87491D'; WarningSoft='#FBEBDD'; Console='#102334'
    TrayMining='#9BE7D4'; TrayWarning='#FFD29D'
}
foreach ($color in $palette.GetEnumerator()) {
    $script:menuColors[$color.Key] = [Drawing.ColorTranslator]::FromHtml($color.Value)
}

function New-PPMenuLabel {
    param([string]$Text, [float]$Size=10, [string]$Tone='Text', [switch]$Bold)
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.UseMnemonic = $false
    $label.ForeColor = $script:menuColors[$Tone]
    $family = if ($Bold) { 'Segoe UI Semibold' } else { 'Segoe UI' }
    $label.Font = New-Object Drawing.Font($family,$Size)
    $label.Margin = New-Object Windows.Forms.Padding(0)
    $label
}

function New-PPMenuButton {
    param([string]$Text, [switch]$Primary)
    $colors = $script:menuColors
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.FlatStyle = 'Flat'
    $button.UseVisualStyleBackColor = $false
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    $button.Font = New-Object Drawing.Font('Segoe UI Semibold',9)
    $button.BackColor = if ($Primary) { $colors.Accent } else { $colors.Surface }
    $button.ForeColor = if ($Primary) { $colors.Surface } else { $colors.Text }
    $button.FlatAppearance.BorderColor = if ($Primary) { $colors.Accent } else { $colors.Border }
    $button.FlatAppearance.MouseOverBackColor = if ($Primary) { [Drawing.ColorTranslator]::FromHtml('#086759') } else { $colors.Hover }
    $button.Height = 35
    $button
}

function New-PPTrayPopup {
    param($Icon)
    $colors = $script:menuColors
    $menu = New-Object Windows.Forms.ContextMenuStrip
    $menu.ShowImageMargin = $false
    $menu.ShowCheckMargin = $false
    $menu.BackColor = $colors.Surface
    $menu.Padding = New-Object Windows.Forms.Padding(0,0,0,4)

    $renderer = New-Object Windows.Forms.ToolStripProfessionalRenderer
    $renderer.RoundedEdges = $false
    $renderer.Add_RenderMenuItemBackground({
        param($sender,$eventArgs)
        $color = if ($eventArgs.Item.Selected) { $colors.AccentSoft } else { $colors.Surface }
        $brush = New-Object Drawing.SolidBrush($color)
        try {
            $eventArgs.Graphics.FillRectangle($brush,0,0,$eventArgs.Item.Width,$eventArgs.Item.Height)
        } finally { $brush.Dispose() }
    }.GetNewClosure())
    $menu.Renderer = $renderer

    $header = New-Object Windows.Forms.Panel
    $header.Size = New-Object Drawing.Size(268,89)
    $header.BackColor = $colors.Rail
    $mark = New-Object Windows.Forms.PictureBox
    $mark.Image = $Icon.ToBitmap()
    $mark.SizeMode = 'Zoom'
    $mark.SetBounds(5,11,29,29)
    $header.Controls.Add($mark)
    $menu.Add_Disposed({ $mark.Image.Dispose() }.GetNewClosure())
    $brand = New-PPMenuLabel 'PearlPilot' 12 'RailText' -Bold
    $brand.SetBounds(44,13,214,24)
    $header.Controls.Add($brand)
    $status = New-PPMenuLabel 'Starting' 10 'RailText' -Bold
    $status.SetBounds(6,45,248,20)
    $status.AutoEllipsis = $true
    $header.Controls.Add($status)
    $detail = New-PPMenuLabel '' 9 'RailMuted'
    $detail.SetBounds(6,66,248,18)
    $detail.AutoEllipsis = $true
    $header.Controls.Add($detail)
    $hostItem = New-Object Windows.Forms.ToolStripControlHost($header)
    $hostItem.AutoSize = $false
    $hostItem.Size = $header.Size
    $hostItem.Margin = New-Object Windows.Forms.Padding(0,0,0,4)
    [void]$menu.Items.Add($hostItem)
    $renderer.Add_RenderToolStripBackground({
        param($sender,$eventArgs)
        $brush = New-Object Drawing.SolidBrush($colors.Rail)
        try { $eventArgs.Graphics.FillRectangle($brush,1,1,$eventArgs.ToolStrip.Width-2,$header.Height+1) }
        finally { $brush.Dispose() }
    }.GetNewClosure())
    [pscustomobject]@{ Menu=$menu; Status=$status; Detail=$detail }
}

function Add-PPTrayAction {
    param($Menu, [string]$Text, [switch]$Primary)
    $item = New-Object Windows.Forms.ToolStripMenuItem($Text)
    $item.AutoSize = $false
    $item.Size = New-Object Drawing.Size(268,32)
    $item.Padding = New-Object Windows.Forms.Padding(13,0,8,0)
    $family = if ($Primary) { 'Segoe UI Semibold' } else { 'Segoe UI' }
    $item.Font = New-Object Drawing.Font($family,10)
    $item.ForeColor = if ($Primary) { $script:menuColors.Accent } else { $script:menuColors.Text }
    [void]$Menu.Items.Add($item)
    $item
}

function Get-PPTrayStatus {
    param($Snapshot, [string]$Policy, $Temperature, [bool]$WorkerExited)
    $state = Get-PPOption $Snapshot 'State'
    $title = switch ($state) {
        'MINING' { 'Mining' }
        'STARTING' { 'Starting miner' }
        'STOPPING' { 'Stopping miner' }
        'PAUSED' { if ($Policy -eq 'Idle') { 'Ready to mine' } else { 'Mining paused' } }
        'STOPPED' { 'Mining stopped' }
        'UPDATING' {
            if ($Snapshot.Operation -eq 'Install') { 'Updating WildRig' } else { 'Backend busy' }
        }
        'RECOVERING' { 'Recovering miner' }
        'NOT_CONFIGURED' { 'Backend setup needed' }
        'DOCKER_UNAVAILABLE' { 'Docker unavailable' }
        'GPU_UNAVAILABLE' { 'GPU unavailable' }
        'ERROR' { 'Backend needs attention' }
        default { if ($WorkerExited) { 'Controller offline' } else { 'Connecting to controller' } }
    }
    $hint = switch ($Policy) {
        'Idle' { 'Windows is unlocked' }
        'Disabled' { 'Automatic mining is off' }
        'Backend panel open' { 'Backend is open' }
        'Settings open' { 'Settings is open' }
        'Gaming / configured GPU application active' { 'GPU application active' }
        default { $Policy }
    }
    if ($WorkerExited) { $hint = 'Restart PearlPilot' }
    $rate = Get-PPOption (Get-PPOption $Snapshot 'Telemetry') 'Hashrate'
    if ($state -eq 'MINING' -and $null -ne $rate) { $hint = '{0:N1} TH/s' -f ($rate / 1e12) }
    $parts = @($hint)
    if ($null -ne $Temperature) { $parts += '{0:N0} °C' -f $Temperature }
    $issue = $WorkerExited -or $state -in @('RECOVERING','ERROR','DOCKER_UNAVAILABLE','GPU_UNAVAILABLE','NOT_CONFIGURED') -or
        [bool](Get-PPOption $Snapshot 'Error')
    [pscustomobject]@{ Title=$title; Detail=($parts -join '  ·  '); Mining=($state -eq 'MINING'); HasIssue=$issue;
        CanRetry=($state -in @('RECOVERING','ERROR','DOCKER_UNAVAILABLE','GPU_UNAVAILABLE')) }
}

function New-PPMenuGrid {
    param([int]$Columns, [int[]]$Rows)
    $grid = New-Object Windows.Forms.TableLayoutPanel
    $grid.Dock = 'Fill'
    $grid.Margin = New-Object Windows.Forms.Padding(0)
    $grid.ColumnCount = $Columns
    $grid.RowCount = $Rows.Count
    $grid.GrowStyle = 'FixedSize'
    for ($column = 0; $column -lt $Columns; $column++) {
        [void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', (100 / $Columns))))
    }
    foreach ($height in $Rows) {
        if ($height -gt 0) { [void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height))) }
        else { [void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100))) }
    }
    $grid
}

function New-PPMenuHeading {
    param([string]$Kicker, [string]$Title, [string]$Description)
    $heading = New-PPMenuGrid 1 @(0,0,0)
    $heading.AutoSize = $true
    $heading.AutoSizeMode = 'GrowAndShrink'
    $heading.Margin = New-Object Windows.Forms.Padding(0,0,0,12)
    $heading.Controls.Add((New-PPMenuLabel $Kicker 8 'Accent' -Bold),0,0)
    $heading.Controls.Add((New-PPMenuLabel $Title 23 'Text' -Bold),0,1)
    $heading.Controls.Add((New-PPMenuLabel $Description 10 'Muted'),0,2)
    foreach ($row in $heading.RowStyles) { $row.SizeType = 'AutoSize' }
    foreach ($label in $heading.Controls) {
        $label.AutoSize = $true
        $label.Dock = 'Top'
        $label.Margin = New-Object Windows.Forms.Padding(0,0,0,3)
    }
    $heading
}

function New-PPMenuMetric {
    param([string]$Title, [string]$InitialHint)
    $card = New-PPMenuGrid 1 @(20,37,24)
    $card.Padding = New-Object Windows.Forms.Padding(14,11,14,8)
    $card.BackColor = $script:menuColors.Surface
    $card.Margin = New-Object Windows.Forms.Padding(0,0,10,10)
    $caption = New-PPMenuLabel $Title 9 'Muted' -Bold
    $value = New-PPMenuLabel '—' 21 'Text' -Bold
    $value.AutoEllipsis = $true
    $hint = New-PPMenuLabel $InitialHint 9 'Muted'
    $hint.AutoEllipsis = $true
    # Draw changing telemetry in one paint pass to avoid a blank frame.
    $doubleBuffered = [Windows.Forms.Control].GetProperty('DoubleBuffered',[Reflection.BindingFlags]'Instance,NonPublic')
    foreach ($control in @($card,$value,$hint)) { $doubleBuffered.SetValue($control,$true,$null) }
    $card.Controls.Add($caption,0,0)
    $card.Controls.Add($value,0,1)
    $card.Controls.Add($hint,0,2)
    foreach ($label in $card.Controls) { $label.Dock = 'Fill' }
    [pscustomobject]@{ Card=$card; Value=$value; Hint=$hint }
}

function New-PPMenuTextBox {
    param([switch]$Console)
    $text = New-Object Windows.Forms.TextBox
    $text.Multiline = $true
    $text.ReadOnly = $true
    $text.Dock = 'Fill'
    $text.BorderStyle = 'None'
    $text.ScrollBars = if ($Console) { 'Both' } else { 'Vertical' }
    $text.WordWrap = -not $Console
    $text.BackColor = if ($Console) { $script:menuColors.Console } else { $script:menuColors.Surface }
    $text.ForeColor = if ($Console) { $script:menuColors.RailText } else { $script:menuColors.Text }
    $font = if ($Console) { 'Consolas' } else { 'Segoe UI' }
    $text.Font = New-Object Drawing.Font($font,10)
    $text
}

function New-PPMenuDetails {
    param([string]$Title)
    $card = New-PPMenuGrid 1 @(28,0)
    $card.Padding = New-Object Windows.Forms.Padding(15,12,15,12)
    $card.BackColor = $script:menuColors.Surface
    $heading = New-PPMenuLabel $Title 12 'Text' -Bold
    $heading.Dock = 'Fill'
    $text = New-PPMenuTextBox
    $text.Margin = New-Object Windows.Forms.Padding(0)
    $card.Controls.Add($heading,0,0)
    $card.Controls.Add($text,0,1)
    [pscustomobject]@{ Card=$card; Text=$text }
}

function Add-PPStatisticsPage {
    param($Page)
    $grid = New-PPMenuGrid 1 @(85,62,114,0)
    $grid.RowStyles[0].SizeType = 'AutoSize'
    $Page.Controls.Add($grid)
    $grid.Controls.Add((New-PPMenuHeading 'LIVE TELEMETRY' 'Mining overview' 'Track PearlHash performance and GPU health on this PC.'),0,0)

    $banner = New-PPMenuGrid 3 @(0)
    $banner.ColumnStyles[0].SizeType = 'Absolute'
    $banner.ColumnStyles[0].Width = 144
    $banner.ColumnStyles[2].SizeType = 'Absolute'
    $banner.ColumnStyles[2].Width = 120
    $banner.BackColor = $script:menuColors.Surface
    $banner.Padding = New-Object Windows.Forms.Padding(10,8,12,8)
    $banner.Margin = New-Object Windows.Forms.Padding(0,0,0,12)
    $status = New-PPMenuLabel 'Connecting' 9 'Muted' -Bold
    $status.BackColor = $script:menuColors.Input
    $status.TextAlign = 'MiddleCenter'
    $status.Dock = 'Fill'
    $status.Margin = New-Object Windows.Forms.Padding(0,0,12,0)
    $policy = New-PPMenuLabel 'Waiting for the mining controller' 10 'Text'
    $policy.Dock = 'Fill'
    $policy.TextAlign = 'MiddleLeft'
    $policy.AutoEllipsis = $true
    $banner.Controls.Add($status,0,0)
    $banner.Controls.Add($policy,1,0)
    $mineButton = New-PPMenuButton 'Mine now' -Primary
    $mineButton.Dock = 'Fill'
    $mineButton.Margin = New-Object Windows.Forms.Padding(8,0,0,0)
    $mineButton.Add_Click({ Switch-PPMining })
    $banner.Controls.Add($mineButton,2,0)
    $grid.Controls.Add($banner,0,1)

    $metrics = New-PPMenuGrid 3 @(0)
    $hashrate = New-PPMenuMetric 'HASHRATE' 'Current PearlHash work'
    $hashrate.Value.ForeColor = $script:menuColors.Accent
    $temperature = New-PPMenuMetric 'GPU TEMPERATURE' 'Hottest selected GPU'
    $shares = New-PPMenuMetric 'ACCEPTED SHARES' 'Current miner session'
    $shares.Card.Margin = New-Object Windows.Forms.Padding(0,0,0,10)
    $metrics.Controls.Add($hashrate.Card,0,0)
    $metrics.Controls.Add($temperature.Card,1,0)
    $metrics.Controls.Add($shares.Card,2,0)
    $grid.Controls.Add($metrics,0,2)

    $details = New-PPMenuGrid 2 @(0)
    $session = New-PPMenuGrid 1 @(31,156,0)
    $session.Padding = New-Object Windows.Forms.Padding(15,12,15,12)
    $session.BackColor = $script:menuColors.Surface
    $session.Margin = New-Object Windows.Forms.Padding(0,0,5,0)
    $title = New-PPMenuLabel 'Session & pool' 12 'Text' -Bold
    $title.Dock = 'Fill'
    $session.Controls.Add($title,0,0)
    $rows = New-PPMenuGrid 2 (@(26) * 6)
    $rows.ColumnStyles[0].Width = 44
    $rows.ColumnStyles[1].Width = 56
    $sessionValues = @{}
    $row = 0
    foreach ($entry in @(
        @('Pool connection','PoolConnected'), @('Rejected shares','Rejected'),
        @('Stale shares','Stale'), @('Miner uptime','MinerUptimeSeconds'),
        @('Container uptime','ContainerUptimeSeconds'), @('Last share (UTC)','LastShareUtc')
    )) {
        $key = New-PPMenuLabel $entry[0] 9 'Muted'
        $value = New-PPMenuLabel '—' 9 'Text' -Bold
        $value.AutoEllipsis = $true
        $key.Dock = $value.Dock = 'Fill'
        $rows.Controls.Add($key,0,$row)
        $rows.Controls.Add($value,1,$row++)
        $sessionValues[$entry[1]] = $value
    }
    $session.Controls.Add($rows,0,1)
    $sessionNotes = New-PPMenuTextBox
    $sessionNotes.Margin = New-Object Windows.Forms.Padding(0,4,0,0)
    $session.Controls.Add($sessionNotes,0,2)
    $details.Controls.Add($session,0,0)

    $gpu = New-PPMenuGrid 1 @(31,29,26,8,33,0)
    $gpu.Padding = New-Object Windows.Forms.Padding(15,12,15,12)
    $gpu.BackColor = $script:menuColors.Surface
    $gpu.Margin = New-Object Windows.Forms.Padding(5,0,0,0)
    $title = New-PPMenuLabel 'GPU activity' 12 'Text' -Bold
    $title.Dock = 'Fill'
    $gpu.Controls.Add($title,0,0)
    $gpuName = New-PPMenuLabel 'Waiting for NVIDIA telemetry' 12 'Text' -Bold
    $gpuName.AutoEllipsis = $true
    $gpuName.Dock = 'Fill'
    $gpu.Controls.Add($gpuName,0,1)
    $gpuUsage = New-PPMenuLabel 'Utilization   —' 9 'Muted'
    $gpuUsage.Dock = 'Fill'
    $gpu.Controls.Add($gpuUsage,0,2)
    $meter = New-Object Windows.Forms.Panel
    $meter.Margin = New-Object Windows.Forms.Padding(0)
    $meter.Dock = 'Fill'
    $meter.BackColor = $script:menuColors.Hover
    $meter.Tag = 0
    $fill = New-Object Windows.Forms.Panel
    $fill.BackColor = $script:menuColors.Accent
    $fill.Dock = 'Left'
    $fill.Width = 0
    $meter.Controls.Add($fill)
    $meter.Add_SizeChanged({ $fill.Width = [int]($meter.ClientSize.Width * $meter.Tag / 100) }.GetNewClosure())
    $gpu.Controls.Add($meter,0,3)
    $gpuPower = New-PPMenuLabel 'Power   —' 9 'Muted'
    $gpuPower.Dock = 'Fill'
    $gpuPower.TextAlign = 'MiddleLeft'
    $gpu.Controls.Add($gpuPower,0,4)
    $gpuNotes = New-PPMenuTextBox
    $gpuNotes.Margin = New-Object Windows.Forms.Padding(0)
    $gpu.Controls.Add($gpuNotes,0,5)
    $details.Controls.Add($gpu,1,0)
    $grid.Controls.Add($details,0,3)

    [pscustomobject]@{ Status=$status; Policy=$policy; MineButton=$mineButton; Hashrate=$hashrate; Temperature=$temperature; Shares=$shares;
        Session=$sessionValues; SessionNotes=$sessionNotes; GpuName=$gpuName; GpuUsage=$gpuUsage;
        GpuMeter=$meter; GpuFill=$fill; GpuPower=$gpuPower; GpuNotes=$gpuNotes }
}

function Set-PPMenuText {
    param($Control, [string]$Text)
    if ($Control.Text -cne $Text) { $Control.Text = $Text }
}

function Update-PPStatisticsPage {
    param($Page, $Snapshot, $Gpu, [string]$Policy, [string]$UnavailableStatus)
    $state = Get-PPOption $Snapshot 'State' 'CONNECTING'
    $status = switch ($state) {
        'DOCKER_UNAVAILABLE' { 'Docker unavailable' }
        'GPU_UNAVAILABLE' { 'GPU unavailable' }
        'NOT_CONFIGURED' { 'Setup needed' }
        default { [Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase(([string]$state).ToLowerInvariant()) }
    }
    $statusTone = 'Muted'
    $statusBackground = 'Input'
    if ($state -eq 'MINING') { $statusTone = 'Accent'; $statusBackground = 'AccentSoft' }
    if ($state -in @('ERROR','RECOVERING','DOCKER_UNAVAILABLE','GPU_UNAVAILABLE','STOPPING')) {
        $statusTone = 'Warning'
        $statusBackground = 'WarningSoft'
    }
    if ($UnavailableStatus -like 'ERROR:*') { $status = 'Controller offline'; $statusTone = 'Warning'; $statusBackground = 'WarningSoft' }
    Set-PPMenuText $Page.Status $status
    $Page.Status.ForeColor = $script:menuColors[$statusTone]
    $Page.Status.BackColor = $script:menuColors[$statusBackground]
    Set-PPMenuText $Page.Policy $(if ($Snapshot) { $Policy } else { $UnavailableStatus })

    $telemetry = Get-PPOption $Snapshot 'Telemetry'
    $rate = Get-PPOption $telemetry 'Hashrate'
    $average = Get-PPOption $telemetry 'AverageHashrate'
    $temperature = Get-PPOption $Gpu 'TemperatureC'
    $accepted = Get-PPOption $telemetry 'Accepted'
    Set-PPMenuText $Page.Hashrate.Value $(if ($null -ne $rate) { '{0:N1} TH/s' -f ($rate / 1e12) } else { '—' })
    Set-PPMenuText $Page.Hashrate.Hint $(if ($null -ne $average) { '60-second average  {0:N1} TH/s' -f ($average / 1e12) } else { 'Current PearlHash work' })
    Set-PPMenuText $Page.Temperature.Value $(if ($null -ne $temperature) { '{0:N0} °C' -f $temperature } else { '—' })
    Set-PPMenuText $Page.Shares.Value $(if ($null -ne $accepted) { '{0:N0}' -f $accepted } else { '—' })

    $pool = Get-PPOption $telemetry 'PoolConnected'
    Set-PPMenuText $Page.Session.PoolConnected $(if ($pool -eq $true) { 'Connected' } elseif ($pool -eq $false) { 'Disconnected' } else { '—' })
    foreach ($key in @('Rejected','Stale','MinerUptimeSeconds','ContainerUptimeSeconds','LastShareUtc')) {
        $value = Get-PPOption $telemetry $key
        $formatted = if ($null -eq $value) { '—' } elseif ($key.EndsWith('Seconds')) { '{0:N0} s' -f $value } else { [string]$value }
        Set-PPMenuText $Page.Session[$key] $formatted
    }
    $session = @()
    $installed = Get-PPOption $Snapshot 'Installed'
    $available = Get-PPOption $Snapshot 'Available'
    if ($installed) { $session += 'Installed WildRig   ' + $installed.Version }
    if ($available) { $session += 'Available WildRig   ' + $available.Version }
    if ($telemetry -and $telemetry.RecentErrors) { $session += @('','Recent miner messages') + $telemetry.RecentErrors }
    if ($Snapshot -and $Snapshot.Error) { $session += @('', $Snapshot.Error) }
    Set-PPMenuText $Page.SessionNotes ($session -join "`r`n")

    $devices = @(if ($Gpu -and $Gpu.Available) { $Gpu.Gpus })
    $primary = if ($devices.Count) { $devices[0] } else { $null }
    $usage = Get-PPOption $primary 'Utilization'
    $power = Get-PPOption $primary 'PowerWatts'
    Set-PPMenuText $Page.GpuName (Get-PPOption $primary 'Name' 'Waiting for NVIDIA telemetry')
    Set-PPMenuText $Page.GpuUsage $(if ($null -ne $usage) { 'Utilization   {0:N0}%' -f $usage } else { 'Utilization   —' })
    Set-PPMenuText $Page.GpuPower $(if ($null -ne $power) { 'Power draw   {0:N0} W' -f $power } else { 'Power draw   —' })
    $Page.GpuMeter.Tag = [Math]::Max(0,[Math]::Min(100,[double]$usage))
    $Page.GpuFill.Width = [int]($Page.GpuMeter.ClientSize.Width * $Page.GpuMeter.Tag / 100)
    $additional = foreach ($card in ($devices | Select-Object -Skip 1)) {
        $utilization = if ($null -ne $card.Utilization) { '{0:N0}%' -f $card.Utilization } else { '—' }
        $power = if ($null -ne $card.PowerWatts) { '{0:N0} W' -f $card.PowerWatts } else { '—' }
        $card.Name
        "Utilization  $utilization    •    Power  $power"
        ''
    }
    Set-PPMenuText $Page.GpuNotes ($additional -join "`r`n")
}

function Add-PPSettingsPage {
    param($Form, $Page, [switch]$Setup)
    $config = $script:configuration
    $launchRoot = $appRoot
    $stopMiner = ${function:Stop-PPManagedMiner}
    $grid = New-PPMenuGrid 1 @(85,0,53)
    $grid.RowStyles[0].SizeType = 'AutoSize'
    $Page.Controls.Add($grid)
    $heading = if ($Setup) {
        New-PPMenuHeading 'FIRST-RUN SETUP' 'Set up PearlPilot' 'Add your public payout address to get started.'
    } else {
        New-PPMenuHeading 'PREFERENCES' 'Mining settings' 'Manage your payout, mining policy, and WildRig preferences.'
    }
    $grid.Controls.Add($heading,0,0)

    $scroll = New-Object Windows.Forms.Panel
    $scroll.Dock = 'Fill'
    $scroll.Margin = New-Object Windows.Forms.Padding(0)
    $scroll.AutoScroll = $true
    $grid.Controls.Add($scroll,0,1)
    $columns = New-PPMenuGrid 2 @(0)
    $columns.Dock = 'Top'
    $columns.Height = 468
    $scroll.Controls.Add($columns)
    $left = New-PPMenuGrid 1 @(204,155,0)
    $right = New-PPMenuGrid 1 @(302,166)
    $left.Margin = New-Object Windows.Forms.Padding(0,0,5,0)
    $right.Margin = New-Object Windows.Forms.Padding(5,0,0,0)
    $columns.Controls.Add($left,0,0)
    $columns.Controls.Add($right,1,0)

    $groups = @(
        @{ Title='Payout & pool'; Column=$left; Row=0; Fields=@(
            @('Wallet','Public PRL wallet'), @('PoolUrl','Pool endpoint'), @('WorkerName','Worker name')
        ) },
        @{ Title='WildRig'; Column=$left; Row=1; Fields=@(
            @('PearlHashKernel','PearlHash kernel (blank for auto)'),
            @('GpuIntensity','Intensity (blank for auto)')
        ) },
        @{ Title='Mining policy'; Column=$right; Row=0; Fields=@(
            @('GpuList','GPU index'), @('LockDelayMinutes','Start after lock (minutes)'),
            @('IdleMinutes','Unlocked idle minutes (0 to disable)'),
            @('TemperatureLimitC','Stop temperature (°C)'), @('GamingProcesses','Pause for processes (comma-separated)')
        ) }
    )
    $fields = @{}
    $fieldValues = @()
    foreach ($group in $groups) {
        $card = New-PPMenuGrid 1 @(30,0)
        $card.BackColor = $script:menuColors.Surface
        $card.Padding = New-Object Windows.Forms.Padding(14,10,14,10)
        $card.Margin = New-Object Windows.Forms.Padding(0,0,0,10)
        $title = New-PPMenuLabel $group.Title 12 'Text' -Bold
        $title.Dock = 'Fill'
        $card.Controls.Add($title,0,0)
        $fieldGrid = New-PPMenuGrid 1 (@(49) * $group.Fields.Count)
        $card.Controls.Add($fieldGrid,0,1)
        $row = 0
        foreach ($entry in $group.Fields) {
            $fieldValues += ,$entry
            $field = New-PPMenuGrid 1 @(19,27)
            $label = New-PPMenuLabel $entry[1] 9 'Muted'
            $label.Dock = 'Fill'
            $box = New-Object Windows.Forms.TextBox
            $box.Text = [string]$config.($entry[0])
            $box.AccessibleName = $entry[1]
            $box.Dock = 'Top'
            $box.Margin = New-Object Windows.Forms.Padding(0)
            $box.BackColor = $script:menuColors.Input
            $box.ForeColor = $script:menuColors.Text
            $box.BorderStyle = 'FixedSingle'
            $field.Controls.Add($label,0,0)
            $field.Controls.Add($box,0,1)
            $fieldGrid.Controls.Add($field,0,$row++)
            $fields[$entry[0]] = $box
        }
        $group.Column.Controls.Add($card,0,$group.Row)
    }

    $behavior = New-PPMenuGrid 1 @(29,29,29,29,0)
    $behavior.BackColor = $script:menuColors.Surface
    $behavior.Padding = New-Object Windows.Forms.Padding(14,10,14,10)
    $behavior.Margin = New-Object Windows.Forms.Padding(0)
    $behaviorTitle = New-PPMenuLabel 'Automation' 12 'Text' -Bold
    $behaviorTitle.Dock = 'Fill'
    $behavior.Controls.Add($behaviorTitle,0,0)
    $automatic = New-Object Windows.Forms.CheckBox
    $automatic.Text = 'Mine automatically when locked'
    $automatic.Checked = [bool]$config.AutomaticMining
    $startup = New-Object Windows.Forms.CheckBox
    $startup.Text = 'Start PearlPilot when I sign in'
    $startup.Checked = [bool]$config.StartWithWindows
    $updates = New-Object Windows.Forms.CheckBox
    $updates.Text = 'Automatically update WildRig when idle'
    $updates.Checked = [bool]$config.AutomaticUpdates
    foreach ($box in @($automatic,$startup,$updates)) { $box.Dock = 'Fill'; $box.Margin = New-Object Windows.Forms.Padding(0) }
    $behavior.Controls.Add($automatic,0,1)
    $behavior.Controls.Add($startup,0,2)
    $behavior.Controls.Add($updates,0,3)
    $note = New-PPMenuLabel 'Mining requires NVIDIA temperature data.' 9 'Muted'
    $note.Dock = 'Fill'
    $behavior.Controls.Add($note,0,4)
    $right.Controls.Add($behavior,0,1)

    $footer = New-PPMenuGrid 2 @(0)
    $footer.Padding = New-Object Windows.Forms.Padding(0,10,0,0)
    $footer.ColumnStyles[1].SizeType = 'Absolute'
    $footer.ColumnStyles[1].Width = 144
    $message = if ($Setup) { 'Your public payout address is enough to get started.' } else { 'Mining pauses while this page is open.' }
    $footerNote = New-PPMenuLabel $message 9 'Muted'
    $footerNote.Dock = 'Fill'
    $footerNote.TextAlign = 'MiddleLeft'
    $footer.Controls.Add($footerNote,0,0)
    $save = New-PPMenuButton 'Save settings' -Primary
    $save.Dock = 'Fill'
    $save.Margin = New-Object Windows.Forms.Padding(0,2,0,2)
    $save.Add_Click({
        try {
            $candidate = $config | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            foreach ($entry in $fieldValues) {
                $name = $entry[0]
                $value = $fields[$name].Text.Trim()
                if ($name -in @('LockDelayMinutes','TemperatureLimitC','IdleMinutes')) {
                    $number = 0
                    if (-not [int]::TryParse($value,[ref]$number)) { throw ($entry[1]+' must be a whole number.') }
                    $candidate.$name = $number
                } else { $candidate.$name = $value }
            }
            $candidate.Configured = $true
            $candidate.AutomaticMining = $automatic.Checked
            $candidate.AutomaticUpdates = $updates.Checked
            $candidate.StartWithWindows = $startup.Checked
            $candidate.Backend = 'Docker'
            $validation = Test-PPConfiguration -Configuration $candidate
            if (-not $validation.Valid) { throw ($validation.Errors -join "`n") }
            if (-not $Setup) { & $stopMiner -Reason 'Saving settings' }
            Save-PPConfiguration -Configuration $candidate
            if ($candidate.StartWithWindows) { Enable-PPStartup -AppRoot $launchRoot } else { Disable-PPStartup }
            foreach ($property in $candidate.PSObject.Properties) {
                $config | Add-Member NoteProperty $property.Name $property.Value -Force
            }
            $Form.Tag = $true
            $Form.Close()
        } catch {
            [void][Windows.Forms.MessageBox]::Show($Form,$_.Exception.Message,'Cannot save settings','OK','Error')
        }
    }.GetNewClosure())
    $footer.Controls.Add($save,1,0)
    $grid.Controls.Add($footer,0,2)
}

function Add-PPBackendPage {
    param($Page, [string]$PanelId)
    $grid = New-PPMenuGrid 1 @(85,114,90,0)
    $grid.RowStyles[0].SizeType = 'AutoSize'
    $Page.Controls.Add($grid)
    $grid.Controls.Add((New-PPMenuHeading 'DOCKER BACKEND' 'WildRig control center' 'Manage releases, check prerequisites, and benchmark your miner.'),0,0)
    $versions = New-PPMenuGrid 3 @(0)
    $installed = New-PPMenuMetric 'INSTALLED' 'Docker WildRig'
    $available = New-PPMenuMetric 'AVAILABLE' 'Check for releases'
    $operation = New-PPMenuMetric 'CONTROLLER' 'Mining pauses on this page'
    $operation.Value.Font = New-Object Drawing.Font('Segoe UI Semibold',17)
    $operation.Card.Margin = New-Object Windows.Forms.Padding(0,0,0,10)
    $versions.Controls.Add($installed.Card,0,0)
    $versions.Controls.Add($available.Card,1,0)
    $versions.Controls.Add($operation.Card,2,0)
    $grid.Controls.Add($versions,0,1)

    $actions = New-PPMenuGrid 4 @(40,40)
    $backendDataRoot = $dataRoot
    $publishIntent = ${function:Publish-PPIntent}
    $showError = ${function:Show-PPTrayError}
    $buttons = @(
        @('Check for updates','Check'), @('Update','Install'), @('Rollback','Rollback'),
        @('Diagnostics','Diagnostics'), @('Benchmark 2 × 60s','Benchmark'), @('Retry controller','Retry')
    )
    for ($index = 0; $index -lt $buttons.Count; $index++) {
        $entry = $buttons[$index]
        $action = $entry[1]
        $button = New-PPMenuButton $entry[0] -Primary:($action -eq 'Install')
        $button.Dock = 'Fill'
        $column = $index % 4
        $rightMargin = if ($column -eq 3) { 0 } else { 8 }
        $button.Margin = New-Object Windows.Forms.Padding(0,0,$rightMargin,6)
        $button.Add_Click({
            try {
                & $publishIntent -Status 'Backend panel open'
                Send-PPBackendRequest $backendDataRoot $action -PanelId $PanelId
            } catch { & $showError -Action 'Backend operation' -Exception $_.Exception }
        }.GetNewClosure())
        $actions.Controls.Add($button,$column,[int][Math]::Floor($index / 4))
    }
    $grid.Controls.Add($actions,0,2)
    $details = New-PPMenuDetails 'Diagnostics & benchmark'
    $details.Text.Text = 'Waiting for the mining controller.'
    $grid.Controls.Add($details.Card,0,3)
    [pscustomobject]@{ Installed=$installed; Available=$available; Operation=$operation; Details=$details.Text }
}

function Update-PPBackendPage {
    param($Page, $Snapshot, [string]$UnavailableStatus)
    if (-not $Snapshot) {
        foreach ($card in @($Page.Installed,$Page.Available,$Page.Operation)) { Set-PPMenuText $card.Value '—' }
        Set-PPMenuText $Page.Available.Hint 'Check for releases'
        $Page.Available.Hint.ForeColor = $script:menuColors.Muted
        Set-PPMenuText $Page.Details $UnavailableStatus
        return
    }
    Set-PPMenuText $Page.Installed.Value $(if ($Snapshot.Installed) { $Snapshot.Installed.Version } else { '—' })
    Set-PPMenuText $Page.Available.Value $(if ($Snapshot.Available) { $Snapshot.Available.Version } else { '—' })
    $releaseHint = 'Check for releases'
    $releaseTone = 'Muted'
    if ($Snapshot.Available) {
        if (-not $Snapshot.Installed -or [version]$Snapshot.Available.Version -gt [version]$Snapshot.Installed.Version) {
            $releaseHint = 'Ready to update'
            $releaseTone = 'Accent'
        } else { $releaseHint = 'Up to date' }
    }
    Set-PPMenuText $Page.Available.Hint $releaseHint
    $Page.Available.Hint.ForeColor = $script:menuColors[$releaseTone]
    $state = if ($Snapshot.Operation) {
        @{ Check='Checking'; Diagnostics='Diagnosing'; Install='Updating'; Rollback='Rolling back'; Retry='Retrying'; Benchmark='Benchmarking' }[$Snapshot.Operation]
    } else {
        switch ($Snapshot.State) {
            'DOCKER_UNAVAILABLE' { 'Offline' }
            'GPU_UNAVAILABLE' { 'GPU offline' }
            'NOT_CONFIGURED' { 'Setup needed' }
            default { [Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($Snapshot.State.ToLowerInvariant()) }
        }
    }
    Set-PPMenuText $Page.Operation.Value $state
    $lines = @()
    if ($Snapshot.Error) { $lines += @('Controller message',$Snapshot.Error,'') }
    if ($Snapshot.Operation -eq 'Benchmark' -and $Snapshot.Telemetry -and $null -ne $Snapshot.Telemetry.Hashrate) {
        $lines += @(('Benchmark in progress   {0:N1} TH/s' -f ($Snapshot.Telemetry.Hashrate / 1e12)), '')
    }
    $checks = Get-PPOption $Snapshot.Diagnostics 'Checks'
    foreach ($check in $checks) {
        $result = if ($check.Ready) { 'PASS' } else { 'REVIEW' }
        $lines += @("$result    $($check.Check)",$check.Detail,'')
    }
    $benchmarkPath = Join-Path $dataRoot 'Backend\benchmark.json'
    if (Test-Path -LiteralPath $benchmarkPath) {
        try {
            $results = @(Read-PPJson $benchmarkPath)
            if ($results.Count) { $lines += 'Last benchmark' }
            foreach ($result in $results) {
                $rate = if ($null -ne $result.AverageHashrate) { '{0:N1} TH/s' -f ($result.AverageHashrate / 1e12) } else { 'Hashrate unavailable' }
                $power = if ($null -ne $result.AveragePowerWatts) { '   •   {0:N0} W' -f $result.AveragePowerWatts } else { '' }
                $efficiency = if ($null -ne $result.HashesPerWatt) { '   •   {0:N2} TH/W' -f ($result.HashesPerWatt / 1e12) } else { '' }
                $lines += "$($result.Profile)    $rate$power$efficiency"
                $stability = if ($result.Stable) { 'Stable' } else { 'Insufficient stable samples' }
                $lines += '{0} seconds   •   {1} samples   •   {2} accepted shares   •   {3}' -f $result.Seconds,$result.Samples,$result.Accepted,$stability
                if ($null -ne $result.RejectedShareRate) { $lines += 'Rejected shares   {0:P1}' -f $result.RejectedShareRate }
                if ($result.RecentErrors) { $lines += $result.RecentErrors }
                $lines += ''
            }
        } catch { $lines += 'Benchmark results are temporarily unavailable.' }
    }
    if (-not $lines.Count) { $lines = @('Choose Diagnostics to check Docker, CUDA, and pool connectivity.','Run a benchmark to compare WildRig defaults with your configured settings.') }
    Set-PPMenuText $Page.Details ($lines -join "`r`n")
}

function Add-PPLogsPage {
    param($Page)
    $grid = New-PPMenuGrid 1 @(85,49,0)
    $grid.RowStyles[0].SizeType = 'AutoSize'
    $Page.Controls.Add($grid)
    $grid.Controls.Add((New-PPMenuHeading 'ACTIVITY LOG' 'Logs' 'Read recent controller and WildRig messages.'),0,0)
    $tools = New-PPMenuGrid 3 @(0)
    $tools.Margin = New-Object Windows.Forms.Padding(0,0,0,10)
    $tools.ColumnStyles[1].SizeType = 'Absolute'
    $tools.ColumnStyles[1].Width = 104
    $tools.ColumnStyles[2].SizeType = 'Absolute'
    $tools.ColumnStyles[2].Width = 134
    $choice = New-Object Windows.Forms.ComboBox
    $choice.DropDownStyle = 'DropDownList'
    $choice.AccessibleName = 'Log file'
    $choice.Anchor = 'Left,Right'
    $choice.Margin = New-Object Windows.Forms.Padding(0,0,10,0)
    $choice.Items.AddRange(@('PearlPilot.log','WildRig-Docker.log'))
    $choice.SelectedIndex = 0
    $tools.Controls.Add($choice,0,0)
    $refresh = New-PPMenuButton 'Refresh'
    $refresh.Dock = 'Fill'
    $refresh.Margin = New-Object Windows.Forms.Padding(0,0,8,0)
    $tools.Controls.Add($refresh,1,0)
    $open = New-PPMenuButton 'Open log folder'
    $open.Dock = 'Fill'
    $open.Margin = New-Object Windows.Forms.Padding(0)
    $tools.Controls.Add($open,2,0)
    $grid.Controls.Add($tools,0,1)

    $console = New-Object Windows.Forms.Panel
    $console.Dock = 'Fill'
    $console.Margin = New-Object Windows.Forms.Padding(0)
    $console.Padding = New-Object Windows.Forms.Padding(13)
    $console.BackColor = $script:menuColors.Console
    $text = New-PPMenuTextBox -Console
    $console.Controls.Add($text)
    $grid.Controls.Add($console,0,2)

    $logRoot = Join-Path $dataRoot 'Logs'
    $showError = ${function:Show-PPTrayError}
    $readLog = {
        $file = Join-Path $logRoot ([string]$choice.SelectedItem)
        try {
            if (Test-Path -LiteralPath $file) {
                $text.Lines = @(Get-Content -LiteralPath $file -Tail 150 -ErrorAction Stop)
                $text.SelectionStart = $text.TextLength
                $text.ScrollToCaret()
            } else {
                $text.Text = 'No log has been written yet.'
            }
        } catch { $text.Text = 'Cannot read the log. Try Refresh.' }
    }.GetNewClosure()
    $choice.Add_SelectedIndexChanged($readLog)
    $refresh.Add_Click($readLog)
    $Page.Add_VisibleChanged({ if ($Page.Visible) { & $readLog } }.GetNewClosure())
    $open.Add_Click({
        try { Start-Process explorer.exe -ArgumentList (ConvertTo-PPArgument $logRoot) }
        catch { & $showError -Action 'Opening logs' -Exception $_.Exception }
    }.GetNewClosure())
}

function Set-PPMenuPage {
    param($Window, [string]$Name)
    if ($Window.SelectedPage -eq $Name) { return }
    $Window.SelectedPage = $Name
    foreach ($key in $Window.Pages.Keys) {
        $selected = $key -eq $Name
        $Window.Pages[$key].Visible = $selected
        $Window.Navigation[$key].BackColor = if ($selected) { $script:menuColors.RailActive } else { $script:menuColors.Rail }
        $Window.Navigation[$key].ForeColor = if ($selected) { $script:menuColors.RailText } else { $script:menuColors.RailMuted }
    }
}

function Show-PPMenu {
    param([string]$InitialTab='Statistics', [switch]$Setup)
    if ($script:menuWindow) {
        Set-PPMenuPage $script:menuWindow $InitialTab
        if ($script:menuWindow.Form.WindowState -eq 'Minimized') { $script:menuWindow.Form.WindowState = 'Normal' }
        $script:menuWindow.Form.Activate()
        return
    }

    $form = New-Object Windows.Forms.Form
    $form.Text = 'Menu'
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object Drawing.Font('Segoe UI',10)
    $form.BackColor = $script:menuColors.Canvas
    $form.ForeColor = $script:menuColors.Text
    $form.AutoScaleDimensions = New-Object Drawing.SizeF(96,96)
    $form.AutoScaleMode = 'Dpi'
    $form.ClientSize = New-Object Drawing.Size(990,660)
    $form.MinimumSize = New-Object Drawing.Size(830,565)
    $form.Add_Shown({ $this.Activate() })
    $form.SuspendLayout()

    $layout = New-PPMenuGrid 2 @(0)
    $layout.ColumnStyles[0].SizeType = 'Absolute'
    $layout.ColumnStyles[0].Width = 194
    $form.Controls.Add($layout)
    $rail = New-PPMenuGrid 1 @(70,28,46,46,46,46,0,38)
    $rail.BackColor = $script:menuColors.Rail
    $rail.Padding = New-Object Windows.Forms.Padding(14,22,14,12)
    $layout.Controls.Add($rail,0,0)
    $brand = New-PPMenuGrid 2 @(42,0)
    $brand.ColumnStyles[0].SizeType = 'Absolute'
    $brand.ColumnStyles[0].Width = 43
    $form.Icon = New-Object Drawing.Icon($iconPath)
    $brandImage = New-Object Windows.Forms.PictureBox
    $brandImage.Image = $form.Icon.ToBitmap()
    $brandImage.SizeMode = 'Zoom'
    $brandImage.Dock = 'Fill'
    $brandImage.Margin = New-Object Windows.Forms.Padding(0,0,7,0)
    $windowIcon = $form.Icon
    $form.Add_Disposed({ $brandImage.Image.Dispose(); $windowIcon.Dispose() }.GetNewClosure())
    $brand.Controls.Add($brandImage,0,0)
    $wordmark = New-PPMenuLabel 'PearlPilot' 16 'RailText' -Bold
    $wordmark.Dock = 'Fill'
    $wordmark.TextAlign = 'MiddleLeft'
    $brand.Controls.Add($wordmark,1,0)
    $rail.Controls.Add($brand,0,0)
    $navigationLabel = New-PPMenuLabel 'WORKSPACE' 8 'RailMuted' -Bold
    $navigationLabel.Padding = New-Object Windows.Forms.Padding(8,0,0,0)
    $navigationLabel.Dock = 'Fill'
    $rail.Controls.Add($navigationLabel,0,1)
    $runtimeLabel = New-PPMenuLabel 'WINDOWS  /  DOCKER' 8 'RailMuted' -Bold
    $runtimeLabel.Padding = New-Object Windows.Forms.Padding(8,0,0,0)
    $runtimeLabel.Dock = 'Fill'
    $runtimeLabel.TextAlign = 'MiddleLeft'
    $rail.Controls.Add($runtimeLabel,0,7)

    $pageHost = New-Object Windows.Forms.Panel
    $pageHost.Dock = 'Fill'
    $pageHost.Margin = New-Object Windows.Forms.Padding(0)
    $layout.Controls.Add($pageHost,1,0)
    $window = [pscustomobject]@{
        Form=$form; Pages=@{}; Navigation=@{}; SelectedPage=''; PanelId=[guid]::NewGuid().ToString('N')
        Statistics=$null; Backend=$null
    }
    $selectPage = ${function:Set-PPMenuPage}
    $pageNames = if ($Setup) { 'Settings' } else { 'Statistics','Settings','Backend','Logs' }
    $row = 2
    foreach ($name in $pageNames) {
        $page = New-Object Windows.Forms.Panel
        $page.Dock = 'Fill'
        $page.Padding = New-Object Windows.Forms.Padding(24,22,24,22)
        $page.Visible = $false
        $pageHost.Controls.Add($page)
        $window.Pages[$name] = $page
        $caption = if ($name -eq 'Statistics') { 'Overview' } else { $name }
        $button = New-PPMenuButton $caption
        $button.Dock = 'Fill'
        $button.FlatAppearance.BorderSize = 0
        $button.FlatAppearance.MouseOverBackColor = $script:menuColors.RailActive
        $button.TextAlign = 'MiddleLeft'
        $button.Padding = New-Object Windows.Forms.Padding(9,0,0,0)
        $button.Margin = New-Object Windows.Forms.Padding(0,0,0,5)
        $button.Add_Click({ & $selectPage $window $name }.GetNewClosure())
        $rail.Controls.Add($button,0,$row++)
        $window.Navigation[$name] = $button
    }
    Add-PPSettingsPage $form $window.Pages['Settings'] -Setup:$Setup
    if (-not $Setup) {
        $window.Statistics = Add-PPStatisticsPage $window.Pages['Statistics']
        $window.Backend = Add-PPBackendPage $window.Pages['Backend'] $window.PanelId
        Add-PPLogsPage $window.Pages['Logs']
    }
    Set-PPMenuPage $window $(if ($Setup) { 'Settings' } else { $InitialTab })
    $form.ResumeLayout($true)

    if ($Setup) {
        try { [void]$form.ShowDialog(); return [bool]$form.Tag }
        finally { $form.Dispose() }
    }
    $script:menuWindow = $window
    try { $form.Show() }
    catch { $form.Dispose(); $script:menuWindow = $null; throw }
}
