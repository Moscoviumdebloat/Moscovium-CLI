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

function Get-ToolboxActions {
    @(
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

function Get-WinutilConfigPath {
    $json = $EmbeddedWinutilConfigJson

    if ([string]::IsNullOrWhiteSpace($json)) {
        $candidate = $null
        if ($PSScriptRoot) { $candidate = Join-Path $PSScriptRoot '..\data\winutil-debloat.json' }
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $json = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8
        }
        else {
            throw 'The WinUtil preset is not embedded in this build.'
        }
    }

    Initialize-State
    $path = Join-Path $Ctx.StateDir 'winutil-debloat.json'
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding $false))
    return $path
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

function Invoke-ToolboxAction {
    param([Parameter(Mandatory)][string]$Id)

    $action = Resolve-ToolboxAction -Id $Id
    if (-not $action) { return }

    if ($action.Admin -and -not $Ctx.IsAdmin) {
        Write-Err "$($action.Name) needs administrator rights. Re-run from an elevated prompt, or let Moscovium relaunch itself."
        return
    }

    if ($Ctx.DryRun) {
        Write-Line '  . ' -Color DarkYellow -NoNewline
        Write-Line "$($action.Name)" -Color DarkYellow
        Write-Info "would run toolbox action '$($action.Id)'"
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

            'network-better' {
                $code = Invoke-NativeCommand -FilePath 'netsh.exe' -Arguments @('int', 'tcp', 'set', 'global', 'autotuninglevel=disabled')
                if ($code -ne 0) { throw "netsh exited with code $code." }
                Write-Ok 'TCP autotuning disabled.'
            }

            'network-default' {
                $code = Invoke-NativeCommand -FilePath 'netsh.exe' -Arguments @('int', 'tcp', 'set', 'global', 'autotuninglevel=normal')
                if ($code -ne 0) { throw "netsh exited with code $code." }
                Write-Ok 'TCP autotuning restored to normal.'
            }

            'dynamictick-off' {
                $code = Invoke-NativeCommand -FilePath 'bcdedit.exe' -Arguments @('/set', 'disabledynamictick', 'yes')
                if ($code -ne 0) { throw "bcdedit exited with code $code." }
                Write-Ok 'Dynamic tick disabled. Reboot to apply.'
            }

            'dynamictick-on' {
                $code = Invoke-NativeCommand -FilePath 'bcdedit.exe' -Arguments @('/deletevalue', 'disabledynamictick')
                # A missing value is not a failure; it means the tweak was never applied.
                if ($code -ne 0) { Write-Warn 'No override was set; dynamic tick was already at its default.' }
                else { Write-Ok 'Dynamic tick restored. Reboot to apply.' }
            }

            'priority-22' {
                Set-RegistryValue -Path 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\PriorityControl' `
                    -Name 'Win32PrioritySeparation' -Type 'DWord' -Value 22
                Write-Ok 'Win32PrioritySeparation set to 22. Reboot to apply.'
            }

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
