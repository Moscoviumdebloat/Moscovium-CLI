# =============================================================================
# Applying, reverting and reporting on tweaks.
#
# Most tweaks are a list of registry values. Four are actions rather than state
# ("kind" in the catalog): PowerPlan, RestorePoint, CleanDisk, CleanTemp. Only
# PowerPlan is reversible, and only because we record the previously active
# scheme before switching.
# =============================================================================

function Test-TweakNeedsAdmin {
    param([Parameter(Mandatory)]$Tweak)

    if ($Tweak.kind -ne 'Registry') { return $true }

    foreach ($value in @($Tweak.registry)) {
        if ((Resolve-RegistryPath -FullPath $value.path).NeedsAdmin) { return $true }
    }
    return $false
}

function Get-TweakStatus {
    param([Parameter(Mandatory)]$Tweak)

    if ($Tweak.kind -ne 'Registry') { return 'Action' }

    $values = @($Tweak.registry)
    if ($values.Count -eq 0) { return 'Unknown' }

    $applied = 0
    foreach ($value in $values) {
        try { if (Test-RegistryValueApplied -Desired $value) { $applied++ } }
        catch { Write-Log "Status check failed for $($value.path)\$($value.name): $($_.Exception.Message)" 'WARN' }
    }

    if ($applied -eq 0)             { return 'NotApplied' }
    if ($applied -eq $values.Count) { return 'Applied' }
    return 'Partial'
}

function Get-ActivePowerScheme {
    try {
        $output = & powercfg.exe /getactivescheme 2>&1
        $match = [regex]::Match(($output -join ' '), '([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})')
        if ($match.Success) { return $match.Groups[1].Value }
    }
    catch { Write-Log "Could not read active power scheme: $($_.Exception.Message)" 'WARN' }
    return $null
}

function Invoke-TweakAction {
    param(
        [Parameter(Mandatory)]$Tweak,
        [Parameter(Mandatory)]$BackupEntry
    )

    switch ($Tweak.kind) {

        'PowerPlan' {
            $previous = Get-ActivePowerScheme
            if ($previous) { $BackupEntry.extra = @{ previousScheme = $previous } }

            # Well-known GUID of the built-in High performance scheme.
            $highPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
            & powercfg.exe -setactive $highPerformance | Out-Null

            if ($LASTEXITCODE -ne 0) {
                throw "powercfg exited with code $LASTEXITCODE. The High performance plan may be hidden by your OEM or by group policy."
            }
            return
        }

        'RestorePoint' {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
            Checkpoint-Computer -Description 'Moscovium CLI' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
            return
        }

        'CleanDisk' {
            # /verylowdisk runs every handler silently and exits on its own.
            $process = Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/verylowdisk' -PassThru -Wait -ErrorAction Stop
            if ($process.ExitCode -ne 0) {
                Write-Log "cleanmgr exited with code $($process.ExitCode)" 'WARN'
            }
            return
        }

        'CleanTemp' {
            $roots = @($env:TEMP, (Join-Path $env:SystemRoot 'Temp')) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
            $removed = 0

            foreach ($root in $roots) {
                # Files in use will fail; that is expected and not an error.
                Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                        $removed++
                    }
                    catch { }
                }
            }

            Write-Info "Removed $removed item(s) from $($roots.Count) temp folder(s)."
            return
        }

        default { throw "Unknown tweak kind '$($Tweak.kind)'." }
    }
}

function Invoke-TweakApply {
    param(
        [Parameter(Mandatory)]$Tweak,
        [Parameter(Mandatory)]$BackupRecord
    )

    $needsAdmin = Test-TweakNeedsAdmin -Tweak $Tweak

    # Dry run is checked before elevation so an unelevated preview still shows
    # the whole plan, including the parts that would need admin to carry out.
    if ($Ctx.DryRun) {
        Write-Status -Glyph (Get-Glyph 'Info') -Color (Get-Color 'Warn') -Message $Tweak.name -MessageColor (Get-Color 'Warn')

        if ($needsAdmin -and -not $Ctx.IsAdmin) {
            Write-Info 'needs administrator - would be skipped at this elevation'
        }

        if ($Tweak.kind -ne 'Registry') {
            Write-Info "would run action: $($Tweak.kind)"
        }
        else {
            foreach ($value in @($Tweak.registry)) {
                $label = if ($value.name) { $value.name } else { '(Default)' }
                Write-Info ("would set {0}\{1} = {2} ({3})" -f $value.path, $label, $value.value, $value.type)
            }
        }

        $Ctx.Skipped++
        return
    }

    if ($needsAdmin -and -not $Ctx.IsAdmin) {
        Write-Warn "$($Tweak.name) - skipped, needs administrator."
        $Ctx.Skipped++
        return
    }

    $entry = [pscustomobject]@{
        kind   = $Tweak.kind
        values = @()
        extra  = $null
    }

    try {
        if ($Tweak.kind -ne 'Registry') {
            Invoke-TweakAction -Tweak $Tweak -BackupEntry $entry
        }
        else {
            # Snapshot everything first so a failure part-way through still
            # leaves a complete, usable undo record.
            $entry.values = @(foreach ($value in @($Tweak.registry)) {
                Get-RegistryValueSnapshot -Path $value.path -Name $value.name
            })

            foreach ($value in @($Tweak.registry)) {
                Set-RegistryValue -Path $value.path -Name $value.name -Type $value.type -Value $value.value
            }
        }

        $BackupRecord.entries[$Tweak.name] = $entry
        Write-Ok $Tweak.name
        $Ctx.Applied++
    }
    catch {
        # Keep whatever we snapshotted: values written before the failure still
        # need to be revertible.
        if ($entry.values.Count -gt 0) { $BackupRecord.entries[$Tweak.name] = $entry }

        Write-Err "$($Tweak.name) - $($_.Exception.Message)"
        $Ctx.Failed++
    }
}

function Invoke-TweakRevert {
    param([Parameter(Mandatory)]$Tweak)

    $backup = Find-TweakBackup -TweakName $Tweak.name
    if (-not $backup) {
        Write-Warn "$($Tweak.name) - no backup found, nothing to revert."
        $Ctx.Skipped++
        return
    }

    $entry = $backup.Entry

    if ($Ctx.DryRun) {
        Write-Status -Glyph (Get-Glyph 'Info') -Color (Get-Color 'Warn') -Message $Tweak.name -MessageColor (Get-Color 'Warn')
        Write-Info "would restore from $(Split-Path -Leaf $backup.File)"
        $Ctx.Skipped++
        return
    }

    if ($Tweak.kind -ne 'Registry') {
        if ($Tweak.kind -eq 'PowerPlan' -and $entry.extra -and $entry.extra.previousScheme) {
            try {
                & powercfg.exe -setactive $entry.extra.previousScheme | Out-Null
                Write-Ok "$($Tweak.name) - restored power scheme $($entry.extra.previousScheme)"
                $Ctx.Applied++
            }
            catch {
                Write-Err "$($Tweak.name) - $($_.Exception.Message)"
                $Ctx.Failed++
            }
        }
        else {
            Write-Warn "$($Tweak.name) - '$($Tweak.kind)' actions cannot be undone."
            $Ctx.Skipped++
        }
        return
    }

    if ((Test-TweakNeedsAdmin -Tweak $Tweak) -and (-not $Ctx.IsAdmin)) {
        Write-Warn "$($Tweak.name) - skipped, needs administrator."
        $Ctx.Skipped++
        return
    }

    try {
        $createdKeys = [System.Collections.Generic.List[string]]::new()

        foreach ($value in @($entry.values)) {
            if ($value.existed) {
                Set-RegistryValue -Path $value.path -Name $value.name -Type $value.type -Value $value.value
            }
            else {
                Remove-RegistryValue -Path $value.path -Name $value.name
                if (-not $value.keyExisted) { $createdKeys.Add($value.path) }
            }
        }

        # Drop keys this tweak created, deepest first so parents empty out. Only
        # keys that are genuinely empty are removed. This is what makes tweaks
        # like Classic Right-Click Menu (an empty marker key) actually revert.
        foreach ($path in ($createdKeys | Sort-Object -Property Length -Descending -Unique)) {
            if (Remove-EmptyRegistryKey -Path $path) { Write-Log "Removed created key $path" }
        }

        Write-Ok "$($Tweak.name) - reverted"
        $Ctx.Applied++
    }
    catch {
        Write-Err "$($Tweak.name) - $($_.Exception.Message)"
        $Ctx.Failed++
    }
}

function Invoke-Tweaks {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Tweaks,
        [ValidateSet('Apply', 'Revert')][string]$Mode = 'Apply'
    )

    if ($Tweaks.Count -eq 0) {
        Write-Warn 'No tweaks selected.'
        return
    }

    $verb = if ($Mode -eq 'Apply') { 'Applying' } else { 'Reverting' }
    Write-SectionHeading "$verb $($Tweaks.Count) tweak$(if ($Tweaks.Count -ne 1) { 's' })"

    $record = New-BackupRecord

    foreach ($tweak in $Tweaks) {
        if ($Mode -eq 'Apply') { Invoke-TweakApply -Tweak $tweak -BackupRecord $record }
        else                   { Invoke-TweakRevert -Tweak $tweak }
    }

    if ($Mode -eq 'Apply') {
        $path = Save-BackupRecord -Record $record
        if ($path) {
            Write-Line ''
            Write-Info "Undo snapshot: $path"
        }
    }

    Write-RunSummary
}

function Write-RunSummary {
    Write-Line ''
    $parts = @()
    if ($Ctx.Applied -gt 0) { $parts += "$($Ctx.Applied) succeeded" }
    if ($Ctx.Skipped -gt 0) { $parts += "$($Ctx.Skipped) skipped" }
    if ($Ctx.Failed  -gt 0) { $parts += "$($Ctx.Failed) failed" }
    if ($parts.Count -eq 0) { $parts += 'nothing to do' }

    $color = if ($Ctx.Failed -gt 0) { 'Red' } elseif ($Ctx.Skipped -gt 0) { 'Yellow' } else { 'Green' }
    Write-Line ('  ' + ($parts -join ', ') + '.') -Color $color

    if ($Ctx.DryRun) {
        Write-Line '  Dry run: nothing was changed.' -Color DarkYellow
    }

    $Ctx.Applied = 0; $Ctx.Skipped = 0; $Ctx.Failed = 0
}

function Show-TweakStatus {
    param([object[]]$Tweaks)

    if (-not $Tweaks -or $Tweaks.Count -eq 0) { $Tweaks = $Ctx.Tweaks }

    foreach ($category in $Ctx.TweakCategories) {
        $inCategory = @($Tweaks | Where-Object { $_.category -eq $category })
        if ($inCategory.Count -eq 0) { continue }

        $applied = @($inCategory | Where-Object { (Get-TweakStatus -Tweak $_) -eq 'Applied' }).Count
        Write-SectionHeading $category -Suffix "$applied/$($inCategory.Count)"

        foreach ($tweak in $inCategory) {
            $status = Get-TweakStatus -Tweak $tweak

            $glyph, $color, $label = switch ($status) {
                'Applied'    { (Get-Glyph 'Checked'),   (Get-Color 'Ok'),     'applied' }
                'Partial'    { (Get-Glyph 'Partial'),   (Get-Color 'Warn'),   'partial' }
                'NotApplied' { (Get-Glyph 'Unchecked'), (Get-Color 'Muted'),  '' }
                'Action'     { (Get-Glyph 'Action'),    (Get-Color 'AccentDim'), 'action' }
                default      { (Get-Glyph 'Info'),      (Get-Color 'Muted'),  'unknown' }
            }

            # The longest catalog name is 43 characters; pad past it so the
            # status column never runs into the name.
            Write-Line "  $glyph " -Color $color -NoNewline
            Write-Line $tweak.name.PadRight(46) -Color $(if ($status -eq 'NotApplied') { Get-Color 'Muted' } else { Get-Color 'Text' }) -NoNewline
            Write-Line $label -Color $color
        }
    }

    Write-Line ''
    $g = $Ctx.Theme.Glyph
    Write-Info ("legend   {0} applied   {1} partial   {2} not applied   {3} one-shot action" -f `
        $g.Checked, $g.Partial, $g.Unchecked, $g.Action)
}
