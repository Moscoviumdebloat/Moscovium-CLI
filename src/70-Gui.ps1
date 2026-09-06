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

# WPF cannot run on an MTA thread. powershell.exe is STA; pwsh is not, so a run
# started there is relaunched into an STA host rather than failing.
function Invoke-StaRelaunch {
    param([hashtable]$BoundParameters = @{})

    Write-Warn 'The GUI needs an STA thread, and this PowerShell host is running MTA.'

    $command = Get-RelaunchCommand -BoundParameters $BoundParameters
    $host51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    Write-Step 'Relaunching in an STA host'
    Write-Log "STA relaunch: $command"

    try {
        Start-Process -FilePath $host51 -ArgumentList @(
            '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-Command', $command
        ) -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-Err "Could not start an STA host: $($_.Exception.Message)"
        return $false
    }
}

# -----------------------------------------------------------------------------
# Small WPF helpers
# -----------------------------------------------------------------------------

# Console colours mapped onto the window's palette, so log output reads the same
# as it does in the terminal.
function ConvertTo-Brush {
    param($Color)

    $hex = switch ([string]$Color) {
        'Green'      { '#FF7BD88F' }
        'DarkGreen'  { '#FF5FA86F' }
        'Yellow'     { '#FFF0C674' }
        'DarkYellow' { '#FFD0A354' }
        'Red'        { '#FFF07178' }
        'DarkRed'    { '#FFC05058' }
        'Cyan'       { '#FF4FC3F7' }
        'DarkCyan'   { '#FF3A93BC' }
        'White'      { '#FFF4F4F8' }
        'Gray'       { '#FFC8C8D2' }
        'DarkGray'   { '#FF8E8E9C' }
        default      { '#FFE4E4EA' }
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

# Tints a row while its checkbox is ticked. Reached from $sender rather than a
# captured $border: CheckBox -> Grid -> Border.
function Set-GuiRowTint {
    param([Parameter(Mandatory)]$CheckBox)

    $border = $CheckBox.Parent.Parent
    if (-not $border) { return }

    if ($CheckBox.IsChecked -eq $true) {
        $border.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#FF17323C'))
    }
    else {
        $border.Background = [Windows.Media.Brushes]::Transparent
    }
}

# One row: a checkbox, a primary label, a secondary line, and a status chip.
# The catalog item rides along in .Tag so selection can be read back directly.
function New-GuiRow {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$Primary,
        [AllowEmptyString()][string]$Secondary = '',
        [AllowEmptyString()][string]$Status = '',
        [string]$StatusBrush = '#FF8E8E9C',
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
    if ($NoCheckBox) { $check.Visibility = 'Hidden' }

    # A tick is easy to lose in a list of 127, so tint the whole row.
    $check.Add_Checked({   param($sender, $e) Set-GuiRowTint -CheckBox $sender })
    $check.Add_Unchecked({ param($sender, $e) Set-GuiRowTint -CheckBox $sender })

    [Windows.Controls.Grid]::SetColumn($check, 0)
    $grid.Children.Add($check) | Out-Null

    $stack = New-Object Windows.Controls.StackPanel
    [Windows.Controls.Grid]::SetColumn($stack, 1)

    $title = New-Object Windows.Controls.TextBlock
    $title.Text = $Primary
    $title.Foreground = ConvertTo-Brush 'White'
    $title.FontSize = 13
    $stack.Children.Add($title) | Out-Null

    if ($Secondary) {
        $sub = New-Object Windows.Controls.TextBlock
        $sub.Text = $Secondary
        $sub.Foreground = ConvertTo-Brush 'DarkGray'
        $sub.FontSize = 11
        $sub.TextWrapping = 'Wrap'
        $sub.Margin = New-Object Windows.Thickness 0, 1, 0, 0
        $stack.Children.Add($sub) | Out-Null
    }

    $grid.Children.Add($stack) | Out-Null

    if ($Status) {
        $chip = New-Object Windows.Controls.TextBlock
        $chip.Text = $Status
        $chip.FontSize = 11
        $chip.VerticalAlignment = 'Center'
        $chip.Margin = New-Object Windows.Thickness 10, 0, 4, 0
        $chip.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($StatusBrush))
        [Windows.Controls.Grid]::SetColumn($chip, 2)
        $grid.Children.Add($chip) | Out-Null
    }

    $border.Child = $grid

    # Clicking anywhere on the row toggles it, not just the 13px checkbox.
    $border.Add_MouseLeftButtonUp({
        param($sender, $e)
        $box = $sender.Child.Children[0]
        if ($box.Visibility -eq 'Visible') { $box.IsChecked = -not $box.IsChecked }
    })

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

    foreach ($tweak in $Ctx.Tweaks) {
        if ($category -and $category -ne 'All categories' -and $tweak.category -ne $category) { continue }
        if ($search -and -not (
            (Test-NameMatch -Value $tweak.name -Pattern $search) -or
            (Test-NameMatch -Value $tweak.description -Pattern $search) -or
            (Test-NameMatch -Value $tweak.category -Pattern $search))) { continue }

        $status = Get-TweakStatus -Tweak $tweak
        $label, $brush = switch ($status) {
            'Applied' { 'applied', '#FF7BD88F' }
            'Partial' { 'partial', '#FFF0C674' }
            'Action'  { 'action',  '#FF4FC3F7' }
            default   { '',        '#FF8E8E9C' }
        }

        $row = New-GuiRow -Item $tweak -Primary $tweak.name -Secondary $tweak.description -Status $label -StatusBrush $brush
        $ui.TweakRows.Children.Add($row.Element) | Out-Null
        $built.Add($row)
    }

    $Ctx.Gui.Rows.Tweaks = @($built)
}

function Update-GuiAppRow {
    if (-not $Ctx.Gui) { return }
    $ui = $Ctx.Gui.Ui

    $ui.AppRows.Children.Clear()
    $built = [System.Collections.Generic.List[object]]::new()

    $search = [string]$ui.AppSearch.Text
    $category = [string]$ui.AppCategory.SelectedItem

    foreach ($app in $Ctx.Apps) {
        if ($category -and $category -ne 'All categories' -and $app.category -ne $category) { continue }
        if ($search -and -not (
            (Test-NameMatch -Value $app.name -Pattern $search) -or
            (Test-NameMatch -Value $app.id -Pattern $search) -or
            (Test-NameMatch -Value ([string]$app.description) -Pattern $search))) { continue }

        $how = if ($app.scriptUrl) { 'script' }
               elseif ($app.zipUrl) { 'archive' }
               elseif ($app.downloadUrl) { 'download' }
               else { 'winget' }

        $row = New-GuiRow -Item $app -Primary $app.name -Secondary ([string]$app.description) -Status $how -StatusBrush '#FF8E8E9C'
        $ui.AppRows.Children.Add($row.Element) | Out-Null
        $built.Add($row)
    }

    $Ctx.Gui.Rows.Apps = @($built)
}

function Update-GuiToolboxRow {
    if (-not $Ctx.Gui) { return }
    $ui = $Ctx.Gui.Ui

    $ui.ToolboxRows.Children.Clear()
    $built = [System.Collections.Generic.List[object]]::new()

    foreach ($action in Get-ToolboxActions) {
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

    $Ctx.Gui.Rows.Toolbox = @($built)
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
        'VersionText', 'CatalogChip', 'ElevChip', 'ElevChipBorder', 'DryRunToggle', 'BtnElevate',
        'NavList', 'TweaksPanel', 'AppsPanel', 'ToolboxPanel', 'ProfilesPanel',
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
        Rows      = [pscustomobject]@{ Tweaks = @(); Apps = @(); Toolbox = @() }
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

    # ---- header ------------------------------------------------------------
    $ui.VersionText.Text = "v$($Ctx.Version)"
    $ui.CatalogChip.Text = "$($Ctx.Tweaks.Count) tweaks   $($Ctx.Apps.Count) apps"

    if ($Ctx.IsAdmin) {
        $ui.ElevChip.Text = 'elevated'
        $ui.ElevChip.Foreground = ConvertTo-Brush 'Green'
        $ui.BtnElevate.Visibility = 'Collapsed'
    }
    else {
        $ui.ElevChip.Text = 'not elevated'
    }

    $ui.DryRunToggle.IsChecked = $Ctx.DryRun
    $ui.DryRunToggle.Add_Click({ param($sender, $e) $Ctx.DryRun = [bool]$sender.IsChecked })

    $ui.BtnElevate.Add_Click({
        param($sender, $e)
        if (Invoke-SelfElevate -BoundParameters $Ctx.Gui.Bound) { $Ctx.Gui.Window.Close() }
    })

    $ui.BtnClearLog.Add_Click({ if ($Ctx.Gui) { $Ctx.Gui.Paragraph.Inlines.Clear() } })

    # ---- navigation --------------------------------------------------------
    $ui.NavList.Add_SelectionChanged({
        param($sender, $e)
        if (-not $Ctx.Gui) { return }

        $panels = @($Ctx.Gui.Ui.TweaksPanel, $Ctx.Gui.Ui.AppsPanel, $Ctx.Gui.Ui.ToolboxPanel, $Ctx.Gui.Ui.ProfilesPanel)
        for ($i = 0; $i -lt $panels.Count; $i++) {
            $panels[$i].Visibility = if ($i -eq $sender.SelectedIndex) { 'Visible' } else { 'Collapsed' }
        }
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

    # ---- actions -----------------------------------------------------------
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
        if ($Ctx.Gui) { $Ctx.Theme.Glyph = $Ctx.Gui.Glyphs }
        $Ctx.Gui = $null
        $Ctx.Sink = $null
        $Ctx.ProgressSink = $null
        $Ctx.ConfirmSink = $null
    })

    # ---- go ----------------------------------------------------------------
    Update-GuiTweakRow
    Update-GuiAppRow
    Update-GuiToolboxRow

    $ui.StatusText.Text = 'Ready'

    Write-Rule -Title 'Moscovium' -Suffix "v$($Ctx.Version)"
    Write-Info "$($Ctx.Tweaks.Count) tweaks, $($Ctx.Apps.Count) apps loaded."
    if (-not $Ctx.IsAdmin) { Write-Warn 'Not elevated - machine-wide tweaks will be skipped.' }

    [pscustomobject]@{
        Window = $window
        Ui     = $ui
        Rows   = $Ctx.Gui.Rows
    }
}

function Show-Gui {
    param([hashtable]$BoundParameters = @{})

    if (-not (Test-StaApartment)) {
        if (Invoke-StaRelaunch -BoundParameters $BoundParameters) {
            Write-Ok 'GUI launched in a separate STA window.'
            return 0
        }
        return 1
    }

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
    $buttons = @('BtnApply', 'BtnRevert', 'BtnInstall', 'BtnRunProfile', 'BtnSaveProfile')
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
