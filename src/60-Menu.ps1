# =============================================================================
# Interactive menus.
#
# This is what `irm moscovium.win | iex` lands in, so it has to work in a plain
# console with no arguments. Show-Selector drives every list; when the host
# cannot read individual keypresses it degrades to a numbered prompt rather than
# failing.
# =============================================================================

function Get-ConsoleWidth {
    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        if ($width -gt 20) { return $width }
    }
    catch { }
    return 100
}

function Get-ConsoleHeight {
    try {
        $height = $Host.UI.RawUI.WindowSize.Height
        if ($height -gt 10) { return $height }
    }
    catch { }
    return 30
}

# Rendering a frame in one pass and padding each line to the console width lets
# us repaint from the cursor home position without the flicker of Clear-Host.
function Write-Frame {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Lines, [ref]$PreviousHeight)

    $width = (Get-ConsoleWidth) - 1

    $homed = $false
    try {
        [Console]::SetCursorPosition(0, 0)
        $homed = $true
    }
    catch { Clear-Host }

    foreach ($line in $Lines) {
        # A line can be one string in one colour, or a run of segments in
        # different colours - which is what a box with a coloured title, or a
        # meter whose cells shade from green to red, is made of. Segments are
        # written with -NoNewline and the row is padded once at the end, so the
        # result is still exactly one console line.
        if (@($line.Segments).Count -gt 0) {
            $used = 0

            foreach ($segment in @($line.Segments)) {
                if ($used -ge $width) { break }

                $text = [string]$segment.Text
                if (($used + $text.Length) -gt $width) { $text = $text.Substring(0, $width - $used) }
                if ($text.Length -eq 0) { continue }
                $used += $text.Length

                if (-not $Ctx.UseColor) { Write-Host $text -NoNewline; continue }

                $splat = @{ Object = $text; NoNewline = $true }
                if ($segment.Color)      { $splat.ForegroundColor = $segment.Color }
                if ($segment.Background) { $splat.BackgroundColor = $segment.Background }
                Write-Host @splat
            }

            if ($used -lt $width) { Write-Host (' ' * ($width - $used)) -NoNewline }
            Write-Host ''
            continue
        }

        $text = [string]$line.Text
        if ($text.Length -gt $width) { $text = $text.Substring(0, $width) }
        # Padding to the full width is what turns a background colour into a
        # solid selection bar rather than a coloured word.
        $text = $text.PadRight($width)

        if (-not $Ctx.UseColor) { Write-Host $text; continue }

        $splat = @{ Object = $text }
        if ($line.Color)      { $splat.ForegroundColor = $line.Color }
        if ($line.Background) { $splat.BackgroundColor = $line.Background }
        Write-Host @splat
    }

    # Erase whatever the previous, taller frame left behind.
    if ($homed -and $PreviousHeight) {
        for ($i = $Lines.Count; $i -lt $PreviousHeight.Value; $i++) {
            Write-Host (' ' * $width)
        }
    }
    if ($PreviousHeight) { $PreviousHeight.Value = $Lines.Count }
}

# Segments is always present, even when empty: Set-StrictMode makes reading an
# absent property throw, and Write-Frame checks it on every line.
function New-FrameLine {
    param([AllowEmptyString()][string]$Text = '', $Color = $null, $Background = $null)
    [pscustomobject]@{ Text = $Text; Color = $Color; Background = $Background; Segments = @() }
}

function New-FrameSegment {
    param([AllowEmptyString()][string]$Text = '', $Color = $null, $Background = $null)
    [pscustomobject]@{ Text = $Text; Color = $Color; Background = $Background }
}

# A frame line built from coloured pieces. Text is kept in step with the
# segments so callers that only want to measure or match a line still can -
# the tests do, and so does the log pane.
function New-FrameLineFromSegments {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Segments)

    $text = -join @($Segments | ForEach-Object { [string]$_.Text })
    [pscustomobject]@{ Text = $text; Color = $null; Background = $null; Segments = @($Segments) }
}

function Read-MenuKey {
    $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    [pscustomobject]@{
        Code = $key.VirtualKeyCode
        Char = $key.Character
    }
}

# Numbered fallback for hosts without keypress support (redirected stdin, ISE).
function Show-SelectorFallback {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$Label,
        [Parameter(Mandatory)][string]$Title,
        [switch]$SingleSelect
    )

    Write-SectionHeading $Title

    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Line ("  {0,3}. " -f ($i + 1)) -Color DarkGray -NoNewline
        Write-Line (& $Label $Items[$i])
    }

    Write-Line ''
    $hint = if ($SingleSelect) { 'Enter a number' } else { 'Enter numbers separated by commas, or "all"' }
    Write-Line "  $hint (blank to cancel): " -Color Yellow -NoNewline

    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return [pscustomobject]@{ Confirmed = $false; Selected = @() }
    }

    if ($answer.Trim() -eq 'all' -and -not $SingleSelect) {
        return [pscustomobject]@{ Confirmed = $true; Selected = @($Items) }
    }

    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($token in ($answer -split ',')) {
        $index = 0
        if ([int]::TryParse($token.Trim(), [ref]$index) -and $index -ge 1 -and $index -le $Items.Count) {
            $selected.Add($Items[$index - 1])
            if ($SingleSelect) { break }
        }
        else {
            Write-Warn "Ignoring '$($token.Trim())'."
        }
    }

    [pscustomobject]@{ Confirmed = ($selected.Count -gt 0); Selected = @($selected) }
}

# Indices of $Items whose label (plus sublabel) match the current filter, in
# order. An empty filter matches everything.
function Get-VisibleIndex {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [AllowEmptyString()][string]$Filter,
        [Parameter(Mandatory)][scriptblock]$Label,
        [scriptblock]$Sublabel
    )

    @(
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if (-not $Filter) { $i; continue }

            $text = [string](& $Label $Items[$i])
            if ($Sublabel) { $text += ' ' + [string](& $Sublabel $Items[$i]) }

            if (Test-NameMatch -Value $text -Pattern $Filter) { $i }
        }
    )
}

# Clamps the cursor into range and scrolls the window just far enough to keep it
# visible. Split out from the key loop so the off-by-ones are testable.
function Get-ScrollWindow {
    param(
        [Parameter(Mandatory)][int]$Cursor,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][int]$Viewport
    )

    if ($Count -le 0) { return [pscustomobject]@{ Cursor = 0; Offset = 0 } }

    if ($Cursor -ge $Count) { $Cursor = $Count - 1 }
    if ($Cursor -lt 0) { $Cursor = 0 }

    if ($Cursor -lt $Offset) { $Offset = $Cursor }
    if ($Cursor -ge $Offset + $Viewport) { $Offset = $Cursor - $Viewport + 1 }

    $maxOffset = [Math]::Max(0, $Count - $Viewport)
    if ($Offset -gt $maxOffset) { $Offset = $maxOffset }
    if ($Offset -lt 0) { $Offset = 0 }

    [pscustomobject]@{ Cursor = $Cursor; Offset = $Offset }
}

function Show-Selector {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$Label,
        [scriptblock]$Sublabel,
        [Parameter(Mandatory)][string]$Title,
        [string]$Subtitle = '',
        [switch]$SingleSelect,
        # Draw the wordmark instead of the plain title. The main menu is the
        # front page, so it gets the art; sub-menus want to say where you are.
        [switch]$Art
    )

    if ($Items.Count -eq 0) {
        Write-Warn 'Nothing to show here.'
        return [pscustomobject]@{ Confirmed = $false; Selected = @() }
    }

    if (-not (Test-Interactive)) {
        return Show-SelectorFallback -Items $Items -Label $Label -Title $Title -SingleSelect:$SingleSelect
    }

    $selected = [System.Collections.Generic.HashSet[int]]::new()
    $cursor = 0
    $offset = 0
    $filter = ''
    $previousHeight = 0

    # Clear once up front. Write-Frame repaints by homing the cursor to (0,0),
    # which is the top of the *buffer* - in a scrolled conhost window that is
    # off-screen. Clearing resets the buffer so (0,0) is the top of the visible
    # window, and every frame is sized to fit without scrolling, so it stays that
    # way for as long as the selector is open.
    Clear-Host

    while ($true) {
        # @() is required: PowerShell unrolls a returned array, so a filter that
        # matches one item would hand back a bare int and one that matches none
        # would hand back $null - and .Count on either throws under StrictMode.
        $visible = @(Get-VisibleIndex -Items $Items -Filter $filter -Label $Label -Sublabel $Sublabel)

        # Recomputed every frame so a resize is picked up. A window too narrow
        # for the art falls back to the plain title rather than wrapping it into
        # nonsense, and the rows it costs come out of the list's viewport so the
        # frame still fits without scrolling.
        $wordmark = @()
        if ($Art -and (Get-ConsoleWidth) -ge ((Get-WordmarkWidth) + 2)) {
            $wordmark = @(Get-WordmarkLines)
        }
        $headerRows = if ($wordmark.Count -gt 0) { $wordmark.Count - 1 } else { 0 }

        $viewport = [Math]::Max(5, (Get-ConsoleHeight) - 10 - $headerRows)
        $view = Get-ScrollWindow -Cursor $cursor -Offset $offset -Count $visible.Count -Viewport $viewport
        $cursor = $view.Cursor
        $offset = $view.Offset

        # Same width as Write-Rule, so the selector lines up with section rules.
        $rule = (Get-Glyph 'HLine') * (Get-RuleWidth)

        $lines = [System.Collections.Generic.List[object]]::new()
        $lines.Add((New-FrameLine))
        if ($wordmark.Count -gt 0) {
            foreach ($line in $wordmark) { $lines.Add((New-FrameLine $line.Text $line.Color)) }
        }
        else {
            $lines.Add((New-FrameLine ('  ' + $Title) (Get-Color 'Accent')))
        }
        if ($Subtitle) { $lines.Add((New-FrameLine ('  ' + $Subtitle) (Get-Color 'Muted'))) }
        $lines.Add((New-FrameLine ('  ' + $rule) (Get-Color 'Muted')))

        if ($visible.Count -eq 0) {
            $lines.Add((New-FrameLine "     no match for '$filter'" (Get-Color 'Warn')))
        }

        $last = [Math]::Min($offset + $viewport, $visible.Count)
        for ($row = $offset; $row -lt $last; $row++) {
            $index = $visible[$row]
            $isCursor = ($row -eq $cursor)
            $isSelected = $selected.Contains($index)

            $marker = if ($SingleSelect) { ' ' }
                      elseif ($isSelected) { Get-Glyph 'Checked' }
                      else { Get-Glyph 'Unchecked' }

            $pointer = if ($isCursor) { Get-Glyph 'Pointer' } else { ' ' }
            $text = '  {0} {1} {2}' -f $pointer, $marker, (& $Label $Items[$index])

            if ($Sublabel) {
                $extra = (& $Sublabel $Items[$index])
                if ($extra) { $text = $text.PadRight(48) + $extra }
            }

            if ($isCursor) {
                # A padded full-width line plus a background colour is a real
                # selection bar - the whole row inverts, not just the text.
                $lines.Add((New-FrameLine $text (Get-Color 'HighlightFg') (Get-Color 'HighlightBg')))
            }
            elseif ($isSelected) {
                $lines.Add((New-FrameLine $text (Get-Color 'SelectedFg')))
            }
            else {
                $lines.Add((New-FrameLine $text (Get-Color 'Text')))
            }
        }

        $lines.Add((New-FrameLine ('  ' + $rule) (Get-Color 'Muted')))

        $dot = Get-Glyph 'Sep'
        $position = if ($visible.Count -gt 0) { "$($cursor + 1)/$($visible.Count)" } else { '0/0' }
        $status = "  $position"
        if (-not $SingleSelect) { $status += "   $dot   $($selected.Count) selected" }
        if ($filter) { $status += "   $dot   filter: $filter" }
        $lines.Add((New-FrameLine $status (Get-Color 'Muted')))

        $keys = if ($SingleSelect) {
            "  up/down move   $dot   enter choose   $dot   / filter   $dot   esc back"
        }
        else {
            "  up/down move   $dot   space toggle   $dot   a all   $dot   n none   $dot   i invert   $dot   / filter   $dot   enter confirm   $dot   esc back"
        }
        $lines.Add((New-FrameLine $keys (Get-Color 'Muted')))

        Write-Frame -Lines $lines.ToArray() -PreviousHeight ([ref]$previousHeight)

        $key = Read-MenuKey

        switch ($key.Code) {
            38 { if ($visible.Count) { $cursor = ($cursor - 1 + $visible.Count) % $visible.Count }; continue }  # up
            40 { if ($visible.Count) { $cursor = ($cursor + 1) % $visible.Count }; continue }                    # down
            33 { $cursor = [Math]::Max(0, $cursor - $viewport); continue }                                       # page up
            34 { $cursor = [Math]::Min($visible.Count - 1, $cursor + $viewport); continue }                      # page down
            36 { $cursor = 0; continue }                                                                        # home
            35 { $cursor = $visible.Count - 1; continue }                                                        # end

            27 {  # escape
                Clear-Host
                return [pscustomobject]@{ Confirmed = $false; Selected = @() }
            }

            13 {  # enter
                Clear-Host
                if ($SingleSelect) {
                    if ($visible.Count -eq 0) { return [pscustomobject]@{ Confirmed = $false; Selected = @() } }
                    return [pscustomobject]@{ Confirmed = $true; Selected = @($Items[$visible[$cursor]]) }
                }
                $chosen = @($selected | Sort-Object | ForEach-Object { $Items[$_] })
                return [pscustomobject]@{ Confirmed = $true; Selected = $chosen }
            }

            8 {  # backspace trims the filter
                if ($filter.Length -gt 0) { $filter = $filter.Substring(0, $filter.Length - 1) }
                continue
            }
        }

        switch -CaseSensitive ($key.Char) {
            ' ' {
                if (-not $SingleSelect -and $visible.Count -gt 0) {
                    $index = $visible[$cursor]
                    if ($selected.Contains($index)) { [void]$selected.Remove($index) }
                    else { [void]$selected.Add($index) }
                }
                continue
            }
            '/' {
                # Prompt on the last line rather than repainting the whole frame.
                Write-Line ''
                Write-Line '  filter: ' -Color Yellow -NoNewline
                $filter = Read-Host
                $cursor = 0; $offset = 0
                continue
            }
            default {
                if ($SingleSelect) { continue }
                switch -Regex ([string]$key.Char) {
                    '^[aA]$' { foreach ($i in $visible) { [void]$selected.Add($i) }; continue }
                    '^[nN]$' { $selected.Clear(); continue }
                    '^[iI]$' {
                        foreach ($i in $visible) {
                            if ($selected.Contains($i)) { [void]$selected.Remove($i) } else { [void]$selected.Add($i) }
                        }
                        continue
                    }
                }
            }
        }
    }
}

# -----------------------------------------------------------------------------
# Screens
# -----------------------------------------------------------------------------

function Select-Category {
    param(
        [Parameter(Mandatory)][string[]]$Categories,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Counter
    )

    $options = @(
        [pscustomobject]@{ Name = 'All'; IsAll = $true }
    ) + @($Categories | ForEach-Object { [pscustomobject]@{ Name = $_; IsAll = $false } })

    $result = Show-Selector -Items $options -Title $Title -SingleSelect `
        -Subtitle 'Pick a category to narrow the list' `
        -Label { param($o) $o.Name } `
        -Sublabel { param($o) "$(& $Counter $o) item(s)" }

    if (-not $result.Confirmed) { return $null }
    return $result.Selected[0]
}

function Show-TweakMenu {
    $category = Select-Category -Categories $Ctx.TweakCategories -Title 'Tweaks' -Counter {
        param($o)
        if ($o.IsAll) { $Ctx.Tweaks.Count } else { @($Ctx.Tweaks | Where-Object { $_.category -eq $o.Name }).Count }
    }
    if (-not $category) { return }

    $pool = if ($category.IsAll) { $Ctx.Tweaks } else { @($Ctx.Tweaks | Where-Object { $_.category -eq $category.Name }) }

    # Status is read once up front: 40 tweaks is ~90 registry reads, and doing it
    # per keypress would make the list feel sluggish.
    $statuses = @{}
    foreach ($tweak in $pool) { $statuses[$tweak.name] = Get-TweakStatus -Tweak $tweak }

    $result = Show-Selector -Items $pool -Title "Tweaks - $($category.Name)" `
        -Subtitle 'Space to select, Enter to continue' `
        -Label { param($t) $t.name } `
        -Sublabel {
            param($t)
            switch ($statuses[$t.name]) {
                'Applied'    { 'applied' }
                'Partial'    { 'partial' }
                'Action'     { 'action' }
                default      { '' }
            }
        }

    if (-not $result.Confirmed -or $result.Selected.Count -eq 0) { return }

    $mode = Show-Selector -Items @(
        [pscustomobject]@{ Name = 'Apply';  Mode = 'Apply' }
        [pscustomobject]@{ Name = 'Revert'; Mode = 'Revert' }
    ) -Title "$($result.Selected.Count) tweak(s) selected" -SingleSelect `
        -Subtitle 'Revert restores the values Moscovium recorded before applying' `
        -Label { param($m) $m.Name }

    if (-not $mode.Confirmed) { return }

    Write-Banner
    foreach ($tweak in $result.Selected) { Write-Info $tweak.name }

    if (Confirm-Action "$($mode.Selected[0].Mode) these $($result.Selected.Count) tweak(s)?" -DefaultYes) {
        Invoke-Tweaks -Tweaks $result.Selected -Mode $mode.Selected[0].Mode
    }

    Wait-ForKey
}

function Show-AppMenu {
    $category = Select-Category -Categories $Ctx.AppCategories -Title 'Apps' -Counter {
        param($o)
        if ($o.IsAll) { $Ctx.Apps.Count } else { @($Ctx.Apps | Where-Object { $_.category -eq $o.Name }).Count }
    }
    if (-not $category) { return }

    $pool = if ($category.IsAll) { $Ctx.Apps } else { @($Ctx.Apps | Where-Object { $_.category -eq $category.Name }) }

    $result = Show-Selector -Items $pool -Title "Apps - $($category.Name)" `
        -Subtitle 'Space to select, / to search, Enter to install' `
        -Label { param($a) $a.name } `
        -Sublabel { param($a) [string]$a.description }

    if (-not $result.Confirmed -or $result.Selected.Count -eq 0) { return }

    Write-Banner
    foreach ($app in $result.Selected) { Write-Info $app.name }

    if (Confirm-Action "Install these $($result.Selected.Count) app(s)?" -DefaultYes) {
        Invoke-AppInstall -Apps $result.Selected
    }

    Wait-ForKey
}

function Show-ToolboxMenu {
    # Without the one-click box: it is the main menu's first entry instead.
    $actions = Get-ToolboxListActions

    $result = Show-Selector -Items $actions -Title 'Toolbox' -SingleSelect `
        -Subtitle 'One-shot actions and classic control panels' `
        -Label { param($a) $a.Name } `
        -Sublabel { param($a) if ($a.Admin) { 'admin' } else { '' } }

    if (-not $result.Confirmed) { return }

    Write-Banner
    Invoke-ToolboxAction -Id $result.Selected[0].Id
    Wait-ForKey
}

# Type a query, pick a result, install it. The results list is a selector like
# any other, so filtering and paging come for free.
function Show-AppSearchMenu {
    $query = ''

    while ($true) {
        Write-Banner
        Write-SectionHeading 'Search apps'
        Write-Info 'One query across winget, Chocolatey and Scoop. Blank to go back.'
        if ($query) { Write-Info "Last search: $query" }

        Write-Line ''
        Write-Line '  Search for: ' -Color Yellow -NoNewline
        $query = [string](Read-Host)
        if ([string]::IsNullOrWhiteSpace($query)) { return }

        Write-Line ''
        Write-Step "Searching winget, Chocolatey and Scoop for '$query'"
        $search = Search-AllPackages -Query $query -Limit 25

        foreach ($problem in @($search.Errors)) { Write-Warn $problem }

        $results = @($search.Results)
        if ($results.Count -eq 0) {
            Write-Warn "Nothing matched '$query'."
            Wait-ForKey
            continue
        }

        $choice = Show-Selector -Items $results -Title "Results for '$query'" -SingleSelect `
            -Subtitle "$($results.Count) found - enter to install, esc to search again" `
            -Label {
                param($r)
                $version = $r.Version
                if (-not $version) { $version = '-' }
                '{0,-8}{1,-34}{2}' -f $r.Manager, $r.Id, $version
            } `
            -Sublabel { param($r) if ($r.Detail) { $r.Detail } else { $r.Name } }

        if (-not $choice.Confirmed) { continue }

        Write-Banner
        Install-SearchResult -Result $choice.Selected[0] | Out-Null
        Wait-ForKey
    }
}

function Show-PackageMenu {
    while ($true) {
        # Rebuilt each pass so an install that just finished shows as installed
        # without leaving and coming back.
        $entries = @(Get-PackageManagerReport)

        $result = Show-Selector -Items $entries -Title 'Package managers' -SingleSelect `
            -Subtitle 'Chocolatey, Scoop and winget - install one, or see what is already here' `
            -Label { param($e) $e.Manager.Name } `
            -Sublabel {
                param($e)
                if (-not $e.Installed) { return 'not installed' }
                if (-not $e.OnPath) { return 'installed - needs a new terminal' }
                return 'installed'
            }

        if (-not $result.Confirmed) { return }

        Write-Banner
        Invoke-PackageManagerInstall -Id $result.Selected[0].Manager.Id | Out-Null
        Wait-ForKey
    }
}

function Show-CustomizationMenu {
    while ($true) {
        # Rebuilt each pass so an install that just finished shows as installed
        # without leaving and coming back.
        $entries = @(Get-CustomizationReport)

        $result = Show-Selector -Items $entries -Title 'Customization' -SingleSelect `
            -Subtitle 'Shell replacements, each fetched from its own vendor and installed by its own setup' `
            -Label { param($e) $e.Tool.Name } `
            -Sublabel { param($e) if ($e.Installed) { 'installed' } else { $e.Tool.Summary } }

        if (-not $result.Confirmed) { return }

        Write-Banner
        Install-CustomizationTool -Id $result.Selected[0].Tool.Id | Out-Null
        Wait-ForKey
    }
}

# The desktop app's Cursors, wallpaper and Counter-Strike pages, as one screen.
# Until this existed the Personalise features were window-only.
# The Pointer Options tab as a screen: every setting with its current value,
# enter to change it. Toggles flip; ranges ask for a number.
# Drivers: what is there, what is broken, where the real ones come from.
# Deliberately no "install all drivers" - see the note at the top of 47-Drivers.
function Show-DriverMenu {
    while ($true) {
        $adapters = @()
        try { $adapters = @(Get-GraphicsAdapter) } catch { }

        $problems = @()
        try { $problems = @(Get-DriverProblemDevice) } catch { }

        $subtitle = 'No device is reporting a problem'
        if ($problems.Count -gt 0) { $subtitle = "$($problems.Count) device(s) reporting a problem" }

        $options = [System.Collections.Generic.List[object]]::new()
        $options.Add([pscustomobject]@{ Name = 'Overview'; Hint = 'Adapters, problem devices, driver sources'; Action = 'overview'; Data = $null })

        # One row per adapter that has a real vendor page behind it.
        foreach ($adapter in $adapters) {
            if (-not $adapter.Vendor -or $adapter.Vendor.Virtual -or -not $adapter.Vendor.Url) { continue }
            $options.Add([pscustomobject]@{
                Name = "Get $($adapter.Vendor.Name) drivers"
                Hint = $adapter.Vendor.Url
                Action = 'vendor'; Data = $adapter.Vendor
            })
        }

        $options.Add([pscustomobject]@{ Name = 'Back up all drivers'; Hint = 'Export every third-party package to a folder (admin)'; Action = 'backup'; Data = $null })
        $options.Add([pscustomobject]@{ Name = 'List driver packages'; Hint = 'Third-party packages Windows did not ship with (admin)'; Action = 'packages'; Data = $null })
        $options.Add([pscustomobject]@{ Name = 'Install Display Driver Uninstaller'; Hint = 'DDU - run it in Safe Mode, not from here'; Action = 'ddu'; Data = $null })
        $options.Add([pscustomobject]@{ Name = 'Open Device Manager'; Hint = 'devmgmt.msc'; Action = 'devmgmt'; Data = $null })

        $result = Show-Selector -Items @($options) -Title 'Drivers' -SingleSelect `
            -Subtitle $subtitle `
            -Label { param($o) $o.Name } `
            -Sublabel { param($o) $o.Hint }

        if (-not $result.Confirmed) { return }
        $choice = $result.Selected[0]

        Write-Banner
        switch ($choice.Action) {
            'overview' { Show-DriverOverview }
            'vendor' {
                Write-SectionHeading "$($choice.Data.Name) drivers"
                Write-Info 'Opening the vendor download page in your browser:'
                Write-Line "      $($choice.Data.Url)" -Color White
                try { Start-Process $choice.Data.Url | Out-Null }
                catch { Write-Err "Could not open the browser: $($_.Exception.Message)" }
            }
            'backup' {
                $default = Get-DefaultDriverBackupPath
                Write-SectionHeading 'Back up drivers'
                Write-Line "  Folder (blank for $default): " -Color Yellow -NoNewline
                $folder = [string](Read-Host)
                if (-not $folder) { $folder = $default }
                Backup-Driver -Path $folder | Out-Null
            }
            'packages' {
                Write-SectionHeading 'Third-party driver packages'
                $packages = @(Get-DriverPackage)
                if ($packages.Count -gt 0) {
                    Write-Info "$($packages.Count) package(s)"
                    foreach ($package in @($packages | Sort-Object ProviderName, ClassName)) {
                        Write-Line '  - ' -Color DarkGray -NoNewline
                        Write-Line ([string]$package.Driver).PadRight(16) -Color White -NoNewline
                        Write-Line ([string]$package.ProviderName).PadRight(28) -Color Gray -NoNewline
                        Write-Line ([string]$package.ClassName) -Color DarkGray
                    }
                }
            }
            'ddu' {
                # Through the app engine, so it gets the same winget handling
                # everything else does.
                $resolved = Resolve-App -Names @('Wagnardsoft.DisplayDriverUninstaller')
                if ($resolved.Matched.Count -gt 0) { Invoke-AppInstall -Apps $resolved.Matched }
                else {
                    Write-SectionHeading 'Display Driver Uninstaller'
                    Invoke-WingetInstall -Id 'Wagnardsoft.DisplayDriverUninstaller' -Name 'Display Driver Uninstaller'
                }
                Write-Line ''
                Write-Warn 'DDU is meant to be run from Safe Mode. Running it on a live desktop is how people end up with no display driver at all.'
            }
            'devmgmt' { Invoke-ToolboxAction -Id 'device-manager' }
        }
        Wait-ForKey
    }
}

function Show-MouseMenu {
    while ($true) {
        $entries = @(Get-MouseSnapshot)

        $options = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $entries) {
            $options.Add([pscustomobject]@{
                Kind = 'setting'
                Id = $entry.Setting.Id
                Name = $entry.Setting.Name
                Hint = (Format-MouseValue -Setting $entry.Setting -Value $entry.Value)
                Entry = $entry
            })
        }
        foreach ($preset in Get-MousePresets) {
            $options.Add([pscustomobject]@{
                Kind = 'preset'; Id = $preset.Id; Name = "Preset: $($preset.Name)"
                Hint = $preset.Summary; Entry = $null
            })
        }

        $result = Show-Selector -Items @($options) -Title 'Mouse' -SingleSelect `
            -Subtitle 'Pointer Options, applied live - no sign-out, no administrator' `
            -Label { param($o) $o.Name } `
            -Sublabel { param($o) $o.Hint }

        if (-not $result.Confirmed) { return }
        $choice = $result.Selected[0]

        Write-Banner

        if ($choice.Kind -eq 'preset') {
            Invoke-MousePreset -Id $choice.Id | Out-Null
            Wait-ForKey
            continue
        }

        $setting = $choice.Entry.Setting

        if ($setting.Kind -eq 'toggle') {
            # A toggle has one useful action, so do it rather than asking.
            $next = 0
            if (-not $choice.Entry.Value) { $next = 1 }
            Set-MouseSetting -Id $setting.Id -Value $next | Out-Null
        }
        else {
            Write-SectionHeading $setting.Name
            Write-Info $setting.Description
            Write-Info "Now: $(Format-MouseValue -Setting $setting -Value $choice.Entry.Value)"
            Write-Line ''
            Write-Line "  New value ($($setting.Minimum)-$($setting.Maximum), blank to cancel): " -Color Yellow -NoNewline

            $typed = [string](Read-Host)
            if ($typed) {
                $number = 0
                if ([int]::TryParse($typed.Trim(), [ref]$number)) {
                    Set-MouseSetting -Id $setting.Id -Value $number | Out-Null
                }
                else { Write-Err "'$typed' is not a number." }
            }
        }

        Wait-ForKey
    }
}

function Show-PersonalizeMenu {
    while ($true) {
        $options = [System.Collections.Generic.List[object]]::new()
        foreach ($preset in Get-CursorPresets) {
            $options.Add([pscustomobject]@{ Name = "Cursors: $($preset.Name)"; Hint = $preset.Credit; Action = 'preset'; Id = $preset.Id })
        }
        $options.Add([pscustomobject]@{ Name = 'Cursors: from a folder of .cur/.ani'; Hint = 'Matched to roles by file name'; Action = 'folder'; Id = '' })
        $options.Add([pscustomobject]@{ Name = 'Cursors: restore Windows defaults';   Hint = '';                               Action = 'restore'; Id = '' })
        $options.Add([pscustomobject]@{ Name = 'Wallpaper';                           Hint = 'Any image, with a fit style';    Action = 'wallpaper'; Id = '' })

        # Counter-Strike has its own two screens - see Show-CsMenu.
        $result = Show-Selector -Items @($options) -Title 'Personalise' -SingleSelect `
            -Subtitle 'Cursor packs fetched from the desktop app, and wallpaper' `
            -Label { param($o) $o.Name } `
            -Sublabel { param($o) $o.Hint }

        if (-not $result.Confirmed) { return }
        $choice = $result.Selected[0]

        Write-Banner
        switch ($choice.Action) {
            'preset'  { Install-CursorPreset -Id $choice.Id | Out-Null }
            'restore' { Restore-DefaultCursor }
            'folder' {
                Write-Line '  Folder of .cur / .ani files: ' -Color Yellow -NoNewline
                $folder = [string](Read-Host)
                if ($folder) {
                    try { Install-CursorScheme -Path $folder -SchemeName (Split-Path -Leaf $folder) }
                    catch { Write-Err $_.Exception.Message }
                }
            }
            'wallpaper' {
                Write-Line '  Image path: ' -Color Yellow -NoNewline
                $image = [string](Read-Host)
                if ($image) {
                    Write-Line '  Style [Fill/Fit/Stretch/Tile/Center/Span] (Fill): ' -Color Yellow -NoNewline
                    $style = [string](Read-Host)
                    if (-not $style) { $style = 'Fill' }
                    try { Set-Wallpaper -Path $image -Style $style }
                    catch { Write-Err $_.Exception.Message }
                }
            }
        }
        Wait-ForKey
    }
}

# One screen per game, the way the desktop app has one page per game. They
# differ in more than the title: the launch options are different strings, the
# cfg folders are different paths, and yabosen.cfg is a CS2 config.
function Show-CsMenu {
    param([ValidateSet('CS2', 'CSGO')][string]$Game = 'CS2')

    $label = 'CS2'
    if ($Game -eq 'CSGO') { $label = 'CS:GO' }

    while ($true) {
        $folders = @(Find-CsConfigFolder -Game $Game)

        $subtitle = "No cfg folder found - looked for $(Get-CsConfigRelativePath -Game $Game)"
        if ($folders.Count -eq 1) { $subtitle = $folders[0] }
        elseif ($folders.Count -gt 1) { $subtitle = "$($folders.Count) cfg folders found" }

        $options = [System.Collections.Generic.List[object]]::new()

        # yabosen.cfg is a CS2 config, so it is only offered there - which is
        # also the only place the desktop app offers it.
        if ($Game -eq 'CS2') {
            $options.Add([pscustomobject]@{ Name = 'Install yabosen.cfg'; Hint = 'Downloaded from Yabosen/YabosenCFG'; Action = 'cfg-default' })
        }
        $options.Add([pscustomobject]@{ Name = 'Install a .cfg of yours'; Hint = 'Copied into every cfg folder found'; Action = 'cfg-file' })
        $options.Add([pscustomobject]@{ Name = 'Launch options';          Hint = (Get-CsLaunchOption -Game $Game);   Action = 'launch' })
        $options.Add([pscustomobject]@{ Name = 'Show the cfg folders';    Hint = '';                                 Action = 'folders' })

        $result = Show-Selector -Items @($options) -Title $label -SingleSelect `
            -Subtitle $subtitle `
            -Label { param($o) $o.Name } `
            -Sublabel { param($o) $o.Hint }

        if (-not $result.Confirmed) { return }

        Write-Banner
        switch ($result.Selected[0].Action) {
            'cfg-default' { Install-CsConfig -Game $Game }
            'cfg-file' {
                Write-Line '  Path to the .cfg: ' -Color Yellow -NoNewline
                $cfg = [string](Read-Host)
                if ($cfg) { Install-CsConfig -LocalPath $cfg -Game $Game }
            }
            'launch' { Show-CsLaunchOption -Game $Game }
            'folders' {
                Write-SectionHeading "$label cfg folders"
                if ($folders.Count -eq 0) {
                    Write-Warn "None found. Looked for $(Get-CsConfigRelativePath -Game $Game) on every ready drive."
                }
                else {
                    foreach ($folder in $folders) { Write-Ok $folder }
                }
            }
        }
        Wait-ForKey
    }
}

# Prints the string and puts it on the clipboard when there is one - a console
# over SSH has none, and that is not a failure.
function Show-CsLaunchOption {
    param([ValidateSet('CS2', 'CSGO')][string]$Game = 'CS2')

    $options = Get-CsLaunchOption -Game $Game
    Write-Line ''
    Write-Info "$Game launch options - paste into Steam > Properties > Launch Options:"
    Write-Line "      $options" -Color White

    try {
        Set-Clipboard -Value $options -ErrorAction Stop
        Write-Ok 'Copied to the clipboard.'
    }
    catch { Write-Info 'No clipboard here; copy it from above.' }
}

function Show-ProfileMenu {
    $options = @(
        [pscustomobject]@{ Name = 'Run a profile';   Action = 'run' }
        [pscustomobject]@{ Name = 'Build and save a profile'; Action = 'save' }
    )

    $choice = Show-Selector -Items $options -Title 'Profiles' -SingleSelect `
        -Subtitle 'Profiles are interchangeable with the Moscovium desktop app' `
        -Label { param($o) $o.Name }

    if (-not $choice.Confirmed) { return }

    Write-Banner

    if ($choice.Selected[0].Action -eq 'run') {
        Write-Line '  Path to profile .json: ' -Color Yellow -NoNewline
        $path = Read-Host
        if ($path) {
            try { Invoke-SetupProfile -Path $path.Trim('"') }
            catch { Write-Err $_.Exception.Message }
        }
        Wait-ForKey
        return
    }

    $tweakPick = Show-Selector -Items $Ctx.Tweaks -Title 'Profile: tweaks' `
        -Subtitle 'Choose the tweaks this profile should apply' `
        -Label { param($t) $t.name } -Sublabel { param($t) $t.category }

    $appPick = Show-Selector -Items $Ctx.Apps -Title 'Profile: apps' `
        -Subtitle 'Choose the apps this profile should install' `
        -Label { param($a) $a.name } -Sublabel { param($a) $a.category }

    $extras = Show-Selector -Items @(
        [pscustomobject]@{ Name = 'Install Visual C++ runtimes'; Key = 'InstallVCRuntimes' }
        [pscustomobject]@{ Name = 'Upgrade all winget apps';     Key = 'UpgradeAllApps' }
        [pscustomobject]@{ Name = 'Open WinUtil with preset';    Key = 'RunChrisTitus' }
        [pscustomobject]@{ Name = 'Run Win11Debloat preset';     Key = 'RunRaphi' }
        [pscustomobject]@{ Name = 'Run Windows Update';          Key = 'RunWindowsUpdate' }
    ) -Title 'Profile: extras' -Subtitle 'Optional steps, run after tweaks and apps' -Label { param($e) $e.Name }

    $chosenKeys = @($extras.Selected | ForEach-Object { $_.Key })

    $setupProfile = New-SetupProfile `
        -Tweaks @($tweakPick.Selected | ForEach-Object { $_.name }) `
        -Apps   @($appPick.Selected   | ForEach-Object { $_.id }) `
        -InstallVCRuntimes:($chosenKeys -contains 'InstallVCRuntimes') `
        -UpgradeAllApps:($chosenKeys    -contains 'UpgradeAllApps') `
        -RunChrisTitus:($chosenKeys     -contains 'RunChrisTitus') `
        -RunRaphi:($chosenKeys          -contains 'RunRaphi') `
        -RunWindowsUpdate:($chosenKeys  -contains 'RunWindowsUpdate')

    Write-Banner
    Write-Line '  Save profile as (path): ' -Color Yellow -NoNewline
    $path = Read-Host

    if ($path) {
        try { Save-SetupProfile -SetupProfile $setupProfile -Path $path.Trim('"') }
        catch { Write-Err $_.Exception.Message }
    }

    Wait-ForKey
}

function Wait-ForKey {
    Write-Line ''
    Write-Line '  Press any key to return to the menu...' -Color DarkGray -NoNewline

    if (Test-Interactive) { [void](Read-MenuKey) } else { [void](Read-Host) }
    Clear-Host
}

function Show-MainMenu {
    $options = @(
        # First, because it is the thing most people opened this for.
        [pscustomobject]@{ Name = 'One click'; Hint = 'The whole debloat pass - 6 steps, one prompt';         Action = 'oneclick' }
        [pscustomobject]@{ Name = 'Tweaks';   Hint = "$($Ctx.Tweaks.Count) registry tweaks, apply or revert"; Action = 'tweaks' }
        [pscustomobject]@{ Name = 'Apps';     Hint = "$($Ctx.Apps.Count) curated packages";                    Action = 'apps' }
        [pscustomobject]@{ Name = 'Toolbox';  Hint = 'Debloat scripts, network, boot, control panels';         Action = 'toolbox' }
        [pscustomobject]@{ Name = 'Profiles'; Hint = 'Save or run a setup checklist';                          Action = 'profiles' }
        [pscustomobject]@{ Name = 'Search apps'; Hint = 'Find anything in winget, Chocolatey or Scoop';         Action = 'findapp' }
        [pscustomobject]@{ Name = 'Packages'; Hint = 'Install Chocolatey or Scoop';                             Action = 'packages' }
        [pscustomobject]@{ Name = 'Customize'; Hint = 'Open-Shell, Nilesoft Shell, StartAllBack, ExplorerPatcher';  Action = 'customize' }
        [pscustomobject]@{ Name = 'Personalise'; Hint = 'Cursor packs and wallpaper';                              Action = 'personalise' }
        [pscustomobject]@{ Name = 'Mouse';    Hint = 'Pointer speed, acceleration, trails, visibility';        Action = 'mouse' }
        [pscustomobject]@{ Name = 'Drivers';  Hint = 'Adapters, problem devices, backup, vendor downloads';   Action = 'drivers' }
        [pscustomobject]@{ Name = 'Counter-Strike 2'; Hint = 'Configs and launch options';                         Action = 'cs2' }
        [pscustomobject]@{ Name = 'CS:GO';        Hint = 'Configs and launch options for the legacy build';        Action = 'csgo' }
        [pscustomobject]@{ Name = 'Tasks';    Hint = 'Live CPU, memory, disk, network and processes';          Action = 'tasks' }
        [pscustomobject]@{ Name = 'Status';   Hint = 'What is currently applied on this machine';              Action = 'status' }
        [pscustomobject]@{ Name = 'GUI';      Hint = 'Open the same thing as a window';                       Action = 'gui' }
        [pscustomobject]@{ Name = 'Quit';     Hint = '';                                                       Action = 'quit' }
    )

    while ($true) {
        $admin = if ($Ctx.IsAdmin) { 'elevated' } else { 'not elevated - HKLM tweaks will be skipped' }
        $subtitle = "Moscovium CLI v$($Ctx.Version)   |   $admin"
        if ($Ctx.DryRun) { $subtitle += '   |   DRY RUN' }

        $result = Show-Selector -Items $options -Title 'Moscovium' -SingleSelect -Art `
            -Subtitle $subtitle `
            -Label { param($o) $o.Name } `
            -Sublabel { param($o) $o.Hint }

        if (-not $result.Confirmed) { return }

        switch ($result.Selected[0].Action) {
            'oneclick' { Write-Banner; Invoke-ToolboxAction -Id 'oneclick'; Wait-ForKey }
            'tweaks'   { Show-TweakMenu }
            'apps'     { Show-AppMenu }
            'toolbox'  { Show-ToolboxMenu }
            'profiles' { Show-ProfileMenu }
            'findapp'  { Show-AppSearchMenu }
            'packages' { Show-PackageMenu }
            'customize' { Show-CustomizationMenu }
            'personalise' { Show-PersonalizeMenu }
            'mouse'    { Show-MouseMenu }
            'drivers'  { Show-DriverMenu }
            'cs2'      { Show-CsMenu -Game CS2 }
            'csgo'     { Show-CsMenu -Game CSGO }
            'tasks'    { Show-TaskManager }
            'status'   { Write-Banner; Show-TweakStatus; Wait-ForKey }
            'gui'      { Clear-Host; Show-Gui | Out-Null; Clear-Host }
            'quit'     { return }
        }
    }
}
