# =============================================================================
# Personalisation and per-game config, ported from the desktop app's Cursors,
# Customization and CS2/CS:GO pages.
#
# The cursor *packs* the desktop app bundles (four schemes, several hundred .cur
# and .ani files) cannot travel in a single script, so what is here is the
# mechanism: point it at a folder of cursor files and it installs them, or put
# the Windows defaults back. Wallpaper and the CS2 config helpers port whole.
#
# Settings live alongside, because the app store needs an install path and a
# GitHub token and there was nowhere else to put them.
# =============================================================================

# -----------------------------------------------------------------------------
# Settings
# -----------------------------------------------------------------------------

function Get-SettingsPath { Join-Path $Ctx.StateDir 'settings.json' }

function Get-MoscoviumSetting {
    param([Parameter(Mandatory)][string]$Name)

    $path = Get-SettingsPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    try {
        $settings = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $property = $settings.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
        if ($property -and $property.Value) { return $property.Value }
    }
    catch { Write-Log "Unreadable settings file: $($_.Exception.Message)" 'WARN' }

    return $null
}

function Set-MoscoviumSetting {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    Initialize-State
    $path = Get-SettingsPath

    $settings = [ordered]@{}
    if (Test-Path -LiteralPath $path) {
        try {
            $existing = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($property in $existing.PSObject.Properties) { $settings[$property.Name] = $property.Value }
        }
        catch { }
    }

    if ([string]::IsNullOrEmpty($Value)) { $settings.Remove($Name) | Out-Null }
    else { $settings[$Name] = $Value }

    $json = ([pscustomobject]$settings | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($path, $json + "`n", (New-Object Text.UTF8Encoding $false))

    # A token in a log or on screen is a token leaked.
    $shown = if ($Name -match 'Token|Secret|Password') { '<hidden>' } else { $Value }
    Write-Ok "$Name = $shown"
}

# -----------------------------------------------------------------------------
# Cursors
# -----------------------------------------------------------------------------

# The value names under HKCU\Control Panel\Cursors, and the file-name stems each
# one is matched against when installing a folder of cursors.
function Get-CursorRoleMap {
    [ordered]@{
        'Arrow'       = @('arrow', 'normal', 'pointer', 'default')
        'Help'        = @('help')
        'AppStarting' = @('appstarting', 'working', 'busy_arrow')
        'Wait'        = @('wait', 'busy')
        'Crosshair'   = @('crosshair', 'precision')
        'IBeam'       = @('ibeam', 'text', 'beam')
        'NWPen'       = @('nwpen', 'handwriting', 'pen')
        'No'          = @('no', 'unavailable')
        # The macOS pack spells these 'Vertical Resize', 'Diagonal Resize 1' and
        # so on, and the match below is exact on the stem - so the full names
        # have to be here or four of its seventeen roles come out unmatched.
        'SizeNS'      = @('sizens', 'vertical', 'vertical resize')
        'SizeWE'      = @('sizewe', 'horizontal', 'horizontal resize')
        'SizeNWSE'    = @('sizenwse', 'diagonal1', 'diagonal 1', 'diagonal resize 1')
        'SizeNESW'    = @('sizenesw', 'diagonal2', 'diagonal 2', 'diagonal resize 2')
        'SizeAll'     = @('sizeall', 'move')
        'UpArrow'     = @('uparrow', 'alternate')
        'Hand'        = @('hand', 'link')
        'Person'      = @('person')
        'Pin'         = @('pin')
    }
}

function Update-CursorScheme {
    # Tells Windows to re-read the cursor registry values immediately.
    # Built by joining lines rather than a here-string: build.ps1 indents every
    # source line into the bundle's script block, and a here-string terminator
    # must sit at column 0.
    $signature = @(
        '[DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]',
        'public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, System.IntPtr pvParam, uint fWinIni);'
    ) -join [Environment]::NewLine
    try {
        if (-not ('Moscovium.Native' -as [type])) {
            Add-Type -MemberDefinition $signature -Name 'Native' -Namespace 'Moscovium' -PassThru | Out-Null
        }
        # SPI_SETCURSORS = 0x0057, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE = 3
        [Moscovium.Native]::SystemParametersInfo(0x0057, 0, [IntPtr]::Zero, 3) | Out-Null
    }
    catch {
        Write-Warn "Cursors are set but Windows was not told to reload them - sign out and back in. ($($_.Exception.Message))"
    }
}

function Install-CursorScheme {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$SchemeName = 'Moscovium Custom'
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "No such folder: $Path" }

    $files = @(Get-ChildItem -LiteralPath $Path -Include '*.cur', '*.ani' -File -Recurse -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { throw "No .cur or .ani files under '$Path'." }

    if ($Ctx.DryRun) {
        Write-Warn "Dry run: would install $($files.Count) cursor file(s) as '$SchemeName'."
        return
    }

    # Copy out of the source folder first: the registry points at these paths for
    # as long as the scheme is active, so they must not be somewhere temporary.
    $destination = Join-Path (Join-Path $Ctx.StateDir 'Cursors') $SchemeName
    New-Item -ItemType Directory -Path $destination -Force | Out-Null

    $roles = Get-CursorRoleMap
    $assigned = [ordered]@{}

    foreach ($role in $roles.Keys) {
        foreach ($stem in $roles[$role]) {
            $match = @($files | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name).ToLowerInvariant() -eq $stem }) |
                Select-Object -First 1
            if ($match) {
                $copy = Join-Path $destination $match.Name
                Copy-Item -LiteralPath $match.FullName -Destination $copy -Force
                $assigned[$role] = $copy
                break
            }
        }
    }

    if ($assigned.Count -eq 0) {
        throw "Found $($files.Count) cursor file(s) but none had a recognisable name (arrow, ibeam, wait, ...)."
    }

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser', 'Registry64')
    try {
        $key = $base.CreateSubKey('Control Panel\Cursors', $true)
        try {
            $key.SetValue('', $SchemeName, [Microsoft.Win32.RegistryValueKind]::String)
            foreach ($role in $roles.Keys) {
                # A role the pack does not cover is cleared, not left pointing at
                # whatever the previous scheme had - otherwise switching packs
                # leaves a mixed set behind. Empty means "the built-in one".
                $value = ''
                if ($assigned.Contains($role)) { $value = $assigned[$role] }
                $key.SetValue($role, $value, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            }
        }
        finally { $key.Dispose() }

        # Registering under Schemes is what makes it appear in the Mouse
        # Properties dropdown, and is what the desktop app does. The value is
        # every role's path in the fixed role order, comma-separated.
        $schemes = $base.CreateSubKey('Control Panel\Cursors\Schemes', $true)
        try {
            $ordered = foreach ($role in $roles.Keys) { if ($assigned.Contains($role)) { $assigned[$role] } else { '' } }
            $schemes.SetValue($SchemeName, ($ordered -join ','), [Microsoft.Win32.RegistryValueKind]::String)
        }
        finally { $schemes.Dispose() }
    }
    finally { $base.Dispose() }

    Update-CursorScheme
    Write-Ok "Cursor scheme '$SchemeName' applied - $($assigned.Count) of $($roles.Count) roles matched."
    foreach ($role in $roles.Keys) {
        if (-not $assigned.Contains($role)) { Write-Info "unmatched: $role" }
    }
}

# -----------------------------------------------------------------------------
# The desktop app's cursor packs
#
# Three packs, six presets, 345 files in the desktop repository - too much to
# carry in a single script, so a preset is fetched at apply time: the seventeen
# files Windows actually has roles for, straight from the repository that the
# desktop app bundles them out of, then handed to Install-CursorScheme like any
# other folder. Same idea as the Customization installers: the vendor's current
# copy rather than an embedded one, and here the vendor is Moscovium itself.
#
# 'main' rather than a pinned commit, deliberately: the desktop app ships from
# main, so this applies exactly the files it would.
# -----------------------------------------------------------------------------

$CursorPackBaseUrl = 'https://raw.githubusercontent.com/Moscoviumdebloat/Moscovium/main/Assets/Cursors/'

function Get-CursorPresets {
    @(
        [pscustomobject]@{
            Id = 'concept1-dark'; Name = 'Cursor Concept 1 Dark Free'
            Folder = 'CursorConcept1/cursor/dark'; Naming = 'standard'
            Credit = 'Minimal, clean cursor design by Jepri Creations.'
        }
        [pscustomobject]@{
            Id = 'concept1-light'; Name = 'Cursor Concept 1 Light Free'
            Folder = 'CursorConcept1/cursor/light'; Naming = 'standard'
            Credit = 'Minimal, clean cursor design by Jepri Creations.'
        }
        [pscustomobject]@{
            Id = 'material-dark'; Name = 'Material Design Dark Free'
            Folder = 'MaterialDesign/dark'; Naming = 'standard'
            Credit = 'Google-inspired Material Design cursors by Jepri Creations.'
        }
        [pscustomobject]@{
            Id = 'material-light'; Name = 'Material Design Light Free'
            Folder = 'MaterialDesign/light'; Naming = 'standard'
            Credit = 'Google-inspired Material Design cursors by Jepri Creations.'
        }
        [pscustomobject]@{
            Id = 'macos'; Name = 'macOS Cursors No Shadow'
            Folder = 'MacOSCursors/1. Sierra and newer/1. No Shadow/1. Normal'; Naming = 'macos'
            Credit = 'macOS Sierra cursors for Windows by antiden.'
        }
        [pscustomobject]@{
            Id = 'macos-shadow'; Name = 'macOS Cursors With Shadow'
            Folder = 'MacOSCursors/1. Sierra and newer/2. With Shadow/1. Normal'; Naming = 'macos'
            Credit = 'macOS Sierra cursors for Windows by antiden.'
        }
    )
}

# The seventeen files a preset needs, in role order. Two naming conventions
# across the three packs, exactly as the desktop app's two mapping builders.
function Get-CursorPresetFile {
    param([Parameter(Mandatory)]$Preset)

    if ($Preset.Naming -eq 'macos') {
        return @(
            'Normal.cur', 'Help.cur', 'Working.ani', 'Busy.ani', 'Precision.cur', 'Text.cur',
            'Handwriting.cur', 'Unavailable.cur', 'Vertical Resize.cur', 'Horizontal Resize.cur',
            'Diagonal Resize 1.cur', 'Diagonal Resize 2.cur', 'Move.cur', 'Alternate.cur',
            'Link.cur', 'Person.cur', 'Pin.cur'
        )
    }

    @(
        'arrow.cur', 'help.cur', 'appstarting.ani', 'wait.ani', 'crosshair.cur', 'ibeam.cur',
        'nwpen.cur', 'no.cur', 'sizens.cur', 'sizewe.cur', 'sizenwse.cur', 'sizenesw.cur',
        'sizeall.cur', 'uparrow.cur', 'hand.cur', 'person.cur', 'pin.cur'
    )
}

# Every path segment escaped on its own: the macOS folders have spaces and
# dots, and escaping the joined path would also escape the slashes.
function Get-CursorPresetUrl {
    param([Parameter(Mandatory)]$Preset, [Parameter(Mandatory)][string]$FileName)

    $segments = @($Preset.Folder -split '/') + @($FileName)
    return $CursorPackBaseUrl + (($segments | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
}

function Resolve-CursorPreset {
    param([Parameter(Mandatory)][string]$Id)

    $presets = Get-CursorPresets
    $exact = @($presets | Where-Object { $_.Id -eq $Id })
    if ($exact.Count -eq 1) { return $exact[0] }

    $fuzzy = @($presets | Where-Object {
        (Test-NameMatch -Value $_.Id -Pattern $Id) -or (Test-NameMatch -Value $_.Name -Pattern $Id)
    })
    if ($fuzzy.Count -eq 1) { return $fuzzy[0] }

    if ($fuzzy.Count -gt 1) {
        Write-Err "'$Id' is ambiguous. Did you mean one of these?"
        foreach ($preset in $fuzzy) { Write-Info $preset.Id }
        return $null
    }

    Write-Err "Unknown cursor pack '$Id'. Known: $((Get-CursorPresets | ForEach-Object { $_.Id }) -join ', ')."
    return $null
}

function Install-CursorPreset {
    param([Parameter(Mandatory)][string]$Id)

    $preset = Resolve-CursorPreset -Id $Id
    if (-not $preset) { return $false }

    $files = @(Get-CursorPresetFile -Preset $preset)

    if ($Ctx.DryRun) {
        Write-Status -Glyph (Get-Glyph 'Info') -Color (Get-Color 'Warn') -Message $preset.Name -MessageColor (Get-Color 'Warn')
        Write-Info "would download $($files.Count) cursor files from $CursorPackBaseUrl$($preset.Folder)/ and apply them"
        return $false
    }

    Write-Line ''
    Write-Info "$($preset.Name) - $($preset.Credit)"
    Write-Info "$($files.Count) files from the desktop app's repository:"
    Write-Line "      $CursorPackBaseUrl$($preset.Folder)/" -Color Gray
    Write-Info 'Cursors are per-user and reversible: Restore Windows defaults puts them back.'

    if (-not (Confirm-Action "Download and apply $($preset.Name)?" -DefaultYes)) {
        Write-Warn "$($preset.Name) - skipped."
        return $false
    }

    # Into downloads/, not straight into the scheme folder: Install-CursorScheme
    # copies from wherever it is pointed into the folder the registry will
    # reference, and does the role matching, so this only has to fetch.
    $staging = Join-Path (Join-Path $Ctx.StateDir 'downloads\cursors') $preset.Id
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    Write-Step "Downloading $($preset.Name)"
    try {
        $index = 0
        foreach ($file in $files) {
            $index++
            $url = Get-CursorPresetUrl -Preset $preset -FileName $file
            # A .cur is 4KB or so; the floor only has to catch an empty or
            # truncated response, since a 404 already throws.
            Save-RemoteFile -Url $url -Destination (Join-Path $staging $file) -Label "$index/$($files.Count) $file" -MinimumBytes 64 | Out-Null
        }
    }
    catch {
        Write-Err "$($preset.Name) - $($_.Exception.Message)"
        return $false
    }

    try {
        Install-CursorScheme -Path $staging -SchemeName $preset.Name
        return $true
    }
    catch {
        Write-Err "$($preset.Name) - $($_.Exception.Message)"
        return $false
    }
}

function Show-CursorPresetCatalog {
    Write-SectionHeading 'Cursor packs'

    foreach ($preset in Get-CursorPresets) {
        Write-Line '  - ' -Color DarkGray -NoNewline
        Write-Line $preset.Id.PadRight(16) -Color White -NoNewline
        Write-Line $preset.Name -Color Gray
        Write-Info $preset.Credit
    }

    Write-Line ''
    Write-Info 'Apply one with:  -Cursor <id>     a folder of your own:  -Cursor <path>     back to Windows:  -Cursor default'
}

function Restore-DefaultCursor {
    if ($Ctx.DryRun) {
        Write-Warn 'Dry run: would restore the Windows default cursors.'
        return
    }

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser', 'Registry64')
    try {
        $key = $base.CreateSubKey('Control Panel\Cursors', $true)
        try {
            $key.SetValue('', 'Windows Default', [Microsoft.Win32.RegistryValueKind]::String)
            # An empty value is what "use the built-in one" looks like here.
            foreach ($role in (Get-CursorRoleMap).Keys) {
                $key.SetValue($role, '', [Microsoft.Win32.RegistryValueKind]::ExpandString)
            }
        }
        finally { $key.Dispose() }
    }
    finally { $base.Dispose() }

    Update-CursorScheme
    Write-Ok 'Windows default cursors restored.'
}

# -----------------------------------------------------------------------------
# Wallpaper
# -----------------------------------------------------------------------------

function Set-Wallpaper {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Fill', 'Fit', 'Stretch', 'Tile', 'Center', 'Span')][string]$Style = 'Fill'
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "No such image: $Path" }

    if ($Ctx.DryRun) {
        Write-Warn "Dry run: would set the wallpaper to $Path ($Style)."
        return
    }

    $styleValue, $tile = switch ($Style) {
        'Fill'    { '10', '0' }
        'Fit'     { '6',  '0' }
        'Stretch' { '2',  '0' }
        'Tile'    { '0',  '1' }
        'Center'  { '0',  '0' }
        'Span'    { '22', '0' }
    }

    Set-RegistryValue -Path 'HKEY_CURRENT_USER\Control Panel\Desktop' -Name 'WallpaperStyle' -Type 'String' -Value $styleValue
    Set-RegistryValue -Path 'HKEY_CURRENT_USER\Control Panel\Desktop' -Name 'TileWallpaper' -Type 'String' -Value $tile

    $signature = @(
        '[DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]',
        'public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);'
    ) -join [Environment]::NewLine
    if (-not ('Moscovium.Wallpaper' -as [type])) {
        Add-Type -MemberDefinition $signature -Name 'Wallpaper' -Namespace 'Moscovium' -PassThru | Out-Null
    }

    # SPI_SETDESKWALLPAPER = 20, SPIF_UPDATEINIFILE | SPIF_SENDWININICHANGE = 3
    [Moscovium.Wallpaper]::SystemParametersInfo(20, 0, (Resolve-Path -LiteralPath $Path).Path, 3) | Out-Null
    Write-Ok "Wallpaper set ($Style)."
}

# -----------------------------------------------------------------------------
# CS2 / CS:GO configs
# -----------------------------------------------------------------------------

# Steam can live on any drive, and a library folder can hold the game without
# Steam itself being there, so every ready drive gets checked.
# CS2 and CS:GO keep their configs in different places inside the same Steam
# folder: the CS2 update moved cfg down into game\csgo\, and the legacy CS:GO
# depot still uses the original csgo\ path. On a normal modern install only the
# CS2 one exists, which is why the desktop app gets away with searching that
# path for both of its pages - its CS:GO page writes into the CS2 folder.
#
# Now that the two have separate tabs here, each looks in its own place.
function Get-CsConfigRelativePath {
    param([ValidateSet('CS2', 'CSGO')][string]$Game = 'CS2')

    if ($Game -eq 'CSGO') { return 'steamapps\common\Counter-Strike Global Offensive\csgo\cfg' }
    return 'steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg'
}

function Find-CsConfigFolder {
    param([ValidateSet('CS2', 'CSGO')][string]$Game = 'CS2')

    $relative = Get-CsConfigRelativePath -Game $Game
    $found = [System.Collections.Generic.List[string]]::new()

    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "Steam\$relative")
        (Join-Path $env:ProgramFiles "Steam\$relative")
    )

    foreach ($drive in ([IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady })) {
        foreach ($stem in @('Steam', 'SteamLibrary', 'Games\Steam')) {
            $candidates += (Join-Path $drive.RootDirectory.FullName "$stem\$relative")
        }
    }

    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath $candidate) -and -not $found.Contains($candidate)) { $found.Add($candidate) }
    }

    @($found)
}

# Both strings verbatim from the desktop app's CS2 and CS:GO pages.
function Get-CsLaunchOption {
    param([ValidateSet('CS2', 'CSGO')][string]$Game = 'CS2')

    switch ($Game) {
        'CSGO'  { return '-tickrate 128 -allow_third_party_software +exec autoexec -freq 180' }
        default { return '-high -novid -allow_third_party_software -tickrate 128 -noaafonts' }
    }
}

function Install-CsConfig {
    param(
        [string]$Url = 'https://raw.githubusercontent.com/Yabosen/YabosenCFG/main/yabosen.cfg',
        [string]$FileName = 'yabosen.cfg',
        [string]$LocalPath,
        [ValidateSet('CS2', 'CSGO')][string]$Game = 'CS2'
    )

    $label = 'CS2'
    if ($Game -eq 'CSGO') { $label = 'CS:GO' }

    $folders = @(Find-CsConfigFolder -Game $Game)
    if ($folders.Count -eq 0) {
        Write-Err "No $label cfg folder found. Is it installed through Steam?"
        Write-Info "Looked for: $(Get-CsConfigRelativePath -Game $Game)"
        return
    }

    if ($Ctx.DryRun) {
        Write-Warn "Dry run: would install $FileName into $($folders.Count) folder(s)."
        foreach ($folder in $folders) { Write-Info $folder }
        return
    }

    try {
        if ($LocalPath) {
            if (-not (Test-Path -LiteralPath $LocalPath)) { throw "No such file: $LocalPath" }
            $FileName = Split-Path -Leaf $LocalPath
            $source = $LocalPath
        }
        else {
            Write-Step "Downloading $FileName"
            Write-Info $Url
            $source = Join-Path $Ctx.StateDir $FileName
            Save-RemoteFile -Url $Url -Destination $source -Label $FileName -MinimumBytes 16 | Out-Null
        }

        foreach ($folder in $folders) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $folder $FileName) -Force
            Write-Ok $folder
        }

        Write-Line ''
        Write-Info "In game: exec $([IO.Path]::GetFileNameWithoutExtension($FileName))"
    }
    catch {
        Write-Err "Config install failed: $($_.Exception.Message)"
    }
}
