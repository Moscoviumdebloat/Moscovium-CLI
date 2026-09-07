# =============================================================================
# Task manager, console front-end.
#
# btop's layout, drawn with Write-Frame: bordered boxes with the title in the
# top edge, a braille history graph, meters whose cells shade green to red
# along their own length, and a process table underneath.
#
# Two things make that possible without ANSI:
#
#   Frame segments. A frame line can carry several differently coloured pieces
#   (see New-FrameLineFromSegments), which is what a box with a coloured title
#   or a shaded meter is. Write-Frame writes them with -NoNewline and pads the
#   row once at the end, so it is still one console line.
#
#   Measured layout. The gauges take what they need, the keys and status rows
#   are reserved, and the process table gets the rest, so the frame never grows
#   past the window - which would scroll it and break the home-the-cursor
#   repaint for the rest of the session.
# =============================================================================

# Rows outside the boxes: the blank line, the title, the status line and the
# keys, plus one spare.
#
# The spare row matters. Write-Frame prints one line per frame line, and a frame
# exactly as tall as the window scrolls it by one on the final newline - which
# moves the top of the buffer off-screen and breaks every later repaint.
$TaskChromeRows = 5

# -----------------------------------------------------------------------------
# Keyboard
#
# [Console]::KeyAvailable, not $Host.UI.RawUI.KeyAvailable.
#
# RawUI's version reports any pending console input record - including focus
# changes, window resizes and key-*up* events - while ReadKey('IncludeKeyDown')
# accepts only key-down records. So RawUI can say a key is waiting when ReadKey
# will block, and the monitor stops refreshing until a real key arrives. That
# was the "it does not auto update" bug.
#
# The Console pair is consistent: both filter to real key presses. ConsoleKey's
# numeric values are the virtual key codes, so the switch arms are unchanged.
# -----------------------------------------------------------------------------

function Test-TaskKeyboard {
    try {
        $null = [Console]::KeyAvailable
        return $true
    }
    catch { return $false }
}

function Read-TaskKey {
    $key = [Console]::ReadKey($true)
    [pscustomobject]@{
        Code = [int]$key.Key
        Char = $key.KeyChar
    }
}

# Anything typed before the monitor opened - the Enter that picked it out of the
# menu, most often - would otherwise be spent on the first frame.
function Clear-TaskKeyBuffer {
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } }
    catch { }
}

# Waits up to $TimeoutMs for a keypress, polling rather than blocking, so the
# view refreshes on its own while nobody is typing.
function Wait-TaskKey {
    param([int]$TimeoutMs = 1000)

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        try { if ([Console]::KeyAvailable) { return (Read-TaskKey) } }
        catch { return $null }
        Start-Sleep -Milliseconds 30
    }
    return $null
}

# -----------------------------------------------------------------------------
# Boxes
# -----------------------------------------------------------------------------

function Get-TaskSortLabel {
    param([Parameter(Mandatory)][string]$Key)

    switch ($Key) {
        'mem'  { return 'memory' }
        'pid'  { return 'pid' }
        'name' { return 'name' }
        default { return 'cpu' }
    }
}

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

# '  |/- cpu -----------\|' - the title sits in the top edge, btop style.
function New-TaskBoxTop {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][int]$Width,
        [string]$Trailing = ''
    )

    $line = Get-Glyph 'HLine'
    $border = Get-Color 'Muted'

    $segments = [System.Collections.Generic.List[object]]::new()
    $segments.Add((New-FrameSegment '  ' $border))
    $segments.Add((New-FrameSegment ((Get-Glyph 'TopLeft') + $line) $border))
    $segments.Add((New-FrameSegment " $Title " (Get-Color 'Accent')))

    # Anything the box wants to say on its own top edge - a peak, a total -
    # goes right-aligned before the corner.
    $tail = ''
    if ($Trailing) { $tail = " $Trailing " }

    # Everything between the two corners is $Width - 2 wide, same as the inner
    # width New-TaskBoxRow pads to. The two-space indent is outside the box and
    # must not be counted here - getting that wrong put the top edge two
    # characters short of the walls below it.
    $fillWidth = ($Width - 2) - 1 - ($Title.Length + 2) - $tail.Length
    if ($fillWidth -lt 0) { $fillWidth = 0 }

    $segments.Add((New-FrameSegment ($line * $fillWidth) $border))
    if ($tail) { $segments.Add((New-FrameSegment $tail (Get-Color 'Muted'))) }
    $segments.Add((New-FrameSegment (Get-Glyph 'TopRight') $border))

    return (New-FrameLineFromSegments -Segments @($segments))
}

function New-TaskBoxBottom {
    param([Parameter(Mandatory)][int]$Width)

    $border = Get-Color 'Muted'
    $inner = $Width - 2
    if ($inner -lt 0) { $inner = 0 }

    return (New-FrameLineFromSegments -Segments @(
        (New-FrameSegment '  ' $border)
        (New-FrameSegment ((Get-Glyph 'BottomLeft') + ((Get-Glyph 'HLine') * $inner) + (Get-Glyph 'BottomRight')) $border)
    ))
}

# Wraps content segments in the box's side walls, padding to the inner width so
# the right wall lines up whatever the content did.
function New-TaskBoxRow {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Content,
        [Parameter(Mandatory)][int]$Width
    )

    $border = Get-Color 'Muted'
    $wall = Get-Glyph 'VLine'
    $inner = $Width - 2

    $segments = [System.Collections.Generic.List[object]]::new()
    $segments.Add((New-FrameSegment '  ' $border))
    $segments.Add((New-FrameSegment $wall $border))

    # Clamp here rather than trusting each caller to size its own text. Content
    # longer than the box would push the right wall off the end of the row, and
    # every box has some elastic piece - a detail string, a process name - that
    # can outgrow a narrow window. One place to get right.
    $used = 0
    foreach ($segment in @($Content)) {
        if ($used -ge $inner) { break }

        $text = [string]$segment.Text
        if (($used + $text.Length) -gt $inner) {
            $text = $text.Substring(0, $inner - $used)
            $segments.Add((New-FrameSegment $text $segment.Color $segment.Background))
            $used = $inner
            break
        }

        $used += $text.Length
        $segments.Add($segment)
    }

    if ($used -lt $inner) { $segments.Add((New-FrameSegment (' ' * ($inner - $used)))) }
    $segments.Add((New-FrameSegment $wall $border))

    return (New-FrameLineFromSegments -Segments @($segments))
}

# Meter cells coloured by their own position along the bar, not by the current
# reading - so the right-hand end is red whether or not the value has reached
# it, and the bar shows headroom as well as load. btop's trick.
#
# Runs of one colour are coalesced into a single segment: a 20-cell meter ends
# up as three or four Write-Host calls rather than twenty.
function New-TaskMeterSegments {
    param([double]$Percent, [Parameter(Mandatory)][int]$Width)

    if ($Width -lt 1) { return @() }

    $clamped = [Math]::Max(0.0, [Math]::Min(100.0, $Percent))
    $filled = [int][Math]::Round(($clamped / 100.0) * $Width)
    if ($filled -gt $Width) { $filled = $Width }

    $full = Get-Glyph 'BarFull'
    $empty = Get-Glyph 'BarEmpty'
    $dim = Get-Color 'Muted'

    $segments = [System.Collections.Generic.List[object]]::new()

    $runColor = $null
    $runLength = 0

    for ($i = 0; $i -lt $filled; $i++) {
        # Position of this cell along the bar, as a percentage.
        $color = Get-LoadColor -Percent ((($i + 1) / [double]$Width) * 100.0)

        if ($runLength -gt 0 -and $color -eq $runColor) { $runLength++; continue }
        if ($runLength -gt 0) { $segments.Add((New-FrameSegment ($full * $runLength) $runColor)) }
        $runColor = $color
        $runLength = 1
    }
    if ($runLength -gt 0) { $segments.Add((New-FrameSegment ($full * $runLength) $runColor)) }

    if ($filled -lt $Width) { $segments.Add((New-FrameSegment ($empty * ($Width - $filled)) $dim)) }

    return @($segments)
}

# -----------------------------------------------------------------------------
# The boxes
# -----------------------------------------------------------------------------

# CPU: history graph, total meter, then a meter per core.
function New-TaskCpuBox {
    param(
        [Parameter(Mandatory)]$Monitor,
        [Parameter(Mandatory)][int]$Width,
        [int]$GraphHeight = 3
    )

    $lines = [System.Collections.Generic.List[object]]::new()
    $inner = $Width - 2

    $peak = 0.0
    foreach ($value in $Monitor.CpuHistory) { if ($value -gt $peak) { $peak = $value } }

    $lines.Add((New-TaskBoxTop -Title 'cpu' -Width $Width -Trailing ('peak {0:N0}%' -f $peak)))

    if ($GraphHeight -gt 0) {
        $graphWidth = $inner - 2
        $graph = @(New-HistoryGraph -Values @($Monitor.CpuHistory) -Width $graphWidth -Height $GraphHeight -Maximum 100)

        # Top rows of the graph are the high readings, so they shade upward
        # through the load bands - the same idea as the meter cells.
        for ($row = 0; $row -lt $graph.Count; $row++) {
            $band = 100.0 * (($graph.Count - $row) / [double]$graph.Count)
            $lines.Add((New-TaskBoxRow -Width $Width -Content @(
                (New-FrameSegment ' ' )
                (New-FrameSegment $graph[$row] (Get-LoadColor -Percent $band))
            )))
        }
    }

    $meterWidth = [Math]::Max(10, [Math]::Min(34, $inner - 22))
    $lines.Add((New-TaskBoxRow -Width $Width -Content @(
        @((New-FrameSegment ' total ' (Get-Color 'Text')),
          (New-FrameSegment ('{0,4:N0}% ' -f $Monitor.Cpu.Total) (Get-LoadColor -Percent $Monitor.Cpu.Total))) +
        @(New-TaskMeterSegments -Percent $Monitor.Cpu.Total -Width $meterWidth)
    )))

    foreach ($line in @(New-TaskCoreRows -Monitor $Monitor -Width $Width)) { $lines.Add($line) }
    $lines.Add((New-TaskBoxBottom -Width $Width))

    return @($lines)
}

# One labelled meter per core, wrapped to the box. Past twelve cores the labels
# would cost more rows than the process table, so it collapses to a single
# dot-per-core strip off the graph ramp - dense, but it still shows which cores
# are pinned.
function New-TaskCoreRows {
    param([Parameter(Mandatory)]$Monitor, [Parameter(Mandatory)][int]$Width)

    $lines = [System.Collections.Generic.List[object]]::new()
    $cores = @($Monitor.Cpu.Cores)
    if ($cores.Count -eq 0) { return @($lines) }

    $inner = $Width - 2

    if ($cores.Count -gt 12) {
        $content = [System.Collections.Generic.List[object]]::new()
        $content.Add((New-FrameSegment (' {0,2} cores ' -f $cores.Count) (Get-Color 'Muted')))
        foreach ($core in $cores) {
            $content.Add((New-FrameSegment (Get-Glyph 'BarFull') (Get-LoadColor -Percent $core)))
        }
        $lines.Add((New-TaskBoxRow -Width $Width -Content @($content)))
        return @($lines)
    }

    # ' 0  15% ######....' - eleven characters of label plus the meter.
    $meterWidth = 8
    $cellWidth = 9 + $meterWidth + 2
    $perLine = [Math]::Max(1, [int](($inner - 1) / $cellWidth))

    for ($start = 0; $start -lt $cores.Count; $start += $perLine) {
        $content = [System.Collections.Generic.List[object]]::new()
        $content.Add((New-FrameSegment ' '))

        for ($i = $start; $i -lt [Math]::Min($start + $perLine, $cores.Count); $i++) {
            $content.Add((New-FrameSegment (' {0,-2}' -f $i) (Get-Color 'Muted')))
            $content.Add((New-FrameSegment ('{0,4:N0}% ' -f $cores[$i]) (Get-LoadColor -Percent $cores[$i])))
            foreach ($segment in @(New-TaskMeterSegments -Percent $cores[$i] -Width $meterWidth)) {
                $content.Add($segment)
            }
            $content.Add((New-FrameSegment '  '))
        }

        $lines.Add((New-TaskBoxRow -Width $Width -Content @($content)))
    }

    return @($lines)
}

# Memory, disk and network in one box: three rows, each a label, a reading, a
# meter and its detail. Kept as rows rather than side-by-side boxes so the
# meters all start at the same column and can be compared at a glance.
function New-TaskSystemBox {
    param([Parameter(Mandatory)]$Monitor, [Parameter(Mandatory)][int]$Width)

    $lines = [System.Collections.Generic.List[object]]::new()
    $inner = $Width - 2

    $lines.Add((New-TaskBoxTop -Title 'mem  disk  net' -Width $Width))

    $meterWidth = [Math]::Max(10, [Math]::Min(28, $inner - 46))
    $detailWidth = [Math]::Max(0, $inner - 14 - $meterWidth - 2)

    if ($Monitor.Memory) {
        $detail = '{0} of {1}   commit {2}' -f `
            (Format-Bytes $Monitor.Memory.Used), (Format-Bytes $Monitor.Memory.Total),
            (Format-Bytes $Monitor.Memory.CommitUsed)

        $lines.Add((New-TaskBoxRow -Width $Width -Content (
            @((New-FrameSegment ' mem  ' (Get-Color 'Text')),
              (New-FrameSegment ('{0,4:N0}% ' -f $Monitor.Memory.Percent) (Get-LoadColor -Percent $Monitor.Memory.Percent))) +
            @(New-TaskMeterSegments -Percent $Monitor.Memory.Percent -Width $meterWidth) +
            @((New-FrameSegment ('  ' + $detail.PadRight($detailWidth)) (Get-Color 'Muted')))
        )))
    }

    # The fullest volume: that is the one about to cause a problem. The rest are
    # counted, not listed, so eight volumes cannot push out the process table.
    $disks = @($Monitor.Disks)
    if ($disks.Count -gt 0) {
        $worst = @($disks | Sort-Object -Property Percent -Descending)[0]

        $detail = '{0} {1} free of {2}' -f $worst.Name, (Format-Bytes $worst.Free), (Format-Bytes $worst.Total)
        if ($disks.Count -gt 1) { $detail += '   +{0} more' -f ($disks.Count - 1) }

        $lines.Add((New-TaskBoxRow -Width $Width -Content (
            @((New-FrameSegment ' disk ' (Get-Color 'Text')),
              (New-FrameSegment ('{0,4:N0}% ' -f $worst.Percent) (Get-LoadColor -Percent $worst.Percent))) +
            @(New-TaskMeterSegments -Percent $worst.Percent -Width $meterWidth) +
            @((New-FrameSegment ('  ' + $detail.PadRight($detailWidth)) (Get-Color 'Muted')))
        )))
    }

    # Network has no ceiling to be a percentage of, so the meter is replaced by
    # a sparkline scaled to the busiest sample still on screen.
    $scale = Get-HistoryScale -History $Monitor.RxHistory `
        -Minimum (Get-HistoryScale -History $Monitor.TxHistory -Minimum 65536)
    $spark = New-Sparkline -Values @($Monitor.RxHistory) -Width $meterWidth -Maximum $scale

    $detail = 'down {0}   up {1}' -f (Format-Rate $Monitor.Network.Received), (Format-Rate $Monitor.Network.Sent)

    $lines.Add((New-TaskBoxRow -Width $Width -Content @(
        (New-FrameSegment ' net  ' (Get-Color 'Text'))
        (New-FrameSegment '      ' (Get-Color 'Muted'))
        (New-FrameSegment $spark (Get-Color 'Accent'))
        (New-FrameSegment ('  ' + $detail.PadRight($detailWidth)) (Get-Color 'Muted'))
    )))

    foreach ($problem in @($Monitor.Errors)) {
        $lines.Add((New-TaskBoxRow -Width $Width -Content @(
            (New-FrameSegment (' ' + $problem) (Get-Color 'Warn'))
        )))
    }

    $lines.Add((New-TaskBoxBottom -Width $Width))
    return @($lines)
}

# -----------------------------------------------------------------------------
# Process table
# -----------------------------------------------------------------------------

# Column widths for a given box width. One place, so the header and the rows
# cannot drift apart.
function Get-TaskColumnLayout {
    param([Parameter(Mandatory)][int]$Width)

    $wide = $Width -ge 76
    $fixed = 30
    if ($wide) { $fixed = 44 }

    [pscustomobject]@{
        Wide = $wide
        Name = [Math]::Max(10, [Math]::Min(30, $Width - $fixed))
    }
}

function New-TaskTableHeader {
    param([Parameter(Mandatory)][int]$Width)

    $layout = Get-TaskColumnLayout -Width $Width
    $faint = Get-Color 'Faint'

    $text = ' ' + 'pid'.PadRight(8) + 'name'.PadRight($layout.Name) +
            'cpu%'.PadLeft(7) + 'memory'.PadLeft(9)
    if ($layout.Wide) { $text += 'thr'.PadLeft(6) + 'cpu time'.PadLeft(11) }

    return (New-TaskBoxRow -Width $Width -Content @((New-FrameSegment $text $faint)))
}

# One process row. The name is plain, the numbers carry the load colour, and
# the cursor row inverts - so the eye lands on the busy processes without
# having to read any of the figures.
function New-TaskProcessRow {
    param(
        [Parameter(Mandatory)]$Process,
        [Parameter(Mandatory)][int]$Width,
        [switch]$Selected
    )

    $layout = Get-TaskColumnLayout -Width $Width

    $name = [string]$Process.Name
    if ($name.Length -gt $layout.Name) { $name = $name.Substring(0, $layout.Name - 1) + '.' }

    # A process we have only sampled once has no delta yet, and a dash is
    # honest where 0.0 would be a claim.
    $cpu = '-'
    if ($Process.CpuKnown) { $cpu = '{0:N1}' -f $Process.Cpu }

    if ($Selected) {
        $text = ' ' + ([string]$Process.Id).PadRight(8) + $name.PadRight($layout.Name) +
                $cpu.PadLeft(7) + (Format-Bytes $Process.WorkingSet).PadLeft(9)
        if ($layout.Wide) {
            $text += ([string]$Process.Threads).PadLeft(6) + (Format-CpuTime $Process.CpuSeconds).PadLeft(11)
        }
        # A padded full-width run plus a background is a real selection bar.
        $inner = $Width - 2
        return (New-TaskBoxRow -Width $Width -Content @(
            (New-FrameSegment $text.PadRight($inner) (Get-Color 'HighlightFg') (Get-Color 'HighlightBg'))
        ))
    }

    $cpuColor = Get-Color 'Muted'
    if ($Process.CpuKnown -and $Process.Cpu -ge 1) { $cpuColor = Get-LoadColor -Percent $Process.Cpu }

    $segments = [System.Collections.Generic.List[object]]::new()
    $segments.Add((New-FrameSegment (' ' + ([string]$Process.Id).PadRight(8)) (Get-Color 'Faint')))
    $segments.Add((New-FrameSegment $name.PadRight($layout.Name) (Get-Color 'Text')))
    $segments.Add((New-FrameSegment $cpu.PadLeft(7) $cpuColor))
    $segments.Add((New-FrameSegment (Format-Bytes $Process.WorkingSet).PadLeft(9) (Get-Color 'Muted')))

    if ($layout.Wide) {
        $segments.Add((New-FrameSegment ([string]$Process.Threads).PadLeft(6) (Get-Color 'Faint')))
        $segments.Add((New-FrameSegment (Format-CpuTime $Process.CpuSeconds).PadLeft(11) (Get-Color 'Faint')))
    }

    return (New-TaskBoxRow -Width $Width -Content @($segments))
}

function New-TaskProcessBox {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][int]$Cursor,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][int]$Viewport,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)]$Monitor
    )

    $lines = [System.Collections.Generic.List[object]]::new()

    $title = 'proc'
    $trailing = '{0} shown' -f $Rows.Count
    if ($Monitor.Filter) { $trailing = "{0} of {1}   filter: {2}" -f $Rows.Count, @($Monitor.Processes).Count, $Monitor.Filter }

    $lines.Add((New-TaskBoxTop -Title $title -Width $Width -Trailing $trailing))
    $lines.Add((New-TaskTableHeader -Width $Width))

    if ($Rows.Count -eq 0) {
        $lines.Add((New-TaskBoxRow -Width $Width -Content @(
            (New-FrameSegment ' nothing matches that filter' (Get-Color 'Warn'))
        )))
    }
    else {
        $last = [Math]::Min($Offset + $Viewport, $Rows.Count)
        for ($row = $Offset; $row -lt $last; $row++) {
            $lines.Add((New-TaskProcessRow -Process $Rows[$row] -Width $Width -Selected:($row -eq $Cursor)))
        }
    }

    $lines.Add((New-TaskBoxBottom -Width $Width))
    return @($lines)
}

# -----------------------------------------------------------------------------
# The loop
# -----------------------------------------------------------------------------

# How tall the CPU graph can be. It is the first thing to give up rows on a
# short window, because a graph is worth less than another process row.
function Get-TaskGraphHeight {
    param([Parameter(Mandatory)][int]$ConsoleHeight)

    if ($ConsoleHeight -lt 26) { return 0 }
    if ($ConsoleHeight -lt 34) { return 2 }
    return 3
}

# The whole frame, so the loop and the tests build it the same way and the
# "does it fit the window" invariant can be checked without a terminal.
#
# Returns the frame lines plus the viewport and cursor the layout settled on,
# because the caller needs those back to interpret the next keypress.
function New-TaskFrame {
    param(
        [Parameter(Mandatory)]$Monitor,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$ConsoleHeight,
        [int]$Cursor = 0,
        [int]$Offset = 0,
        [switch]$Paused
    )

    $cpuBox = @(New-TaskCpuBox -Monitor $Monitor -Width $Width -GraphHeight (Get-TaskGraphHeight -ConsoleHeight $ConsoleHeight))
    $systemBox = @(New-TaskSystemBox -Monitor $Monitor -Width $Width)

    # Everything except the process rows: the two boxes above, the process
    # box's own top, header and bottom, and the page chrome.
    $spent = $TaskChromeRows + $cpuBox.Count + $systemBox.Count + 3
    $viewport = [Math]::Max(3, $ConsoleHeight - $spent)

    $view = Get-ScrollWindow -Cursor $Cursor -Offset $Offset -Count $Rows.Count -Viewport $viewport

    $lines = [System.Collections.Generic.List[object]]::new()
    $lines.Add((New-FrameLine))

    # A title row, not the wordmark: five rows of ASCII art is five process
    # rows, and this screen is about the processes.
    $titleSegments = [System.Collections.Generic.List[object]]::new()
    $titleSegments.Add((New-FrameSegment '  tasks' (Get-Color 'Accent')))
    $titleSegments.Add((New-FrameSegment ("   {0} cores   {1} processes" -f $Monitor.Cores, @($Monitor.Processes).Count) (Get-Color 'Muted')))
    if ($Monitor.Memory) {
        $titleSegments.Add((New-FrameSegment ('   up ' + (Format-Uptime $Monitor.Memory.BootTime)) (Get-Color 'Muted')))
    }
    $titleSegments.Add((New-FrameSegment ('   sort: ' + (Get-TaskSortLabel -Key $Monitor.SortKey)) (Get-Color 'Faint')))
    if (-not $Monitor.Ready) { $titleSegments.Add((New-FrameSegment '   sampling' (Get-Color 'Faint'))) }
    if ($Paused) { $titleSegments.Add((New-FrameSegment '   PAUSED' (Get-Color 'Warn'))) }
    $lines.Add((New-FrameLineFromSegments -Segments @($titleSegments)))

    foreach ($line in $cpuBox) { $lines.Add($line) }
    foreach ($line in $systemBox) { $lines.Add($line) }
    foreach ($line in @(New-TaskProcessBox -Rows $Rows -Cursor $view.Cursor -Offset $view.Offset `
        -Viewport $viewport -Width $Width -Monitor $Monitor)) { $lines.Add($line) }

    $lines.Add((New-FrameLine (Get-TaskKeyHint) (Get-Color 'Muted')))

    [pscustomobject]@{
        Lines    = @($lines)
        Viewport = $viewport
        Cursor   = $view.Cursor
        Offset   = $view.Offset
    }
}

# The box width for a given console. Capped, because a meter stretched across a
# 200-column terminal is harder to read than one that stops.
function Get-TaskBoxWidth {
    param([Parameter(Mandatory)][int]$ConsoleWidth)
    return [Math]::Max(46, [Math]::Min(96, $ConsoleWidth - 4))
}

function Show-TaskManager {
    param([int]$IntervalMs = 1000)

    # A host that cannot read individual keys cannot drive a live view, and a
    # frame repainted where nobody can see it is worse than useless.
    if (-not (Test-Interactive) -or -not (Test-TaskKeyboard)) {
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
    Clear-TaskKeyBuffer

    # The first sample has nothing to difference against, so every rate reads
    # zero. Take it now and let the loop draw the second one.
    Update-TaskMonitor -Monitor $monitor | Out-Null

    while ($true) {
        if (-not $paused) { Update-TaskMonitor -Monitor $monitor | Out-Null }

        $rows = @(Select-TaskProcess -Processes @($monitor.Processes) -Filter $monitor.Filter)

        $frame = New-TaskFrame -Monitor $monitor -Rows $rows `
            -Width (Get-TaskBoxWidth -ConsoleWidth (Get-ConsoleWidth)) `
            -ConsoleHeight (Get-ConsoleHeight) `
            -Cursor $cursor -Offset $offset -Paused:$paused

        $cursor = $frame.Cursor
        $offset = $frame.Offset
        $viewport = $frame.Viewport

        Write-Frame -Lines $frame.Lines -PreviousHeight ([ref]$previousHeight)

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
                Clear-TaskKeyBuffer
                [void](Wait-TaskKey -TimeoutMs 15000)

                Clear-Host
                Clear-TaskKeyBuffer
                $previousHeight = 0
                # The ended process leaves a hole in the list, so resample
                # rather than leaving the cursor on a row that is gone.
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
                Clear-TaskKeyBuffer
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

    Write-Line ('  cpu    {0,5:N1}%   {1} cores' -f $monitor.Cpu.Total, $monitor.Cores) -Color (Get-LoadColor -Percent $monitor.Cpu.Total)

    if ($monitor.Memory) {
        Write-Line ('  mem    {0,5:N1}%   {1} of {2}   commit {3} of {4}' -f `
            $monitor.Memory.Percent, (Format-Bytes $monitor.Memory.Used), (Format-Bytes $monitor.Memory.Total),
            (Format-Bytes $monitor.Memory.CommitUsed), (Format-Bytes $monitor.Memory.CommitTotal)) `
            -Color (Get-LoadColor -Percent $monitor.Memory.Percent)
    }

    foreach ($disk in @($monitor.Disks)) {
        Write-Line ('  disk   {0,5:N1}%   {1} {2} free of {3}' -f `
            $disk.Percent, $disk.Name, (Format-Bytes $disk.Free), (Format-Bytes $disk.Total)) `
            -Color (Get-LoadColor -Percent $disk.Percent)
    }

    Write-Line ('  net            down {0}   up {1}' -f `
        (Format-Rate $monitor.Network.Received), (Format-Rate $monitor.Network.Sent)) -Color (Get-Color 'Accent')

    foreach ($problem in @($monitor.Errors)) { Write-Warn $problem }

    Write-Line ''
    Write-Line ('  {0,-8}{1,-30}{2,7}{3,9}{4,6}' -f 'pid', 'name', 'cpu%', 'memory', 'thr') -Color (Get-Color 'Faint')

    foreach ($proc in @(@($monitor.Processes) | Select-Object -First $Top)) {
        $cpu = '-'
        if ($proc.CpuKnown) { $cpu = '{0:N1}' -f $proc.Cpu }
        Write-Line ('  {0,-8}{1,-30}{2,7}{3,9}{4,6}' -f `
            $proc.Id, $proc.Name, $cpu, (Format-Bytes $proc.WorkingSet), $proc.Threads)
    }

    Write-Line ''
    Write-Info "Showing the top $Top of $(@($monitor.Processes).Count) processes by CPU."
}
