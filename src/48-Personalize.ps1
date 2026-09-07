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
        'SizeNS'      = @('sizens', 'vertical')
        'SizeWE'      = @('sizewe', 'horizontal')
        'SizeNWSE'    = @('sizenwse', 'diagonal1', 'diagonal 1')
        'SizeNESW'    = @('sizenesw', 'diagonal2', 'diagonal 2')
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
            foreach ($role in $assigned.Keys) {
                $key.SetValue($role, $assigned[$role], [Microsoft.Win32.RegistryValueKind]::ExpandString)
            }
        }
        finally { $key.Dispose() }
    }
    finally { $base.Dispose() }

    Update-CursorScheme
    Write-Ok "Cursor scheme '$SchemeName' applied - $($assigned.Count) of $($roles.Count) roles matched."
    foreach ($role in $roles.Keys) {
        if (-not $assigned.Contains($role)) { Write-Info "unmatched: $role" }
    }
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
function Find-CsConfigFolder {
    $relative = 'steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg'
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

function Get-CsLaunchOption { '-high -novid -allow_third_party_software -tickrate 128 -noaafonts' }

function Install-CsConfig {
    param(
        [string]$Url = 'https://raw.githubusercontent.com/Yabosen/YabosenCFG/main/yabosen.cfg',
        [string]$FileName = 'yabosen.cfg',
        [string]$LocalPath
    )

    $folders = @(Find-CsConfigFolder)
    if ($folders.Count -eq 0) {
        Write-Err 'No CS2 cfg folder found. Is Counter-Strike installed through Steam?'
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
