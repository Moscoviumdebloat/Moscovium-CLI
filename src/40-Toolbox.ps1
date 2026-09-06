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
        [pscustomobject]@{
            Id = 'winutil'; Name = 'Chris Titus WinUtil'; Admin = $true
            Description = 'Opens the interactive WinUtil TUI (christitus.com/win).'
        }
        [pscustomobject]@{
            Id = 'winutil-auto'; Name = 'WinUtil (Moscovium preset)'; Admin = $true
            Description = 'Runs WinUtil unattended with the 15-tweak preset the GUI bundles.'
        }
        [pscustomobject]@{
            Id = 'raphi'; Name = 'Raphi Win11Debloat'; Admin = $true
            Description = 'Opens the interactive Win11Debloat menu (debloat.raphi.re).'
        }
        [pscustomobject]@{
            Id = 'raphi-auto'; Name = 'Raphi Win11Debloat (Moscovium preset)'; Admin = $true
            Description = 'Runs Win11Debloat unattended with the GUI''s 23-flag preset.'
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

# Fetches a remote script, shows the user where it came from, and runs it in
# this session after an explicit yes.
function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Label,
        [string[]]$ScriptArguments = @()
    )

    Write-Line ''
    Write-Warn "$Label runs a script published by a third party:"
    Write-Line "      $Url" -Color White
    if ($ScriptArguments.Count -gt 0) {
        Write-Info "arguments: $($ScriptArguments -join ' ')"
    }
    Write-Info 'Moscovium does not review or pin the contents of that script.'

    if (-not (Confirm-Action "Download and run it now?")) {
        Write-Warn "$Label - skipped."
        return
    }

    Write-Step "Fetching $Url"
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $text = Invoke-RestMethod -Uri $Url -TimeoutSec 120
    $block = [scriptblock]::Create($text)

    Write-Step "Running $Label"
    if ($ScriptArguments.Count -gt 0) { & $block @ScriptArguments } else { & $block }

    Write-Ok "$Label finished."
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
                Invoke-RemoteScript -Url 'https://christitus.com/win' -Label 'WinUtil'
            }

            'winutil-auto' {
                $config = Get-WinutilConfigPath
                Write-Info "preset: $config"
                Invoke-RemoteScript -Url 'https://christitus.com/win' -Label 'WinUtil (preset)' `
                    -ScriptArguments @('-Config', $config, '-Run')
            }

            'raphi' {
                Invoke-RemoteScript -Url 'https://debloat.raphi.re/' -Label 'Win11Debloat'
            }

            'raphi-auto' {
                Invoke-RemoteScript -Url 'https://debloat.raphi.re/' -Label 'Win11Debloat (preset)' `
                    -ScriptArguments (@('-RunDefaults') + (Get-RaphiPresetArguments))
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
