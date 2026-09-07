# =============================================================================
# GUI mode.
#
# A WPF window that is a second front-end on the same engine, not a second
# implementation. Every button ends up in Invoke-Tweaks, Invoke-AppInstall,
# Invoke-ToolboxAction or Invoke-SetupProfile - the identical functions the CLI
# calls - with $Ctx.Sink, $Ctx.ProgressSink and $Ctx.ConfirmSink redirecting
# their output into the log pane, progress bar and dialogs.
#
# WPF ships with .NET Framework, so this still needs nothing installed and still
# works from `irm ... | iex`.
#
# -----------------------------------------------------------------------------
# Why there is not a single .GetNewClosure() in this file
# -----------------------------------------------------------------------------
# Event handlers fire after the function that registered them has returned, so
# the obvious move is to capture state with .GetNewClosure(). That breaks here,
# and only in the shipped bundle:
#
#   .GetNewClosure() binds the script block to a new dynamic module. Command
#   lookup from inside that module falls back to the *global* scope - it does not
#   see the enclosing one. The bundle runs everything inside `& { ... }`, so
#   every engine function lives in that wrapper scope, and a closure cannot call
#   any of them. Running from src/ hides this, because there the functions are at
#   script scope, which a closure can reach.
#
#   A plain script block is the mirror image: it resolves functions and enclosing
#   variables fine, but not the locals of a function that has already returned.
#
# So: plain script blocks everywhere, and no handler depends on a dead function's
# locals. Per-window state hangs off $Ctx.Gui, which lives in the wrapper scope
# and stays reachable, and per-row state is read back from $sender.
#
# The XAML is ASCII only, like the rest of src/, and lives in data/gui.xaml.
# =============================================================================

# Populated by build.ps1 from data/gui.xaml. Empty in the source tree, where
# Get-GuiXaml falls back to reading that file - the same arrangement as the
# catalogs, and for the same reason: a here-string cannot survive being indented
# into the bundle's script block.
$EmbeddedGuiXaml = ''

function Get-GuiXaml {
    if (-not [string]::IsNullOrWhiteSpace($EmbeddedGuiXaml)) { return $EmbeddedGuiXaml }

    $roots = @()
    if ($PSScriptRoot) { $roots += (Join-Path $PSScriptRoot '..\data') }
    if ($PSCommandPath) { $roots += (Join-Path (Split-Path -Parent $PSCommandPath) 'data') }
    $roots += (Join-Path (Get-Location).Path 'data')

    foreach ($root in $roots) {
        $candidate = Join-Path $root 'gui.xaml'
        if (Test-Path -LiteralPath $candidate) { return (Get-Content -LiteralPath $candidate -Raw -Encoding UTF8) }
    }

    throw 'The GUI layout is neither embedded in this build nor present at data/gui.xaml.'
}

# -----------------------------------------------------------------------------
# Host requirements
# -----------------------------------------------------------------------------

function Test-StaApartment {
    try { return ([Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA) }
    catch { return $false }
}

function Import-WpfAssembly {
    foreach ($name in @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml', 'System.Windows.Forms')) {
        Add-Type -AssemblyName $name -ErrorAction Stop
    }
}

# The GUI has two hard requirements the current host may not meet, and both are
# fixed the same way - by relaunching:
#
#   STA    WPF cannot run on an MTA thread. powershell.exe is STA; pwsh is not.
#   Admin  Nearly every tweak writes to HKLM. A non-elevated window would show a
#          catalog it mostly cannot apply, so the window is always elevated and
#          there is no in-app "restart as admin" to explain.
#
# Returns $true when a replacement was started and this run should stand down.
function Invoke-GuiRelaunch {
    param([hashtable]$BoundParameters = @{})

    $needsSta = -not (Test-StaApartment)

    # A dry run writes nothing, so demanding a UAC prompt to preview a plan would
    # be theatre. The header badge makes it obvious which mode the window is in.
    $needsAdmin = (-not $Ctx.IsAdmin) -and (-not $Ctx.DryRun)

    if (-not $needsSta -and -not $needsAdmin) { return $false }

    $reasons = @()
    if ($needsAdmin) { $reasons += 'administrator rights' }
    if ($needsSta)   { $reasons += 'an STA thread' }
    Write-Step ("Reopening the GUI with " + ($reasons -join ' and '))

    $command = Get-RelaunchCommand -BoundParameters $BoundParameters
    # Always the 5.1 host: it is STA by default and always present.
    $host51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    $start = @{
        FilePath     = $host51
        ArgumentList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-Command', $command)
        ErrorAction  = 'Stop'
    }
    # UAC is the prompt; asking first would just be a dialog about a dialog.
    if ($needsAdmin) { $start.Verb = 'RunAs' }

    Write-Log "GUI relaunch: $command"

    try {
        Start-Process @start | Out-Null
        return $true
    }
    catch {
        # Almost always the user dismissing UAC.
        Write-Err "The GUI needs administrator rights and was not granted them: $($_.Exception.Message)"
        return $true
    }
}

# -----------------------------------------------------------------------------
# Small WPF helpers
# -----------------------------------------------------------------------------

# Console colours mapped onto the window's palette, so log output reads the same
# as it does in the terminal.
function ConvertTo-Brush {
    param($Color)

    # The console's sixteen colours mapped onto the window's purple palette, so
    # log output reads as part of the same design rather than a terminal pasted
    # into it. Cyan is the CLI's accent, so it lands on the purple accent here.
    $hex = switch ([string]$Color) {
        'Green'      { '#FF7EE0A6' }
        'DarkGreen'  { '#FF56A87A' }
        'Yellow'     { '#FFFFCB7A' }
        'DarkYellow' { '#FFD1A055' }
        'Red'        { '#FFFF7B94' }
        'DarkRed'    { '#FFC2536B' }
        'Cyan'       { '#FFB388FF' }
        'DarkCyan'   { '#FF7D5CC0' }
        'Magenta'    { '#FFD8B4FE' }
        'DarkMagenta'{ '#FF9268D8' }
        'White'      { '#FFF3EFFC' }
        'Gray'       { '#FFC5BDDC' }
        'DarkGray'   { '#FF8B81A8' }
        default      { '#FFEDE8F7' }
    }

    New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
}

# Lets the window repaint and handle input during a long synchronous run. The
# engine functions are ordinary blocking PowerShell, so without this the window
# would freeze for the length of an install.
function Invoke-UiEvents {
    $frame = New-Object Windows.Threading.DispatcherFrame
    $callback = [Windows.Threading.DispatcherOperationCallback] {
        param($state)
        $state.Continue = $false
        return $null
    }
    [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::Background, $callback, $frame) | Out-Null
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

function New-HexBrush {
    param([Parameter(Mandatory)][string]$Hex)
    New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex))
}

# Row background, decided from ticked + hovered together so neither clobbers the
# other. Reached from $sender rather than a captured $border, because handlers
# outlive the function that built the row: CheckBox -> Grid -> Border.
function Set-GuiRowVisual {
    param([Parameter(Mandatory)]$Border, [switch]$Hover)

    $box = $Border.Child.Children[0]

    if ($box.IsChecked -eq $true) { $Border.Background = New-HexBrush '#FF1D1233' }
    elseif ($Hover)               { $Border.Background = New-HexBrush '#FF120C1E' }
    else                          { $Border.Background = [Windows.Media.Brushes]::Transparent }
}

# A tinted pill for a row's status, instead of loose coloured text.
function New-GuiPill {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Foreground,
        [Parameter(Mandatory)][string]$Background
    )

    $pill = New-Object Windows.Controls.Border
    $pill.CornerRadius = New-Object Windows.CornerRadius 9
    $pill.Padding = New-Object Windows.Thickness 9, 2, 9, 2
    $pill.Margin = New-Object Windows.Thickness 10, 0, 2, 0
    $pill.VerticalAlignment = 'Center'
    $pill.Background = New-HexBrush $Background

    $label = New-Object Windows.Controls.TextBlock
    $label.Text = $Text
    $label.FontSize = 10.5
    $label.Foreground = New-HexBrush $Foreground
    $pill.Child = $label

    return $pill
}

# A category divider inside a list, so 40 tweaks read as five groups.
function New-GuiGroupHeader {
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][int]$Count, [switch]$First)

    $panel = New-Object Windows.Controls.DockPanel
    $panel.Margin = New-Object Windows.Thickness 4, $(if ($First) { 2 } else { 14 }), 4, 5
    $panel.LastChildFill = $true

    # Not $count: parameter variables keep their declared type, so assigning a
    # TextBlock to it fails the [int] conversion.
    $badge = New-Object Windows.Controls.TextBlock
    $badge.Text = [string]$Count
    $badge.FontSize = 11
    $badge.Foreground = New-HexBrush '#FF5F5680'
    [Windows.Controls.DockPanel]::SetDock($badge, 'Right')
    $panel.Children.Add($badge) | Out-Null

    $label = New-Object Windows.Controls.TextBlock
    $label.Text = $Title.ToUpperInvariant()
    $label.FontSize = 10.5
    $label.FontWeight = 'SemiBold'
    $label.Foreground = New-HexBrush '#FF8B81A8'
    [Windows.Controls.DockPanel]::SetDock($label, 'Left')
    $panel.Children.Add($label) | Out-Null

    $rule = New-Object Windows.Controls.Border
    $rule.Height = 1
    $rule.Background = New-HexBrush '#FF241A3A'
    $rule.VerticalAlignment = 'Center'
    $rule.Margin = New-Object Windows.Thickness 10, 1, 10, 0
    $panel.Children.Add($rule) | Out-Null

    return $panel
}

# Keeps the action buttons honest about how much is selected, and disabled when
# nothing is.
function Update-GuiActionState {
    if (-not $Ctx.Gui) { return }

    $ui = $Ctx.Gui.Ui
    $tweaks = @(Get-CheckedItem -Rows $Ctx.Gui.Rows.Tweaks).Count
    $apps = @(Get-CheckedItem -Rows $Ctx.Gui.Rows.Apps).Count

    $ui.BtnApply.Content  = if ($tweaks) { "Apply $tweaks" } else { 'Apply selected' }
    $ui.BtnRevert.Content = if ($tweaks) { "Revert $tweaks" } else { 'Revert selected' }
    $ui.BtnApply.IsEnabled = ($tweaks -gt 0)
    $ui.BtnRevert.IsEnabled = ($tweaks -gt 0)

    $ui.BtnInstall.Content = if ($apps) { "Install $apps" } else { 'Install selected' }
    $ui.BtnInstall.IsEnabled = ($apps -gt 0)

    $store = @(Get-CheckedItem -Rows $Ctx.Gui.Rows.Store).Count
    $ui.BtnStoreInstall.Content = if ($store) { "Install $store" } else { 'Install selected' }
    $ui.BtnStoreInstall.IsEnabled = ($store -gt 0)
}

# One row: a checkbox, a primary label, a secondary line, and a status chip.
# The catalog item rides along in .Tag so selection can be read back directly.
function New-GuiRow {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$Primary,
        [AllowEmptyString()][string]$Secondary = '',
        [AllowEmptyString()][string]$Status = '',
        [string]$StatusBrush = '#FF8B81A8',
        [string]$StatusFill = '#FF150F22',
        [switch]$NoCheckBox
    )

    $border = New-Object Windows.Controls.Border
    $border.Padding = New-Object Windows.Thickness 8, 6, 8, 6
    $border.CornerRadius = New-Object Windows.CornerRadius 4
    $border.Margin = New-Object Windows.Thickness 0, 0, 0, 2

    # checkbox | text (fills) | status chip
    $grid = New-Object Windows.Controls.Grid
    foreach ($unit in @([Windows.GridUnitType]::Auto, [Windows.GridUnitType]::Star, [Windows.GridUnitType]::Auto)) {
        $column = New-Object Windows.Controls.ColumnDefinition
        $column.Width = New-Object Windows.GridLength 1, $unit
        $grid.ColumnDefinitions.Add($column)
    }

    $check = New-Object Windows.Controls.CheckBox
    $check.VerticalAlignment = 'Center'
    $check.Margin = New-Object Windows.Thickness 0, 0, 10, 0
    $check.Foreground = ConvertTo-Brush 'Gray'
    $check.Tag = $Item
    if ($NoCheckBox) { $check.Visibility = 'Collapsed' }

    # A tick is easy to lose in a list of 127, so tint the whole row - and keep
    # the action buttons' counts in step.
    $check.Add_Checked({
        param($sender, $e)
        Set-GuiRowVisual -Border $sender.Parent.Parent
        Update-GuiActionState
    })
    $check.Add_Unchecked({
        param($sender, $e)
        Set-GuiRowVisual -Border $sender.Parent.Parent
        Update-GuiActionState
    })

    [Windows.Controls.Grid]::SetColumn($check, 0)
    $grid.Children.Add($check) | Out-Null

    $stack = New-Object Windows.Controls.StackPanel
    [Windows.Controls.Grid]::SetColumn($stack, 1)

    $title = New-Object Windows.Controls.TextBlock
    $title.Text = $Primary
    $title.Foreground = New-HexBrush '#FFEDE8F7'
    $title.FontSize = 13
    $stack.Children.Add($title) | Out-Null

    if ($Secondary) {
        $sub = New-Object Windows.Controls.TextBlock
        $sub.Text = $Secondary
        $sub.Foreground = New-HexBrush '#FF8B81A8'
        $sub.FontSize = 11
        $sub.TextWrapping = 'Wrap'
        $sub.Margin = New-Object Windows.Thickness 0, 1, 0, 0
        $stack.Children.Add($sub) | Out-Null
    }

    $grid.Children.Add($stack) | Out-Null

    if ($Status) {
        $pill = New-GuiPill -Text $Status -Foreground $StatusBrush -Background $StatusFill
        [Windows.Controls.Grid]::SetColumn($pill, 2)
        $grid.Children.Add($pill) | Out-Null
    }

    $border.Child = $grid

    # Clicking anywhere on the row toggles it, not just the 18px checkbox.
    $border.Add_MouseLeftButtonUp({
        param($sender, $e)
        $box = $sender.Child.Children[0]
        if ($box.Visibility -eq 'Visible') { $box.IsChecked = -not $box.IsChecked }
    })

    $border.Add_MouseEnter({ param($sender, $e) Set-GuiRowVisual -Border $sender -Hover })
    $border.Add_MouseLeave({ param($sender, $e) Set-GuiRowVisual -Border $sender })

    [pscustomobject]@{ Element = $border; CheckBox = $check; Item = $Item }
}

function Get-CheckedItem {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
    @($Rows | Where-Object { $_.CheckBox.IsChecked -eq $true } | ForEach-Object { $_.Item })
}

# -----------------------------------------------------------------------------
# Row population
#
# Functions rather than script blocks, so handlers can call them by name. They
# read the window out of $Ctx.Gui, which outlives New-GuiWindow.
# -----------------------------------------------------------------------------

function Update-GuiTweakRow {
    if (-not $Ctx.Gui) { return }
    $ui = $Ctx.Gui.Ui

    $ui.TweakRows.Children.Clear()
    $built = [System.Collections.Generic.List[object]]::new()

    $search = [string]$ui.TweakSearch.Text
    $category = [string]$ui.TweakCategory.SelectedItem
    $first = $true

    # Walk categories rather than the flat list, so the rows arrive grouped.
    foreach ($group in $Ctx.TweakCategories) {
        if ($category -and $category -ne 'All categories' -and $group -ne $category) { continue }

        $matching = @($Ctx.Tweaks | Where-Object {
            $_.category -eq $group -and (
                -not $search -or
                (Test-NameMatch -Value $_.name -Pattern $search) -or
                (Test-NameMatch -Value $_.description -Pattern $search) -or
                (Test-NameMatch -Value $_.category -Pattern $search))
        })

        if ($matching.Count -eq 0) { continue }

        $ui.TweakRows.Children.Add((New-GuiGroupHeader -Title $group -Count $matching.Count -First:$first)) | Out-Null
        $first = $false

        foreach ($tweak in $matching) {
            $status = Get-TweakStatus -Tweak $tweak
            $label, $ink, $fill = switch ($status) {
                'Applied' { 'applied', '#FF7EE0A6', '#FF102A1E' }
                'Partial' { 'partial', '#FFFFCB7A', '#FF2E2410' }
                'Action'  { 'action',  '#FFB388FF', '#FF1E1436' }
                default   { '',        '#FF8B81A8', '#FF150F22' }
            }

            $row = New-GuiRow -Item $tweak -Primary $tweak.name -Secondary $tweak.description `
                -Status $label -StatusBrush $ink -StatusFill $fill
            $ui.TweakRows.Children.Add($row.Element) | Out-Null
            $built.Add($row)
        }
    }

    $Ctx.Gui.Rows.Tweaks = @($built)
    Update-GuiActionState
}

function Update-GuiAppRow {
    if (-not $Ctx.Gui) { return }
    $ui = $Ctx.Gui.Ui

    $ui.AppRows.Children.Clear()
    $built = [System.Collections.Generic.List[object]]::new()

    $search = [string]$ui.AppSearch.Text
    $category = [string]$ui.AppCategory.SelectedItem
    $first = $true

    foreach ($group in $Ctx.AppCategories) {
        if ($category -and $category -ne 'All categories' -and $group -ne $category) { continue }

        $matching = @($Ctx.Apps | Where-Object {
            $_.category -eq $group -and (
                -not $search -or
                (Test-NameMatch -Value $_.name -Pattern $search) -or
                (Test-NameMatch -Value $_.id -Pattern $search) -or
                (Test-NameMatch -Value ([string]$_.description) -Pattern $search))
        })

        if ($matching.Count -eq 0) { continue }

        $ui.AppRows.Children.Add((New-GuiGroupHeader -Title $group -Count $matching.Count -First:$first)) | Out-Null
        $first = $false

        foreach ($app in $matching) {
            # Anything but winget is worth flagging: it means a vendor download
            # or, for a script, remote code.
            $how, $ink, $fill = if ($app.scriptUrl)      { 'script',   '#FFFFCB7A', '#FF2E2410' }
                                elseif ($app.zipUrl)     { 'archive',  '#FF8B81A8', '#FF150F22' }
                                elseif ($app.downloadUrl){ 'download', '#FF8B81A8', '#FF150F22' }
                                else                     { 'winget',   '#FF7D5CC0', '#FF150F22' }

            $row = New-GuiRow -Item $app -Primary $app.name -Secondary ([string]$app.description) `
                -Status $how -StatusBrush $ink -StatusFill $fill
            $ui.AppRows.Children.Add($row.Element) | Out-Null
            $built.Add($row)
        }
    }

    $Ctx.Gui.Rows.Apps = @($built)
    Update-GuiActionState
}

function Update-GuiToolboxRow {
    if (-not $Ctx.Gui) { return }
    $ui = $Ctx.Gui.Ui

    $ui.ToolboxRows.Children.Clear()
    $built = [System.Collections.Generic.List[object]]::new()

    # Group by what the action actually does, so "runs a third-party script" is
    # never mistaken for "opens a control panel".
    $groups = @(
        @{ Title = 'Third-party debloat scripts'; Ids = @('winutil', 'winutil-preset', 'raphi', 'raphi-auto') }
        @{ Title = 'System tuning';               Ids = @('updates-security', 'network-better', 'network-default', 'dynamictick-off', 'dynamictick-on', 'priority-22', 'priority-default') }
        @{ Title = 'Classic control panels';      Ids = @('control-panel', 'services', 'mouse', 'keyboard', 'sound') }
    )

    # The one-click box is not here: it has the landing page to itself.
    $all = @(Get-ToolboxListActions)

    # Anything a future catalog adds that the grouping above does not know about
    # still gets shown, under Other.
    $known = @($groups | ForEach-Object { $_.Ids })
    $rest = @($all | Where-Object { $known -notcontains $_.Id })
    if ($rest.Count -gt 0) { $groups += @{ Title = 'Other'; Ids = @($rest | ForEach-Object { $_.Id }) } }

    $first = $true

    foreach ($group in $groups) {
        $members = @($all | Where-Object { $group.Ids -contains $_.Id })
        if ($members.Count -eq 0) { continue }

        $ui.ToolboxRows.Children.Add((New-GuiGroupHeader -Title $group.Title -Count $members.Count -First:$first)) | Out-Null
        $first = $false

        foreach ($action in $members) {
            $row = New-GuiRow -Item $action -Primary $action.Name -Secondary $action.Description -NoCheckBox

            # One click runs it; a checkbox would imply batching, which these are not.
            $run = New-Object Windows.Controls.Button
            $run.Content = 'Run'
            $run.Padding = New-Object Windows.Thickness 12, 4, 12, 4
            $run.Margin = New-Object Windows.Thickness 8, 0, 0, 0
            $run.VerticalAlignment = 'Center'
            $run.Tag = $action.Id
            [Windows.Controls.Grid]::SetColumn($run, 2)

            $run.Add_Click({
                param($sender, $e)
                $id = [string]$sender.Tag
                Invoke-GuiWork -Label "toolbox: $id" -Work { Invoke-ToolboxAction -Id $id }
            })

            $row.Element.Child.Children.Add($run) | Out-Null

            $ui.ToolboxRows.Children.Add($row.Element) | Out-Null
            $built.Add($row)
        }
    }

    $Ctx.Gui.Rows.Toolbox = @($built)
}

# The landing page's step list. Built from the real presets rather than written
# into the XAML, so the counts cannot drift from what the box actually runs.
function Update-GuiOneClickSteps {
    if (-not $Ctx.Gui) { return }
    $ui = $Ctx.Gui.Ui

    $ui.OneClickSteps.Children.Clear()

    # A preset that failed to load is worth saying out loud, not worth crashing
    # the page over - the other eight nav pages still work.
    $steps = $null
    try { $steps = @(Get-OneClickSteps) }
    catch {
        $ui.OneClickBlurb.Text = "The presets could not be read: $($_.Exception.Message)"
        $ui.BtnOneClick.IsEnabled = $false
        return
    }

    $number = 0
    foreach ($step in $steps) {
        $number++

        $line = New-Object Windows.Controls.Grid
        $line.Margin = New-Object Windows.Thickness 0, 0, 0, 7
        foreach ($unit in @([Windows.GridUnitType]::Auto, [Windows.GridUnitType]::Star)) {
            $column = New-Object Windows.Controls.ColumnDefinition
            $column.Width = New-Object Windows.GridLength 1, $unit
            $line.ColumnDefinitions.Add($column)
        }

        $chip = New-Object Windows.Controls.Border
        $chip.Width = 24
        $chip.Height = 24
        $chip.CornerRadius = New-Object Windows.CornerRadius 12
        $chip.Background = New-HexBrush '#FF1C1430'
        $chip.BorderBrush = New-HexBrush '#FF261B3D'
        $chip.BorderThickness = New-Object Windows.Thickness 1
        $chip.VerticalAlignment = 'Top'

        $index = New-Object Windows.Controls.TextBlock
        $index.Text = [string]$number
        $index.FontSize = 11.5
        $index.Foreground = New-HexBrush '#FFB388FF'
        $index.HorizontalAlignment = 'Center'
        $index.VerticalAlignment = 'Center'
        $chip.Child = $index

        [Windows.Controls.Grid]::SetColumn($chip, 0)
        $line.Children.Add($chip) | Out-Null

        $text = New-Object Windows.Controls.StackPanel
        $text.Margin = New-Object Windows.Thickness 11, 1, 0, 0

        $title = New-Object Windows.Controls.TextBlock
        $title.Text = $step.Title
        $title.FontSize = 13
        $title.TextWrapping = 'Wrap'
        $title.Foreground = New-HexBrush '#FFEDE8F7'
        $text.Children.Add($title) | Out-Null

        if ($step.Detail) {
            $detail = New-Object Windows.Controls.TextBlock
            $detail.Text = $step.Detail
            $detail.FontSize = 11.5
            $detail.TextWrapping = 'Wrap'
            $detail.Foreground = New-HexBrush '#FF8B81A8'
            $detail.Margin = New-Object Windows.Thickness 0, 2, 0, 0
            $text.Children.Add($detail) | Out-Null
        }

        [Windows.Controls.Grid]::SetColumn($text, 1)
        $line.Children.Add($text) | Out-Null

        $ui.OneClickSteps.Children.Add($line) | Out-Null
    }
}

function Update-GuiPackageRow {
    if (-not $Ctx.Gui) { return }
    $ui = $Ctx.Gui.Ui

    $ui.PackageRows.Children.Clear()

    foreach ($entry in @(Get-PackageManagerReport)) {
        $manager = $entry.Manager

        $state = 'not installed'
        $ink, $fill = '#FF8B81A8', '#FF150F22'
        if ($entry.Installed) {
            $state = 'installed'
            $ink, $fill = '#FF7EE0A6', '#FF102A1E'
            # On disk but not on this process's PATH, which was copied at
            # startup - so it works in a new terminal and not in here.
            if (-not $entry.OnPath) {
                $state = 'new terminal'
                $ink, $fill = '#FFFFCB7A', '#FF2E2410'
            }
        }

        $secondary = $manager.Summary
        if ($entry.Installed -and $entry.Path) { $secondary = $entry.Path }

        $row = New-GuiRow -Item $manager -Primary "$($manager.Name)   $($manager.Site)" `
            -Secondary $secondary -Status $state -StatusBrush $ink -StatusFill $fill -NoCheckBox

        # winget arrives with App Installer from the Store; scripting around
        # the Store is the kind of thing that breaks on the next Windows build.
        if (-not [string]::IsNullOrWhiteSpace($manager.InstallCommand) -and -not $entry.Installed) {
            $install = New-Object Windows.Controls.Button
            $install.Content = 'Install'
            $install.Padding = New-Object Windows.Thickness 12, 4, 12, 4
            $install.Margin = New-Object Windows.Thickness 8, 0, 0, 0
            $install.VerticalAlignment = 'Center'
            $install.Tag = $manager.Id
            [Windows.Controls.Grid]::SetColumn($install, 2)

            $install.Add_Click({
                param($sender, $e)
                $id = [string]$sender.Tag
                Invoke-GuiWork -Label "installing $id" -Work { Invoke-PackageManagerInstall -Id $id | Out-Null }
                Update-GuiPackageRow
            })

            $row.Element.Child.Children.Add($install) | Out-Null
        }

        $ui.PackageRows.Children.Add($row.Element) | Out-Null
    }
}

function Update-GuiCustomizationRow {
    if (-not $Ctx.Gui) { return }
    $ui = $Ctx.Gui.Ui

    $ui.CustomizationRows.Children.Clear()

    foreach ($entry in @(Get-CustomizationReport)) {
        $tool = $entry.Tool

        $state = 'not installed'
        $ink, $fill = '#FF8B81A8', '#FF150F22'
        if ($entry.Installed) {
            $state = 'installed'
            $ink, $fill = '#FF7EE0A6', '#FF102A1E'
        }

        $secondary = $tool.Summary
        if ($tool.Note) { $secondary += '   ' + $tool.Note }

        $row = New-GuiRow -Item $tool -Primary "$($tool.Name)   $($tool.Site)" `
            -Secondary $secondary -Status $state -StatusBrush $ink -StatusFill $fill -NoCheckBox

        if (-not $entry.Installed) {
            $install = New-Object Windows.Controls.Button
            $install.Content = 'Install'
            $install.Padding = New-Object Windows.Thickness 12, 4, 12, 4
            $install.Margin = New-Object Windows.Thickness 8, 0, 0, 0
            $install.VerticalAlignment = 'Center'
            $install.Tag = $tool.Id
            [Windows.Controls.Grid]::SetColumn($install, 2)

            $install.Add_Click({
                param($sender, $e)
                $id = [string]$sender.Tag
                Invoke-GuiWork -Label "installing $id" -Work { Install-CustomizationTool -Id $id | Out-Null }
                Update-GuiCustomizationRow
            })

            $row.Element.Child.Children.Add($install) | Out-Null
        }

        $ui.CustomizationRows.Children.Add($row.Element) | Out-Null
    }
}

# -----------------------------------------------------------------------------
# Task manager page
#
# The sampling is 52-Tasks.ps1's, unchanged - this only draws it. A
# DispatcherTimer does the refreshing, which works because Show-Gui runs a real
# message loop through ShowDialog; the cooperative Invoke-UiEvents pumping is
# only for long synchronous work.
# -----------------------------------------------------------------------------

function Set-GuiTaskTimer {
    param([bool]$Running)

    if (-not $Ctx.Gui) { return }
    if (-not $Ctx.Gui.TaskTimer) { return }

    if (-not $Running) {
        $Ctx.Gui.TaskTimer.Stop()
        return
    }

    # A stale previous sample would difference this second's counters against
    # one from whenever the page was last open, which reads as a huge spike.
    $Ctx.Gui.Monitor.PreviousStamp = $null
    Update-GuiTaskSample
    $Ctx.Gui.TaskTimer.Start()
}

# Percent to brush, matching the console's load bands so a red bar means the
# same thing in both front-ends.
function Get-GuiLoadBrush {
    param([double]$Percent)

    switch (Get-LoadBand -Percent $Percent) {
        'high'   { return (New-HexBrush '#FFFF7B94') }
        'medium' { return (New-HexBrush '#FFFFCB7A') }
        default  { return (New-HexBrush '#FFB388FF') }
    }
}

# The CPU history, as a filled polygon on a Canvas. Redrawn from scratch each
# tick: 120 points is nothing, and holding a Polyline's PointCollection across
# ticks would mean tracking it as extra window state for no gain.
function Update-GuiCpuGraph {
    param([Parameter(Mandatory)][AllowEmptyCollection()][double[]]$History)

    if (-not $Ctx.Gui) { return }
    $canvas = $Ctx.Gui.Ui.CpuGraph

    $canvas.Children.Clear()

    $width = [double]$canvas.ActualWidth
    $height = [double]$canvas.ActualHeight
    if ($width -le 1 -or $height -le 1) { return }
    if ($History.Count -lt 2) { return }

    # Scaled to the samples in hand rather than to a fixed time axis, so the
    # graph fills the panel from the first few ticks instead of drawing a stub
    # against the right edge for the first two minutes. The console sparkline
    # pads instead - it is one character per sample there, with nothing to
    # stretch. Oldest on the left either way.
    $step = $width / ($History.Count - 1)

    $points = New-Object Windows.Media.PointCollection
    $points.Add((New-Object Windows.Point (0, $height)))
    for ($i = 0; $i -lt $History.Count; $i++) {
        $x = $i * $step
        $y = $height - (([Math]::Max(0.0, [Math]::Min(100.0, $History[$i])) / 100.0) * $height)
        $points.Add((New-Object Windows.Point ($x, $y)))
    }
    $points.Add((New-Object Windows.Point ($width, $height)))

    $fill = New-Object Windows.Media.LinearGradientBrush
    $fill.StartPoint = New-Object Windows.Point (0, 0)
    $fill.EndPoint = New-Object Windows.Point (0, 1)
    $fill.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString('#66B388FF'), 0)))
    $fill.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString('#08B388FF'), 1)))

    $area = New-Object Windows.Shapes.Polygon
    $area.Points = $points
    $area.Fill = $fill
    $canvas.Children.Add($area) | Out-Null

    # The line on top, without the two baseline points the fill needed.
    $edge = New-Object Windows.Shapes.Polyline
    $edgePoints = New-Object Windows.Media.PointCollection
    for ($i = 1; $i -lt ($points.Count - 1); $i++) { $edgePoints.Add($points[$i]) }
    $edge.Points = $edgePoints
    $edge.Stroke = New-HexBrush '#FFB388FF'
    $edge.StrokeThickness = 1.4
    $canvas.Children.Add($edge) | Out-Null
}

# One narrow vertical bar per core, tallest to the bottom - btop's core strip.
function Update-GuiCoreStrip {
    param([Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Cores)

    if (-not $Ctx.Gui) { return }
    $strip = $Ctx.Gui.Ui.CoreStrip

    $strip.Children.Clear()
    if ($Cores.Count -eq 0) { return }

    # Wide bars for a couple of cores, hairlines for a threadripper.
    $barWidth = 10
    if ($Cores.Count -gt 8)  { $barWidth = 6 }
    if ($Cores.Count -gt 24) { $barWidth = 3 }

    foreach ($core in $Cores) {
        $column = New-Object Windows.Controls.Grid
        $column.Width = $barWidth
        $column.Height = 54
        $column.Margin = New-Object Windows.Thickness 0, 0, 2, 0

        $track = New-Object Windows.Controls.Border
        $track.Background = New-HexBrush '#FF130E1F'
        $track.CornerRadius = New-Object Windows.CornerRadius 2
        $column.Children.Add($track) | Out-Null

        $level = New-Object Windows.Controls.Border
        $level.VerticalAlignment = 'Bottom'
        $level.CornerRadius = New-Object Windows.CornerRadius 2
        $level.Background = Get-GuiLoadBrush -Percent $core
        # A floor of one pixel, so an idle core is still a mark rather than a gap.
        $level.Height = [Math]::Max(1.0, 54.0 * [Math]::Max(0.0, [Math]::Min(100.0, $core)) / 100.0)
        $column.Children.Add($level) | Out-Null

        $strip.Children.Add($column) | Out-Null
    }
}

# One refresh of the whole page.
function Update-GuiTaskSample {
    if (-not $Ctx.Gui) { return }

    $ui = $Ctx.Gui.Ui
    $monitor = $Ctx.Gui.Monitor

    Update-TaskMonitor -Monitor $monitor | Out-Null

    # ---- meters ------------------------------------------------------------
    $ui.CpuValue.Text = '{0:N0}%' -f $monitor.Cpu.Total
    $ui.CpuValue.Foreground = Get-GuiLoadBrush -Percent $monitor.Cpu.Total
    $ui.CpuBar.Value = [Math]::Max(0.0, [Math]::Min(100.0, $monitor.Cpu.Total))
    $ui.CpuBar.Foreground = Get-GuiLoadBrush -Percent $monitor.Cpu.Total
    $ui.CpuDetail.Text = '{0} cores' -f $monitor.Cores

    if ($monitor.Memory) {
        $ui.MemValue.Text = '{0:N0}%' -f $monitor.Memory.Percent
        $ui.MemValue.Foreground = Get-GuiLoadBrush -Percent $monitor.Memory.Percent
        $ui.MemBar.Value = [Math]::Max(0.0, [Math]::Min(100.0, $monitor.Memory.Percent))
        $ui.MemBar.Foreground = Get-GuiLoadBrush -Percent $monitor.Memory.Percent
        $ui.MemDetail.Text = '{0} of {1}   commit {2}' -f `
            (Format-CompactBytes $monitor.Memory.Used), (Format-CompactBytes $monitor.Memory.Total),
            (Format-CompactBytes $monitor.Memory.CommitUsed)
    }

    # The fullest volume, because that is the one about to cause a problem.
    $disks = @($monitor.Disks)
    if ($disks.Count -gt 0) {
        $worst = @($disks | Sort-Object -Property Percent -Descending)[0]
        $ui.DiskValue.Text = '{0:N0}%' -f $worst.Percent
        $ui.DiskValue.Foreground = Get-GuiLoadBrush -Percent $worst.Percent
        $ui.DiskBar.Value = [Math]::Max(0.0, [Math]::Min(100.0, $worst.Percent))
        $ui.DiskBar.Foreground = Get-GuiLoadBrush -Percent $worst.Percent

        $extra = ''
        if ($disks.Count -gt 1) { $extra = '   +{0} more' -f ($disks.Count - 1) }
        $ui.DiskDetail.Text = '{0} {1} free{2}' -f $worst.Name, (Format-CompactBytes $worst.Free), $extra
    }

    # Headline is the combined rate; the split goes underneath, where the other
    # three cards put their detail.
    $ui.NetValue.Text = Format-Rate ($monitor.Network.Received + $monitor.Network.Sent)
    $ui.NetDetail.Text = 'down {0}   up {1}' -f `
        (Format-CompactBytes $monitor.Network.Received), (Format-CompactBytes $monitor.Network.Sent)

    Update-GuiCpuGraph -History @($monitor.CpuHistory)
    Update-GuiCoreStrip -Cores @($monitor.Cpu.Cores)

    # ---- process table -----------------------------------------------------
    $rows = @(Select-TaskProcess -Processes @($monitor.Processes) -Filter $monitor.Filter)

    # Keep whatever was selected selected across the refresh: the whole
    # ItemsSource is replaced every tick, and without this the row under the
    # cursor would deselect itself once a second.
    $selectedId = $null
    if ($ui.TaskRows.SelectedItem) { $selectedId = $ui.TaskRows.SelectedItem.Id }

    $view = [System.Collections.Generic.List[object]]::new()
    foreach ($proc in $rows) {
        $cpuText = '-'
        if ($proc.CpuKnown) { $cpuText = '{0:N1}' -f $proc.Cpu }

        $view.Add([pscustomobject]@{
            Id         = $proc.Id
            Name       = $proc.Name
            CpuText    = $cpuText
            MemoryText = Format-CompactBytes $proc.WorkingSet
            Threads    = $proc.Threads
            TimeText   = Format-CpuTime $proc.CpuSeconds
        })
    }

    $ui.TaskRows.ItemsSource = @($view)

    if ($null -ne $selectedId) {
        foreach ($item in $view) {
            if ($item.Id -eq $selectedId) { $ui.TaskRows.SelectedItem = $item; break }
        }
    }

    $summary = '{0} processes' -f @($monitor.Processes).Count
    if ($monitor.Memory) { $summary += '   up ' + (Format-Uptime $monitor.Memory.BootTime) }
    if (-not $monitor.Ready) { $summary += '   sampling' }
    if ($Ctx.Gui.TaskPaused) { $summary += '   PAUSED' }
    foreach ($problem in @($monitor.Errors)) { $summary += '   ' + $problem }
    $ui.TaskSummary.Text = $summary
}

# Nav rows carry a count on the right, so the sidebar says how much is behind
# each page without opening it.
function Set-GuiNavContent {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][string]$Text, [int]$Count = -1)

    $panel = New-Object Windows.Controls.DockPanel
    $panel.LastChildFill = $true

    if ($Count -ge 0) {
        $badge = New-Object Windows.Controls.TextBlock
        $badge.Text = [string]$Count
        $badge.FontSize = 11
        $badge.Foreground = New-HexBrush '#FF5F5680'
        $badge.VerticalAlignment = 'Center'
        [Windows.Controls.DockPanel]::SetDock($badge, 'Right')
        $panel.Children.Add($badge) | Out-Null
    }

    $label = New-Object Windows.Controls.TextBlock
    $label.Text = $Text
    $label.FontSize = 14

    # The global TextBlock style pins a Foreground, which would break the
    # inheritance the nav's selected/unselected colours rely on. Bind to the
    # owning ListBoxItem so the label tracks selection.
    $binding = New-Object Windows.Data.Binding 'Foreground'
    $source = New-Object Windows.Data.RelativeSource ([Windows.Data.RelativeSourceMode]::FindAncestor)
    $source.AncestorType = [Windows.Controls.ListBoxItem]
    $binding.RelativeSource = $source
    [void]$label.SetBinding([Windows.Controls.TextBlock]::ForegroundProperty, $binding)

    $panel.Children.Add($label) | Out-Null

    $Item.Content = $panel
}

# A drawn window icon, so the title bar and taskbar are not the generic
# PowerShell one. Cheaper than shipping an .ico through the single-file bundle.
function New-GuiIcon {
    $visual = New-Object Windows.Media.DrawingVisual
    $dc = $visual.RenderOpen()
    try {
        $accent = New-HexBrush '#FFB388FF'
        $dc.DrawRoundedRectangle($accent, $null, (New-Object Windows.Rect 0, 0, 32, 32), 7, 7)

        # A stylised M, stroked rather than typeset, so no font is involved.
        $pen = New-Object Windows.Media.Pen ((New-HexBrush '#FF14082B'), 3.4)
        $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'; $pen.LineJoin = 'Round'
        $geometry = [Windows.Media.Geometry]::Parse('M 8,23 L 8,9 L 16,18 L 24,9 L 24,23')
        $dc.DrawGeometry($null, $pen, $geometry)
    }
    finally { $dc.Close() }

    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap(32, 32, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    return $bitmap
}


# -----------------------------------------------------------------------------
# Store, Guides, Personalise and Settings pages
# -----------------------------------------------------------------------------

function Update-GuiStoreRow {
    if (-not $Ctx.Gui) { return }
    $ui = $Ctx.Gui.Ui

    $ui.StoreRows.Children.Clear()
    $built = [System.Collections.Generic.List[object]]::new()

    foreach ($app in @($Ctx.StoreApps)) {
        $installable = [bool]$app.DownloadUrl
        $ink, $fill = if ($installable) { '#FF7EE0A6', '#FF102A1E' } else { '#FF8B81A8', '#FF150F22' }

        $row = New-GuiRow -Item $app -Primary "$($app.Name)  $($app.Author)" `
            -Secondary $app.Description -Status $app.Version -StatusBrush $ink -StatusFill $fill
        # Nothing to install means nothing to tick.
        if (-not $installable) { $row.CheckBox.IsEnabled = $false }

        $ui.StoreRows.Children.Add($row.Element) | Out-Null
        $built.Add($row)
    }

    $Ctx.Gui.Rows.Store = @($built)
    Update-GuiActionState
}

function Update-GuiGuideRow {
    if (-not $Ctx.Gui) { return }
    $ui = $Ctx.Gui.Ui

    Initialize-GuideCatalog
    $ui.GuideRows.Children.Clear()

    $first = $true
    foreach ($category in $Ctx.GuideCategories) {
        $inCategory = @($Ctx.Guides | Where-Object { $_.category -eq $category })
        if ($inCategory.Count -eq 0) { continue }

        $ui.GuideRows.Children.Add((New-GuiGroupHeader -Title $category -Count $inCategory.Count -First:$first)) | Out-Null
        $first = $false

        foreach ($guide in $inCategory) {
            $ui.GuideRows.Children.Add((New-GuiGuideCard -Guide $guide)) | Out-Null
        }
    }
}

# One collapsible guide: a clickable header, and the numbered steps underneath.
function New-GuiGuideCard {
    param([Parameter(Mandatory)]$Guide)

    $outer = New-Object Windows.Controls.StackPanel
    $outer.Margin = New-Object Windows.Thickness 0, 0, 0, 3

    $header = New-Object Windows.Controls.Border
    $header.Padding = New-Object Windows.Thickness 10, 8, 10, 8
    $header.CornerRadius = New-Object Windows.CornerRadius 5
    $header.Cursor = 'Hand'
    $header.Background = [Windows.Media.Brushes]::Transparent

    $headerStack = New-Object Windows.Controls.StackPanel

    $title = New-Object Windows.Controls.TextBlock
    $title.Text = $Guide.title
    $title.FontSize = 13
    $title.Foreground = New-HexBrush '#FFEDE8F7'
    $headerStack.Children.Add($title) | Out-Null

    $summary = New-Object Windows.Controls.TextBlock
    $summary.Text = "$($Guide.summary)   -   $(@($Guide.steps).Count) steps"
    $summary.FontSize = 11
    $summary.TextWrapping = 'Wrap'
    $summary.Foreground = New-HexBrush '#FF8B81A8'
    $summary.Margin = New-Object Windows.Thickness 0, 1, 0, 0
    $headerStack.Children.Add($summary) | Out-Null

    $header.Child = $headerStack
    $outer.Children.Add($header) | Out-Null

    $steps = New-Object Windows.Controls.StackPanel
    $steps.Margin = New-Object Windows.Thickness 14, 4, 10, 12
    $steps.Visibility = 'Collapsed'

    $list = @($Guide.steps)
    for ($i = 0; $i -lt $list.Count; $i++) {
        $line = New-Object Windows.Controls.Grid
        foreach ($unit in @([Windows.GridUnitType]::Auto, [Windows.GridUnitType]::Star)) {
            $column = New-Object Windows.Controls.ColumnDefinition
            $column.Width = New-Object Windows.GridLength 1, $unit
            $line.ColumnDefinitions.Add($column)
        }

        $number = New-Object Windows.Controls.TextBlock
        $number.Text = '{0}.' -f ($i + 1)
        $number.FontSize = 12
        $number.MinWidth = 24
        $number.Foreground = New-HexBrush '#FFB388FF'
        $number.VerticalAlignment = 'Top'
        [Windows.Controls.Grid]::SetColumn($number, 0)
        $line.Children.Add($number) | Out-Null

        $text = New-Object Windows.Controls.TextBlock
        # WPF renders the source typography fine, so no transliteration here.
        $text.Text = [string]$list[$i]
        $text.FontSize = 12
        $text.TextWrapping = 'Wrap'
        $text.Foreground = New-HexBrush '#FFC5BDDC'
        $text.Margin = New-Object Windows.Thickness 6, 0, 0, 6
        [Windows.Controls.Grid]::SetColumn($text, 1)
        $line.Children.Add($text) | Out-Null

        $steps.Children.Add($line) | Out-Null
    }

    $outer.Children.Add($steps) | Out-Null

    # The steps panel is the sibling after the header, reached from $sender.
    $header.Add_MouseLeftButtonUp({
        param($sender, $e)
        $panel = $sender.Parent
        $body = $panel.Children[1]
        $body.Visibility = if ($body.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
    })
    $header.Add_MouseEnter({ param($sender, $e) $sender.Background = New-HexBrush '#FF120C1E' })
    $header.Add_MouseLeave({ param($sender, $e) $sender.Background = [Windows.Media.Brushes]::Transparent })

    return $outer
}

function Update-GuiCsFolderText {
    if (-not $Ctx.Gui) { return }

    $folders = @(Find-CsConfigFolder)
    $Ctx.Gui.Ui.CsFolderText.Text = if ($folders.Count -eq 0) {
        'No Counter-Strike cfg folder found. Is it installed through Steam?'
    }
    else {
        "Found $($folders.Count) cfg folder(s):" + [Environment]::NewLine + ($folders -join [Environment]::NewLine)
    }
}

# -----------------------------------------------------------------------------
# The window
# -----------------------------------------------------------------------------

# Builds and wires the window without showing it. Split out from Show-Gui so the
# whole thing can be constructed, populated and rendered to an image in a test
# without a human clicking anything.
function New-GuiWindow {
    param([hashtable]$BoundParameters = @{})

    $reader = New-Object Xml.XmlNodeReader ([xml](Get-GuiXaml))
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # Pull every x:Name into a lookup so handlers read as $ui.BtnApply.
    $ui = @{}
    foreach ($name in @(
        'VersionText', 'CatalogChip', 'DryRunBadge',
        'NavList', 'OneClickPanel', 'TasksPanel', 'TweaksPanel', 'AppsPanel', 'ToolboxPanel', 'ProfilesPanel',
        'StorePanel', 'GuidesPanel', 'PersonalizePanel', 'SettingsPanel',
        'PackagesPanel', 'PackageRows',
        'CustomizationPanel', 'CustomizationRows',
        'OneClickSteps', 'OneClickBlurb', 'BtnOneClick', 'BtnOneClickToolbox',
        'TaskSummary', 'CpuValue', 'CpuBar', 'CpuDetail', 'MemValue', 'MemBar', 'MemDetail',
        'DiskValue', 'DiskBar', 'DiskDetail', 'NetValue', 'NetDetail',
        'CpuGraph', 'CoreStrip', 'TaskRows', 'TaskSearch', 'TaskSort', 'BtnTaskPause', 'BtnTaskKill',
        'StoreRows', 'BtnStoreRefresh', 'BtnStoreInstall', 'GuideRows',
        'CursorPresets', 'BtnCursorInstall', 'BtnCursorRestore', 'WallpaperStyle', 'BtnWallpaper', 'BtnCsLaunchCsgo',
        'CsFolderText', 'BtnCsDefault', 'BtnCsFile', 'BtnCsLaunch',
        'InstallPath', 'BtnBrowseInstallPath', 'GitHubToken', 'BtnSaveSettings', 'BtnOpenStateFolder',
        'TweakSearch', 'TweakCategory', 'TweakRows', 'BtnApply', 'BtnRevert', 'BtnTweakAll', 'BtnTweakNone',
        'AppSearch', 'AppCategory', 'AppRows', 'BtnInstall', 'BtnAppNone',
        'ToolboxRows',
        'ProfilePath', 'BtnBrowseProfile', 'BtnRunProfile', 'BtnSaveProfile',
        'LogBox', 'BtnClearLog', 'StatusText', 'Progress')) {
        $ui[$name] = $window.FindName($name)
    }

    # ---- log pane ----------------------------------------------------------
    $document = New-Object Windows.Documents.FlowDocument
    # Wide enough that rules and status lines never wrap, without the permanent
    # horizontal scrollbar a fixed large width would cause. Tracked on resize.
    $document.PageWidth = 900
    $paragraph = New-Object Windows.Documents.Paragraph
    $paragraph.Margin = New-Object Windows.Thickness 0
    $paragraph.LineHeight = 15
    $document.Blocks.Add($paragraph)
    $ui.LogBox.Document = $document

    # ---- shared state ------------------------------------------------------
    # Everything a handler needs, parked somewhere it can still reach once this
    # function has returned. See the note at the top of the file.
    $Ctx.Gui = [pscustomobject]@{
        Window    = $window
        Ui        = $ui
        Paragraph = $paragraph
        Rows      = [pscustomobject]@{ Tweaks = @(); Apps = @(); Toolbox = @(); Store = @() }
        # Filled in below. Lets a handler say which page it wants by name
        # instead of hard-coding an index into the sidebar.
        NavNames  = @()

        # Task manager state. It lives here rather than in the handlers for the
        # reason at the top of this file: a handler runs long after the function
        # that registered it returned, so it can only reach $Ctx.
        Monitor    = New-TaskMonitor
        TaskTimer  = $null
        TaskPaused = $false
        Bound     = $BoundParameters
        Glyphs    = $Ctx.Theme.Glyph
    }

    # The console glyph set may have fallen back to ASCII because conhost cannot
    # encode box drawing. WPF has no such problem, so the log pane always gets the
    # good glyphs; the console's set is restored when the window closes.
    $Ctx.Theme.Glyph = New-GlyphSet -Unicode $true

    $ui.LogBox.Add_SizeChanged({
        param($sender, $e)
        if ($sender.Document) { $sender.Document.PageWidth = [Math]::Max(600, $sender.ActualWidth - 24) }
    })

    # Redirecting Write-Line is what lets every engine function report into the
    # window without knowing the window exists.
    $Ctx.Sink = {
        param($text, $color, $newline)
        if (-not $Ctx.Gui) { return }

        $run = New-Object Windows.Documents.Run ([string]$text)
        if ($color) { $run.Foreground = ConvertTo-Brush $color }
        $Ctx.Gui.Paragraph.Inlines.Add($run)
        if ($newline) { $Ctx.Gui.Paragraph.Inlines.Add((New-Object Windows.Documents.LineBreak)) }

        $Ctx.Gui.Ui.LogBox.ScrollToEnd()
        Invoke-UiEvents
    }

    $Ctx.ProgressSink = {
        param($label, $fraction, $detail)
        if (-not $Ctx.Gui) { return }

        $bar = $Ctx.Gui.Ui.Progress
        $bar.Visibility = 'Visible'

        if ($fraction -lt 0) {
            $bar.IsIndeterminate = $true
        }
        else {
            $bar.IsIndeterminate = $false
            $bar.Value = [Math]::Round($fraction * 100)
        }

        $Ctx.Gui.Ui.StatusText.Text = if ($detail) { "$label   $detail" } else { [string]$label }
        Invoke-UiEvents
    }

    $Ctx.ConfirmSink = {
        param($message, $defaultYes)

        $default = if ($defaultYes) { [Windows.MessageBoxResult]::Yes } else { [Windows.MessageBoxResult]::No }
        $owner = if ($Ctx.Gui) { $Ctx.Gui.Window } else { $null }

        $answer = [Windows.MessageBox]::Show($owner, [string]$message, 'Moscovium',
            [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question, $default)

        return ($answer -eq [Windows.MessageBoxResult]::Yes)
    }

    try { $window.Icon = New-GuiIcon } catch { Write-Log "Window icon failed: $($_.Exception.Message)" 'WARN' }

    # ---- navigation labels -------------------------------------------------
    Initialize-GuideCatalog

    # Order has to match the ListBoxItems in the XAML and the $panels array in
    # the SelectionChanged handler. -1 means "no count worth showing".
    $navNames  = @('One click', 'Tasks', 'Tweaks', 'Apps', 'Package managers', 'Store', 'Toolbox', 'Guides', 'Personalise', 'Customization', 'Profiles', 'Settings')
    $navCounts = @(-1, -1, $Ctx.Tweaks.Count, $Ctx.Apps.Count, @(Get-PackageManagers).Count, -1, @(Get-ToolboxListActions).Count, $Ctx.Guides.Count, -1, @(Get-CustomizationTools).Count, -1, -1)

    # The item Content becomes a DockPanel below, so the labels are no longer
    # readable off the ListBox. Keep them where a handler can still find them.
    $Ctx.Gui.NavNames = $navNames

    if ($ui.NavList.Items.Count -ne $navNames.Count) {
        Write-Log "Nav has $($ui.NavList.Items.Count) items but $($navNames.Count) names." 'WARN'
    }

    for ($i = 0; $i -lt $ui.NavList.Items.Count -and $i -lt $navNames.Count; $i++) {
        Set-GuiNavContent -Item $ui.NavList.Items[$i] -Text $navNames[$i] -Count $navCounts[$i]
    }

    # ---- keyboard ----------------------------------------------------------
    $window.Add_PreviewKeyDown({
        param($sender, $e)
        if (-not $Ctx.Gui) { return }
        $ui = $Ctx.Gui.Ui

        $box = if ($ui.AppsPanel.Visibility -eq 'Visible') { $ui.AppSearch }
               elseif ($ui.TweaksPanel.Visibility -eq 'Visible') { $ui.TweakSearch }
               else { $null }

        $ctrl = [Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control

        if ($ctrl -and $e.Key -eq [Windows.Input.Key]::F) {
            if ($box) { [void]$box.Focus(); $box.SelectAll() }
            $e.Handled = $true
        }
        elseif ($e.Key -eq [Windows.Input.Key]::Escape) {
            if ($box -and $box.Text) { $box.Text = ''; $e.Handled = $true }
        }
    })

    # ---- header ------------------------------------------------------------
    $ui.VersionText.Text = "v$($Ctx.Version)"
    $ui.CatalogChip.Text = "$($Ctx.Tweaks.Count) tweaks   $($Ctx.Apps.Count) apps"

    # The window is always elevated, so there is nothing to report and no button
    # to offer. Dry run is a CLI flag only; surface it read-only when it is on,
    # so a dry run never looks like a real one.
    if ($Ctx.DryRun) { $ui.DryRunBadge.Visibility = 'Visible' }

    $ui.BtnClearLog.Add_Click({ if ($Ctx.Gui) { $Ctx.Gui.Paragraph.Inlines.Clear() } })

    # ---- navigation --------------------------------------------------------
    $ui.NavList.Add_SelectionChanged({
        param($sender, $e)
        if (-not $Ctx.Gui) { return }

        $panels = @($Ctx.Gui.Ui.OneClickPanel, $Ctx.Gui.Ui.TasksPanel, $Ctx.Gui.Ui.TweaksPanel,
                    $Ctx.Gui.Ui.AppsPanel, $Ctx.Gui.Ui.PackagesPanel, $Ctx.Gui.Ui.StorePanel,
                    $Ctx.Gui.Ui.ToolboxPanel, $Ctx.Gui.Ui.GuidesPanel, $Ctx.Gui.Ui.PersonalizePanel,
                    $Ctx.Gui.Ui.CustomizationPanel, $Ctx.Gui.Ui.ProfilesPanel, $Ctx.Gui.Ui.SettingsPanel)
        for ($i = 0; $i -lt $panels.Count; $i++) {
            $panels[$i].Visibility = if ($i -eq $sender.SelectedIndex) { 'Visible' } else { 'Collapsed' }
        }

        # Sampling costs a CIM round trip a second, so it only runs while the
        # page is on screen. Leaving the page stops the clock; coming back takes
        # a fresh baseline rather than differencing against a minutes-old one.
        Set-GuiTaskTimer -Running ($Ctx.Gui.Ui.TasksPanel.Visibility -eq 'Visible')
    })

    # ---- filters -----------------------------------------------------------
    $ui.TweakCategory.Items.Add('All categories') | Out-Null
    foreach ($c in $Ctx.TweakCategories) { $ui.TweakCategory.Items.Add($c) | Out-Null }
    $ui.TweakCategory.SelectedIndex = 0

    $ui.AppCategory.Items.Add('All categories') | Out-Null
    foreach ($c in $Ctx.AppCategories) { $ui.AppCategory.Items.Add($c) | Out-Null }
    $ui.AppCategory.SelectedIndex = 0

    $ui.TweakSearch.Add_TextChanged({ Update-GuiTweakRow })
    $ui.TweakCategory.Add_SelectionChanged({ Update-GuiTweakRow })
    $ui.AppSearch.Add_TextChanged({ Update-GuiAppRow })
    $ui.AppCategory.Add_SelectionChanged({ Update-GuiAppRow })

    $ui.BtnTweakAll.Add_Click({ foreach ($r in $Ctx.Gui.Rows.Tweaks) { $r.CheckBox.IsChecked = $true } })
    $ui.BtnTweakNone.Add_Click({ foreach ($r in $Ctx.Gui.Rows.Tweaks) { $r.CheckBox.IsChecked = $false } })
    $ui.BtnAppNone.Add_Click({ foreach ($r in $Ctx.Gui.Rows.Apps) { $r.CheckBox.IsChecked = $false } })

    # ---- task manager ------------------------------------------------------
    foreach ($label in @('CPU', 'Memory', 'PID', 'Name')) { $ui.TaskSort.Items.Add($label) | Out-Null }
    $ui.TaskSort.SelectedIndex = 0

    $ui.TaskSort.Add_SelectionChanged({
        param($sender, $e)
        if (-not $Ctx.Gui) { return }

        $Ctx.Gui.Monitor.SortKey = switch ([string]$sender.SelectedItem) {
            'Memory' { 'mem' }
            'PID'    { 'pid' }
            'Name'   { 'name' }
            default  { 'cpu' }
        }
        # Re-sort what we already have rather than waiting a whole tick.
        $Ctx.Gui.Monitor.Processes = @(Sort-TaskProcess -Processes @($Ctx.Gui.Monitor.Processes) -Key $Ctx.Gui.Monitor.SortKey)
        Update-GuiTaskSample
    })

    $ui.TaskSearch.Add_TextChanged({
        param($sender, $e)
        if (-not $Ctx.Gui) { return }
        $Ctx.Gui.Monitor.Filter = [string]$sender.Text
        Update-GuiTaskSample
    })

    $ui.BtnTaskPause.Add_Click({
        param($sender, $e)
        if (-not $Ctx.Gui) { return }

        $Ctx.Gui.TaskPaused = -not $Ctx.Gui.TaskPaused
        if ($Ctx.Gui.TaskPaused) {
            $Ctx.Gui.TaskTimer.Stop()
            $sender.Content = 'Resume'
        }
        else {
            $sender.Content = 'Pause'
            # Fresh baseline, same reason as Set-GuiTaskTimer.
            $Ctx.Gui.Monitor.PreviousStamp = $null
            Update-GuiTaskSample
            $Ctx.Gui.TaskTimer.Start()
        }
    })

    $ui.BtnTaskKill.Add_Click({
        param($sender, $e)
        if (-not $Ctx.Gui) { return }

        $selected = $Ctx.Gui.Ui.TaskRows.SelectedItem
        if (-not $selected) { $Ctx.Gui.Ui.StatusText.Text = 'Select a process first.'; return }

        # Hold the clock while the confirm dialog is up: a tick landing mid-modal
        # would replace the ItemsSource under the row being asked about.
        $wasRunning = $Ctx.Gui.TaskTimer.IsEnabled
        $Ctx.Gui.TaskTimer.Stop()

        try {
            Stop-TaskProcess -Id ([int]$selected.Id) -Name ([string]$selected.Name) | Out-Null
            $Ctx.Gui.Monitor.PreviousStamp = $null
            Update-GuiTaskSample
        }
        finally {
            if ($wasRunning -and -not $Ctx.Gui.TaskPaused) { $Ctx.Gui.TaskTimer.Start() }
        }
    })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({ Update-GuiTaskSample })
    $Ctx.Gui.TaskTimer = $timer

    # ---- actions -----------------------------------------------------------
    $ui.BtnOneClick.Add_Click({
        Invoke-GuiWork -Label 'one-click debloat box' -Work { Invoke-ToolboxAction -Id 'oneclick' }
        # Steps 3 to 6 write registry and boot state the Tweaks page reports on.
        Update-GuiTweakRow
    })

    # Not a duplicate of the nav: someone reading the landing page and deciding
    # they want fewer steps should not have to find the sidebar.
    $ui.BtnOneClickToolbox.Add_Click({
        if (-not $Ctx.Gui) { return }
        $index = [array]::IndexOf([string[]]@($Ctx.Gui.NavNames), 'Toolbox')
        if ($index -ge 0) { $Ctx.Gui.Ui.NavList.SelectedIndex = $index }
    })

    $ui.BtnApply.Add_Click({
        $selected = Get-CheckedItem -Rows $Ctx.Gui.Rows.Tweaks
        if ($selected.Count -eq 0) { $Ctx.Gui.Ui.StatusText.Text = 'Nothing selected.'; return }

        Invoke-GuiWork -Label 'applying tweaks' -Work { Invoke-Tweaks -Tweaks $selected -Mode Apply }
        Update-GuiTweakRow
    })

    $ui.BtnRevert.Add_Click({
        $selected = Get-CheckedItem -Rows $Ctx.Gui.Rows.Tweaks
        if ($selected.Count -eq 0) { $Ctx.Gui.Ui.StatusText.Text = 'Nothing selected.'; return }

        Invoke-GuiWork -Label 'reverting tweaks' -Work { Invoke-Tweaks -Tweaks $selected -Mode Revert }
        Update-GuiTweakRow
    })

    $ui.BtnInstall.Add_Click({
        $selected = Get-CheckedItem -Rows $Ctx.Gui.Rows.Apps
        if ($selected.Count -eq 0) { $Ctx.Gui.Ui.StatusText.Text = 'Nothing selected.'; return }

        Invoke-GuiWork -Label 'installing apps' -Work { Invoke-AppInstall -Apps $selected }
    })

    # ---- store -------------------------------------------------------------
    # Loaded on demand: listing two orgs and every repo's latest release is a
    # few dozen API calls, which has no business happening at window-open.
    $ui.BtnStoreRefresh.Add_Click({
        Invoke-GuiWork -Label 'loading store' -Work { Get-StoreApp -Refresh | Out-Null }
        Update-GuiStoreRow
        $Ctx.Gui.Ui.BtnStoreRefresh.Content = 'Reload'
    })

    $ui.BtnStoreInstall.Add_Click({
        $selected = Get-CheckedItem -Rows $Ctx.Gui.Rows.Store
        if ($selected.Count -eq 0) { $Ctx.Gui.Ui.StatusText.Text = 'Nothing selected.'; return }
        Invoke-GuiWork -Label 'installing store apps' -Work { Invoke-StoreInstall -Apps $selected }
    })

    # ---- personalise -------------------------------------------------------
    $ui.BtnCursorInstall.Add_Click({
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Pick a folder containing .cur / .ani files'
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }

        $folder = $dialog.SelectedPath
        Invoke-GuiWork -Label 'installing cursors' -Work {
            Install-CursorScheme -Path $folder -SchemeName (Split-Path -Leaf $folder)
        }
    })

    $ui.BtnCursorRestore.Add_Click({
        Invoke-GuiWork -Label 'restoring cursors' -Work { Restore-DefaultCursor }
    })

    foreach ($preset in Get-CursorPresets) {
        $button = New-Object Windows.Controls.Button
        $button.Content = $preset.Name
        $button.ToolTip = $preset.Credit
        $button.Tag = $preset.Id
        $button.Margin = New-Object Windows.Thickness 0, 0, 8, 8
        $button.Style = $window.FindResource('Primary')

        # Plain script block, per the note at the top of the file: it reads the
        # preset id back off $sender rather than capturing it.
        $button.Add_Click({
            param($sender, $e)
            $id = [string]$sender.Tag
            Invoke-GuiWork -Label "installing cursors: $id" -Work { Install-CursorPreset -Id $id | Out-Null }
        })

        $ui.CursorPresets.Children.Add($button) | Out-Null
    }

    foreach ($style in @('Fill', 'Fit', 'Stretch', 'Tile', 'Center', 'Span')) {
        $ui.WallpaperStyle.Items.Add($style) | Out-Null
    }
    $ui.WallpaperStyle.SelectedIndex = 0

    $ui.BtnWallpaper.Add_Click({
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Images|*.jpg;*.jpeg;*.png;*.bmp;*.gif|All files (*.*)|*.*'
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }

        $image = $dialog.FileName
        $style = [string]$Ctx.Gui.Ui.WallpaperStyle.SelectedItem
        Invoke-GuiWork -Label 'setting wallpaper' -Work { Set-Wallpaper -Path $image -Style $style }
    })

    $ui.BtnCsDefault.Add_Click({
        Invoke-GuiWork -Label 'installing config' -Work { Install-CsConfig }
        Update-GuiCsFolderText
    })

    $ui.BtnCsFile.Add_Click({
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Counter-Strike config (*.cfg)|*.cfg'
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }

        $cfg = $dialog.FileName
        Invoke-GuiWork -Label 'installing config' -Work { Install-CsConfig -LocalPath $cfg }
    })

    $ui.BtnCsLaunch.Add_Click({
        $options = Get-CsLaunchOption
        [Windows.Clipboard]::SetText($options)
        $Ctx.Gui.Ui.StatusText.Text = "Copied: $options"
        Write-Ok "Launch options copied to the clipboard: $options"
    })

    $ui.BtnCsLaunchCsgo.Add_Click({
        $options = Get-CsLaunchOption -Game CSGO
        [Windows.Clipboard]::SetText($options)
        $Ctx.Gui.Ui.StatusText.Text = "Copied: $options"
        Write-Ok "CS:GO launch options copied to the clipboard: $options"
    })

    # ---- settings ----------------------------------------------------------
    $ui.InstallPath.Text = Get-StoreInstallRoot
    if (Get-MoscoviumSetting -Name 'GitHubToken') { $ui.GitHubToken.Password = '' }

    $ui.BtnBrowseInstallPath.Add_Click({
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Where store apps should be installed'
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $Ctx.Gui.Ui.InstallPath.Text = $dialog.SelectedPath }
    })

    $ui.BtnSaveSettings.Add_Click({
        $ui = $Ctx.Gui.Ui
        Set-MoscoviumSetting -Name 'AppsInstallPath' -Value ([string]$ui.InstallPath.Text)

        # An empty box means "leave the stored token alone", not "clear it" - the
        # box is never pre-filled with a secret, so blank is the normal state.
        $token = [string]$ui.GitHubToken.Password
        if ($token) {
            Set-MoscoviumSetting -Name 'GitHubToken' -Value $token
            $ui.GitHubToken.Password = ''
        }

        $ui.StatusText.Text = 'Settings saved.'
    })

    $ui.BtnOpenStateFolder.Add_Click({
        Initialize-State
        Start-Process -FilePath 'explorer.exe' -ArgumentList $Ctx.StateDir | Out-Null
    })

    # ---- profiles ----------------------------------------------------------
    $ui.BtnBrowseProfile.Add_Click({
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Moscovium profile (*.json)|*.json|All files (*.*)|*.*'
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $Ctx.Gui.Ui.ProfilePath.Text = $dialog.FileName }
    })

    $ui.BtnRunProfile.Add_Click({
        $path = [string]$Ctx.Gui.Ui.ProfilePath.Text
        if (-not $path) { $Ctx.Gui.Ui.StatusText.Text = 'Choose a profile first.'; return }

        Invoke-GuiWork -Label 'running profile' -Work { Invoke-SetupProfile -Path $path }
        Update-GuiTweakRow
    })

    $ui.BtnSaveProfile.Add_Click({
        $dialog = New-Object Windows.Forms.SaveFileDialog
        $dialog.Filter = 'Moscovium profile (*.json)|*.json'
        $dialog.FileName = 'moscovium-profile.json'
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }

        $target = $dialog.FileName
        $setupProfile = New-SetupProfile `
            -Tweaks @(Get-CheckedItem -Rows $Ctx.Gui.Rows.Tweaks | ForEach-Object { $_.name }) `
            -Apps   @(Get-CheckedItem -Rows $Ctx.Gui.Rows.Apps   | ForEach-Object { $_.id })

        Invoke-GuiWork -Label 'saving profile' -Work { Save-SetupProfile -SetupProfile $setupProfile -Path $target | Out-Null }
        $Ctx.Gui.Ui.ProfilePath.Text = $target
    })

    # Put the console back the way we found it.
    $window.Add_Closed({
        param($sender, $e)
        # The timer holds a reference to the dispatcher, so a running one keeps
        # the sampling going after the window is gone.
        if ($Ctx.Gui -and $Ctx.Gui.TaskTimer) { $Ctx.Gui.TaskTimer.Stop() }
        if ($Ctx.Gui) { $Ctx.Theme.Glyph = $Ctx.Gui.Glyphs }
        $Ctx.Gui = $null
        $Ctx.Sink = $null
        $Ctx.ProgressSink = $null
        $Ctx.ConfirmSink = $null
    })

    # ---- go ----------------------------------------------------------------
    Update-GuiOneClickSteps
    Update-GuiPackageRow
    Update-GuiCustomizationRow
    Update-GuiTweakRow
    Update-GuiAppRow
    Update-GuiToolboxRow
    Update-GuiGuideRow
    Update-GuiCsFolderText

    $ui.StatusText.Text = 'Ready'

    Write-Rule -Title 'Moscovium' -Suffix "v$($Ctx.Version)"
    Write-Info "$($Ctx.Tweaks.Count) tweaks, $($Ctx.Apps.Count) apps loaded."

    # No elevation notice: Show-Gui guarantees it, so saying so would be noise.
    if ($Ctx.DryRun) { Write-Warn 'Dry run - nothing will actually be changed.' }

    [pscustomobject]@{
        Window   = $window
        Ui       = $ui
        Rows     = $Ctx.Gui.Rows
        NavNames = $Ctx.Gui.NavNames
    }
}

function Show-Gui {
    param([hashtable]$BoundParameters = @{})

    # Elevated and STA or not at all - see Invoke-GuiRelaunch.
    if (Invoke-GuiRelaunch -BoundParameters $BoundParameters) { return 0 }

    try { Import-WpfAssembly }
    catch {
        Write-Err "WPF is not available on this machine: $($_.Exception.Message)"
        return 1
    }

    $gui = New-GuiWindow -BoundParameters $BoundParameters
    $gui.Window.ShowDialog() | Out-Null
    return 0
}

# Runs an engine call with the action buttons disabled and the progress bar
# live, so a long install cannot be started twice and the window still repaints.
function Invoke-GuiWork {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Work
    )

    if (-not $Ctx.Gui) { & $Work; return }

    $ui = $Ctx.Gui.Ui
    $buttons = @('BtnOneClick', 'BtnApply', 'BtnRevert', 'BtnInstall', 'BtnStoreInstall', 'BtnStoreRefresh', 'BtnRunProfile', 'BtnSaveProfile')
    foreach ($name in $buttons) { $ui[$name].IsEnabled = $false }

    $ui.StatusText.Text = $Label
    $ui.Progress.Visibility = 'Visible'
    $ui.Progress.IsIndeterminate = $true
    Invoke-UiEvents

    try { & $Work }
    catch { Write-Err $_.Exception.Message }
    finally {
        foreach ($name in $buttons) { $ui[$name].IsEnabled = $true }
        $ui.Progress.IsIndeterminate = $false
        $ui.Progress.Visibility = 'Hidden'
        $ui.StatusText.Text = 'Ready'
        Invoke-UiEvents
    }
}
