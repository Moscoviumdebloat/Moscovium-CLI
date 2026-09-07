# =============================================================================
# Task manager, console front-end.
#
# Draws through the same Write-Frame the selector uses - home the cursor, print
# a frame sized to fit the window, blank whatever a taller previous frame left
# behind. No ANSI, no alternate screen buffer: it repaints in place on a legacy
# conhost exactly as it does in Windows Terminal.
#
# The layout is measured, not guessed. The gauges take whatever they need, the
# keys and status line are reserved, and the process table gets the rest - so
# the frame never grows past the window and starts scrolling, which would break
# the home-the-cursor repaint for good.
# =============================================================================

# Rows the frame spends on things that are not process-table body: the blank
# line, the title, two rules, the column header, the status line and the keys
# make seven, plus one spare row.
#
# The spare row matters. Write-Frame prints one line per frame line, and a frame
# exactly as tall as the window scrolls it by one on the final newline - which
# moves the top of the buffer off-screen and breaks the home-the-cursor repaint
# for the rest of the session.
$TaskChromeRows = 8

# The key hint, on one line that has to fit an 80-column window.
#
# Write-Frame truncates at the window width, so anything longer loses its own
# tail - and the tail here is 'esc back', the one key someone stuck in the
# monitor needs. Hence single-space separators rather than the selector's
# roomier three: this view has more keys to name than any other.
function Get-TaskKeyHint {
    $dot = Get-Glyph 'Sep'
    $parts = @('up/down move', 'c/m/p/n sort', 'k kill', '/ filter', 'space pause', 'esc back')
    return ('  ' + ($parts -join " $dot "))
}

function Get-TaskSortLabel {
    param([Parameter(Mandatory)][string]$Key)

    switch ($Key) {
        'mem'  { return 'memory' }
        'pid'  { return 'pid' }
        'name' { return 'name' }
        default { return 'cpu' }
    }
}

# One gauge: label, percentage, bar, then whatever trailing text fits.
function New-TaskGaugeLine {
    param(
        [Parameter(Mandatory)][string]$Label,
        [double]$Percent,
        [int]$BarWidth = 20,
        [string]$Trailing = ''
    )

    $bar = New-MeterBar -Percent $Percent -Width $BarWidth
    $text = '  {0,-5} {1,3:N0}%  {2}' -f $Label, $Percent, $bar
    if ($Trailing) { $text += '  ' + $Trailing }

    return (New-FrameLine $text (Get-LoadColor -Percent $Percent))
}

# Per-core load. Up to twelve cores get a labelled cell each, wrapped to the
# window; past that the cells would take more rows than the process table, so
# it collapses to one character per core off the sparkline ramp - dense, but it
# still shows which cores are pinned.
function New-TaskCoreLines {
    param([Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Cores, [int]$Width = 78)

    $lines = [System.Collections.Generic.List[object]]::new()
    if ($Cores.Count -eq 0) { return @($lines) }

    if ($Cores.Count -gt 12) {
        $ramp = @(Get-Glyph 'Spark')
        $strip = New-Object Text.StringBuilder
        foreach ($core in $Cores) {
            $level = [int][Math]::Round(([Math]::Max(0.0, [Math]::Min(100.0, $core)) / 100.0) * ($ramp.Count - 1))
            [void]$strip.Append($ramp[$level])
        }
        $lines.Add((New-FrameLine ("        cores {0}  {1}" -f $Cores.Count, $strip.ToString()) (Get-Color 'AccentDim')))
        return @($lines)
    }

    # '  0 12% [##..]  ' - eight cells fit an 80-column window.
    $cells = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Cores.Count; $i++) {
        $cells.Add(('{0,2} {1,3:N0}% {2}' -f $i, $Cores[$i], (New-MeterBar -Percent $Cores[$i] -Width 6)))
    }

    $perLine = [Math]::Max(1, [int](($Width - 8) / 15))
    for ($start = 0; $start -lt $cells.Count; $start += $perLine) {
        $end = [Math]::Min($start + $perLine, $cells.Count) - 1
        $lines.Add((New-FrameLine ('        ' + (@($cells[$start..$end]) -join '  ')) (Get-Color 'AccentDim')))
    }

    return @($lines)
}

# Everything above the process table.
function New-TaskHeaderLines {
    param([Parameter(Mandatory)]$Monitor, [int]$Width = 78)

    $lines = [System.Collections.Generic.List[object]]::new()

    # Bar and graph split the width left after the label and percentage.
    $barWidth = 20
    $graphWidth = [Math]::Max(8, [Math]::Min(40, $Width - 58))

    # ---- CPU ---------------------------------------------------------------
    $cpuGraph = New-Sparkline -Values @($Monitor.CpuHistory) -Width $graphWidth -Maximum 100
    $lines.Add((New-TaskGaugeLine -Label 'CPU' -Percent $Monitor.Cpu.Total -BarWidth $barWidth -Trailing $cpuGraph))
    foreach ($line in @(New-TaskCoreLines -Cores @($Monitor.Cpu.Cores) -Width $Width)) { $lines.Add($line) }

    # ---- memory ------------------------------------------------------------
    if ($Monitor.Memory) {
        $memText = '{0} / {1}   commit {2} / {3}' -f `
            (Format-Bytes $Monitor.Memory.Used), (Format-Bytes $Monitor.Memory.Total),
            (Format-Bytes $Monitor.Memory.CommitUsed), (Format-Bytes $Monitor.Memory.CommitTotal)
        $lines.Add((New-TaskGaugeLine -Label 'MEM' -Percent $Monitor.Memory.Percent -BarWidth $barWidth -Trailing $memText))
    }

    # ---- disks -------------------------------------------------------------
    # Capped at three: a machine with eight volumes should not lose the process
    # table to a list of drives.
    $shown = 0
    foreach ($disk in @($Monitor.Disks)) {
        if ($shown -ge 3) { break }
        $label = if ($disk.Label) { " $($disk.Label)" } else { '' }
        $diskText = '{0}{1}   {2} free of {3}' -f $disk.Name, $label, (Format-Bytes $disk.Free), (Format-Bytes $disk.Total)
        $lines.Add((New-TaskGaugeLine -Label 'DISK' -Percent $disk.Percent -BarWidth $barWidth -Trailing $diskText))
        $shown++
    }

    # ---- network -----------------------------------------------------------
    # No natural ceiling, so both graphs scale to the busiest sample still on
    # screen. The floor keeps an idle link from drawing background noise as
    # spikes.
    $scale = Get-HistoryScale -History $Monitor.RxHistory -Minimum (Get-HistoryScale -History $Monitor.TxHistory -Minimum 65536)
    $netText = 'down {0}   up {1}' -f (Format-Rate $Monitor.Network.Received), (Format-Rate $Monitor.Network.Sent)
    $netGraph = New-Sparkline -Values @($Monitor.RxHistory) -Width $graphWidth -Maximum $scale
    $lines.Add((New-FrameLine ('  NET        ' + $netText.PadRight(30) + '  ' + $netGraph) (Get-Color 'Accent')))

    foreach ($problem in @($Monitor.Errors)) {
        $lines.Add((New-FrameLine ('  ' + $problem) (Get-Color 'Warn')))
    }

    return @($lines)
}

# One table row, header included - the header is the same shape with words in
# place of numbers, which is the cheapest way to keep them aligned.
function New-TaskTableRow {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Pointer,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Cpu,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Memory,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Threads,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Time,
        [Parameter(Mandatory)][int]$NameWidth,
        [switch]$Wide
    )

    $shown = $Name
    if ($shown.Length -gt $NameWidth) { $shown = $shown.Substring(0, $NameWidth - 1) + '.' }

    $text = '  ' + $Pointer + ' ' + $Id.PadRight(7) + ' ' + $shown.PadRight($NameWidth) +
            ' ' + $Cpu.PadLeft(7) + ' ' + $Memory.PadLeft(9)

    if ($Wide) { $text += ' ' + $Threads.PadLeft(5) + ' ' + $Time.PadLeft(10) }

    return $text
}

# The table header and body. Columns drop right-to-left on a narrow window
# rather than wrapping, because a wrapped row would break the row-per-process
# arithmetic the cursor relies on.
function New-TaskTableLines {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][int]$Cursor,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][int]$Viewport,
        [int]$Width = 78
    )

    $lines = [System.Collections.Generic.List[object]]::new()
    $wide = $Width -ge 74

    # Columns are padded by hand rather than through a composite format string
    # with a computed width - the name column is the only elastic one, and
    # building '{1,-24}' at runtime is a lot of quoting for one number.
    $fixed = 32
    if ($wide) { $fixed = 46 }
    $nameWidth = [Math]::Max(12, [Math]::Min(28, $Width - $fixed))

    $lines.Add((New-FrameLine (
        New-TaskTableRow -Pointer ' ' -Id 'PID' -Name 'NAME' -Cpu 'CPU%' -Memory 'MEMORY' `
            -Threads 'THR' -Time 'CPU TIME' -NameWidth $nameWidth -Wide:$wide
    ) (Get-Color 'Muted')))

    if ($Rows.Count -eq 0) {
        $lines.Add((New-FrameLine '      no matching process' (Get-Color 'Warn')))
        return @($lines)
    }

    $last = [Math]::Min($Offset + $Viewport, $Rows.Count)
    for ($row = $Offset; $row -lt $last; $row++) {
        $proc = $Rows[$row]

        # A process whose CPU we have only sampled once has no delta yet, and a
        # dash is honest where 0.0 would not be.
        $cpu = '-'
        if ($proc.CpuKnown) { $cpu = '{0:N1}' -f $proc.Cpu }

        $pointer = ' '
        if ($row -eq $Cursor) { $pointer = Get-Glyph 'Pointer' }

        $rendered = New-TaskTableRow -Pointer $pointer -Id ([string]$proc.Id) -Name $proc.Name `
            -Cpu $cpu -Memory (Format-Bytes $proc.WorkingSet) -Threads ([string]$proc.Threads) `
            -Time (Format-CpuTime $proc.CpuSeconds) -NameWidth $nameWidth -Wide:$wide

        if ($row -eq $Cursor) {
            $lines.Add((New-FrameLine $rendered (Get-Color 'HighlightFg') (Get-Color 'HighlightBg')))
        }
        else {
            # Busy processes colour like the gauges do, so the eye lands on them
            # without having to read the numbers.
            $color = if ($proc.CpuKnown -and $proc.Cpu -ge 5) { Get-LoadColor -Percent $proc.Cpu } else { Get-Color 'Text' }
            $lines.Add((New-FrameLine $rendered $color))
        }
    }

    return @($lines)
}

# Waits up to $TimeoutMs for a keypress, polling rather than blocking, so the
# view refreshes on its own while nobody is typing.
function Wait-TaskKey {
    param([int]$TimeoutMs = 1000)

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        try { if ($Host.UI.RawUI.KeyAvailable) { return (Read-MenuKey) } }
        catch { return $null }
        Start-Sleep -Milliseconds 40
    }
    return $null
}

function Show-TaskManager {
    param([int]$IntervalMs = 1000)

    if (-not (Test-Interactive)) {
        Show-TaskSnapshot
        return
    }

    $monitor = New-TaskMonitor
    $cursor = 0
    $offset = 0
    $previousHeight = 0
    $paused = $false

    # Same reason as the selector: Write-Frame homes to the top of the buffer,
    # which in a scrolled window is off-screen. Clearing makes (0,0) the top of
    # what you can see, and a frame that always fits keeps it that way.
    Clear-Host

    # First sample has no previous to difference against, so every rate reads
    # zero. Take it immediately and let the loop draw the second one.
    Update-TaskMonitor -Monitor $monitor | Out-Null

    while ($true) {
        if (-not $paused) { Update-TaskMonitor -Monitor $monitor | Out-Null }

        $width = (Get-ConsoleWidth) - 2
        $rows = @(Select-TaskProcess -Processes @($monitor.Processes) -Filter $monitor.Filter)

        $header = @(New-TaskHeaderLines -Monitor $monitor -Width $width)
        $viewport = [Math]::Max(3, (Get-ConsoleHeight) - $TaskChromeRows - $header.Count)

        $view = Get-ScrollWindow -Cursor $cursor -Offset $offset -Count $rows.Count -Viewport $viewport
        $cursor = $view.Cursor
        $offset = $view.Offset

        $rule = (Get-Glyph 'HLine') * (Get-RuleWidth)
        $dot = Get-Glyph 'Sep'

        $lines = [System.Collections.Generic.List[object]]::new()
        $lines.Add((New-FrameLine))

        $title = '  Tasks'
        if ($monitor.Memory) { $title += '   up ' + (Format-Uptime $monitor.Memory.BootTime) }
        $title += "   {0} cores   {1} processes" -f $monitor.Cores, @($monitor.Processes).Count
        if ($paused) { $title += '   PAUSED' }
        $lines.Add((New-FrameLine $title (Get-Color 'Accent')))

        foreach ($line in $header) { $lines.Add($line) }
        $lines.Add((New-FrameLine ('  ' + $rule) (Get-Color 'Muted')))

        foreach ($line in @(New-TaskTableLines -Rows $rows -Cursor $cursor -Offset $offset -Viewport $viewport -Width $width)) {
            $lines.Add($line)
        }

        $lines.Add((New-FrameLine ('  ' + $rule) (Get-Color 'Muted')))

        $position = if ($rows.Count -gt 0) { "$($cursor + 1)/$($rows.Count)" } else { '0/0' }
        $status = "  $position   $dot   sort: $(Get-TaskSortLabel -Key $monitor.SortKey)"
        if ($monitor.Filter) { $status += "   $dot   filter: $($monitor.Filter)" }
        if (-not $monitor.Ready) { $status += "   $dot   sampling" }
        $lines.Add((New-FrameLine $status (Get-Color 'Muted')))

        $lines.Add((New-FrameLine (Get-TaskKeyHint) (Get-Color 'Muted')))

        Write-Frame -Lines $lines.ToArray() -PreviousHeight ([ref]$previousHeight)

        $key = Wait-TaskKey -TimeoutMs $IntervalMs
        if ($null -eq $key) { continue }

        switch ($key.Code) {
            38 { if ($rows.Count) { $cursor = [Math]::Max(0, $cursor - 1) }; continue }                   # up
            40 { if ($rows.Count) { $cursor = [Math]::Min($rows.Count - 1, $cursor + 1) }; continue }     # down
            33 { $cursor = [Math]::Max(0, $cursor - $viewport); continue }                                # page up
            34 { $cursor = [Math]::Min([Math]::Max(0, $rows.Count - 1), $cursor + $viewport); continue }  # page down
            36 { $cursor = 0; continue }                                                                  # home
            35 { $cursor = [Math]::Max(0, $rows.Count - 1); continue }                                    # end

            27 { Clear-Host; return }                                                                     # escape

            8 {
                if ($monitor.Filter.Length -gt 0) {
                    $monitor.Filter = $monitor.Filter.Substring(0, $monitor.Filter.Length - 1)
                    $cursor = 0; $offset = 0
                }
                continue
            }
        }

        switch -Regex ([string]$key.Char) {
            '^[cC]$' { $monitor.SortKey = 'cpu';  $cursor = 0; $offset = 0; continue }
            '^[mM]$' { $monitor.SortKey = 'mem';  $cursor = 0; $offset = 0; continue }
            '^[pP]$' { $monitor.SortKey = 'pid';  $cursor = 0; $offset = 0; continue }
            '^[nN]$' { $monitor.SortKey = 'name'; $cursor = 0; $offset = 0; continue }
            '^[qQ]$' { Clear-Host; return }

            '^[kK]$' {
                if ($rows.Count -eq 0) { continue }
                $target = $rows[$cursor]

                # Drop out of the frame to ask: the confirm prompt reads from
                # the host, and a Read-Host inside a repainting frame would be
                # overwritten before it could be answered.
                Clear-Host
                Write-Line ''
                Stop-TaskProcess -Id $target.Id -Name $target.Name | Out-Null
                Write-Line ''
                Write-Info 'Press a key to go back to the monitor.'
                [void](Wait-TaskKey -TimeoutMs 10000)

                Clear-Host
                $previousHeight = 0
                # The killed process leaves a hole in the list; resample so the
                # cursor is not pointing at a row that no longer exists.
                $monitor.PreviousStamp = $null
                Update-TaskMonitor -Monitor $monitor | Out-Null
                continue
            }

            '^/$' {
                Write-Line ''
                Write-Line '  filter: ' -Color Yellow -NoNewline
                $monitor.Filter = [string](Read-Host)
                $cursor = 0; $offset = 0
                $previousHeight = 0
                Clear-Host
                continue
            }

            '^ $' { $paused = -not $paused; continue }
        }
    }
}

# What -Tasks prints when there is no console to drive: one sample, no loop.
# Also what a redirected run gets, so `-Tasks > tasks.txt` is useful instead of
# spinning forever repainting a frame nobody can see.
function Show-TaskSnapshot {
    param([int]$Top = 20)

    $monitor = New-TaskMonitor

    # Two samples a second apart: the first has nothing to difference against,
    # so without the second every CPU figure would be zero.
    Update-TaskMonitor -Monitor $monitor | Out-Null
    Start-Sleep -Milliseconds 1000
    Update-TaskMonitor -Monitor $monitor | Out-Null

    Write-SectionHeading 'Tasks'

    Write-Line ('  CPU    {0,5:N1}%   {1} cores' -f $monitor.Cpu.Total, $monitor.Cores) -Color (Get-LoadColor -Percent $monitor.Cpu.Total)

    if ($monitor.Memory) {
        Write-Line ('  MEM    {0,5:N1}%   {1} of {2}   commit {3} of {4}' -f `
            $monitor.Memory.Percent, (Format-Bytes $monitor.Memory.Used), (Format-Bytes $monitor.Memory.Total),
            (Format-Bytes $monitor.Memory.CommitUsed), (Format-Bytes $monitor.Memory.CommitTotal)) `
            -Color (Get-LoadColor -Percent $monitor.Memory.Percent)
    }

    foreach ($disk in @($monitor.Disks)) {
        Write-Line ('  DISK   {0,5:N1}%   {1} {2} free of {3}' -f `
            $disk.Percent, $disk.Name, (Format-Bytes $disk.Free), (Format-Bytes $disk.Total)) `
            -Color (Get-LoadColor -Percent $disk.Percent)
    }

    Write-Line ('  NET            down {0}   up {1}' -f `
        (Format-Rate $monitor.Network.Received), (Format-Rate $monitor.Network.Sent)) -Color (Get-Color 'Accent')

    foreach ($problem in @($monitor.Errors)) { Write-Warn $problem }

    Write-Line ''
    Write-Line ('  {0,-7} {1,-28} {2,7} {3,9} {4,5}' -f 'PID', 'NAME', 'CPU%', 'MEMORY', 'THR') -Color (Get-Color 'Muted')

    foreach ($proc in @(@($monitor.Processes) | Select-Object -First $Top)) {
        $cpu = if ($proc.CpuKnown) { '{0,7:N1}' -f $proc.Cpu } else { '      -' }
        Write-Line ('  {0,-7} {1,-28} {2} {3,9} {4,5}' -f `
            $proc.Id, $proc.Name, $cpu, (Format-Bytes $proc.WorkingSet), $proc.Threads)
    }

    Write-Line ''
    Write-Info "Showing the top $Top of $(@($monitor.Processes).Count) processes by CPU."
}
