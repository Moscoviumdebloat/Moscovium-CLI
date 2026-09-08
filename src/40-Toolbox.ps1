# =============================================================================
# Toolbox: the one-shot actions from the GUI's Optimizations, Toolbox and
# Legacy Menus pages.
#
# Several of these hand control to a third-party script fetched over the network.
# Those always print the URL and ask first, because running them is remote code
# execution with whatever privileges this process holds.
#
# Everything from the GUI's three pages (Optimizations, Toolbox, Legacy Menus)
# is here. That now includes the MAS activation bootstrap and the StartAllBack
# trial reset that were originally left out - the user asked for them. MAS runs
# its upstream script over the network via Invoke-RemoteScript; the StartAllBack
# reset ships as a verbatim copy in data/startallback-trial-reset.ps1, embedded at
# build time, because fetching it fresh over irm | iex was not reliable enough.
# =============================================================================

$EmbeddedWinutilConfigJson = ''
$EmbeddedWinutilOneClickJson = ''
$EmbeddedRaphiOneClickJson = ''
$EmbeddedStartAllBackScript = ''

function Get-ToolboxActions {
    @(
        # Standalone: this one has its own front door - the GUI's landing page
        # and the CLI's first menu entry - so the toolbox lists leave it out
        # rather than burying it among the one-shot actions. Still addressable
        # as -Toolbox oneclick, and still shown by -List toolbox.
        [pscustomobject]@{
            Id = 'oneclick'; Name = 'One-click debloat box'; Admin = $true; Standalone = $true
            Description = 'The whole thing in one go: WinUtil preset, Win11Debloat preset, recommended Windows Update settings, TCP autotuning off, Win32PrioritySeparation 22, dynamic tick off.'
        }
        # The four below launch a third-party script in its own elevated window,
        # so they do not require Moscovium itself to be elevated first.
        [pscustomobject]@{
            Id = 'winutil'; Name = 'Chris Titus WinUtil'; Admin = $false
            Description = 'Opens the WinUtil GUI (christitus.com/win) in a new elevated window.'
        }
        [pscustomobject]@{
            Id = 'winutil-preset'; Name = 'WinUtil (Moscovium preset)'; Admin = $false
            Description = 'Opens WinUtil with the GUI''s 15 tweaks preselected. You still press Run Tweaks - WinUtil has no unattended mode.'
        }
        [pscustomobject]@{
            Id = 'raphi'; Name = 'Raphi Win11Debloat'; Admin = $false
            Description = 'Opens the interactive Win11Debloat menu (debloat.raphi.re).'
        }
        [pscustomobject]@{
            Id = 'raphi-auto'; Name = 'Raphi Win11Debloat (Moscovium preset)'; Admin = $false
            Description = 'Runs Win11Debloat unattended with the GUI''s 24-flag preset.'
        }
        [pscustomobject]@{
            Id = 'updates-security'; Name = 'Windows Update: security-only'; Admin = $true
            Description = 'Defers feature updates 365 days and quality updates 4 days, stops driver offers, and blocks reboots while you are signed in.'
        }
        [pscustomobject]@{
            Id = 'network-better'; Name = 'Network: disable TCP autotuning'; Admin = $true
            Description = 'Can help on flaky Wi-Fi. Reverse with network-default.'
        }
        [pscustomobject]@{
            Id = 'network-default'; Name = 'Network: restore TCP autotuning'; Admin = $true
            Description = 'Puts TCP autotuning back to normal.'
        }
        [pscustomobject]@{
            Id = 'dynamictick-off'; Name = 'Boot: disable dynamic tick'; Admin = $true
            Description = 'bcdedit /set disabledynamictick yes. Needs a reboot.'
        }
        [pscustomobject]@{
            Id = 'dynamictick-on'; Name = 'Boot: re-enable dynamic tick'; Admin = $true
            Description = 'Removes the override and restores the Windows default.'
        }
        [pscustomobject]@{
            Id = 'priority-22'; Name = 'CPU: Win32PrioritySeparation = 22'; Admin = $true
            Description = 'Favours the foreground app. Needs a reboot.'
        }
        [pscustomobject]@{
            Id = 'priority-default'; Name = 'CPU: Win32PrioritySeparation = 2'; Admin = $true
            Description = 'Restores the Windows default.'
        }
        [pscustomobject]@{
            Id = 'control-panel'; Name = 'Open: Control Panel'; Admin = $false
            Description = 'The classic Control Panel.'
        }
        [pscustomobject]@{
            Id = 'services'; Name = 'Open: Services'; Admin = $false
            Description = 'services.msc'
        }
        [pscustomobject]@{
            Id = 'device-manager'; Name = 'Open: Device Manager'; Admin = $false
            Description = 'devmgmt.msc, where a device with a problem code gets sorted out.'
        }
        [pscustomobject]@{
            Id = 'mouse'; Name = 'Open: Mouse properties'; Admin = $false
            Description = 'main.cpl, where mouse acceleration lives.'
        }
        [pscustomobject]@{
            Id = 'keyboard'; Name = 'Open: Keyboard properties'; Admin = $false
            Description = 'The classic keyboard repeat-rate dialog.'
        }
        [pscustomobject]@{
            Id = 'sound'; Name = 'Open: Sound control panel'; Admin = $false
            Description = 'mmsys.cpl, the classic playback/recording device list.'
        }
        [pscustomobject]@{
            Id = 'startallback-reset'; Name = 'StartAllBack: trial reset'; Admin = $false
            Description = 'Runs a bundled copy of Moscoviumdebloat/Moscovium''s StartAllBack.ps1 in its own window. Clears the per-user CLSID entries it leaves behind and restarts Explorer.'
        }
        [pscustomobject]@{
            Id = 'mas'; Name = 'Microsoft Activation Scripts (MAS)'; Admin = $false
            Description = 'Runs the Massgrave activation script (get.activated.win) in its own elevated window. Activates Windows and Office.'
        }
    )
}

# The actions that belong in a list of one-shot actions - everything without a
# front door of its own. Tested by property presence, not by value, because
# Set-StrictMode makes reading an absent property on the other entries throw.
function Get-ToolboxListActions {
    @(Get-ToolboxActions | Where-Object { -not $_.PSObject.Properties['Standalone'] })
}

function Resolve-ToolboxAction {
    param([Parameter(Mandatory)][string]$Id)

    $actions = Get-ToolboxActions

    $exact = @($actions | Where-Object { $_.Id -eq $Id })
    if ($exact.Count -eq 1) { return $exact[0] }

    $fuzzy = @($actions | Where-Object {
        (Test-NameMatch -Value $_.Id -Pattern $Id) -or (Test-NameMatch -Value $_.Name -Pattern $Id)
    })
    if ($fuzzy.Count -eq 1) { return $fuzzy[0] }

    if ($fuzzy.Count -gt 1) {
        Write-Err "'$Id' is ambiguous. Did you mean one of these?"
        foreach ($a in $fuzzy) { Write-Info $a.Id }
        return $null
    }

    Write-Err "Unknown toolbox action '$Id'. Run -List toolbox to see them all."
    return $null
}

# WinUtil prefers pwsh when it is installed; match that so the script behaves the
# same launched from here as launched by hand.
function Get-PowerShellHost {
    $pwsh = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

# Builds the canonical one-liner for a remote script: the exact command a user
# would paste. With no arguments that is `irm <url> | iex`; with arguments it is
# the script-block form, because iex cannot take parameters.
function New-RemoteScriptCommand {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string[]]$ScriptArguments = @(),
        [switch]$PauseOnError
    )

    $safeUrl = $Url -replace "'", "''"

    if (-not $ScriptArguments -or $ScriptArguments.Count -eq 0) {
        $invocation = "irm '$safeUrl' | iex"
    }
    else {
        # Switches pass through bare; values get quoted, since paths contain spaces.
        $rendered = foreach ($argument in $ScriptArguments) {
            if ($argument -match '^-[A-Za-z]') { $argument }
            else { "'" + ($argument -replace "'", "''") + "'" }
        }

        $invocation = "& ([scriptblock]::Create((irm '$safeUrl'))) $($rendered -join ' ')"
    }

    if (-not $PauseOnError) { return $invocation }

    # The window is launched without -NoExit so it closes as soon as the user
    # quits WinUtil or Win11Debloat. That would also make a script that fails
    # instantly flash past unread, so hold the window open on a terminating
    # error only - a normal quit throws nothing and closes straight away.
    #
    # Deliberately free of double quotes: this whole string is passed as one
    # -Command argument, and embedded quotes get mangled on the way through.
    $handler = "Write-Host ''; " +
               "Write-Host ('Moscovium: the script stopped with an error.') -ForegroundColor Red; " +
               "Write-Host (`$_.Exception.Message) -ForegroundColor Red; " +
               "Write-Host ''; " +
               "Read-Host 'Press Enter to close this window'"

    "try { $invocation } catch { $handler }"
}

# Runs a third-party script the way its authors document it: as `irm <url> | iex`
# in a *separate* PowerShell process, after showing the user the URL.
#
# It has to be a separate process, not `& ([scriptblock]::Create($text))` in this
# one. Three reasons, all of which broke WinUtil:
#
#   1. This bundle runs under Set-StrictMode -Version Latest and
#      $ErrorActionPreference = 'Stop'. Child scopes inherit both, and a
#      15,000-line WPF script is not written to survive either.
#   2. WinUtil calls a bare `break` when it decides to self-elevate. In-process
#      that unwinds into whatever loop we are running, including the menu loop.
#   3. WinUtil is a WPF application and wants its own host and console.
function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Label,
        [string[]]$ScriptArguments = @()
    )

    # Shown to the user: the command they would paste themselves. What actually
    # runs adds the error handler from New-RemoteScriptCommand -PauseOnError,
    # which changes nothing about what is fetched or executed.
    $shown = New-RemoteScriptCommand -Url $Url -ScriptArguments $ScriptArguments
    $command = New-RemoteScriptCommand -Url $Url -ScriptArguments $ScriptArguments -PauseOnError

    $elevation = if ($Ctx.IsAdmin) { 'elevated, as you already are' }
                 else { 'which will ask for administrator rights' }

    Write-Line ''
    Write-Warn "$Label runs a script published by a third party:"
    Write-Line "      $Url" -Color White
    Write-Info 'Moscovium does not review or pin the contents of that script.'
    Write-Line ''
    Write-Info "Runs in a new window ($elevation) as:"
    Write-Line "      $shown" -Color Gray
    Write-Info "The window closes when you quit $Label, or stays open if it fails."

    if (-not (Confirm-Action "Run it now?" -DefaultYes)) {
        Write-Warn "$Label - skipped."
        return $false
    }

    # No -NoExit: the window is meant to close as soon as the tool is quit.
    $start = @{
        FilePath     = Get-PowerShellHost
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command)
        Wait         = $true
        PassThru     = $true
        ErrorAction  = 'Stop'
    }
    # Already elevated: the child inherits it. Otherwise ask, rather than letting
    # the script discover it is unelevated and relaunch itself.
    if (-not $Ctx.IsAdmin) { $start.Verb = 'RunAs' }

    Write-Step "Launching $Label - this returns when you quit it"
    Write-Log "remote script: $command"

    $process = Start-Process @start

    if ($process -and $process.ExitCode -ne 0) {
        Write-Warn "$Label exited with code $($process.ExitCode)."
        return $false
    }

    Write-Ok "$Label closed."
    return $true
}

# Both WinUtil and Win11Debloat take a preset as a file path, so the embedded
# JSON has to be spilled to disk before either can be handed it. Running from a
# source checkout the literal is empty, so fall back to data/.
#
# UTF-8 without a BOM: Win11Debloat reads its config with ConvertFrom-Json,
# which chokes on a BOM in Windows PowerShell 5.1.
function Get-PresetJson {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][string]$DataFile,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not [string]::IsNullOrWhiteSpace($Json)) { return $Json }

    $candidate = $null
    if ($PSScriptRoot) { $candidate = Join-Path $PSScriptRoot (Join-Path '..\data' $DataFile) }
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
        return (Get-Content -LiteralPath $candidate -Raw -Encoding UTF8)
    }

    throw "The $Label preset is not embedded in this build."
}

function Get-PresetConfigPath {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][string]$DataFile,
        [Parameter(Mandatory)][string]$Label
    )

    $text = Get-PresetJson -Json $Json -DataFile $DataFile -Label $Label

    Initialize-State
    $path = Join-Path $Ctx.StateDir $DataFile
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
    return $path
}

# Runs the bundled, verbatim copy of the GUI's StartAllBack.ps1 in its own
# window - the same shape as Invoke-RemoteScript (show what runs, ask, launch
# elevated, wait for the window to close) but from a file already on disk
# rather than a live `irm | iex`, which proved unreliable for this one.
function Invoke-StartAllBackTrialReset {
    $scriptPath = Get-PresetConfigPath -Json $EmbeddedStartAllBackScript `
        -DataFile 'startallback-trial-reset.ps1' -Label 'StartAllBack trial reset'

    $elevation = if ($Ctx.IsAdmin) { 'elevated, as you already are' }
                 else { 'which will ask for administrator rights' }

    Write-Line ''
    Write-Warn 'StartAllBack: trial reset runs a script bundled from Moscoviumdebloat/Moscovium:'
    Write-Line '      StartAllBack.ps1' -Color White
    Write-Info 'It clears the per-user CLSID entries StartAllBack leaves behind, then offers to restart Explorer.'
    Write-Line ''
    Write-Info "Runs in a new window ($elevation) and will ask Y/N twice - once to begin, once to restart Explorer."
    Write-Info 'The window closes itself when the script finishes.'

    if (-not (Confirm-Action 'Run it now?' -DefaultYes)) {
        Write-Warn 'StartAllBack: trial reset - skipped.'
        return $false
    }

    # No -NoExit: the script closes its own window (SendKeys Alt+F4) when done.
    $start = @{
        FilePath     = Get-PowerShellHost
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
        Wait         = $true
        PassThru     = $true
        ErrorAction  = 'Stop'
    }
    if (-not $Ctx.IsAdmin) { $start.Verb = 'RunAs' }

    Write-Step 'Launching StartAllBack: trial reset - this returns when the window closes'
    Write-Log "embedded script: $scriptPath"

    $process = Start-Process @start

    if ($process -and $process.ExitCode -ne 0) {
        Write-Warn "StartAllBack: trial reset exited with code $($process.ExitCode)."
        return $false
    }

    Write-Ok 'StartAllBack: trial reset closed.'
    return $true
}

function Get-WinutilConfigPath {
    Get-PresetConfigPath -Json $EmbeddedWinutilConfigJson -DataFile 'winutil-debloat.json' -Label 'WinUtil'
}

function Get-WinutilOneClickPath {
    Get-PresetConfigPath -Json $EmbeddedWinutilOneClickJson -DataFile 'winutil-oneclick.json' -Label 'WinUtil one-click'
}

function Get-RaphiOneClickPath {
    Get-PresetConfigPath -Json $EmbeddedRaphiOneClickJson -DataFile 'raphi-oneclick.json' -Label 'Win11Debloat one-click'
}

# The six steps, as data. One source of truth: the CLI prints this before
# asking, the GUI's landing page draws it, and Invoke-OneClickDebloat walks it.
#
# Data only, deliberately - no script blocks. A block built here would go
# looking for this function's locals long after it had returned. See the note
# at the top of 70-Gui.ps1.
function Get-OneClickSteps {
    $winutil = Get-PresetJson -Json $EmbeddedWinutilOneClickJson -DataFile 'winutil-oneclick.json' -Label 'WinUtil one-click'
    $raphi   = Get-PresetJson -Json $EmbeddedRaphiOneClickJson -DataFile 'raphi-oneclick.json' -Label 'Win11Debloat one-click'

    $winutilCount = @(($winutil | ConvertFrom-Json)).Count
    $raphiCount   = @(($raphi | ConvertFrom-Json).Tweaks).Count

    @(
        [pscustomobject]@{
            Id = 'winutil'
            Title = "WinUtil with $winutilCount tweaks preselected"
            Detail = 'christitus.com/win - opens its window, and you press Run Tweaks'
        }
        [pscustomobject]@{
            Id = 'raphi'
            Title = "Win11Debloat with $raphiCount tweaks"
            Detail = 'debloat.raphi.re - silent, nothing to click. This is what removes Bing from search.'
        }
        [pscustomobject]@{
            Id = 'updates-security'
            Title = 'Windows Update set to security-only'
            Detail = 'Feature updates deferred 365 days, quality updates 4, no reboots while signed in'
        }
        [pscustomobject]@{
            Id = 'network-better'
            Title = 'TCP autotuning disabled'
            Detail = 'netsh int tcp set global autotuninglevel=disabled'
        }
        [pscustomobject]@{
            Id = 'priority-22'
            Title = 'Win32PrioritySeparation set to 22'
            Detail = 'Favours the foreground app. Needs a reboot.'
        }
        [pscustomobject]@{
            Id = 'dynamictick-off'
            Title = 'Dynamic tick disabled'
            Detail = 'bcdedit /set disabledynamictick yes. Needs a reboot.'
        }
    )
}

# The GUI's Raphi preset, kept in the same order for easy diffing.
function Get-RaphiPresetArguments {
    @(
        '-Silent', '-RemoveApps', '-RemoveGamingApps', '-DisableTelemetry',
        '-DisableBing', '-DisableSuggestions', '-DisableLockscreenTips',
        '-RevertContextMenu', '-TaskbarAlignLeft', '-HideSearchTb',
        '-DisableWidgets', '-DisableCopilot', '-ClearStartAllUsers',
        '-DisableDVR', '-DisableStartRecommended', '-ExplorerToThisPC',
        '-DisableMouseAcceleration', '-DisableDesktopSpotlight',
        '-DisableSettings365Ads', '-DisableSettingsHome',
        '-DisablePaintAI', '-DisableNotepadAI', '-DisableStickyKeys'
    )
}

# Windows Update, set to what WinUtil calls "Security" - the same policy values
# its Invoke-WPFUpdatessecurity writes.
#
# This is implemented here rather than pushed into the WinUtil preset because it
# cannot go in a preset: WPFUpdatessecurity is a Button, and WinUtil's config
# import only restores checkbox selections (Invoke-WPFImpex filters names to
# ^WPF(?:Install|Tweaks|Toggle|Feature|Appx) and hands them to the checkbox
# setter). A config naming it would be silently dropped.
function Set-SecurityUpdatePolicy {
    $updatePolicy = 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $autoUpdate   = "$updatePolicy\AU"

    # Undo a previous "disable updates" pass first, so this lands on a machine
    # that can still fetch security fixes.
    Write-Step 'Restoring Windows Update delivery'
    Remove-RegistryValue -Path $autoUpdate -Name 'NoAutoUpdate'
    Remove-RegistryValue -Path 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' -Name 'DODownloadMode'

    foreach ($pair in @(@('BITS', 'Manual'), @('wuauserv', 'Manual'), @('UsoSvc', 'Automatic'))) {
        try { Set-Service -Name $pair[0] -StartupType $pair[1] -ErrorAction Stop }
        catch { Write-Warn "Could not set the $($pair[0]) service to $($pair[1]) - $($_.Exception.Message)" }
    }
    try { Start-Service -Name 'UsoSvc' -ErrorAction Stop } catch { }

    $taskPaths = @(
        '\Microsoft\Windows\InstallService\*'
        '\Microsoft\Windows\UpdateOrchestrator\*'
        '\Microsoft\Windows\UpdateAssistant\*'
        '\Microsoft\Windows\WaaSMedic\*'
        '\Microsoft\Windows\WindowsUpdate\*'
        '\Microsoft\WindowsUpdate\*'
    )
    foreach ($taskPath in $taskPaths) {
        Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue |
            Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    }

    Write-Step 'Turning off driver offers through Windows Update'
    Set-RegistryValue -Path 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' `
        -Name 'PreventDeviceMetadataFromNetwork' -Type 'DWord' -Value 1

    $driverSearching = 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\DriverSearching'
    Set-RegistryValue -Path $driverSearching -Name 'DontPromptForWindowsUpdate' -Type 'DWord' -Value 1
    Set-RegistryValue -Path $driverSearching -Name 'DontSearchWindowsUpdate' -Type 'DWord' -Value 1
    Set-RegistryValue -Path $driverSearching -Name 'DriverUpdateWizardWuSearchEnabled' -Type 'DWord' -Value 0
    Set-RegistryValue -Path $updatePolicy -Name 'ExcludeWUDriversInQualityUpdate' -Type 'DWord' -Value 1

    Write-Step 'Deferring feature updates 365 days and quality updates 4 days'
    Set-RegistryValue -Path $updatePolicy -Name 'DeferFeatureUpdates' -Type 'DWord' -Value 1
    Set-RegistryValue -Path $updatePolicy -Name 'DeferFeatureUpdatesPeriodInDays' -Type 'DWord' -Value 365
    Set-RegistryValue -Path $updatePolicy -Name 'DeferQualityUpdates' -Type 'DWord' -Value 1
    Set-RegistryValue -Path $updatePolicy -Name 'DeferQualityUpdatesPeriodInDays' -Type 'DWord' -Value 4

    # The pre-policy UX settings would otherwise fight the policy values above.
    $legacySettings = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    foreach ($name in @('BranchReadinessLevel', 'DeferFeatureUpdatesPeriodInDays', 'DeferQualityUpdatesPeriodInDays')) {
        Remove-RegistryValue -Path $legacySettings -Name $name
    }

    Write-Step 'Blocking automatic restarts while you are signed in'
    # NoAutoRebootWithLoggedOnUsers only takes effect under AUOptions 4.
    Set-RegistryValue -Path $autoUpdate -Name 'AUOptions' -Type 'DWord' -Value 4
    Set-RegistryValue -Path $autoUpdate -Name 'NoAutoRebootWithLoggedOnUsers' -Type 'DWord' -Value 1
    Set-RegistryValue -Path $autoUpdate -Name 'AUPowerManagement' -Type 'DWord' -Value 0

    Write-Ok 'Windows Update set to security-only.'
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$NoWait
    )

    Write-Step "$FilePath $($Arguments -join ' ')"
    Write-Log "exec: $FilePath $($Arguments -join ' ')"

    if ($NoWait) {
        Start-Process -FilePath $FilePath -ArgumentList $Arguments -ErrorAction Stop | Out-Null
        return 0
    }

    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -NoNewWindow -ErrorAction Stop
    return $process.ExitCode
}

# The whole debloat pass, in order, behind one confirmation.
#
# Steps 1 and 2 hand control to a third-party script in its own window. Step 1
# is the one that is not unattended: WinUtil has no -Run switch, so the preset
# arrives with everything ticked and the user presses Run Tweaks. Step 2 is
# genuinely silent. Steps 3-6 are ours and run here.
function Invoke-OneClickDebloat {
    $steps = @(Get-OneClickSteps)

    Write-Line ''
    Write-Info "The box runs $($steps.Count) steps, in this order:"
    for ($i = 0; $i -lt $steps.Count; $i++) {
        Write-Line ("      {0}. {1}" -f ($i + 1), $steps[$i].Title) -Color White
        if ($steps[$i].Detail) { Write-Line "         $($steps[$i].Detail)" -Color DarkGray }
    }

    Write-Line ''
    Write-Warn 'Steps 1 and 2 are scripts published by third parties. Moscovium does not review or pin them.'
    Write-Warn 'Step 1 is not unattended: WinUtil has no -Run switch, so press Run Tweaks in its window.'
    Write-Info 'Both presets ask their script to take a restore point first.'
    Write-Info 'Steps 5 and 6 need a reboot before they take effect.'

    if (-not (Confirm-Action 'Run the whole box?' -DefaultYes)) {
        Write-Warn 'One-click debloat box - skipped.'
        return
    }

    # Already answered for the whole run; do not ask again per step. The URLs
    # were both listed above, so nothing new is being consented to.
    $previousAssumeYes = $Ctx.AssumeYes
    $Ctx.AssumeYes = $true

    $failed = [System.Collections.Generic.List[string]]::new()

    try {
        for ($i = 0; $i -lt $steps.Count; $i++) {
            $step = $steps[$i]

            Write-Line ''
            Write-Rule -Title ("Step {0} of {1} - {2}" -f ($i + 1), $steps.Count, $step.Title)

            try {
                $ok = switch ($step.Id) {
                    'winutil' {
                        Invoke-RemoteScript -Url 'https://christitus.com/win' -Label 'WinUtil (one-click preset)' `
                            -ScriptArguments @('-Config', (Get-WinutilOneClickPath))
                    }
                    'raphi' {
                        Invoke-RemoteScript -Url 'https://debloat.raphi.re/' -Label 'Win11Debloat (one-click preset)' `
                            -ScriptArguments @('-Silent', '-Config', (Get-RaphiOneClickPath))
                    }
                    'updates-security' { Set-SecurityUpdatePolicy; $true }
                    default { Invoke-ToolboxStep -Id $step.Id }
                }

                if (-not $ok) { $failed.Add($step.Title) }
            }
            catch {
                Write-Err "$($step.Title) - $($_.Exception.Message)"
                $failed.Add($step.Title)
            }
        }
    }
    finally {
        $Ctx.AssumeYes = $previousAssumeYes
    }

    Write-Line ''
    if ($failed.Count -eq 0) {
        Write-Ok "All $($steps.Count) steps finished."
    }
    else {
        Write-Warn "$($failed.Count) of $($steps.Count) steps did not complete: $(@($failed) -join ', ')"
    }
    Write-Info 'Reboot to pick up the priority and dynamic tick changes.'
}

# The local half of the box. Kept separate from Invoke-ToolboxAction so a step
# can report success or failure rather than swallowing it into a log line.
function Invoke-ToolboxStep {
    param([Parameter(Mandatory)][string]$Id)

    switch ($Id) {
        'network-better' {
            $code = Invoke-NativeCommand -FilePath 'netsh.exe' -Arguments @('int', 'tcp', 'set', 'global', 'autotuninglevel=disabled')
            if ($code -ne 0) { throw "netsh exited with code $code." }
            Write-Ok 'TCP autotuning disabled.'
            return $true
        }
        'priority-22' {
            Set-RegistryValue -Path 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\PriorityControl' `
                -Name 'Win32PrioritySeparation' -Type 'DWord' -Value 22
            Write-Ok 'Win32PrioritySeparation set to 22. Reboot to apply.'
            return $true
        }
        'dynamictick-off' {
            $code = Invoke-NativeCommand -FilePath 'bcdedit.exe' -Arguments @('/set', 'disabledynamictick', 'yes')
            if ($code -ne 0) { throw "bcdedit exited with code $code." }
            Write-Ok 'Dynamic tick disabled. Reboot to apply.'
            return $true
        }
        default { throw "No toolbox step '$Id'." }
    }
}

function Invoke-ToolboxAction {
    param([Parameter(Mandatory)][string]$Id)

    $action = Resolve-ToolboxAction -Id $Id
    if (-not $action) { return }

    # Dry run first: a preview should describe what an elevated run would do
    # rather than refuse because this process is not elevated. Matches the order
    # Invoke-TweakApply uses.
    if ($Ctx.DryRun) {
        Write-Status -Glyph (Get-Glyph 'Info') -Color (Get-Color 'Warn') -Message $action.Name -MessageColor (Get-Color 'Warn')
        Write-Info "would run toolbox action '$($action.Id)'"
        if ($action.Admin -and -not $Ctx.IsAdmin) { Write-Info 'needs administrator rights' }
        return
    }

    if ($action.Admin -and -not $Ctx.IsAdmin) {
        Write-Err "$($action.Name) needs administrator rights. Re-run from an elevated prompt, or let Moscovium relaunch itself."
        return
    }

    Write-SectionHeading $action.Name

    try {
        switch ($action.Id) {

            'winutil' {
                Invoke-RemoteScript -Url 'https://christitus.com/win' -Label 'WinUtil' | Out-Null
            }

            'winutil-preset' {
                $config = Get-WinutilConfigPath
                Write-Info "preset: $config"

                # -Config imports the selections into the GUI; there is no -Run
                # switch. The GUI passes one, which is why its "Automated" button
                # fails outright - WinUtil rejects the unknown parameter. This is
                # the same command WinUtil's own "copy config command" produces.
                Invoke-RemoteScript -Url 'https://christitus.com/win' -Label 'WinUtil (preset)' `
                    -ScriptArguments @('-Config', $config) | Out-Null
            }

            'raphi' {
                Invoke-RemoteScript -Url 'https://debloat.raphi.re/' -Label 'Win11Debloat' | Out-Null
            }

            'raphi-auto' {
                Invoke-RemoteScript -Url 'https://debloat.raphi.re/' -Label 'Win11Debloat (preset)' `
                    -ScriptArguments (@('-RunDefaults') + (Get-RaphiPresetArguments)) | Out-Null
            }

            'oneclick' { Invoke-OneClickDebloat }

            'updates-security' { Set-SecurityUpdatePolicy }

            'network-better' { Invoke-ToolboxStep -Id 'network-better' | Out-Null }

            'network-default' {
                $code = Invoke-NativeCommand -FilePath 'netsh.exe' -Arguments @('int', 'tcp', 'set', 'global', 'autotuninglevel=normal')
                if ($code -ne 0) { throw "netsh exited with code $code." }
                Write-Ok 'TCP autotuning restored to normal.'
            }

            'dynamictick-off' { Invoke-ToolboxStep -Id 'dynamictick-off' | Out-Null }

            'dynamictick-on' {
                $code = Invoke-NativeCommand -FilePath 'bcdedit.exe' -Arguments @('/deletevalue', 'disabledynamictick')
                # A missing value is not a failure; it means the tweak was never applied.
                if ($code -ne 0) { Write-Warn 'No override was set; dynamic tick was already at its default.' }
                else { Write-Ok 'Dynamic tick restored. Reboot to apply.' }
            }

            'priority-22' { Invoke-ToolboxStep -Id 'priority-22' | Out-Null }

            'priority-default' {
                Set-RegistryValue -Path 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\PriorityControl' `
                    -Name 'Win32PrioritySeparation' -Type 'DWord' -Value 2
                Write-Ok 'Win32PrioritySeparation restored to 2. Reboot to apply.'
            }

            'control-panel' { Invoke-NativeCommand -FilePath 'control.exe' -NoWait | Out-Null; Write-Ok 'Opened.' }
            'services'      { Invoke-NativeCommand -FilePath 'services.msc' -NoWait | Out-Null; Write-Ok 'Opened.' }
            'device-manager' { Invoke-NativeCommand -FilePath 'devmgmt.msc' -NoWait | Out-Null; Write-Ok 'Opened.' }
            'mouse'         { Invoke-NativeCommand -FilePath 'control.exe' -Arguments @('main.cpl') -NoWait | Out-Null; Write-Ok 'Opened.' }
            'keyboard'      { Invoke-NativeCommand -FilePath 'control.exe' -Arguments @('keyboard') -NoWait | Out-Null; Write-Ok 'Opened.' }
            'sound'         { Invoke-NativeCommand -FilePath 'control.exe' -Arguments @('mmsys.cpl') -NoWait | Out-Null; Write-Ok 'Opened.' }

            'startallback-reset' { Invoke-StartAllBackTrialReset | Out-Null }
            'mas' {
                Invoke-RemoteScript -Url 'https://get.activated.win' -Label 'Microsoft Activation Scripts (MAS)' | Out-Null
            }

            default { Write-Err "Toolbox action '$($action.Id)' has no implementation." }
        }
    }
    catch {
        Write-Err "$($action.Name) - $($_.Exception.Message)"
    }
}

function Show-ToolboxCatalog {
    Write-SectionHeading 'Toolbox actions'

    foreach ($action in Get-ToolboxActions) {
        Write-Line '  - ' -Color DarkGray -NoNewline
        Write-Line $action.Id.PadRight(20) -Color White -NoNewline
        Write-Line $action.Name -Color Gray
        Write-Info $action.Description
    }

    Write-Line ''
    Write-Info 'Run one with:  -Toolbox <id>'
}
