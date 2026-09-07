# =============================================================================
# Argument dispatch.
#
# Reads everything out of the caller's $PSBoundParameters rather than declaring
# its own variables, so nothing here shadows an automatic variable like $Profile
# and the elevation relaunch can replay the exact invocation.
# =============================================================================

function Show-Help {
    Write-Line ''
    Write-Line '  Moscovium CLI' -Color Cyan
    Write-Line "  v$($Ctx.Version) - Windows debloat and setup toolbox" -Color DarkGray
    Write-Line ''
    Write-Line '  USAGE' -Color White
    Write-Line '    irm moscovium.win | iex                       interactive menu' -Color Gray
    Write-Line '    & ([scriptblock]::Create((irm moscovium.win))) -Status' -Color Gray
    Write-Line '    .\moscovium.ps1 -Apply "Disable Telemetry"' -Color Gray
    Write-Line ''
    Write-Line '  TWEAKS' -Color White
    Write-Line '    -Apply   <names>   apply tweaks by name, category, wildcard, or "all"' -Color Gray
    Write-Line '    -Revert  <names>   restore what those tweaks changed, from the undo snapshot' -Color Gray
    Write-Line '    -Status            show which tweaks are currently applied' -Color Gray
    Write-Line ''
    Write-Line '  APPS' -Color White
    Write-Line '    -Install <names>   install apps by name, id, category, or "all"' -Color Gray
    Write-Line '    -UpgradeAll        winget upgrade --all' -Color Gray
    Write-Line '    -VCRuntimes        install the Visual C++ redistributables' -Color Gray
    Write-Line '    -WindowsUpdate     install pending Windows updates via PSWindowsUpdate' -Color Gray
    Write-Line ''
    Write-Line '  OTHER' -Color White
    Write-Line '    -Gui               open the graphical interface' -Color Gray
    Write-Line '    -Tasks             live task manager: CPU, memory, disk, network, processes' -Color Gray
    Write-Line '    -Toolbox <id>      run a toolbox action (see -List toolbox)' -Color Gray
    Write-Line '    -Profile <path>    run a saved setup profile' -Color Gray
    Write-Line '    -SaveProfile <path>  write the current -Apply/-Install selection as a profile' -Color Gray
    Write-Line '    -List <what>       list tweaks, apps, toolbox, or backups' -Color Gray
    Write-Line '    -Search <term>     search tweaks and apps' -Color Gray
    Write-Line ''
    Write-Line '  FLAGS' -Color White
    Write-Line '    -DryRun            print what would happen, change nothing' -Color Gray
    Write-Line '    -Yes               skip confirmation prompts' -Color Gray
    Write-Line '    -Elevate           relaunch elevated straight away' -Color Gray
    Write-Line '    -NoColor           plain output' -Color Gray
    Write-Line '    -Ascii             ASCII glyphs instead of box drawing' -Color Gray
    Write-Line '    -NoBanner          skip the banner' -Color Gray
    Write-Line '    -Help              this text' -Color Gray
    Write-Line ''
    Write-Line '  EXAMPLES' -Color White
    Write-Line '    -Apply "Privacy & Telemetry" -DryRun     preview a whole category' -Color Gray
    Write-Line '    -Apply all -Yes                          apply everything, no prompts' -Color Gray
    Write-Line '    -Install Browsers,7zip,"VLC*"            mix categories, ids and wildcards' -Color Gray
    Write-Line '    -Revert "Dark Theme"                     undo one tweak' -Color Gray
    Write-Line ''
    Write-Info "State and undo snapshots live in $($Ctx.StateDir)"
    Write-Line ''
}

function Show-TweakCatalog {
    param([string]$Filter)

    foreach ($category in $Ctx.TweakCategories) {
        $inCategory = @($Ctx.Tweaks | Where-Object {
            $_.category -eq $category -and (
                -not $Filter -or
                (Test-NameMatch -Value $_.name -Pattern $Filter) -or
                (Test-NameMatch -Value $_.description -Pattern $Filter)
            )
        })

        if ($inCategory.Count -eq 0) { continue }

        Write-SectionHeading "$category ($($inCategory.Count))"

        foreach ($tweak in $inCategory) {
            Write-Line '  - ' -Color DarkGray -NoNewline
            Write-Line $tweak.name -Color White
            Write-Info $tweak.description

            if ($tweak.kind -ne 'Registry') { Write-Info "action: $($tweak.kind) (not reversible)" }
        }
    }
}

function Show-Backups {
    $backups = @(Get-BackupRecords)

    Write-SectionHeading 'Undo snapshots'

    if ($backups.Count -eq 0) {
        Write-Info "None yet. They are written to $($Ctx.BackupDir) each time tweaks are applied."
        return
    }

    foreach ($backup in $backups) {
        $names = @($backup.Record.entries.PSObject.Properties | ForEach-Object { $_.Name })
        Write-Line '  - ' -Color DarkGray -NoNewline
        Write-Line (Split-Path -Leaf $backup.File) -Color White
        Write-Info "$($backup.Record.createdUtc)  |  $($names.Count) tweak(s)"
        Format-Columns -Items $names -Indent 6
    }
}

function Invoke-Search {
    param([Parameter(Mandatory)][string]$Term)

    $tweaks = @($Ctx.Tweaks | Where-Object {
        (Test-NameMatch -Value $_.name -Pattern $Term) -or
        (Test-NameMatch -Value $_.description -Pattern $Term) -or
        (Test-NameMatch -Value $_.category -Pattern $Term)
    })

    $apps = @($Ctx.Apps | Where-Object {
        (Test-NameMatch -Value $_.name -Pattern $Term) -or
        (Test-NameMatch -Value $_.id -Pattern $Term) -or
        (Test-NameMatch -Value ([string]$_.description) -Pattern $Term) -or
        (Test-NameMatch -Value $_.category -Pattern $Term)
    })

    if ($tweaks.Count -eq 0 -and $apps.Count -eq 0) {
        Write-Warn "Nothing matches '$Term'."
        return
    }

    if ($tweaks.Count -gt 0) {
        Write-SectionHeading "Tweaks matching '$Term' ($($tweaks.Count))"
        foreach ($tweak in $tweaks) {
            Write-Line '  - ' -Color DarkGray -NoNewline
            Write-Line $tweak.name.PadRight(40) -Color White -NoNewline
            Write-Line $tweak.category -Color DarkGray
        }
    }

    if ($apps.Count -gt 0) {
        Write-SectionHeading "Apps matching '$Term' ($($apps.Count))"
        foreach ($app in $apps) {
            Write-Line '  - ' -Color DarkGray -NoNewline
            Write-Line $app.name.PadRight(40) -Color White -NoNewline
            Write-Line $app.id -Color DarkGray
        }
    }
}

function Invoke-List {
    param([string[]]$What)

    if (-not $What -or $What.Count -eq 0) { $What = @('tweaks', 'apps', 'toolbox') }

    foreach ($item in $What) {
        switch -Regex ($item.Trim()) {
            '^tweaks?$'   { Show-TweakCatalog }
            '^apps?$'     { Show-AppCatalog }
            '^toolbox$'   { Show-ToolboxCatalog }
            '^backups?$'  { Show-Backups }
            '^guides?$'   { Show-GuideCatalog }
            '^store$'     { Show-StoreCatalog }
            '^categor'    {
                Write-SectionHeading 'Tweak categories'
                Format-Columns -Items $Ctx.TweakCategories
                Write-SectionHeading 'App categories'
                Format-Columns -Items $Ctx.AppCategories
            }
            default {
                Write-Err "Don't know how to list '$item'. Try: tweaks, apps, toolbox, backups, categories."
            }
        }
    }
}

# Reports names that matched nothing, so a typo never silently does less than
# the user asked for.
function Write-UnknownNames {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Unknown, [Parameter(Mandatory)][string]$Kind)

    foreach ($name in $Unknown) {
        Write-Warn "No $Kind matches '$name'."
    }
}

# Returns a bound multi-value parameter as an array, or an empty array when it
# was not supplied.
function Get-BoundArray {
    param([Parameter(Mandatory)][hashtable]$Bound, [Parameter(Mandatory)][string]$Key)
    if ($Bound.ContainsKey($Key)) { return @($Bound[$Key]) }
    return @()
}

function Invoke-Main {
    param([Parameter(Mandatory)][hashtable]$Bound)

    $has = { param($name) $Bound.ContainsKey($name) }

    if (& $has 'Help') { Show-Help; return 0 }

    if (& $has 'Version') {
        # The build id answers "am I running the copy with the fix, or a cached
        # one?" - the question a single-file irm tool provokes constantly.
        if ($Ctx.BuildStamp) { Write-Line "$($Ctx.Version)  build $($Ctx.BuildStamp)" }
        else { Write-Line $Ctx.Version }
        return 0
    }

    Initialize-Catalog

    # After the catalog, so the banner can show what is in it.
    if (-not $Bound.ContainsKey('NoBanner')) { Write-Banner }

    # Actions that change the machine; anything else can run unelevated.
    $mutating = @('Apply', 'Revert', 'Install', 'Toolbox', 'Profile', 'UpgradeAll', 'WindowsUpdate', 'VCRuntimes')
    $wantsChange = @($mutating | Where-Object { $Bound.ContainsKey($_) }).Count -gt 0

    if ((& $has 'Elevate') -or ($wantsChange -and -not $Ctx.IsAdmin -and -not $Ctx.DryRun)) {
        # Strip -Elevate so the child does not try to elevate again.
        $forward = @{}
        foreach ($key in $Bound.Keys) { if ($key -ne 'Elevate') { $forward[$key] = $Bound[$key] } }

        if (Invoke-SelfElevate -BoundParameters $forward) { return 0 }
        Write-Line ''
    }

    if (& $has 'Gui') { return (Show-Gui -BoundParameters $Bound) }

    # Its own screen, like the GUI: it takes over the console until you leave it,
    # so it does not combine with the one-shot actions below. With output
    # redirected it prints a single snapshot instead.
    if (& $has 'Tasks') { Show-TaskManager; return 0 }

    $didSomething = $false

    if (& $has 'List')   { Invoke-List -What $Bound['List']; $didSomething = $true }
    if (& $has 'Search') { Invoke-Search -Term $Bound['Search']; $didSomething = $true }
    if (& $has 'Status') { Show-TweakStatus; $didSomething = $true }

    if (& $has 'Apply') {
        $resolved = Resolve-Tweak -Names $Bound['Apply']
        Write-UnknownNames -Unknown $resolved.Unknown -Kind 'tweak'

        if ($resolved.Matched.Count -gt 0) {
            $proceed = $Ctx.DryRun -or $Ctx.AssumeYes -or
                (Confirm-Action "Apply $($resolved.Matched.Count) tweak(s)?" -DefaultYes)
            if ($proceed) { Invoke-Tweaks -Tweaks $resolved.Matched -Mode Apply }
        }
        $didSomething = $true
    }

    if (& $has 'Revert') {
        $resolved = Resolve-Tweak -Names $Bound['Revert']
        Write-UnknownNames -Unknown $resolved.Unknown -Kind 'tweak'

        if ($resolved.Matched.Count -gt 0) {
            $proceed = $Ctx.DryRun -or $Ctx.AssumeYes -or
                (Confirm-Action "Revert $($resolved.Matched.Count) tweak(s)?" -DefaultYes)
            if ($proceed) { Invoke-Tweaks -Tweaks $resolved.Matched -Mode Revert }
        }
        $didSomething = $true
    }

    if (& $has 'VCRuntimes') { Install-VCRuntimes; $didSomething = $true }

    if (& $has 'Install') {
        $resolved = Resolve-App -Names $Bound['Install']
        Write-UnknownNames -Unknown $resolved.Unknown -Kind 'app'

        if ($resolved.Matched.Count -gt 0) {
            $proceed = $Ctx.DryRun -or $Ctx.AssumeYes -or
                (Confirm-Action "Install $($resolved.Matched.Count) app(s)?" -DefaultYes)
            if ($proceed) { Invoke-AppInstall -Apps $resolved.Matched }
        }
        $didSomething = $true
    }

    if (& $has 'Guide') {
        $resolved = Resolve-Guide -Names $Bound['Guide']
        Write-UnknownNames -Unknown $resolved.Unknown -Kind 'guide'
        Show-Guide -Guides $resolved.Matched
        $didSomething = $true
    }

    if (& $has 'SetSetting') {
        foreach ($pair in @($Bound['SetSetting'])) {
            $split = ([string]$pair).Split('=', 2)
            if ($split.Count -ne 2) { Write-Err "Expected Name=Value, got '$pair'."; continue }
            Set-MoscoviumSetting -Name $split[0].Trim() -Value $split[1].Trim()
        }
        $didSomething = $true
    }

    if (& $has 'Toolbox')       { Invoke-ToolboxAction -Id $Bound['Toolbox']; $didSomething = $true }
    if (& $has 'Profile')       { Invoke-SetupProfile -Path $Bound['Profile']; $didSomething = $true }
    if (& $has 'UpgradeAll')    { Invoke-UpgradeAll; $didSomething = $true }
    if (& $has 'WindowsUpdate') { Invoke-WindowsUpdate; $didSomething = $true }

    if (& $has 'SaveProfile') {
        # Store what the names resolved to, not the names themselves. A profile
        # saved from -Install Browsers has to list the nine package ids, because
        # the desktop app reads these files too and only understands ids.
        $tweakNames = @((Resolve-Tweak -Names (Get-BoundArray -Bound $Bound -Key 'Apply')).Matched |
            ForEach-Object { $_.name })
        $appIds = @((Resolve-App -Names (Get-BoundArray -Bound $Bound -Key 'Install')).Matched |
            ForEach-Object { $_.id })

        $setupProfile = New-SetupProfile `
            -Tweaks $tweakNames `
            -Apps   $appIds `
            -UpgradeAllApps:(& $has 'UpgradeAll') `
            -InstallVCRuntimes:(& $has 'VCRuntimes') `
            -RunWindowsUpdate:(& $has 'WindowsUpdate')

        Save-SetupProfile -SetupProfile $setupProfile -Path $Bound['SaveProfile'] | Out-Null
        $didSomething = $true
    }

    if (-not $didSomething) {
        Show-MainMenu
    }

    if ($Ctx.Failed -gt 0) { return 1 }
    return 0
}
