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
# works from `irm ... | iex`. Two constraints come with that:
#
#   - WPF requires an STA thread. powershell.exe is STA, but pwsh is MTA by
#     default, so an MTA host is relaunched into an STA one.
#   - Rows are built as real controls rather than data-bound. Binding to
#     PSCustomObject works, but writing back through the PSObject adapter is
#     fiddly enough that explicit controls are the more predictable choice.
#
# The XAML is ASCII only, like the rest of src/.
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
        'Green'     { '#FF7BD88F' }
        'DarkGreen' { '#FF5FA86F' }
        'Yellow'    { '#FFF0C674' }
        'DarkYellow'{ '#FFD0A354' }
        'Red'       { '#FFF07178' }
        'DarkRed'   { '#FFC05058' }
        'Cyan'      { '#FF4FC3F7' }
        'DarkCyan'  { '#FF3A93BC' }
        'White'     { '#FFF4F4F8' }
        'Gray'      { '#FFC8C8D2' }
        'DarkGray'  { '#FF8E8E9C' }
        default     { '#FFE4E4EA' }
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

    # Tint the row while it is ticked - the checkbox alone is easy to lose in
    # a list of 127.
    $check.Add_Checked({   $border.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString("#FF17323C")) }.GetNewClosure())
    $check.Add_Unchecked({ $border.Background = [Windows.Media.Brushes]::Transparent }.GetNewClosure())

    $border.Child = $grid
    # Clicking anywhere on the row toggles it, not just the 13px checkbox.
    $border.Add_MouseLeftButtonUp({
        param($sender, $e)
        $box = $sender.Child.Children[0]
        if ($box.Visibility -eq 'Visible') { $box.IsChecked = -not $box.IsChecked }
    }.GetNewClosure())

    [pscustomobject]@{ Element = $border; CheckBox = $check; Item = $Item }
}

function Get-CheckedItem {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
    @($Rows | Where-Object { $_.CheckBox.IsChecked -eq $true } | ForEach-Object { $_.Item })
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
    # Track the pane width: wide enough that rules and status lines never wrap,
    # without the permanent horizontal scrollbar a fixed width would cause.
    $document.PageWidth = 900
    $paragraph = New-Object Windows.Documents.Paragraph
    $paragraph.Margin = New-Object Windows.Thickness 0
    $paragraph.LineHeight = 15
    $document.Blocks.Add($paragraph)
    $ui.LogBox.Document = $document
    $ui.LogBox.Add_SizeChanged({
        param($sender, $e)
        $document.PageWidth = [Math]::Max(600, $sender.ActualWidth - 24)
    }.GetNewClosure())

    $logState = [pscustomobject]@{ Paragraph = $paragraph; Box = $ui.LogBox }

    # The console glyph set may have fallen back to ASCII because conhost cannot
    # encode box drawing. WPF has no such problem, so the log pane always gets
    # the good glyphs. Stashed so closing the window leaves the console as it was.
    $previousGlyphs = $Ctx.Theme.Glyph
    $Ctx.Theme.Glyph = New-GlyphSet -Unicode $true

    # Redirecting Write-Line is what lets every engine function report into the
    # window without knowing the window exists.
    $Ctx.Sink = {
        param($text, $color, $newline)

        $run = New-Object Windows.Documents.Run ([string]$text)
        if ($color) { $run.Foreground = ConvertTo-Brush $color }
        $logState.Paragraph.Inlines.Add($run)
        if ($newline) { $logState.Paragraph.Inlines.Add((New-Object Windows.Documents.LineBreak)) }

        $logState.Box.ScrollToEnd()
        Invoke-UiEvents
    }.GetNewClosure()

    $Ctx.ProgressSink = {
        param($label, $fraction, $detail)

        $ui.Progress.Visibility = 'Visible'
        if ($fraction -lt 0) {
            $ui.Progress.IsIndeterminate = $true
        }
        else {
            $ui.Progress.IsIndeterminate = $false
            $ui.Progress.Value = [Math]::Round($fraction * 100)
        }

        $ui.StatusText.Text = if ($detail) { "$label   $detail" } else { [string]$label }
        Invoke-UiEvents
    }.GetNewClosure()

    $Ctx.ConfirmSink = {
        param($message, $defaultYes)

        $default = if ($defaultYes) { [Windows.MessageBoxResult]::Yes } else { [Windows.MessageBoxResult]::No }
        $answer = [Windows.MessageBox]::Show($window, [string]$message, 'Moscovium',
            [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question, $default)

        return ($answer -eq [Windows.MessageBoxResult]::Yes)
    }.GetNewClosure()

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
    $ui.DryRunToggle.Add_Click({ $Ctx.DryRun = [bool]$ui.DryRunToggle.IsChecked }.GetNewClosure())

    $ui.BtnElevate.Add_Click({
        if (Invoke-SelfElevate -BoundParameters $BoundParameters) { $window.Close() }
    }.GetNewClosure())

    $ui.BtnClearLog.Add_Click({ $logState.Paragraph.Inlines.Clear() }.GetNewClosure())

    # ---- navigation --------------------------------------------------------
    $panels = @($ui.TweaksPanel, $ui.AppsPanel, $ui.ToolboxPanel, $ui.ProfilesPanel)
    $ui.NavList.Add_SelectionChanged({
        for ($i = 0; $i -lt $panels.Count; $i++) {
            $panels[$i].Visibility = if ($i -eq $ui.NavList.SelectedIndex) { 'Visible' } else { 'Collapsed' }
        }
    }.GetNewClosure())

    # ---- rows --------------------------------------------------------------
    $rows = [pscustomobject]@{ Tweaks = @(); Apps = @(); Toolbox = @() }

    $buildTweaks = {
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

        $rows.Tweaks = @($built)
        $ui.StatusText.Text = "$($built.Count) tweak(s) shown"
    }.GetNewClosure()

    $buildApps = {
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

        $rows.Apps = @($built)
        $ui.StatusText.Text = "$($built.Count) app(s) shown"
    }.GetNewClosure()

    $buildToolbox = {
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
                Invoke-GuiWork -Ui $ui -Label "toolbox: $id" -Work { Invoke-ToolboxAction -Id $id }.GetNewClosure()
            }.GetNewClosure())
            $row.Element.Child.Children.Add($run) | Out-Null

            $ui.ToolboxRows.Children.Add($row.Element) | Out-Null
            $built.Add($row)
        }

        $rows.Toolbox = @($built)
    }.GetNewClosure()

    # ---- filters -----------------------------------------------------------
    $ui.TweakCategory.Items.Add('All categories') | Out-Null
    foreach ($c in $Ctx.TweakCategories) { $ui.TweakCategory.Items.Add($c) | Out-Null }
    $ui.TweakCategory.SelectedIndex = 0

    $ui.AppCategory.Items.Add('All categories') | Out-Null
    foreach ($c in $Ctx.AppCategories) { $ui.AppCategory.Items.Add($c) | Out-Null }
    $ui.AppCategory.SelectedIndex = 0

    $ui.TweakSearch.Add_TextChanged($buildTweaks)
    $ui.TweakCategory.Add_SelectionChanged($buildTweaks)
    $ui.AppSearch.Add_TextChanged($buildApps)
    $ui.AppCategory.Add_SelectionChanged($buildApps)

    $ui.BtnTweakAll.Add_Click({ foreach ($r in $rows.Tweaks) { $r.CheckBox.IsChecked = $true } }.GetNewClosure())
    $ui.BtnTweakNone.Add_Click({ foreach ($r in $rows.Tweaks) { $r.CheckBox.IsChecked = $false } }.GetNewClosure())
    $ui.BtnAppNone.Add_Click({ foreach ($r in $rows.Apps) { $r.CheckBox.IsChecked = $false } }.GetNewClosure())

    # ---- actions -----------------------------------------------------------
    $ui.BtnApply.Add_Click({
        $selected = Get-CheckedItem -Rows $rows.Tweaks
        if ($selected.Count -eq 0) { $ui.StatusText.Text = 'Nothing selected.'; return }
        Invoke-GuiWork -Ui $ui -Label 'applying tweaks' -Work { Invoke-Tweaks -Tweaks $selected -Mode Apply }.GetNewClosure()
        & $buildTweaks
    }.GetNewClosure())

    $ui.BtnRevert.Add_Click({
        $selected = Get-CheckedItem -Rows $rows.Tweaks
        if ($selected.Count -eq 0) { $ui.StatusText.Text = 'Nothing selected.'; return }
        Invoke-GuiWork -Ui $ui -Label 'reverting tweaks' -Work { Invoke-Tweaks -Tweaks $selected -Mode Revert }.GetNewClosure()
        & $buildTweaks
    }.GetNewClosure())

    $ui.BtnInstall.Add_Click({
        $selected = Get-CheckedItem -Rows $rows.Apps
        if ($selected.Count -eq 0) { $ui.StatusText.Text = 'Nothing selected.'; return }
        Invoke-GuiWork -Ui $ui -Label 'installing apps' -Work { Invoke-AppInstall -Apps $selected }.GetNewClosure()
    }.GetNewClosure())

    # ---- profiles ----------------------------------------------------------
    $ui.BtnBrowseProfile.Add_Click({
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Moscovium profile (*.json)|*.json|All files (*.*)|*.*'
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $ui.ProfilePath.Text = $dialog.FileName }
    }.GetNewClosure())

    $ui.BtnRunProfile.Add_Click({
        $path = [string]$ui.ProfilePath.Text
        if (-not $path) { $ui.StatusText.Text = 'Choose a profile first.'; return }
        Invoke-GuiWork -Ui $ui -Label 'running profile' -Work { Invoke-SetupProfile -Path $path }.GetNewClosure()
        & $buildTweaks
    }.GetNewClosure())

    $ui.BtnSaveProfile.Add_Click({
        $dialog = New-Object Windows.Forms.SaveFileDialog
        $dialog.Filter = 'Moscovium profile (*.json)|*.json'
        $dialog.FileName = 'moscovium-profile.json'
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }

        $target = $dialog.FileName
        $setupProfile = New-SetupProfile `
            -Tweaks @(Get-CheckedItem -Rows $rows.Tweaks | ForEach-Object { $_.name }) `
            -Apps   @(Get-CheckedItem -Rows $rows.Apps   | ForEach-Object { $_.id })

        Invoke-GuiWork -Ui $ui -Label 'saving profile' -Work {
            Save-SetupProfile -SetupProfile $setupProfile -Path $target | Out-Null
        }.GetNewClosure()

        $ui.ProfilePath.Text = $target
    }.GetNewClosure())

    # ---- go ----------------------------------------------------------------
    & $buildTweaks
    & $buildApps
    & $buildToolbox

    $ui.StatusText.Text = 'Ready'

    Write-Rule -Title 'Moscovium' -Suffix "v$($Ctx.Version)"
    Write-Info "$($Ctx.Tweaks.Count) tweaks, $($Ctx.Apps.Count) apps loaded."
    if (-not $Ctx.IsAdmin) { Write-Warn 'Not elevated - machine-wide tweaks will be skipped.' }

    # Put the sinks back so anything running after the window closes reports to
    # the console again.
    $window.Add_Closed({
        $Ctx.Sink = $null
        $Ctx.ProgressSink = $null
        $Ctx.ConfirmSink = $null
        $Ctx.Theme.Glyph = $previousGlyphs
    }.GetNewClosure())

    [pscustomobject]@{
        Window  = $window
        Ui      = $ui
        Rows    = $rows
        Refresh = $buildTweaks
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
        [Parameter(Mandatory)][hashtable]$Ui,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Work
    )

    $buttons = @('BtnApply', 'BtnRevert', 'BtnInstall', 'BtnRunProfile', 'BtnSaveProfile')
    foreach ($name in $buttons) { $Ui[$name].IsEnabled = $false }

    $Ui.StatusText.Text = $Label
    $Ui.Progress.Visibility = 'Visible'
    $Ui.Progress.IsIndeterminate = $true
    Invoke-UiEvents

    try { & $Work }
    catch { Write-Err $_.Exception.Message }
    finally {
        foreach ($name in $buttons) { $Ui[$name].IsEnabled = $true }
        $Ui.Progress.IsIndeterminate = $false
        $Ui.Progress.Visibility = 'Hidden'
        $Ui.StatusText.Text = 'Ready'
        Invoke-UiEvents
    }
}
