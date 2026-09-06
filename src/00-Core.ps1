# =============================================================================
# Core: context, output, elevation, state.
#
# Every file in src/ is a pure function library with no top-level side effects.
# build.ps1 concatenates them inside a single script block so that nothing -
# not functions, not variables, not $ErrorActionPreference - leaks into the
# session of someone running `irm ... | iex`, which executes in the caller scope.
#
# Keep src/ pure ASCII. The bundle ships without a BOM, because Invoke-RestMethod
# would hand the BOM to iex, and Windows PowerShell 5.1 reads a BOM-less file as
# ANSI rather than UTF-8. Non-ASCII would therefore mojibake when the script is
# run from disk. build.ps1 enforces this.
#
# Functions read shared state from $Ctx, resolved dynamically from the enclosing
# script block scope. Mutate its members; never reassign $Ctx itself.
# =============================================================================

function New-MoscoviumContext {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$SourceUrl,
        [switch]$DryRun,
        [switch]$AssumeYes,
        [switch]$NoColor
    )

    $stateDir = Join-Path $env:LOCALAPPDATA 'Moscovium'

    [pscustomobject]@{
        Version    = $Version
        SourceUrl  = $SourceUrl
        DryRun     = [bool]$DryRun
        AssumeYes  = [bool]$AssumeYes
        UseColor   = (-not $NoColor) -and (-not [Console]::IsOutputRedirected)
        IsAdmin    = Test-Administrator
        StateDir   = $stateDir
        BackupDir  = Join-Path $stateDir 'backups'
        LogFile    = Join-Path $stateDir 'moscovium-cli.log'
        Tweaks     = @()
        TweakCategories = @()
        Apps       = @()
        AppCategories   = @()
        Applied    = 0
        Failed     = 0
        Skipped    = 0
    }
}

function Initialize-State {
    foreach ($dir in @($Ctx.StateDir, $Ctx.BackupDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')

    # Logging is best-effort: a read-only or missing profile must never abort a run.
    try {
        $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $Ctx.LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch { }
}

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------

function Write-Line {
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Text = '',
        [ConsoleColor]$Color,
        [switch]$NoNewline
    )

    if ($PSBoundParameters.ContainsKey('Color') -and $Ctx.UseColor) {
        Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline
    }
    else {
        Write-Host $Text -NoNewline:$NoNewline
    }
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Line '  ~ ' -Color DarkCyan -NoNewline
    Write-Line $Message
    Write-Log $Message
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Line '  + ' -Color Green -NoNewline
    Write-Line $Message
    Write-Log $Message 'OK'
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Line '  ! ' -Color Yellow -NoNewline
    Write-Line $Message -Color Yellow
    Write-Log $Message 'WARN'
}

function Write-Err {
    param([Parameter(Mandatory)][string]$Message)
    Write-Line '  x ' -Color Red -NoNewline
    Write-Line $Message -Color Red
    Write-Log $Message 'ERROR'
}

function Write-Info {
    param([AllowEmptyString()][string]$Message = '')
    Write-Line "    $Message" -Color DarkGray
}

function Write-SectionHeading {
    param([Parameter(Mandatory)][string]$Title)
    Write-Line ''
    Write-Line "  $Title" -Color White
    Write-Line ('  ' + ('-' * $Title.Length)) -Color DarkGray
}

function Write-Banner {
    # Plain ASCII only: this has to render correctly in a legacy conhost window
    # running code page 437, not just in Windows Terminal. The backtick on the
    # fourth line is part of the letterform, not a PowerShell escape - these are
    # single-quoted strings, so it is taken literally.
    $art = @(
        '',
        '   __  __                                   _',
        '  |  \/  |  ___   ___   ___   ___  __   __ (_) _   _  _ __ ___  ',
        '  | |\/| | / _ \ / __| / __| / _ \ \ \ / / | || | | || ''_ ` _ \ ',
        '  | |  | || (_) |\__ \| (__ | (_) | \ V /  | || |_| || | | | | |',
        '  |_|  |_| \___/ |___/ \___| \___/   \_/   |_| \__,_||_| |_| |_|'
    )

    foreach ($line in $art) { Write-Line $line -Color Cyan }

    Write-Line ("  CLI v{0}   Windows debloat and setup toolbox" -f $Ctx.Version) -Color DarkGray

    $badges = @()
    if ($Ctx.IsAdmin) { $badges += 'elevated' } else { $badges += 'NOT elevated' }
    if ($Ctx.DryRun)  { $badges += 'dry run' }
    Write-Line ('  ' + ($badges -join '  |  ')) -Color DarkGray
    Write-Line ''
}

# -----------------------------------------------------------------------------
# Prompting
# -----------------------------------------------------------------------------

# True when we can read individual keypresses. `irm ... | iex` still leaves the
# host interactive (the pipe is internal to PowerShell), but -NonInteractive
# hosts and redirected stdin need the numbered fallback menus.
function Test-Interactive {
    try {
        if ([Console]::IsInputRedirected) { return $false }
        if (-not $Host.UI.RawUI) { return $false }
        # ISE has no working ReadKey with NoEcho.
        if ($Host.Name -eq 'Windows PowerShell ISE Host') { return $false }
        return $true
    }
    catch { return $false }
}

function Confirm-Action {
    param(
        [Parameter(Mandatory)][string]$Message,
        [switch]$DefaultYes
    )

    if ($Ctx.AssumeYes) { return $true }
    if (-not (Test-Interactive)) {
        Write-Warn "Cannot prompt for confirmation in a non-interactive host. Pass -Yes to proceed."
        return $false
    }

    $hint = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        Write-Line ''
        Write-Line "  $Message $hint " -Color Yellow -NoNewline
        $answer = Read-Host

        if ([string]::IsNullOrWhiteSpace($answer)) { return [bool]$DefaultYes }
        switch -Regex ($answer.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
            default     { Write-Warn 'Please answer y or n.' }
        }
    }
}

# -----------------------------------------------------------------------------
# Elevation
# -----------------------------------------------------------------------------

function Test-Administrator {
    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

# Rebuilds the original invocation as a command string for the elevated child.
# When the script came from disk we re-run the file; when it was piped from the
# network (irm ... | iex) there is nothing on disk, so the child re-fetches the
# same pinned URL.
function Get-RelaunchCommand {
    param([hashtable]$BoundParameters)

    $parts = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $BoundParameters.Keys) {
        $value = $BoundParameters[$key]

        if ($value -is [switch]) {
            if ($value.IsPresent) { $parts.Add("-$key") }
            continue
        }
        if ($value -is [bool]) {
            $parts.Add("-$key`:`$$value")
            continue
        }

        $items = @($value) | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }
        $parts.Add("-$key " + ($items -join ','))
    }

    $argText = $parts -join ' '

    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        $escaped = $PSCommandPath -replace "'", "''"
        return "& '$escaped' $argText"
    }

    $url = $Ctx.SourceUrl -replace "'", "''"
    return "& ([scriptblock]::Create((irm '$url'))) $argText"
}

function Invoke-SelfElevate {
    param([hashtable]$BoundParameters = @{})

    if ($Ctx.IsAdmin) { return $true }

    Write-Warn 'Administrator rights are required for machine-wide changes (HKLM, services, boot config).'

    if (-not (Confirm-Action 'Relaunch Moscovium in an elevated window?' -DefaultYes)) {
        Write-Info 'Staying unelevated. Only per-user (HKCU) changes will succeed.'
        return $false
    }

    $command = Get-RelaunchCommand -BoundParameters $BoundParameters
    Write-Log "Self-elevating with: $command"

    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile'
            '-ExecutionPolicy', 'Bypass'
            '-NoExit'
            '-Command', $command
        ) -ErrorAction Stop

        Write-Ok 'Elevated window launched. Continue there.'
        return $true
    }
    catch {
        Write-Err "Elevation was declined or failed: $($_.Exception.Message)"
        return $false
    }
}

# -----------------------------------------------------------------------------
# Misc
# -----------------------------------------------------------------------------

function Format-Columns {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Items,
        [int]$Indent = 4
    )

    if ($Items.Count -eq 0) { return }

    $width = ($Items | Measure-Object -Property Length -Maximum).Maximum + 2
    $available = 100
    try { $available = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width - $Indent - 1) } catch { }

    $perRow = [Math]::Max(1, [Math]::Floor($available / $width))
    $pad = ' ' * $Indent

    for ($i = 0; $i -lt $Items.Count; $i += $perRow) {
        $row = $Items[$i..([Math]::Min($i + $perRow - 1, $Items.Count - 1))]
        Write-Line ($pad + (($row | ForEach-Object { $_.PadRight($width) }) -join '')).TrimEnd() -Color Gray
    }
}

# Case-insensitive wildcard match used by every -Search/-Apply name resolver.
function Test-NameMatch {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Pattern
    )

    if ($Value -like $Pattern) { return $true }
    # Bare terms behave as substring searches.
    if ($Pattern -notmatch '[\*\?]') { return $Value -like "*$Pattern*" }
    return $false
}
