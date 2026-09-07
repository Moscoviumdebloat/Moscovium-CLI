# =============================================================================
# Toolbox: the one-shot actions from the GUI's Optimizations, Toolbox and
# Legacy Menus pages.
#
# Several of these hand control to a third-party script fetched over the network.
# Those always print the URL and ask first, because running them is remote code
# execution with whatever privileges this process holds.
#
# Deliberately not ported from the GUI: the MAS activation bootstrap and the
# StartAllBack trial reset. Both exist to circumvent licensing. Everything else
# from those three pages is here.
# =============================================================================

$EmbeddedWinutilConfigJson = ''
$EmbeddedWinutilOneClickJson = ''
$EmbeddedRaphiOneClickJson = ''

function Get-ToolboxActions {
    @(
        [pscustomobject]@{
            Id = 'oneclick'; Name = 'One-click debloat box'; Admin = $true
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
    )
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
function Get-PresetConfigPath {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][string]$DataFile,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        $candidate = $null
        if ($PSScriptRoot) { $candidate = Join-Path $PSScriptRoot (Join-Path '..\data' $DataFile) }
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $Json = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8
        }
        else {
            throw "The $Label preset is not embedded in this build."
        }
    }

    Initialize-State
    $path = Join-Path $Ctx.StateDir $DataFile
    [IO.File]::WriteAllText($path, $Json, (New-Object Text.UTF8Encoding $false))
    return $path
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
    $winutilConfig = Get-WinutilOneClickPath
    $raphiConfig   = Get-RaphiOneClickPath

    $winutilCount = @((Get-Content -LiteralPath $winutilConfig -Raw -Encoding UTF8 | ConvertFrom-Json)).Count
    $raphiTweaks  = @((Get-Content -LiteralPath $raphiConfig -Raw -Encoding UTF8 | ConvertFrom-Json).Tweaks).Count

    Write-Line ''
    Write-Info 'The box runs six steps, in this order:'
    Write-Line "      1. WinUtil with $winutilCount tweaks preselected (christitus.com/win)" -Color White
    Write-Line "      2. Win11Debloat with $raphiTweaks tweaks, silent (debloat.raphi.re)" -Color White
    Write-Line '      3. Windows Update set to security-only' -Color White
    Write-Line '      4. TCP autotuning disabled' -Color White
    Write-Line '      5. Win32PrioritySeparation set to 22' -Color White
    Write-Line '      6. Dynamic tick disabled' -Color White
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
        $steps = @(
            @{ Name = 'WinUtil preset'; Action = {
                Invoke-RemoteScript -Url 'https://christitus.com/win' -Label 'WinUtil (one-click preset)' `
                    -ScriptArguments @('-Config', $winutilConfig)
            } }
            @{ Name = 'Win11Debloat preset'; Action = {
                Invoke-RemoteScript -Url 'https://debloat.raphi.re/' -Label 'Win11Debloat (one-click preset)' `
                    -ScriptArguments @('-Silent', '-Config', $raphiConfig)
            } }
            @{ Name = 'Windows Update security-only'; Action = { Set-SecurityUpdatePolicy; $true } }
            @{ Name = 'TCP autotuning'; Action = { Invoke-ToolboxStep -Id 'network-better' } }
            @{ Name = 'Win32PrioritySeparation'; Action = { Invoke-ToolboxStep -Id 'priority-22' } }
            @{ Name = 'Dynamic tick'; Action = { Invoke-ToolboxStep -Id 'dynamictick-off' } }
        )

        $number = 0
        foreach ($step in $steps) {
            $number++
            Write-Line ''
            Write-Rule -Title "Step $number of $($steps.Count) - $($step.Name)"

            try {
                if (-not (& $step.Action)) { $failed.Add($step.Name) }
            }
            catch {
                Write-Err "$($step.Name) - $($_.Exception.Message)"
                $failed.Add($step.Name)
            }
        }
    }
    finally {
        $Ctx.AssumeYes = $previousAssumeYes
    }

    Write-Line ''
    if ($failed.Count -eq 0) {
        Write-Ok 'All six steps finished.'
    }
    else {
        Write-Warn "$($failed.Count) of 6 steps did not complete: $(@($failed) -join ', ')"
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
            'mouse'         { Invoke-NativeCommand -FilePath 'control.exe' -Arguments @('main.cpl') -NoWait | Out-Null; Write-Ok 'Opened.' }
            'keyboard'      { Invoke-NativeCommand -FilePath 'control.exe' -Arguments @('keyboard') -NoWait | Out-Null; Write-Ok 'Opened.' }
            'sound'         { Invoke-NativeCommand -FilePath 'control.exe' -Arguments @('mmsys.cpl') -NoWait | Out-Null; Write-Ok 'Opened.' }

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
