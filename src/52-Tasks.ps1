# =============================================================================
# Task manager engine: the sampling both front-ends draw from.
#
# btop-shaped - gauges and sparklines for CPU, memory, disk and network above a
# sortable process table - but the numbers all come from raw performance
# counters read through CIM.
#
# Why raw counters and not the formatted ones
# -----------------------------------------------------------------------------
# Win32_PerfFormattedData_* does its own two-sample wait inside the provider, so
# a single query costs about 270ms. The Win32_PerfRawData_* equivalent is 9ms
# and hands over the cumulative counters, leaving the delta arithmetic to us -
# which we want anyway, because we are already keeping the previous sample for
# the history graphs. Measured on this project's dev box:
#
#   Win32_PerfFormattedData_PerfOS_Processor   266 ms
#   Win32_PerfRawData_PerfOS_Processor           9 ms
#
# The whole refresh - CPU, memory, disks, network, processes - lands around
# 76ms, which is what makes a one-second interval comfortable in the window as
# well as the console.
#
# Nothing here uses System.Diagnostics.PerformanceCounter: its category and
# counter names are localised, so '\Processor(_Total)\% Processor Time' does not
# exist on a German or Turkish install. CIM class and property names are not
# localised.
# =============================================================================

$TaskCpuQuery = 'SELECT Name,PercentIdleTime,Timestamp_Sys100NS FROM Win32_PerfRawData_PerfOS_Processor'
$TaskNetQuery = 'SELECT Name,BytesReceivedPersec,BytesSentPersec,Timestamp_Sys100NS,Frequency_Sys100NS FROM Win32_PerfRawData_Tcpip_NetworkInterface'
# LastBootUpTime rides along on the memory query rather than costing a second
# one: it is the same single-instance class, and the header wants an uptime.
$TaskMemQuery = 'SELECT TotalVisibleMemorySize,FreePhysicalMemory,TotalVirtualMemorySize,FreeVirtualMemory,LastBootUpTime FROM Win32_OperatingSystem'
$TaskDiskQuery = 'SELECT DeviceID,VolumeName,Size,FreeSpace FROM Win32_LogicalDisk WHERE DriveType=3'

# -----------------------------------------------------------------------------
# Formatting
# -----------------------------------------------------------------------------

# Short enough for a table column: 4 significant characters plus a unit letter.
function Format-Bytes {
    param([AllowNull()]$Bytes)

    $value = 0.0
    if ($null -ne $Bytes) { $value = [double]$Bytes }
    if ($value -lt 0) { $value = 0.0 }

    $units = @('B', 'K', 'M', 'G', 'T', 'P')
    $index = 0
    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value = $value / 1024
        $index++
    }

    # Whole numbers below 10 units read better with a decimal; above 100 the
    # decimal is noise and costs a column.
    if ($index -eq 0 -or $value -ge 100) { return ('{0:N0}{1}' -f $value, $units[$index]) }
    return ('{0:N1}{1}' -f $value, $units[$index])
}

function Format-Rate {
    param([AllowNull()]$BytesPerSecond)
    return ((Format-Bytes $BytesPerSecond) + '/s')
}

# Seconds of CPU time as h:mm:ss, the way a process list shows it.
function Format-CpuTime {
    param([AllowNull()]$Seconds)

    if ($null -eq $Seconds) { return '-' }
    $span = [TimeSpan]::FromSeconds([double]$Seconds)
    return ('{0}:{1:00}:{2:00}' -f [int]$span.TotalHours, $span.Minutes, $span.Seconds)
}

# The load bands the gauges and the process table colour by. Same thresholds in
# both front-ends, so a red bar means the same thing in the window as it does in
# the console.
function Get-LoadBand {
    param([double]$Percent)

    if ($Percent -ge 85) { return 'high' }
    if ($Percent -ge 60) { return 'medium' }
    return 'low'
}

function Get-LoadColor {
    param([double]$Percent)

    switch (Get-LoadBand -Percent $Percent) {
        'high'   { return (Get-Color 'Err') }
        'medium' { return (Get-Color 'Warn') }
        default  { return (Get-Color 'Ok') }
    }
}

# -----------------------------------------------------------------------------
# Drawing primitives
# -----------------------------------------------------------------------------

# A filled bar of $Width cells. Separate from Write-ProgressBar, which writes
# straight to the host; this returns a string a frame line can hold.
function New-MeterBar {
    param([double]$Percent, [int]$Width = 20)

    if ($Width -lt 1) { return '' }
    $clamped = [Math]::Max(0.0, [Math]::Min(100.0, $Percent))

    $filled = [int][Math]::Round(($clamped / 100.0) * $Width)
    if ($filled -gt $Width) { $filled = $Width }

    return ((Get-Glyph 'BarFull') * $filled) + ((Get-Glyph 'BarEmpty') * ($Width - $filled))
}

# A filled history graph $Height character rows tall.
#
# On a Unicode console every cell is a braille 2x4 dot matrix, so the effective
# resolution is 2*Width by 4*Height - which is what makes this read as a curve
# rather than a bar chart, and is the same trick btop uses. On a legacy console
# it falls back to a column chart off the block ramp at 1x1 per cell.
#
# Returns an array of strings, top row first.
function New-HistoryGraph {
    param(
        [AllowEmptyCollection()][double[]]$Values = @(),
        [int]$Width = 40,
        [int]$Height = 3,
        [double]$Maximum = 100
    )

    if ($Width -lt 1 -or $Height -lt 1) { return @() }
    if ($Maximum -le 0) { $Maximum = 1 }

    $braille = [bool]$Ctx.Theme.Unicode

    # Sub-columns per character cell: two for braille, one for blocks.
    $perCell = 1
    if ($braille) { $perCell = 2 }
    $subWidth = $Width * $perCell
    $subHeight = $Height * 4
    if (-not $braille) { $subHeight = $Height }

    # Newest sample on the right. When there is more history than the graph is
    # wide the oldest is dropped; when there is less it is stretched to fill.
    #
    # Stretching rather than left-padding is deliberate. A 92-cell braille
    # graph is 184 sub-columns, so at one sample a second a padded graph would
    # sit three minutes in a mostly empty box - which reads as broken. The
    # shape wobbles slightly as history accumulates and then settles, which is
    # the better trade.
    $recent = @($Values)
    if ($recent.Count -gt $subWidth) { $recent = @($recent[($recent.Count - $subWidth)..($recent.Count - 1)]) }

    # -1 marks a sub-column with nothing to draw, which stays blank rather than
    # reading as a measured zero.
    $heights = New-Object 'int[]' $subWidth
    for ($i = 0; $i -lt $subWidth; $i++) { $heights[$i] = -1 }

    if ($recent.Count -gt 0) {
        for ($i = 0; $i -lt $subWidth; $i++) {
            # Nearest sample at this fraction along the width.
            $source = 0
            if ($subWidth -gt 1 -and $recent.Count -gt 1) {
                $source = [int][Math]::Round(($i / [double]($subWidth - 1)) * ($recent.Count - 1))
            }
            elseif ($recent.Count -gt 1) {
                $source = $recent.Count - 1
            }

            $fraction = [Math]::Max(0.0, [Math]::Min(1.0, $recent[$source] / $Maximum))
            $filled = [int][Math]::Round($fraction * $subHeight)
            # Any non-zero reading gets at least one dot, so a busy-but-quiet
            # machine is not drawn as flat nothing.
            if ($filled -eq 0 -and $recent[$source] -gt 0) { $filled = 1 }
            $heights[$i] = $filled
        }
    }

    if (-not $braille) { return @(New-BlockGraph -Heights $heights -Width $Width -Height $Height) }

    # Braille dot numbering is column-major and does not run in reading order:
    #   1 4
    #   2 5
    #   3 6
    #   7 8
    # so the top-to-bottom bit order differs per half of the cell.
    $leftBits  = @(0x01, 0x02, 0x04, 0x40)
    $rightBits = @(0x08, 0x10, 0x20, 0x80)

    $rows = [System.Collections.Generic.List[string]]::new()
    for ($row = 0; $row -lt $Height; $row++) {
        $line = New-Object Text.StringBuilder

        for ($col = 0; $col -lt $Width; $col++) {
            $mask = 0

            for ($half = 0; $half -lt 2; $half++) {
                $filled = $heights[($col * 2) + $half]
                if ($filled -lt 0) { continue }

                $bits = $rightBits
                if ($half -eq 0) { $bits = $leftBits }

                for ($sub = 0; $sub -lt 4; $sub++) {
                    # Row 0 sub-row 0 is the top of the graph, so measure from
                    # the bottom to decide whether this dot is under the line.
                    $fromBottom = $subHeight - (($row * 4) + $sub)
                    if ($fromBottom -le $filled) { $mask = $mask -bor $bits[$sub] }
                }
            }

            [void]$line.Append((ConvertTo-Char (0x2800 + $mask)))
        }

        $rows.Add($line.ToString())
    }

    return @($rows)
}

# The legacy-console fallback: one block per cell, filled from the bottom.
function New-BlockGraph {
    param(
        [Parameter(Mandatory)][int[]]$Heights,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height
    )

    $full = Get-Glyph 'BarFull'
    $rows = [System.Collections.Generic.List[string]]::new()

    for ($row = 0; $row -lt $Height; $row++) {
        $line = New-Object Text.StringBuilder
        for ($col = 0; $col -lt $Width; $col++) {
            $fromBottom = $Height - $row
            if ($col -lt $Heights.Count -and $Heights[$col] -ge $fromBottom) { [void]$line.Append($full) }
            else { [void]$line.Append(' ') }
        }
        $rows.Add($line.ToString())
    }

    return @($rows)
}

# A history graph one line tall, oldest sample on the left. Scaled against
# $Maximum rather than the data's own peak, so the shape means the same thing
# from one frame to the next.
function New-Sparkline {
    param(
        [AllowEmptyCollection()][double[]]$Values = @(),
        [int]$Width = 40,
        [double]$Maximum = 100
    )

    if ($Width -lt 1) { return '' }

    $ramp = @(Get-Glyph 'Spark')
    if ($ramp.Count -eq 0) { return '' }
    if ($Maximum -le 0) { $Maximum = 1 }

    # Right-aligned: the newest sample sits against the right edge and older
    # ones scroll off the left, so a partly filled history pads rather than
    # stretching a handful of samples across the whole width.
    $recent = @($Values)
    if ($recent.Count -gt $Width) { $recent = @($recent[($recent.Count - $Width)..($recent.Count - 1)]) }

    $cells = New-Object Text.StringBuilder
    [void]$cells.Append(' ' * [Math]::Max(0, $Width - $recent.Count))

    foreach ($value in $recent) {
        $fraction = [Math]::Max(0.0, [Math]::Min(1.0, $value / $Maximum))
        $level = [int][Math]::Round($fraction * ($ramp.Count - 1))
        if ($level -lt 0) { $level = 0 }
        if ($level -gt ($ramp.Count - 1)) { $level = $ramp.Count - 1 }
        [void]$cells.Append($ramp[$level])
    }

    return $cells.ToString()
}

# -----------------------------------------------------------------------------
# Sampling
# -----------------------------------------------------------------------------

function Get-CpuRawSample {
    $sample = @{}
    foreach ($row in @(Get-CimInstance -Query $TaskCpuQuery -ErrorAction Stop)) {
        $sample[[string]$row.Name] = [pscustomobject]@{
            Idle  = [double]$row.PercentIdleTime
            Stamp = [double]$row.Timestamp_Sys100NS
        }
    }
    return $sample
}

# PercentIdleTime is a PERF_100NSEC_TIMER_INV counter: cumulative idle time in
# 100ns ticks. Busy is its complement over the same span.
#
# The _Total instance is the *average* across cores, not the sum - so every
# instance divides by the same timestamp delta. Verified against the formatted
# counter: with this divisor _Total matches the mean of the per-core values to
# the digit, and with a cores multiplier it does not.
function Get-CpuLoad {
    param([Parameter(Mandatory)][AllowNull()]$Previous, [Parameter(Mandatory)]$Current)

    $total = 0.0
    $cores = [System.Collections.Generic.List[double]]::new()

    if ($null -eq $Previous) {
        return [pscustomobject]@{ Total = 0.0; Cores = @(); Ready = $false }
    }

    # '_Total' sorts before the digits, so pull the core names out and sort them
    # numerically - otherwise core 10 lands between core 1 and core 2.
    $coreNames = @($Current.Keys | Where-Object { $_ -ne '_Total' } | Sort-Object { [int]$_ })

    foreach ($name in (@('_Total') + $coreNames)) {
        if (-not $Current.ContainsKey($name) -or -not $Previous.ContainsKey($name)) { continue }

        $timeDelta = $Current[$name].Stamp - $Previous[$name].Stamp
        if ($timeDelta -le 0) { continue }

        $idleDelta = $Current[$name].Idle - $Previous[$name].Idle
        $busy = 100.0 - (100.0 * $idleDelta / $timeDelta)
        $busy = [Math]::Max(0.0, [Math]::Min(100.0, $busy))

        if ($name -eq '_Total') { $total = $busy } else { $cores.Add($busy) }
    }

    return [pscustomobject]@{ Total = $total; Cores = @($cores); Ready = $true }
}

function Get-MemorySample {
    $os = Get-CimInstance -Query $TaskMemQuery -ErrorAction Stop

    # Both are reported in kilobytes.
    $total = [double]$os.TotalVisibleMemorySize * 1024
    $free  = [double]$os.FreePhysicalMemory * 1024
    $used  = [Math]::Max(0.0, $total - $free)

    # Virtual here is physical plus the page file, so used virtual is the commit
    # charge. Windows has no swap partition to report, and commit is the number
    # that actually tells you whether the machine is in trouble.
    $commitTotal = [double]$os.TotalVirtualMemorySize * 1024
    $commitFree  = [double]$os.FreeVirtualMemory * 1024
    $commitUsed  = [Math]::Max(0.0, $commitTotal - $commitFree)

    $boot = $null
    try { $boot = [DateTime]$os.LastBootUpTime } catch { }

    [pscustomobject]@{
        Total          = $total
        Used           = $used
        Free           = $free
        Percent        = if ($total -gt 0) { 100.0 * $used / $total } else { 0.0 }
        CommitTotal    = $commitTotal
        CommitUsed     = $commitUsed
        CommitPercent  = if ($commitTotal -gt 0) { 100.0 * $commitUsed / $commitTotal } else { 0.0 }
        BootTime       = $boot
    }
}

function Format-Uptime {
    param([AllowNull()]$BootTime)

    if ($null -eq $BootTime) { return 'unknown' }

    $span = [DateTime]::Now - [DateTime]$BootTime
    if ($span.TotalSeconds -lt 0) { return 'unknown' }

    if ($span.Days -gt 0) { return ('{0}d {1}h' -f $span.Days, $span.Hours) }
    if ($span.Hours -gt 0) { return ('{0}h {1}m' -f $span.Hours, $span.Minutes) }
    return ('{0}m' -f $span.Minutes)
}

function Get-DiskSample {
    $disks = [System.Collections.Generic.List[object]]::new()

    foreach ($row in @(Get-CimInstance -Query $TaskDiskQuery -ErrorAction Stop)) {
        $size = [double]$row.Size
        if ($size -le 0) { continue }

        $free = [double]$row.FreeSpace
        $used = [Math]::Max(0.0, $size - $free)

        $disks.Add([pscustomobject]@{
            Name    = [string]$row.DeviceID
            Label   = [string]$row.VolumeName
            Total   = $size
            Used    = $used
            Free    = $free
            Percent = 100.0 * $used / $size
        })
    }

    return @($disks)
}

function Get-NetRawSample {
    $sample = @{}
    foreach ($row in @(Get-CimInstance -Query $TaskNetQuery -ErrorAction Stop)) {
        $sample[[string]$row.Name] = [pscustomobject]@{
            Received = [double]$row.BytesReceivedPersec
            Sent     = [double]$row.BytesSentPersec
            Stamp    = [double]$row.Timestamp_Sys100NS
            Frequency = [double]$row.Frequency_Sys100NS
        }
    }
    return $sample
}

# Despite the property names, the raw class reports cumulative byte totals, not
# rates - so the per-second figure is ours to work out. Summed across every
# interface, because a machine with Wi-Fi, Ethernet and a VPN adapter has three
# and the interesting number is the total.
function Get-NetworkLoad {
    param([Parameter(Mandatory)][AllowNull()]$Previous, [Parameter(Mandatory)]$Current)

    if ($null -eq $Previous) {
        return [pscustomobject]@{ Received = 0.0; Sent = 0.0; Ready = $false }
    }

    $received = 0.0
    $sent = 0.0

    foreach ($name in $Current.Keys) {
        if (-not $Previous.ContainsKey($name)) { continue }

        $frequency = $Current[$name].Frequency
        if ($frequency -le 0) { continue }

        $seconds = ($Current[$name].Stamp - $Previous[$name].Stamp) / $frequency
        if ($seconds -le 0) { continue }

        # A counter that went backwards means the adapter was reset; skip it
        # rather than reporting a negative rate.
        $deltaIn  = $Current[$name].Received - $Previous[$name].Received
        $deltaOut = $Current[$name].Sent - $Previous[$name].Sent
        if ($deltaIn -ge 0)  { $received += $deltaIn / $seconds }
        if ($deltaOut -ge 0) { $sent += $deltaOut / $seconds }
    }

    return [pscustomobject]@{ Received = $received; Sent = $sent; Ready = $true }
}

# Get-Process rather than Win32_PerfRawData_PerfProc_Process: it is cheaper
# (29ms against 31ms), and its names are the real ones. The perf class
# disambiguates same-named processes with a '#1' suffix and reports the _Total
# pseudo-instance under pid 0, both of which would have to be undone.
function Get-ProcessRawSample {
    $sample = @{}

    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
        # Reading these can throw on a process this session cannot open, which
        # happens for protected processes when we are not elevated. A null CPU
        # time shows as '-' rather than a wrong number.
        $cpuSeconds = $null
        try { $cpuSeconds = [double]$proc.TotalProcessorTime.TotalSeconds } catch { }

        $threads = 0
        try { $threads = @($proc.Threads).Count } catch { }

        $sample[[int]$proc.Id] = [pscustomobject]@{
            Id         = [int]$proc.Id
            Name       = [string]$proc.ProcessName
            WorkingSet = [double]$proc.WorkingSet64
            Threads    = $threads
            CpuSeconds = $cpuSeconds
        }
    }

    return $sample
}

# CPU share of one process over the elapsed window: its own CPU seconds divided
# by the wall seconds available across every core. A process pegging two cores
# of an eight-core machine reads 25%, which is what Task Manager shows.
function Get-ProcessLoad {
    param(
        [Parameter(Mandatory)][AllowNull()]$Previous,
        [Parameter(Mandatory)]$Current,
        [Parameter(Mandatory)][double]$ElapsedSeconds,
        [Parameter(Mandatory)][int]$Cores
    )

    $available = $ElapsedSeconds * [Math]::Max(1, $Cores)
    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($id in $Current.Keys) {
        $entry = $Current[$id]

        $percent = 0.0
        $known = $false

        if ($null -ne $Previous -and $Previous.ContainsKey($id) -and
            $null -ne $entry.CpuSeconds -and $null -ne $Previous[$id].CpuSeconds -and $available -gt 0) {

            $delta = $entry.CpuSeconds - $Previous[$id].CpuSeconds
            if ($delta -ge 0) {
                $percent = [Math]::Max(0.0, [Math]::Min(100.0, 100.0 * $delta / $available))
                $known = $true
            }
        }

        $rows.Add([pscustomobject]@{
            Id         = $entry.Id
            Name       = $entry.Name
            Cpu        = $percent
            CpuKnown   = $known
            WorkingSet = $entry.WorkingSet
            Threads    = $entry.Threads
            CpuSeconds = $entry.CpuSeconds
        })
    }

    return @($rows)
}

function Sort-TaskProcess {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes,
        [string]$Key = 'cpu'
    )

    switch ($Key) {
        'mem'  { return @($Processes | Sort-Object -Property WorkingSet -Descending) }
        'pid'  { return @($Processes | Sort-Object -Property Id) }
        'name' { return @($Processes | Sort-Object -Property Name, Id) }
        # Working set breaks CPU ties, so the list does not reshuffle every
        # frame while everything sits at 0%.
        default { return @($Processes | Sort-Object -Property Cpu, WorkingSet -Descending) }
    }
}

function Select-TaskProcess {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes,
        [AllowEmptyString()][string]$Filter = ''
    )

    if ([string]::IsNullOrWhiteSpace($Filter)) { return @($Processes) }

    $needle = $Filter.Trim()
    return @($Processes | Where-Object {
        $_.Name -like "*$needle*" -or [string]$_.Id -like "*$needle*"
    })
}

# -----------------------------------------------------------------------------
# The monitor: one object holding the previous sample and the history rings
# -----------------------------------------------------------------------------

function New-TaskMonitor {
    param([int]$HistoryLength = 120)

    [pscustomobject]@{
        Cores         = [Math]::Max(1, [Environment]::ProcessorCount)
        HistoryLength = $HistoryLength

        # Previous raw samples, kept so the next refresh has a delta to work on.
        PreviousCpu   = $null
        PreviousNet   = $null
        PreviousProc  = $null
        PreviousStamp = $null

        Cpu           = [pscustomobject]@{ Total = 0.0; Cores = @(); Ready = $false }
        Memory        = $null
        Disks         = @()
        Network       = [pscustomobject]@{ Received = 0.0; Sent = 0.0; Ready = $false }
        Processes     = @()

        CpuHistory    = [System.Collections.Generic.List[double]]::new()
        MemHistory    = [System.Collections.Generic.List[double]]::new()
        RxHistory     = [System.Collections.Generic.List[double]]::new()
        TxHistory     = [System.Collections.Generic.List[double]]::new()

        SortKey       = 'cpu'
        Filter        = ''

        # Set once the second sample lands: until then there is no delta, so
        # every rate is 0 and saying so beats drawing a flat line as fact.
        Ready         = $false
        Errors        = @()
    }
}

function Add-TaskHistory {
    param([Parameter(Mandatory)]$History, [double]$Value, [int]$Limit)

    $History.Add($Value)
    while ($History.Count -gt $Limit) { $History.RemoveAt(0) }
}

# One refresh, in place. Each source is guarded on its own: a machine where the
# network counters are missing still gets CPU, memory, disks and processes,
# with the failure named in $Monitor.Errors rather than thrown.
function Update-TaskMonitor {
    param([Parameter(Mandatory)]$Monitor)

    $now = [DateTime]::UtcNow
    $elapsed = 0.0
    if ($null -ne $Monitor.PreviousStamp) { $elapsed = ($now - $Monitor.PreviousStamp).TotalSeconds }

    $errors = [System.Collections.Generic.List[string]]::new()

    # ---- CPU ---------------------------------------------------------------
    try {
        $cpuRaw = Get-CpuRawSample
        $Monitor.Cpu = Get-CpuLoad -Previous $Monitor.PreviousCpu -Current $cpuRaw
        $Monitor.PreviousCpu = $cpuRaw

        if ($Monitor.Cpu.Ready) {
            Add-TaskHistory -History $Monitor.CpuHistory -Value $Monitor.Cpu.Total -Limit $Monitor.HistoryLength
        }
    }
    catch { $errors.Add("CPU counters unavailable: $($_.Exception.Message)") }

    # ---- memory ------------------------------------------------------------
    try {
        $Monitor.Memory = Get-MemorySample
        Add-TaskHistory -History $Monitor.MemHistory -Value $Monitor.Memory.Percent -Limit $Monitor.HistoryLength
    }
    catch { $errors.Add("Memory counters unavailable: $($_.Exception.Message)") }

    # ---- disks -------------------------------------------------------------
    try { $Monitor.Disks = @(Get-DiskSample) }
    catch { $errors.Add("Disk list unavailable: $($_.Exception.Message)") }

    # ---- network -----------------------------------------------------------
    try {
        $netRaw = Get-NetRawSample
        $Monitor.Network = Get-NetworkLoad -Previous $Monitor.PreviousNet -Current $netRaw
        $Monitor.PreviousNet = $netRaw

        if ($Monitor.Network.Ready) {
            Add-TaskHistory -History $Monitor.RxHistory -Value $Monitor.Network.Received -Limit $Monitor.HistoryLength
            Add-TaskHistory -History $Monitor.TxHistory -Value $Monitor.Network.Sent -Limit $Monitor.HistoryLength
        }
    }
    catch { $errors.Add("Network counters unavailable: $($_.Exception.Message)") }

    # ---- processes ---------------------------------------------------------
    try {
        $procRaw = Get-ProcessRawSample
        $rows = @(Get-ProcessLoad -Previous $Monitor.PreviousProc -Current $procRaw `
            -ElapsedSeconds $elapsed -Cores $Monitor.Cores)
        $Monitor.PreviousProc = $procRaw
        $Monitor.Processes = @(Sort-TaskProcess -Processes $rows -Key $Monitor.SortKey)
    }
    catch { $errors.Add("Process list unavailable: $($_.Exception.Message)") }

    $Monitor.Errors = @($errors)
    $Monitor.PreviousStamp = $now
    if ($elapsed -gt 0) { $Monitor.Ready = $true }

    return $Monitor
}

# The peak of a history ring, for scaling a graph that has no natural ceiling.
# Network has no equivalent of "100%", so the graph scales to the busiest
# moment still on screen, with a floor so an idle link is not all spikes.
function Get-HistoryScale {
    param([Parameter(Mandatory)]$History, [double]$Minimum = 1)

    $peak = $Minimum
    foreach ($value in $History) { if ($value -gt $peak) { $peak = $value } }
    return $peak
}

# -----------------------------------------------------------------------------
# Killing
# -----------------------------------------------------------------------------

# Windows marks a handful of processes critical: ending one bugchecks the
# machine with CRITICAL_PROCESS_DIED rather than closing a program. The monitor
# refuses those outright instead of asking, because there is no answer to that
# prompt that leaves the machine running.
function Test-CriticalProcess {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    $critical = @(
        'system', 'idle', 'registry', 'memory compression', 'secure system',
        'csrss', 'smss', 'wininit', 'winlogon', 'services', 'lsass'
    )
    return ($critical -contains $Name.ToLowerInvariant())
}

function Stop-TaskProcess {
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name
    )

    if (Test-CriticalProcess -Name $Name) {
        Write-Err "$Name is a critical Windows process - ending it bugchecks the machine. Refusing."
        return $false
    }

    if ($Ctx.DryRun) {
        Write-Info "would kill $Name (pid $Id)"
        return $false
    }

    # No -DefaultYes: an accidental Enter should not end a process.
    if (-not (Confirm-Action "Kill $Name (pid $Id)? Unsaved work in it is lost.")) {
        Write-Warn "$Name (pid $Id) - left running."
        return $false
    }

    try {
        Stop-Process -Id $Id -Force -ErrorAction Stop
        Write-Ok "$Name (pid $Id) ended."
        Write-Log "killed process $Name ($Id)"
        return $true
    }
    catch {
        Write-Err "Could not end $Name (pid $Id): $($_.Exception.Message)"
        return $false
    }
}
