# =============================================================================
# Mouse settings: the Pointer Options tab of the Windows Mouse control panel.
#
# Read and written through SystemParametersInfo rather than the registry.
#
# That is not a style choice. HKCU\Control Panel\Mouse is where Windows caches
# these, but the cache and the effective setting are not the same thing: on the
# machine this was written on, MouseSonar was absent from the registry entirely
# while SPI_GETMOUSEVANISH answered 1. Reading the registry would have reported
# settings that are not what the mouse is actually doing, and writing it would
# change nothing until the next sign-in.
#
# Every SPI_GET below was checked against the registry where the registry did
# have a value, and all six agreed.
#
# The writes pass SPIF_UPDATEINIFILE | SPIF_SENDCHANGE, so Windows persists the
# value itself and every running program is told - the change is live, with no
# sign-out.
#
# All of it is per-user (HKCU), so none of it needs administrator.
# =============================================================================

# uiAction values, from WinUser.h.
$SpiGetMouse            = 0x0003   # acceleration: int[3]
$SpiSetMouse            = 0x0004
$SpiSetMouseTrails      = 0x005D
$SpiGetMouseTrails      = 0x005E
$SpiGetSnapToDefButton  = 0x005F
$SpiSetSnapToDefButton  = 0x0060
$SpiGetMouseSpeed       = 0x0070
$SpiSetMouseSpeed       = 0x0071
$SpiGetMouseSonar       = 0x101C
$SpiSetMouseSonar       = 0x101D
$SpiGetMouseVanish      = 0x1020
$SpiSetMouseVanish      = 0x1021

# SPIF_UPDATEINIFILE | SPIF_SENDCHANGE: persist it, and tell everything running.
$SpiPersistAndBroadcast = 0x0003

# The pointer speed slider has eleven notches and the API takes 1-20, so the
# two are not the same number. This is the mapping the control panel uses, and
# it is why 'speed 10' and 'the middle of the slider' both mean 1:1.
$MousePointerSpeedSteps = @(1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20)

# Three overloads because pvParam is three different things depending on the
# action: a pointer to an int when reading, an int[3] for acceleration, and the
# value itself cast to a pointer when writing a scalar.
#
# Built by joining lines rather than a here-string - build.ps1 indents every
# source line into the bundle's script block, and a here-string terminator has
# to sit at column 0.
function Initialize-MouseNative {
    if ('Moscovium.MouseNative' -as [type]) { return }

    $signature = @(
        '[DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfoW")]',
        'public static extern bool Read(uint uiAction, uint uiParam, ref int pvParam, uint fWinIni);',
        '[DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfoW")]',
        'public static extern bool ReadArray(uint uiAction, uint uiParam, int[] pvParam, uint fWinIni);',
        '[DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfoW")]',
        'public static extern bool Write(uint uiAction, uint uiParam, System.IntPtr pvParam, uint fWinIni);'
    ) -join [Environment]::NewLine

    Add-Type -MemberDefinition $signature -Name 'MouseNative' -Namespace 'Moscovium' -PassThru | Out-Null
}

# -----------------------------------------------------------------------------
# The settings themselves
# -----------------------------------------------------------------------------

function Get-MouseSettings {
    @(
        [pscustomobject]@{
            Id = 'speed'; Name = 'Pointer speed'; Group = 'Motion'
            Kind = 'range'; Minimum = 1; Maximum = 11
            Description = 'The eleven-notch slider. 6 is 1:1 - Windows scales nothing.'
        }
        [pscustomobject]@{
            Id = 'precision'; Name = 'Enhance pointer precision'; Group = 'Motion'
            Kind = 'toggle'; Minimum = 0; Maximum = 1
            Description = 'Mouse acceleration. Off means the same hand movement always travels the same distance.'
        }
        [pscustomobject]@{
            Id = 'snap'; Name = 'Snap to default button'; Group = 'Snap To'
            Kind = 'toggle'; Minimum = 0; Maximum = 1
            Description = 'Jumps the pointer to the default button when a dialog opens.'
        }
        [pscustomobject]@{
            Id = 'trails'; Name = 'Pointer trails'; Group = 'Visibility'
            # 0 is off; 2 to 7 is the Short-to-Long slider. 1 also means off,
            # which is why the range starts at 2.
            Kind = 'range'; Minimum = 0; Maximum = 7
            Description = '0 turns them off; 2 (short) to 7 (long) sets the length.'
        }
        [pscustomobject]@{
            Id = 'vanish'; Name = 'Hide pointer while typing'; Group = 'Visibility'
            Kind = 'toggle'; Minimum = 0; Maximum = 1
            Description = 'Hides the pointer while you type, until the mouse moves again.'
        }
        [pscustomobject]@{
            Id = 'sonar'; Name = 'Show pointer location on CTRL'; Group = 'Visibility'
            Kind = 'toggle'; Minimum = 0; Maximum = 1
            Description = 'Rings the pointer when you press and release CTRL.'
        }
    )
}

function Resolve-MouseSetting {
    param([Parameter(Mandatory)][string]$Id)

    $settings = Get-MouseSettings

    $exact = @($settings | Where-Object { $_.Id -eq $Id })
    if ($exact.Count -eq 1) { return $exact[0] }

    $fuzzy = @($settings | Where-Object {
        (Test-NameMatch -Value $_.Id -Pattern $Id) -or (Test-NameMatch -Value $_.Name -Pattern $Id)
    })
    if ($fuzzy.Count -eq 1) { return $fuzzy[0] }

    if ($fuzzy.Count -gt 1) {
        Write-Err "'$Id' is ambiguous. Did you mean one of these?"
        foreach ($setting in $fuzzy) { Write-Info $setting.Id }
        return $null
    }

    Write-Err "Unknown mouse setting '$Id'. Known: $((Get-MouseSettings | ForEach-Object { $_.Id }) -join ', ')."
    return $null
}

# Slider notch (1-11) to the API's 1-20, and back. Back is nearest-notch,
# because a value set by something other than the control panel - a driver, a
# script - need not be one of the eleven.
function ConvertTo-MousePointerSpeed {
    param([Parameter(Mandatory)][int]$Position)

    $index = [Math]::Max(1, [Math]::Min($MousePointerSpeedSteps.Count, $Position)) - 1
    return $MousePointerSpeedSteps[$index]
}

function ConvertFrom-MousePointerSpeed {
    param([Parameter(Mandatory)][int]$Speed)

    $best = 1
    $closest = [int]::MaxValue

    for ($i = 0; $i -lt $MousePointerSpeedSteps.Count; $i++) {
        $distance = [Math]::Abs($MousePointerSpeedSteps[$i] - $Speed)
        if ($distance -lt $closest) { $closest = $distance; $best = $i + 1 }
    }

    return $best
}

function Get-MouseSettingValue {
    param([Parameter(Mandatory)][string]$Id)

    Initialize-MouseNative
    $value = 0

    switch ($Id) {
        'speed' {
            if (-not [Moscovium.MouseNative]::Read($SpiGetMouseSpeed, 0, [ref]$value, 0)) { throw 'Could not read the pointer speed.' }
            return (ConvertFrom-MousePointerSpeed -Speed $value)
        }
        'precision' {
            # int[3] - threshold1, threshold2, acceleration. Acceleration is the
            # third, and it is the one the checkbox controls.
            $acceleration = New-Object 'int[]' 3
            if (-not [Moscovium.MouseNative]::ReadArray($SpiGetMouse, 0, $acceleration, 0)) { throw 'Could not read the acceleration settings.' }
            if ($acceleration[2] -gt 0) { return 1 }
            return 0
        }
        'snap' {
            if (-not [Moscovium.MouseNative]::Read($SpiGetSnapToDefButton, 0, [ref]$value, 0)) { throw 'Could not read snap-to-default-button.' }
            if ($value) { return 1 }
            return 0
        }
        'trails' {
            if (-not [Moscovium.MouseNative]::Read($SpiGetMouseTrails, 0, [ref]$value, 0)) { throw 'Could not read the pointer trails.' }
            # 1 means off just as 0 does; report both as 0 so a caller has one
            # value to test rather than two.
            if ($value -le 1) { return 0 }
            return $value
        }
        'vanish' {
            if (-not [Moscovium.MouseNative]::Read($SpiGetMouseVanish, 0, [ref]$value, 0)) { throw 'Could not read hide-while-typing.' }
            if ($value) { return 1 }
            return 0
        }
        'sonar' {
            if (-not [Moscovium.MouseNative]::Read($SpiGetMouseSonar, 0, [ref]$value, 0)) { throw 'Could not read the CTRL pointer location.' }
            if ($value) { return 1 }
            return 0
        }
        default { throw "No such mouse setting '$Id'." }
    }
}

function Set-MouseSettingValue {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][int]$Value
    )

    Initialize-MouseNative
    $flags = $SpiPersistAndBroadcast

    switch ($Id) {
        'speed' {
            $speed = ConvertTo-MousePointerSpeed -Position $Value
            # pvParam carries the value itself, not a pointer to it.
            if (-not [Moscovium.MouseNative]::Write($SpiSetMouseSpeed, 0, [IntPtr]$speed, $flags)) { throw 'Could not set the pointer speed.' }
        }
        'precision' {
            # The control panel's own on and off values: thresholds 6 and 10
            # with acceleration 1, or all zeroes.
            $acceleration = New-Object 'int[]' 3
            if ($Value) { $acceleration[0] = 6; $acceleration[1] = 10; $acceleration[2] = 1 }
            if (-not [Moscovium.MouseNative]::ReadArray($SpiSetMouse, 0, $acceleration, $flags)) { throw 'Could not set the acceleration settings.' }
        }
        'snap' {
            # uiParam carries the flag here; pvParam is unused.
            if (-not [Moscovium.MouseNative]::Write($SpiSetSnapToDefButton, [uint32]$Value, [IntPtr]::Zero, $flags)) { throw 'Could not set snap-to-default-button.' }
        }
        'trails' {
            if (-not [Moscovium.MouseNative]::Write($SpiSetMouseTrails, [uint32]$Value, [IntPtr]::Zero, $flags)) { throw 'Could not set the pointer trails.' }
        }
        'vanish' {
            if (-not [Moscovium.MouseNative]::Write($SpiSetMouseVanish, 0, [IntPtr]$Value, $flags)) { throw 'Could not set hide-while-typing.' }
        }
        'sonar' {
            if (-not [Moscovium.MouseNative]::Write($SpiSetMouseSonar, 0, [IntPtr]$Value, $flags)) { throw 'Could not set the CTRL pointer location.' }
        }
        default { throw "No such mouse setting '$Id'." }
    }
}

# Clamps to the setting's own range, so a typo cannot leave the mouse in a
# state the control panel has no way to show.
function Set-MouseSetting {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][int]$Value
    )

    $setting = Resolve-MouseSetting -Id $Id
    if (-not $setting) { return $false }

    $clamped = [Math]::Max($setting.Minimum, [Math]::Min($setting.Maximum, $Value))

    # 1 is another way of saying off, and leaving it set to 1 would make the
    # value read back as 0 - which looks like the write failed.
    if ($setting.Id -eq 'trails' -and $clamped -eq 1) { $clamped = 0 }

    if ($Ctx.DryRun) {
        Write-Status -Glyph (Get-Glyph 'Info') -Color (Get-Color 'Warn') -Message $setting.Name -MessageColor (Get-Color 'Warn')
        Write-Info "would set $($setting.Id) to $clamped"
        return $false
    }

    try {
        Set-MouseSettingValue -Id $setting.Id -Value $clamped
    }
    catch {
        Write-Err "$($setting.Name) - $($_.Exception.Message)"
        return $false
    }

    Write-Ok "$($setting.Name) - $(Format-MouseValue -Setting $setting -Value $clamped)"
    Write-Log "mouse: $($setting.Id) = $clamped"
    return $true
}

function Get-MouseSnapshot {
    $snapshot = [System.Collections.Generic.List[object]]::new()

    foreach ($setting in Get-MouseSettings) {
        $value = $null
        $problem = ''

        try { $value = Get-MouseSettingValue -Id $setting.Id }
        catch { $problem = $_.Exception.Message }

        $snapshot.Add([pscustomobject]@{
            Setting = $setting
            Value   = $value
            Error   = $problem
        })
    }

    return @($snapshot)
}

# -----------------------------------------------------------------------------
# Presets
# -----------------------------------------------------------------------------

function Get-MousePresets {
    @(
        [pscustomobject]@{
            Id = 'raw'; Name = 'Raw input'
            Summary = 'Acceleration off and the slider at 1:1 - the same hand movement always travels the same distance.'
            Values = [ordered]@{ precision = 0; speed = 6; trails = 0; snap = 0 }
        }
        [pscustomobject]@{
            Id = 'default'; Name = 'Windows defaults'
            Summary = 'Acceleration on, slider at 6, no trails, no snap, hide while typing on.'
            Values = [ordered]@{ precision = 1; speed = 6; trails = 0; snap = 0; vanish = 1; sonar = 0 }
        }
    )
}

function Resolve-MousePreset {
    param([Parameter(Mandatory)][string]$Id)

    $preset = @(Get-MousePresets | Where-Object { $_.Id -eq $Id })
    if ($preset.Count -eq 1) { return $preset[0] }

    Write-Err "Unknown mouse preset '$Id'. Known: $((Get-MousePresets | ForEach-Object { $_.Id }) -join ', ')."
    return $null
}

function Invoke-MousePreset {
    param([Parameter(Mandatory)][string]$Id)

    $preset = Resolve-MousePreset -Id $Id
    if (-not $preset) { return $false }

    Write-SectionHeading $preset.Name
    Write-Info $preset.Summary

    $applied = 0
    foreach ($key in $preset.Values.Keys) {
        if (Set-MouseSetting -Id $key -Value $preset.Values[$key]) { $applied++ }
    }

    if (-not $Ctx.DryRun) { Write-Info 'Applied live - no sign-out needed.' }
    return ($applied -gt 0)
}

# -----------------------------------------------------------------------------
# Console output
# -----------------------------------------------------------------------------

function Format-MouseValue {
    param([Parameter(Mandatory)]$Setting, [AllowNull()]$Value)

    if ($null -eq $Value) { return 'unknown' }

    if ($Setting.Kind -eq 'toggle') {
        if ($Value) { return 'on' }
        return 'off'
    }

    if ($Setting.Id -eq 'speed') {
        $note = ''
        if ($Value -eq 6) { $note = '  (1:1)' }
        return ('{0}/11{1}' -f $Value, $note)
    }

    if ($Setting.Id -eq 'trails') {
        if ($Value -le 1) { return 'off' }
        return ('on, length {0}' -f $Value)
    }

    return [string]$Value
}

function Show-MouseSettings {
    Write-SectionHeading 'Mouse'
    Write-Info 'The Pointer Options tab, read live through SystemParametersInfo.'

    $group = ''
    foreach ($entry in @(Get-MouseSnapshot)) {
        if ($entry.Setting.Group -ne $group) {
            $group = $entry.Setting.Group
            Write-Line ''
            Write-Line "  $group" -Color (Get-Color 'Faint')
        }

        if ($entry.Error) {
            Write-Line '    ' -NoNewline
            Write-Line $entry.Setting.Id.PadRight(12) -Color White -NoNewline
            Write-Line $entry.Error -Color (Get-Color 'Err')
            continue
        }

        $rendered = Format-MouseValue -Setting $entry.Setting -Value $entry.Value

        # The speed gets the slider drawn, because 6/11 means more with the
        # notch shown than as a bare number.
        $meter = ''
        if ($entry.Setting.Id -eq 'speed') {
            $meter = '  ' + (New-MeterBar -Percent (100.0 * $entry.Value / 11.0) -Width 11)
        }

        $color = Get-Color 'Text'
        if ($entry.Setting.Kind -eq 'toggle') {
            $color = Get-Color 'Muted'
            if ($entry.Value) { $color = Get-Color 'Ok' }
        }

        Write-Line '    ' -NoNewline
        Write-Line $entry.Setting.Id.PadRight(12) -Color White -NoNewline
        Write-Line ($rendered.PadRight(16)) -Color $color -NoNewline
        Write-Line $meter -Color (Get-Color 'Accent')
        Write-Info $entry.Setting.Description
    }

    Write-Line ''
    Write-Info 'Change one with:  -SetMouse precision=0     a whole preset with:  -MousePreset raw'
}
