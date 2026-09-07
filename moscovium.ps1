<#
    Moscovium CLI v1.2.0
    Windows debloat and setup toolbox - the command line companion to
    https://github.com/Moscoviumdebloat/Moscovium

        irm https://moscovium.win | iex

    Build 80f6fd927c  (a digest of src/ and data/ - same sources, same id).
    Check with:  .\moscovium.ps1 -Version

    GENERATED FILE - do not edit.
    Built from src/ and data/ by build.ps1. Edit those and rebuild.
#>

[CmdletBinding()]
param(
    # Tweaks
    [string[]]$Apply,
    [string[]]$Revert,
    [switch]  $Status,

    # Apps
    [string[]]$Install,
    [switch]  $UpgradeAll,
    [switch]  $VCRuntimes,
    [switch]  $WindowsUpdate,

    # Other actions
    [switch]  $Gui,
    [string]  $Toolbox,
    [string]  $Profile,
    [string]  $SaveProfile,
    [string[]]$List,
    [string]  $Search,

    # Flags
    [switch]  $DryRun,
    [switch]  $Yes,
    [switch]  $Elevate,
    [switch]  $NoColor,
    [switch]  $Ascii,
    [switch]  $NoBanner,
    [switch]  $Version,
    [switch]  $Help,

    # URL this script re-downloads from when relaunching elevated.
    [string]  $SourceUrl = 'https://raw.githubusercontent.com/Moscoviumdebloat/Moscovium-CLI/main/moscovium.ps1'
)

# Everything runs inside this script block so that iex, which executes in the
# caller's scope, leaves no functions, variables or preference changes behind.
#
# None of these parameters are Mandatory: with no arguments $PSBoundParameters is
# an empty dictionary, and PowerShell treats an empty collection as a missing
# mandatory argument and would prompt for it.
& {
    param($Bound, [string]$BuildVersion, [string]$Source, [string]$BuildStamp)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Host 'Moscovium CLI needs Windows PowerShell 5.1 or newer.' -ForegroundColor Red
        return
    }

    # $PSBoundParameters is a Dictionary, not a hashtable; normalise it once.
    $BoundParameters = @{}
    if ($Bound) {
        foreach ($key in $Bound.Keys) { $BoundParameters[$key] = $Bound[$key] }
    }

    # ContainsKey alone would treat an explicit -DryRun:$false as "on".
    function Test-Flag {
        param([string]$Name)
        $BoundParameters.ContainsKey($Name) -and [bool]$BoundParameters[$Name]
    }

# ===== src/00-Core.ps1 =================================================

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
            [switch]$NoColor,
            [switch]$Ascii,
            [string]$BuildStamp = ''
        )

        $stateDir = Join-Path $env:LOCALAPPDATA 'Moscovium'

        $redirected = $true
        try { $redirected = [Console]::IsOutputRedirected } catch { }

        [pscustomobject]@{
            Version    = $Version
            # Identifies exactly which build this is, so `irm ... | iex` users can tell
            # whether they picked up a cached copy.
            BuildStamp = $BuildStamp
            SourceUrl  = $SourceUrl
            DryRun     = [bool]$DryRun
            AssumeYes  = [bool]$AssumeYes
            UseColor   = (-not $NoColor) -and (-not $redirected)
            # Spinners and progress bars rewrite the current line, which only makes
            # sense on a real console.
            Animate    = (-not $redirected)
            Theme      = (New-Theme -Ascii:$Ascii)

            # Output sinks. Left null, everything goes to the console. The GUI sets
            # them so the exact same engine functions drive a window instead - no
            # duplicate apply/install/toolbox logic anywhere.
            #   Sink         (text, color, newline)      -> log pane
            #   ProgressSink (label, fraction, detail)   -> progress bar
            #   ConfirmSink  (message, defaultYes)       -> modal dialog, returns bool
            Sink         = $null
            ProgressSink = $null
            ConfirmSink  = $null

            # Live GUI state, parked here rather than captured in a closure: the
            # wrapper scope stays reachable from plain script blocks, which is what
            # WPF event handlers have to be. See the note at the top of 70-Gui.ps1.
            Gui          = $null

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
            [ConsoleColor]$Background,
            [switch]$NoNewline
        )

        # Every piece of console output in the CLI funnels through here, so a sink
        # set on the context redirects all of it - status lines, rules, chips and
        # summaries alike - without any caller knowing.
        if ($Ctx.Sink) {
            $sinkColor = if ($PSBoundParameters.ContainsKey('Color')) { $Color } else { $null }
            & $Ctx.Sink $Text $sinkColor (-not $NoNewline)
            return
        }

        if (-not $Ctx.UseColor) {
            Write-Host $Text -NoNewline:$NoNewline
            return
        }

        $splat = @{ Object = $Text; NoNewline = $NoNewline }
        if ($PSBoundParameters.ContainsKey('Color'))      { $splat.ForegroundColor = $Color }
        if ($PSBoundParameters.ContainsKey('Background')) { $splat.BackgroundColor = $Background }

        Write-Host @splat
    }

    # Status lines share one shape: two spaces, a coloured glyph, the message. The
    # glyph set swaps to ASCII on a console that cannot render the nicer one.
    function Write-Status {
        param(
            [Parameter(Mandatory)][string]$Glyph,
            [Parameter(Mandatory)][ConsoleColor]$Color,
            [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
            [ConsoleColor]$MessageColor
        )

        Write-Line ('  ' + $Glyph + ' ') -Color $Color -NoNewline
        if ($PSBoundParameters.ContainsKey('MessageColor')) { Write-Line $Message -Color $MessageColor }
        else { Write-Line $Message }
    }

    function Write-Step {
        param([Parameter(Mandatory)][string]$Message)
        Write-Status -Glyph (Get-Glyph 'Step') -Color (Get-Color 'AccentDim') -Message $Message
        Write-Log $Message
    }

    function Write-Ok {
        param([Parameter(Mandatory)][string]$Message)
        Write-Status -Glyph (Get-Glyph 'Ok') -Color (Get-Color 'Ok') -Message $Message
        Write-Log $Message 'OK'
    }

    function Write-Warn {
        param([Parameter(Mandatory)][string]$Message)
        Write-Status -Glyph (Get-Glyph 'Warn') -Color (Get-Color 'Warn') -Message $Message -MessageColor (Get-Color 'Warn')
        Write-Log $Message 'WARN'
    }

    function Write-Err {
        param([Parameter(Mandatory)][string]$Message)
        Write-Status -Glyph (Get-Glyph 'Err') -Color (Get-Color 'Err') -Message $Message -MessageColor (Get-Color 'Err')
        Write-Log $Message 'ERROR'
    }

    function Write-Info {
        param([AllowEmptyString()][string]$Message = '')
        Write-Line "      $Message" -Color (Get-Color 'Muted')
    }

    function Write-SectionHeading {
        param([Parameter(Mandatory)][string]$Title, [AllowEmptyString()][string]$Suffix = '')
        Write-Rule -Title $Title -Suffix $Suffix -TitleColor (Get-Color 'Bright')
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

        # Top-down brightness gradient. Only 16 colours are in play, so the ramp is
        # White -> Cyan -> DarkCyan rather than anything smoother, but it reads well
        # and needs no ANSI support.
        $ramp = @(
            [ConsoleColor]::White
            [ConsoleColor]::White
            [ConsoleColor]::Cyan
            [ConsoleColor]::Cyan
            [ConsoleColor]::DarkCyan
            [ConsoleColor]::DarkCyan
        )

        for ($i = 0; $i -lt $art.Count; $i++) {
            Write-Line $art[$i] -Color $ramp[[Math]::Min($i, $ramp.Count - 1)]
        }

        Write-Rule

        $label = if ($Ctx.BuildStamp) { "v$($Ctx.Version) $(($Ctx.BuildStamp -split ' ')[0])" } else { "v$($Ctx.Version)" }
        $chips = @(New-Chip -Text $label -Color (Get-Color 'Bright'))

        # Counts are only meaningful once the catalog has loaded.
        if ($Ctx.Tweaks.Count -gt 0) {
            $chips += New-Chip -Text "$($Ctx.Tweaks.Count) tweaks" -Color (Get-Color 'Text')
            $chips += New-Chip -Text "$($Ctx.Apps.Count) apps" -Color (Get-Color 'Text')
        }

        if ($Ctx.IsAdmin) {
            $chips += New-Chip -Text 'elevated' -Color (Get-Color 'Ok') -Glyph (Get-Glyph 'Dot')
        }
        else {
            $chips += New-Chip -Text 'not elevated' -Color (Get-Color 'Warn') -Glyph (Get-Glyph 'Dot')
        }

        if ($Ctx.DryRun) {
            $chips += New-Chip -Text 'dry run' -Color (Get-Color 'Warn') -Glyph (Get-Glyph 'Dot')
        }

        Write-Chips -Chips $chips
        Write-Rule -Tight
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

        # The GUI answers with a modal dialog rather than Read-Host, so third-party
        # script prompts stay real questions instead of being auto-accepted.
        if ($Ctx.ConfirmSink) { return [bool](& $Ctx.ConfirmSink $Message ([bool]$DefaultYes)) }

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

# ===== src/01-Catalog.ps1 ==============================================

    # =============================================================================
    # Catalog loading.
    #
    # The tweak and app catalogs are generated from the Moscovium GUI's C# source by
    # tools/Sync-Catalog.ps1 and embedded into the bundle by build.ps1, so the single
    # distributed moscovium.ps1 has no runtime dependency on the repo.
    #
    # build.ps1 rewrites the two assignments below. When they are empty we are
    # running from the source tree, so fall back to reading data/ from disk.
    # =============================================================================

    $EmbeddedTweaksJson = @'
{
    "categories":  [
                       "Privacy & Telemetry",
                       "Explorer & Taskbar",
                       "Gaming & Performance",
                       "Hardware & Gaming",
                       "Advanced"
                   ],
    "tweaks":  [
                   {
                       "name":  "Disable Telemetry",
                       "description":  "Disables Microsoft telemetry, advertising ID, targeted ads and speech data collection.",
                       "category":  "Privacy & Telemetry",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo",
                                            "name":  "Enabled",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Privacy",
                                            "name":  "TailoredExperiencesWithDiagnosticDataEnabled",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Speech_OneCore\\Settings\\OnlineSpeechPrivacy",
                                            "name":  "HasAccepted",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Input\\TIPC",
                                            "name":  "Enabled",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\InputPersonalization",
                                            "name":  "RestrictImplicitInkCollection",
                                            "type":  "DWord",
                                            "value":  1
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\InputPersonalization",
                                            "name":  "RestrictImplicitTextCollection",
                                            "type":  "DWord",
                                            "value":  1
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\InputPersonalization\\TrainedDataStore",
                                            "name":  "HarvestContacts",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Personalization\\Settings",
                                            "name":  "AcceptedPrivacyPolicy",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection",
                                            "name":  "AllowTelemetry",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                            "name":  "Start_TrackProgs",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                            "name":  "PublishUserActivities",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Siuf\\Rules",
                                            "name":  "NumberOfSIUFInPeriod",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Activity History",
                       "description":  "Erases recent docs, clipboard and run history tracking.",
                       "category":  "Privacy & Telemetry",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                            "name":  "EnableActivityFeed",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                            "name":  "PublishUserActivities",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                            "name":  "UploadUserActivities",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Location Tracking",
                       "description":  "Denies location access for apps and disables sensor permission.",
                       "category":  "Privacy & Telemetry",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location",
                                            "name":  "Value",
                                            "type":  "String",
                                            "value":  "Deny"
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Sensor\\Overrides\\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}",
                                            "name":  "SensorPermissionState",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SYSTEM\\Maps",
                                            "name":  "AutoUpdateEnabled",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Delivery Optimization",
                       "description":  "Stops Windows using your bandwidth to upload updates to other PCs.",
                       "category":  "Privacy & Telemetry",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows\\DeliveryOptimization",
                                            "name":  "DODownloadMode",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Consumer Features",
                       "description":  "Stops promoted app installs and Store content suggestions.",
                       "category":  "Privacy & Telemetry",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent",
                                            "name":  "DisableWindowsConsumerFeatures",
                                            "type":  "DWord",
                                            "value":  1
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable WPBT",
                       "description":  "Prevents your PC vendor from running programs at boot (anti-theft, forced software).",
                       "category":  "Privacy & Telemetry",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\Session Manager",
                                            "name":  "DisableWpbtExecution",
                                            "type":  "DWord",
                                            "value":  1
                                        }
                                    ]
                   },
                   {
                       "name":  "Set Time to UTC",
                       "description":  "Fixes clock drift when dual booting with Linux.",
                       "category":  "Privacy & Telemetry",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation",
                                            "name":  "RealTimeIsUniversal",
                                            "type":  "QWord",
                                            "value":  1
                                        }
                                    ]
                   },
                   {
                       "name":  "Show File Extensions",
                       "description":  "Shows .exe, .png etc. in File Explorer.",
                       "category":  "Explorer & Taskbar",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                            "name":  "HideFileExt",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Show Hidden Files",
                       "description":  "Reveals hidden files in File Explorer.",
                       "category":  "Explorer & Taskbar",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                            "name":  "Hidden",
                                            "type":  "DWord",
                                            "value":  1
                                        }
                                    ]
                   },
                   {
                       "name":  "Dark Theme",
                       "description":  "Enables dark mode for the system and apps.",
                       "category":  "Explorer & Taskbar",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                                            "name":  "AppsUseLightTheme",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                                            "name":  "SystemUsesLightTheme",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Lock Screen",
                       "description":  "Skips the lock screen and goes straight to sign-in.",
                       "category":  "Explorer & Taskbar",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows\\Personalization",
                                            "name":  "NoLockScreen",
                                            "type":  "DWord",
                                            "value":  1
                                        }
                                    ]
                   },
                   {
                       "name":  "Hide Start Menu Recommendations",
                       "description":  "Removes the recommended section from the Start menu.",
                       "category":  "Explorer & Taskbar",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Start",
                                            "name":  "HideRecommendedSection",
                                            "type":  "DWord",
                                            "value":  1
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Education",
                                            "name":  "IsEducationEnvironment",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer",
                                            "name":  "HideRecommendedSection",
                                            "type":  "DWord",
                                            "value":  1
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Bing in Start Search",
                       "description":  "Removes Bing web results from Start menu search.",
                       "category":  "Explorer & Taskbar",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
                                            "name":  "BingSearchEnabled",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "End Task with Right Click",
                       "description":  "Adds an End Task option when right-clicking a program on the taskbar.",
                       "category":  "Explorer & Taskbar",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings",
                                            "name":  "TaskbarEndTask",
                                            "type":  "DWord",
                                            "value":  1
                                        }
                                    ]
                   },
                   {
                       "name":  "Taskbar Icons Left",
                       "description":  "Aligns taskbar icons to the left like Windows 10.",
                       "category":  "Explorer & Taskbar",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                            "name":  "TaskbarAl",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Hide Widgets Button",
                       "description":  "Removes the widgets button from the taskbar.",
                       "category":  "Explorer & Taskbar",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                            "name":  "TaskbarDa",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                            "name":  "TaskbarMn",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Classic Right-Click Menu",
                       "description":  "Restores the full classic context menu in File Explorer.",
                       "category":  "Explorer & Taskbar",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}",
                                            "name":  "",
                                            "type":  "String",
                                            "value":  ""
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\\InprocServer32",
                                            "name":  "",
                                            "type":  "String",
                                            "value":  ""
                                        }
                                    ]
                   },
                   {
                       "name":  "Enable Long Paths",
                       "description":  "Supports file paths longer than 260 characters.",
                       "category":  "Explorer & Taskbar",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\FileSystem",
                                            "name":  "LongPathsEnabled",
                                            "type":  "DWord",
                                            "value":  1
                                        }
                                    ]
                   },
                   {
                       "name":  "Game Mode",
                       "description":  "Lets Windows prioritize system resources for games.",
                       "category":  "Gaming & Performance",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\GameBar",
                                            "name":  "AllowAutoGameMode",
                                            "type":  "DWord",
                                            "value":  1
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\GameBar",
                                            "name":  "AutoGameModeEnabled",
                                            "type":  "DWord",
                                            "value":  1
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Fullscreen Optimizations",
                       "description":  "Disables FSO for all apps (can help with exclusive fullscreen games).",
                       "category":  "Gaming & Performance",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\System\\GameConfigStore",
                                            "name":  "GameDVR_DXGIHonorFSEWindowsCompatible",
                                            "type":  "DWord",
                                            "value":  1
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Background Apps",
                       "description":  "Stops Microsoft Store apps from running in the background.",
                       "category":  "Gaming & Performance",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications",
                                            "name":  "GlobalUserDisabled",
                                            "type":  "DWord",
                                            "value":  1
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Mouse Acceleration",
                       "description":  "Removes mouse acceleration for consistent aiming.",
                       "category":  "Gaming & Performance",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Control Panel\\Mouse",
                                            "name":  "MouseSpeed",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Control Panel\\Mouse",
                                            "name":  "MouseThreshold1",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Control Panel\\Mouse",
                                            "name":  "MouseThreshold2",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Multiplane Overlay",
                       "description":  "Can fix stutter caused by overlay composition issues on some GPUs.",
                       "category":  "Gaming & Performance",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\Dwm",
                                            "name":  "OverlayTestMode",
                                            "type":  "DWord",
                                            "value":  5
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers",
                                            "name":  "DisableOverlays",
                                            "type":  "DWord",
                                            "value":  1
                                        }
                                    ]
                   },
                   {
                       "name":  "Visual Effects: Best Performance",
                       "description":  "Turns off animations and eye candy for snappier UI.",
                       "category":  "Gaming & Performance",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Control Panel\\Desktop",
                                            "name":  "DragFullWindows",
                                            "type":  "String",
                                            "value":  "0"
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Control Panel\\Desktop",
                                            "name":  "MenuShowDelay",
                                            "type":  "String",
                                            "value":  "0"
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Control Panel\\Desktop\\WindowMetrics",
                                            "name":  "MinAnimate",
                                            "type":  "String",
                                            "value":  "0"
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Control Panel\\Keyboard",
                                            "name":  "KeyboardDelay",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                            "name":  "ListviewAlphaSelect",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                            "name":  "ListviewShadow",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                            "name":  "TaskbarAnimations",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
                                            "name":  "VisualFXSetting",
                                            "type":  "DWord",
                                            "value":  3
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\DWM",
                                            "name":  "EnableAeroPeek",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                            "name":  "TaskbarMn",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                            "name":  "ShowTaskViewButton",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
                                            "name":  "SearchboxTaskbarMode",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Hibernation",
                       "description":  "Disables hibernation and removes hiberfil.sys (saves disk space).",
                       "category":  "Gaming & Performance",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Power",
                                            "name":  "HibernateEnabled",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FlyoutMenuSettings",
                                            "name":  "ShowHibernateOption",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Sticky Keys",
                       "description":  "Stops the Shift-pressed-5-times Sticky Keys prompt.",
                       "category":  "Gaming & Performance",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Control Panel\\Accessibility\\StickyKeys",
                                            "name":  "Flags",
                                            "type":  "DWord",
                                            "value":  506
                                        }
                                    ]
                   },
                   {
                       "name":  "Enable Hardware Accelerated GPU Scheduling",
                       "description":  "Lets the GPU manage its own scheduling, reducing CPU overhead in games. Requires reboot.",
                       "category":  "Hardware & Gaming",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\DirectX\\GraphicsSettings",
                                            "name":  "HwSchMode",
                                            "type":  "DWord",
                                            "value":  2
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Game DVR Recording",
                       "description":  "Disables Game Bar background recording, a known source of micro-stutter in games.",
                       "category":  "Hardware & Gaming",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\System\\GameConfigStore",
                                            "name":  "GameDVR_Enabled",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\System\\GameConfigStore",
                                            "name":  "GameDVR_FSEBehaviorMode",
                                            "type":  "DWord",
                                            "value":  2
                                        }
                                    ]
                   },
                   {
                       "name":  "High Performance Power Plan",
                       "description":  "Switches Windows to the High Performance power plan so the CPU never downclocks.",
                       "category":  "Hardware & Gaming",
                       "kind":  "PowerPlan",
                       "registry":  [

                                    ]
                   },
                   {
                       "name":  "Disable Memory Integrity (HVCI)",
                       "description":  "Disables VBS memory integrity. Can improve FPS and frame pacing on older CPUs. Security tradeoff, requires reboot.",
                       "category":  "Hardware & Gaming",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\DeviceGuard\\Scenarios\\HypervisorEnforcedCodeIntegrity",
                                            "name":  "Enabled",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable CPU Mitigations",
                       "description":  "Disables Spectre/Meltdown mitigations for a small CPU gain on older CPUs (pre-12th gen). Security tradeoff, requires reboot.",
                       "category":  "Hardware & Gaming",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management",
                                            "name":  "CpuMitigations",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Edge Debloat",
                       "description":  "Disables Edge telemetry, shopping assistant, Rewards, first-run experience and more.",
                       "category":  "Advanced",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\EdgeUpdate",
                                            "name":  "CreateDesktopShortcutDefault",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "PersonalizationReportingEnabled",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge\\ExtensionInstallBlocklist",
                                            "name":  "1",
                                            "type":  "String",
                                            "value":  "ofefcgjbeghpigppfmkologfjadafddi"
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "ShowRecommendationsEnabled",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "HideFirstRunExperience",
                                            "type":  "DWord",
                                            "value":  1
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "UserFeedbackAllowed",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "ConfigureDoNotTrack",
                                            "type":  "DWord",
                                            "value":  1
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "AlternateErrorPagesEnabled",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "EdgeCollectionsEnabled",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "EdgeShoppingAssistantEnabled",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "MicrosoftEdgeInsiderPromotionEnabled",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "ShowMicrosoftRewards",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "WebWidgetAllowed",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "DiagnosticData",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "EdgeAssetDeliveryServiceEnabled",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "WalletDonationEnabled",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                            "name":  "DefaultBrowserSettingsCampaignEnabled",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Storage Sense",
                       "description":  "Prevents Windows from auto-deleting temp files.",
                       "category":  "Advanced",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy",
                                            "name":  "01",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Reserved Storage",
                       "description":  "Frees 7-10 GB held for updates (recommended only on small drives).",
                       "category":  "Advanced",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ReserveManager",
                                            "name":  "ShippedWithReserves",
                                            "type":  "DWord",
                                            "value":  0
                                        }
                                    ]
                   },
                   {
                       "name":  "File Explorer Home & Gallery",
                       "description":  "Removes Home and Gallery from Explorer and opens This PC by default.",
                       "category":  "Advanced",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Classes\\CLSID\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",
                                            "name":  "System.IsPinnedToNameSpaceTree",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Classes\\CLSID\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}",
                                            "name":  "System.IsPinnedToNameSpaceTree",
                                            "type":  "DWord",
                                            "value":  0
                                        },
                                        {
                                            "path":  "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                            "name":  "LaunchTo",
                                            "type":  "DWord",
                                            "value":  1
                                        }
                                    ]
                   },
                   {
                       "name":  "Prefer IPv4 over IPv6",
                       "description":  "Can improve latency on networks without IPv6.",
                       "category":  "Advanced",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
                                            "name":  "DisabledComponents",
                                            "type":  "DWord",
                                            "value":  32
                                        }
                                    ]
                   },
                   {
                       "name":  "Disable Teredo",
                       "description":  "Disables Teredo tunneling, which can cause latency in some games.",
                       "category":  "Advanced",
                       "kind":  "Registry",
                       "registry":  [
                                        {
                                            "path":  "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
                                            "name":  "DisabledComponents",
                                            "type":  "DWord",
                                            "value":  1
                                        }
                                    ]
                   },
                   {
                       "name":  "Create Restore Point",
                       "description":  "Creates a system restore point so you can revert tweaks.",
                       "category":  "Advanced",
                       "kind":  "RestorePoint",
                       "registry":  [

                                    ]
                   },
                   {
                       "name":  "Disk Cleanup",
                       "description":  "Runs Disk Cleanup and removes old Windows updates.",
                       "category":  "Advanced",
                       "kind":  "CleanDisk",
                       "registry":  [

                                    ]
                   },
                   {
                       "name":  "Remove Temp Files",
                       "description":  "Erases TEMP folders for all users.",
                       "category":  "Advanced",
                       "kind":  "CleanTemp",
                       "registry":  [

                                    ]
                   }
               ],
    "source":  {
                   "repo":  "https://github.com/Moscoviumdebloat/Moscovium.git",
                   "commit":  "ad56ca1",
                   "syncedUtc":  "2026-09-06T10:57:32.3675869Z"
               }
}
'@
    $EmbeddedAppsJson = @'
{
    "categories":  [
                       "Browsers",
                       "Gaming & Media",
                       "Creativity & Media",
                       "IDEs & Editors",
                       "Languages & Runtimes",
                       "Dev Tools & AI",
                       "Utilities",
                       "Drivers & Hardware"
                   ],
    "apps":  [
                 {
                     "id":  "Google.Chrome",
                     "name":  "Google Chrome",
                     "wingetId":  "Google.Chrome",
                     "category":  "Browsers",
                     "description":  "The classic Google browser",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Mozilla.Firefox",
                     "name":  "Mozilla Firefox",
                     "wingetId":  "Mozilla.Firefox",
                     "category":  "Browsers",
                     "description":  "Privacy-focused browser from Mozilla",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Brave.Brave",
                     "name":  "Brave",
                     "wingetId":  "Brave.Brave",
                     "category":  "Browsers",
                     "description":  "Chromium browser with built-in ad blocking",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "ImputNet.Helium",
                     "name":  "Helium",
                     "wingetId":  "ImputNet.Helium",
                     "category":  "Browsers",
                     "description":  "Lightweight, fast Chromium browser",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Vivaldi.Vivaldi",
                     "name":  "Vivaldi",
                     "wingetId":  "Vivaldi.Vivaldi",
                     "category":  "Browsers",
                     "description":  "Power-user Chromium browser, highly customizable",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Opera.Opera",
                     "name":  "Opera",
                     "wingetId":  "Opera.Opera",
                     "category":  "Browsers",
                     "description":  "Feature-packed Chromium browser",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Ablaze.Floorp",
                     "name":  "Floorp",
                     "wingetId":  "Ablaze.Floorp",
                     "category":  "Browsers",
                     "description":  "Customizable Firefox fork",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "LibreWolf.LibreWolf",
                     "name":  "LibreWolf",
                     "wingetId":  "LibreWolf.LibreWolf",
                     "category":  "Browsers",
                     "description":  "Privacy-hardened Firefox fork",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "TheBrowserCompany.Arc",
                     "name":  "Arc",
                     "wingetId":  "TheBrowserCompany.Arc",
                     "category":  "Browsers",
                     "description":  "Chromium browser with Spaces & tabs",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Valve.Steam",
                     "name":  "Steam",
                     "wingetId":  "Valve.Steam",
                     "category":  "Gaming & Media",
                     "description":  "PC game store & library",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "EpicGames.EpicGamesLauncher",
                     "name":  "Epic Games Launcher",
                     "wingetId":  "EpicGames.EpicGamesLauncher",
                     "category":  "Gaming & Media",
                     "description":  "Epic store & game launcher",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "ElectronicArts.EADesktop",
                     "name":  "EA App",
                     "wingetId":  "ElectronicArts.EADesktop",
                     "category":  "Gaming & Media",
                     "description":  "EA games launcher",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Discord.Discord",
                     "name":  "Discord",
                     "wingetId":  "Discord.Discord",
                     "category":  "Gaming & Media",
                     "description":  "Chat & voice for communities",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Discord.Discord.PTB",
                     "name":  "Discord PTB",
                     "wingetId":  "Discord.Discord.PTB",
                     "category":  "Gaming & Media",
                     "description":  "Discord public test build",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Telegram.TelegramDesktop",
                     "name":  "Telegram",
                     "wingetId":  "Telegram.TelegramDesktop",
                     "category":  "Gaming & Media",
                     "description":  "Fast, secure messaging",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "TeamSpeakSystems.TeamSpeakClient.Beta.6",
                     "name":  "TeamSpeak 6 (Beta)",
                     "wingetId":  "TeamSpeakSystems.TeamSpeakClient.Beta.6",
                     "category":  "Gaming & Media",
                     "description":  "Low-latency voice chat, beta",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Spotify.Spotify",
                     "name":  "Spotify",
                     "wingetId":  "Spotify.Spotify",
                     "category":  "Gaming & Media",
                     "description":  "Music streaming",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "OBSProject.OBSStudio",
                     "name":  "OBS Studio",
                     "wingetId":  "OBSProject.OBSStudio",
                     "category":  "Gaming & Media",
                     "description":  "Streaming & screen recording",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "qBittorrent.qBittorrent",
                     "name":  "qBittorrent",
                     "wingetId":  "qBittorrent.qBittorrent",
                     "category":  "Gaming & Media",
                     "description":  "Open-source torrent client",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Blizzard.BattleNet",
                     "name":  "Battle.net",
                     "wingetId":  "Blizzard.BattleNet",
                     "category":  "Gaming & Media",
                     "description":  "Blizzard games launcher",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Mojang.MinecraftLauncher",
                     "name":  "Minecraft Launcher",
                     "wingetId":  "Mojang.MinecraftLauncher",
                     "category":  "Gaming & Media",
                     "description":  "Minecraft game launcher",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "GOG.Galaxy",
                     "name":  "GOG Galaxy",
                     "wingetId":  "GOG.Galaxy",
                     "category":  "Gaming & Media",
                     "description":  "DRM-free games launcher",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Playnite.Playnite",
                     "name":  "Playnite",
                     "wingetId":  "Playnite.Playnite",
                     "category":  "Gaming & Media",
                     "description":  "Unified game library manager",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Ubisoft.Connect",
                     "name":  "Ubisoft Connect",
                     "wingetId":  "Ubisoft.Connect",
                     "category":  "Gaming & Media",
                     "description":  "Ubisoft games launcher",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "HeroicGamesLauncher.HeroicGamesLauncher",
                     "name":  "Heroic Games Launcher",
                     "wingetId":  "HeroicGamesLauncher.HeroicGamesLauncher",
                     "category":  "Gaming & Media",
                     "description":  "Open-source Epic & GOG launcher",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "ItchIo.Itch",
                     "name":  "itch.io",
                     "wingetId":  "ItchIo.Itch",
                     "category":  "Gaming & Media",
                     "description":  "Indie games launcher",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Daum.PotPlayer",
                     "name":  "PotPlayer",
                     "wingetId":  "Daum.PotPlayer",
                     "category":  "Gaming & Media",
                     "description":  "Feature-rich video player",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "PeterPawlowski.foobar2000",
                     "name":  "foobar2000",
                     "wingetId":  "PeterPawlowski.foobar2000",
                     "category":  "Gaming & Media",
                     "description":  "Lightweight audio player",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "rocksdanister.LivelyWallpaper",
                     "name":  "Lively Wallpaper",
                     "wingetId":  "rocksdanister.LivelyWallpaper",
                     "category":  "Gaming & Media",
                     "description":  "Animated desktop wallpapers",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "KDE.Krita",
                     "name":  "Krita",
                     "wingetId":  "KDE.Krita",
                     "category":  "Creativity & Media",
                     "description":  "Digital painting app",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "GIMP.GIMP",
                     "name":  "GIMP",
                     "wingetId":  "GIMP.GIMP",
                     "category":  "Creativity & Media",
                     "description":  "Open-source image editor",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "BlenderFoundation.Blender",
                     "name":  "Blender",
                     "wingetId":  "BlenderFoundation.Blender",
                     "category":  "Creativity & Media",
                     "description":  "3D modeling & animation",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "HandBrake.HandBrake",
                     "name":  "HandBrake",
                     "wingetId":  "HandBrake.HandBrake",
                     "category":  "Creativity & Media",
                     "description":  "Video transcoder",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Audacity.Audacity",
                     "name":  "Audacity",
                     "wingetId":  "Audacity.Audacity",
                     "category":  "Creativity & Media",
                     "description":  "Audio editor & recorder",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Microsoft.VisualStudioCode",
                     "name":  "Visual Studio Code",
                     "wingetId":  "Microsoft.VisualStudioCode",
                     "category":  "IDEs & Editors",
                     "description":  "Microsoft's code editor",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Anysphere.Cursor",
                     "name":  "Cursor",
                     "wingetId":  "Anysphere.Cursor",
                     "category":  "IDEs & Editors",
                     "description":  "AI-powered code editor",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Google.Antigravity",
                     "name":  "Antigravity",
                     "wingetId":  "Google.Antigravity",
                     "category":  "IDEs & Editors",
                     "description":  "Google AI IDE",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Microsoft.VisualStudio.2022.Community",
                     "name":  "Visual Studio 2022 (Community)",
                     "wingetId":  "Microsoft.VisualStudio.2022.Community",
                     "category":  "IDEs & Editors",
                     "description":  "Full-featured .NET IDE",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Google.AndroidStudio",
                     "name":  "Android Studio",
                     "wingetId":  "Google.AndroidStudio",
                     "category":  "IDEs & Editors",
                     "description":  "Android development IDE",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "JetBrains.IntelliJIDEA.Community",
                     "name":  "IntelliJ IDEA (Community)",
                     "wingetId":  "JetBrains.IntelliJIDEA.Community",
                     "category":  "IDEs & Editors",
                     "description":  "Java/Kotlin IDE",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "JetBrains.PyCharm.Community",
                     "name":  "PyCharm (Community)",
                     "wingetId":  "JetBrains.PyCharm.Community",
                     "category":  "IDEs & Editors",
                     "description":  "Python IDE",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "JetBrains.WebStorm",
                     "name":  "WebStorm",
                     "wingetId":  "JetBrains.WebStorm",
                     "category":  "IDEs & Editors",
                     "description":  "JavaScript IDE",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "JetBrains.Rider",
                     "name":  "Rider",
                     "wingetId":  "JetBrains.Rider",
                     "category":  "IDEs & Editors",
                     "description":  ".NET IDE",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "JetBrains.CLion",
                     "name":  "CLion",
                     "wingetId":  "JetBrains.CLion",
                     "category":  "IDEs & Editors",
                     "description":  "C/C++ IDE",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "JetBrains.GoLand",
                     "name":  "GoLand",
                     "wingetId":  "JetBrains.GoLand",
                     "category":  "IDEs & Editors",
                     "description":  "Go IDE",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "JetBrains.DataGrip",
                     "name":  "DataGrip",
                     "wingetId":  "JetBrains.DataGrip",
                     "category":  "IDEs & Editors",
                     "description":  "Database IDE",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Notepad++.Notepad++",
                     "name":  "Notepad++",
                     "wingetId":  "Notepad++.Notepad++",
                     "category":  "IDEs & Editors",
                     "description":  "Lightweight text/code editor",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "SublimeHQ.SublimeText.4",
                     "name":  "Sublime Text 4",
                     "wingetId":  "SublimeHQ.SublimeText.4",
                     "category":  "IDEs & Editors",
                     "description":  "Fast code editor",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "ZedIndustries.Zed",
                     "name":  "Zed",
                     "wingetId":  "ZedIndustries.Zed",
                     "category":  "IDEs & Editors",
                     "description":  "High-performance code editor",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "vim.vim",
                     "name":  "Vim",
                     "wingetId":  "vim.vim",
                     "category":  "IDEs & Editors",
                     "description":  "Terminal text editor",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Neovim.Neovim",
                     "name":  "Neovim",
                     "wingetId":  "Neovim.Neovim",
                     "category":  "IDEs & Editors",
                     "description":  "Modern Vim, extensible",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Python.Python.3.13",
                     "name":  "Python 3.13",
                     "wingetId":  "Python.Python.3.13",
                     "category":  "Languages & Runtimes",
                     "description":  "Python language runtime",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "OpenJS.NodeJS.LTS",
                     "name":  "Node.js (LTS)",
                     "wingetId":  "OpenJS.NodeJS.LTS",
                     "category":  "Languages & Runtimes",
                     "description":  "JavaScript runtime",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Git.Git",
                     "name":  "Git",
                     "wingetId":  "Git.Git",
                     "category":  "Languages & Runtimes",
                     "description":  "Version control",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Rustlang.Rustup",
                     "name":  "Rust (rustup)",
                     "wingetId":  "Rustlang.Rustup",
                     "category":  "Languages & Runtimes",
                     "description":  "Rust toolchain installer",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "GoLang.Go",
                     "name":  "Go",
                     "wingetId":  "GoLang.Go",
                     "category":  "Languages & Runtimes",
                     "description":  "Go language toolchain",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "EclipseAdoptium.Temurin.21.JDK",
                     "name":  "OpenJDK 21 (Temurin)",
                     "wingetId":  "EclipseAdoptium.Temurin.21.JDK",
                     "category":  "Languages & Runtimes",
                     "description":  "Java runtime & SDK",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Microsoft.DotNet.SDK.10",
                     "name":  ".NET SDK",
                     "wingetId":  "Microsoft.DotNet.SDK.10",
                     "category":  "Languages & Runtimes",
                     "description":  ".NET development SDK",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Docker.DockerDesktop",
                     "name":  "Docker Desktop",
                     "wingetId":  "Docker.DockerDesktop",
                     "category":  "Dev Tools & AI",
                     "description":  "Containers & dev environments",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Microsoft.WindowsTerminal",
                     "name":  "Windows Terminal",
                     "wingetId":  "Microsoft.WindowsTerminal",
                     "category":  "Dev Tools & AI",
                     "description":  "Modern terminal",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "GitHub.GitHubDesktop",
                     "name":  "GitHub Desktop",
                     "wingetId":  "GitHub.GitHubDesktop",
                     "category":  "Dev Tools & AI",
                     "description":  "Git GUI",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "JetBrains.Toolbox",
                     "name":  "JetBrains Toolbox",
                     "wingetId":  "JetBrains.Toolbox",
                     "category":  "Dev Tools & AI",
                     "description":  "JetBrains IDE manager",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Eugeny.Tabby",
                     "name":  "Tabby (Terminus SSH)",
                     "wingetId":  "Eugeny.Tabby",
                     "category":  "Dev Tools & AI",
                     "description":  "Modern SSH & terminal client",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Termius.Termius",
                     "name":  "Termius (SSH client)",
                     "wingetId":  null,
                     "category":  "Dev Tools & AI",
                     "description":  "Cross-platform SSH client",
                     "source":  null,
                     "downloadUrl":  "https://download.termius.com/windows/Install%20Termius.exe",
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "ElementLabs.LMStudio",
                     "name":  "LM Studio",
                     "wingetId":  "ElementLabs.LMStudio",
                     "category":  "Dev Tools & AI",
                     "description":  "Local LLM chat & models",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Anthropic.ClaudeCode",
                     "name":  "Claude Code (CLI)",
                     "wingetId":  "Anthropic.ClaudeCode",
                     "category":  "Dev Tools & AI",
                     "description":  "Anthropic AI coding agent",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "OpenAI.Codex",
                     "name":  "OpenAI Codex (CLI)",
                     "wingetId":  "OpenAI.Codex",
                     "category":  "Dev Tools & AI",
                     "description":  "OpenAI coding agent",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "T3Tools.T3Code",
                     "name":  "T3 Code",
                     "wingetId":  "T3Tools.T3Code",
                     "category":  "Dev Tools & AI",
                     "description":  "Multi-provider coding agent",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Postman.Postman",
                     "name":  "Postman (API)",
                     "wingetId":  "Postman.Postman",
                     "category":  "Dev Tools & AI",
                     "description":  "API testing client",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Insomnia.Insomnia",
                     "name":  "Insomnia (API)",
                     "wingetId":  "Insomnia.Insomnia",
                     "category":  "Dev Tools & AI",
                     "description":  "API design & testing",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "DevToys-app.DevToys",
                     "name":  "DevToys",
                     "wingetId":  "DevToys-app.DevToys",
                     "category":  "Dev Tools & AI",
                     "description":  "Developer utility toolbox",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Ollama.Ollama",
                     "name":  "Ollama (Local LLMs)",
                     "wingetId":  "Ollama.Ollama",
                     "category":  "Dev Tools & AI",
                     "description":  "Run LLMs locally",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "WinSCP.WinSCP",
                     "name":  "WinSCP",
                     "wingetId":  "WinSCP.WinSCP",
                     "category":  "Dev Tools & AI",
                     "description":  "SFTP/FTP file client",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Microsoft.Sysinternals.Suite",
                     "name":  "Sysinternals Suite",
                     "wingetId":  "Microsoft.Sysinternals.Suite",
                     "category":  "Dev Tools & AI",
                     "description":  "Advanced Windows tools",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "7zip.7zip",
                     "name":  "7-Zip",
                     "wingetId":  "7zip.7zip",
                     "category":  "Utilities",
                     "description":  "Archive manager",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "VideoLAN.VLC",
                     "name":  "VLC Media Player",
                     "wingetId":  "VideoLAN.VLC",
                     "category":  "Utilities",
                     "description":  "Universal media player",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Microsoft.PowerToys",
                     "name":  "PowerToys",
                     "wingetId":  "Microsoft.PowerToys",
                     "category":  "Utilities",
                     "description":  "Windows power utilities",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "voidtools.Everything",
                     "name":  "Everything Search",
                     "wingetId":  "voidtools.Everything",
                     "category":  "Utilities",
                     "description":  "Instant file search",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "ShareX.ShareX",
                     "name":  "ShareX",
                     "wingetId":  "ShareX.ShareX",
                     "category":  "Utilities",
                     "description":  "Screenshots & screen capture",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "dotPDN.PaintDotNet",
                     "name":  "Paint.NET",
                     "wingetId":  "dotPDN.PaintDotNet",
                     "category":  "Utilities",
                     "description":  "Image editor",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "CodecGuide.K-LiteCodecPack.Standard",
                     "name":  "K-Lite Codec Pack",
                     "wingetId":  "CodecGuide.K-LiteCodecPack.Standard",
                     "category":  "Utilities",
                     "description":  "Video/audio codecs",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Rufus.Rufus",
                     "name":  "Rufus (USB Imager)",
                     "wingetId":  "Rufus.Rufus",
                     "category":  "Utilities",
                     "description":  "USB boot drive creator",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "CharlesMilette.TranslucentTB",
                     "name":  "TranslucentTB",
                     "wingetId":  "CharlesMilette.TranslucentTB",
                     "category":  "Utilities",
                     "description":  "Transparent taskbar",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Microsoft.Sysinternals.Autoruns",
                     "name":  "Autoruns",
                     "wingetId":  "Microsoft.Sysinternals.Autoruns",
                     "category":  "Utilities",
                     "description":  "Startup programs manager",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "WinsiderSS.SystemInformer",
                     "name":  "System Informer",
                     "wingetId":  "WinsiderSS.SystemInformer",
                     "category":  "Utilities",
                     "description":  "Advanced task manager",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "rcmaehl.MSEdgeRedirect",
                     "name":  "MSEdgeRedirect",
                     "wingetId":  "rcmaehl.MSEdgeRedirect",
                     "category":  "Utilities",
                     "description":  "Redirect Edge links to your browser",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "RevoUninstaller.RevoUninstaller",
                     "name":  "Revo Uninstaller",
                     "wingetId":  "RevoUninstaller.RevoUninstaller",
                     "category":  "Utilities",
                     "description":  "Thorough app uninstaller",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "TechNobo.TcNoAccountSwitcher",
                     "name":  "TcNo Account Switcher",
                     "wingetId":  "TechNobo.TcNoAccountSwitcher",
                     "category":  "Utilities",
                     "description":  "Switch accounts for games/apps",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "CipherMachines.EnigmaSim",
                     "name":  "Enigma Machine Simulator",
                     "wingetId":  null,
                     "category":  "Utilities",
                     "description":  "Classic Enigma machine sim",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  "https://www.ciphermachinesandcryptology.com/files/EnigmaSim.zip",
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "AntibodySoftware.WizTree",
                     "name":  "WizTree",
                     "wingetId":  "AntibodySoftware.WizTree",
                     "category":  "Utilities",
                     "description":  "Fast disk usage analyzer",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "WinDirStat.WinDirStat",
                     "name":  "WinDirStat",
                     "wingetId":  "WinDirStat.WinDirStat",
                     "category":  "Utilities",
                     "description":  "Disk usage visualizer",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "RamenSoftware.Windhawk",
                     "name":  "Windhawk",
                     "wingetId":  "RamenSoftware.Windhawk",
                     "category":  "Utilities",
                     "description":  "Windows customization mods",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "valinet.ExplorerPatcher",
                     "name":  "ExplorerPatcher",
                     "wingetId":  "valinet.ExplorerPatcher",
                     "category":  "Utilities",
                     "description":  "Windows 11 taskbar/Explorer tweaks",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "StartIsBack.StartAllBack",
                     "name":  "StartAllBack",
                     "wingetId":  "StartIsBack.StartAllBack",
                     "category":  "Utilities",
                     "description":  "Classic Windows 11 Start menu",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Rainmeter.Rainmeter",
                     "name":  "Rainmeter",
                     "wingetId":  "Rainmeter.Rainmeter",
                     "category":  "Utilities",
                     "description":  "Desktop widgets",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "File-New-Project.EarTrumpet",
                     "name":  "EarTrumpet",
                     "wingetId":  "File-New-Project.EarTrumpet",
                     "category":  "Utilities",
                     "description":  "Per-app volume control",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "AntoineAflalo.SoundSwitch",
                     "name":  "SoundSwitch",
                     "wingetId":  "AntoineAflalo.SoundSwitch",
                     "category":  "Utilities",
                     "description":  "Quick audio device switching",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "QL-Win.QuickLook",
                     "name":  "QuickLook",
                     "wingetId":  "QL-Win.QuickLook",
                     "category":  "Utilities",
                     "description":  "Space-preview files",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Klocman.BulkCrapUninstaller",
                     "name":  "Bulk Crap Uninstaller",
                     "wingetId":  "Klocman.BulkCrapUninstaller",
                     "category":  "Utilities",
                     "description":  "Bulk app uninstaller",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "LocalSend.LocalSend",
                     "name":  "LocalSend",
                     "wingetId":  "LocalSend.LocalSend",
                     "category":  "Utilities",
                     "description":  "Local file sharing",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Henry++.simplewall",
                     "name":  "simplewall",
                     "wingetId":  "Henry++.simplewall",
                     "category":  "Utilities",
                     "description":  "Simple firewall manager",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "GlassWire.GlassWire",
                     "name":  "GlassWire",
                     "wingetId":  "GlassWire.GlassWire",
                     "category":  "Utilities",
                     "description":  "Network usage monitor",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Malwarebytes.Malwarebytes",
                     "name":  "Malwarebytes",
                     "wingetId":  "Malwarebytes.Malwarebytes",
                     "category":  "Utilities",
                     "description":  "Antimalware scanner",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "RustDesk.RustDesk",
                     "name":  "RustDesk (Remote Desktop)",
                     "wingetId":  null,
                     "category":  "Utilities",
                     "description":  "Open-source remote desktop",
                     "source":  null,
                     "downloadUrl":  "https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-x86_64.exe",
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  "https://github.com/rustdesk/rustdesk/releases/latest",
                     "resolvePattern":  "https://github\\.com/rustdesk/rustdesk/releases/download/[^\"' ]+/rustdesk-[^\"' ]+-x86_64\\.exe"
                 },
                 {
                     "id":  "JAMSoftware.TreeSize.Free",
                     "name":  "TreeSize Free",
                     "wingetId":  "JAMSoftware.TreeSize.Free",
                     "category":  "Utilities",
                     "description":  "Disk space explorer",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Obsidian.Obsidian",
                     "name":  "Obsidian (Notes)",
                     "wingetId":  "Obsidian.Obsidian",
                     "category":  "Utilities",
                     "description":  "Local markdown notes",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Bitwarden.Bitwarden",
                     "name":  "Bitwarden",
                     "wingetId":  "Bitwarden.Bitwarden",
                     "category":  "Utilities",
                     "description":  "Password manager",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "KeePassXCTeam.KeePassXC",
                     "name":  "KeePassXC",
                     "wingetId":  "KeePassXCTeam.KeePassXC",
                     "category":  "Utilities",
                     "description":  "Offline password manager",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Dropbox.Dropbox",
                     "name":  "Dropbox",
                     "wingetId":  "Dropbox.Dropbox",
                     "category":  "Utilities",
                     "description":  "Cloud file sync",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Mega.MEGASync",
                     "name":  "MEGA Sync",
                     "wingetId":  "Mega.MEGASync",
                     "category":  "Utilities",
                     "description":  "Encrypted cloud storage",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "TheDocumentFoundation.LibreOffice",
                     "name":  "LibreOffice",
                     "wingetId":  "TheDocumentFoundation.LibreOffice",
                     "category":  "Utilities",
                     "description":  "Free office suite",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "ONLYOFFICE.DesktopEditors",
                     "name":  "OnlyOffice",
                     "wingetId":  "ONLYOFFICE.DesktopEditors",
                     "category":  "Utilities",
                     "description":  "Office suite with doc editors",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Wagnardsoft.DisplayDriverUninstaller",
                     "name":  "Display Driver Uninstaller",
                     "wingetId":  "Wagnardsoft.DisplayDriverUninstaller",
                     "category":  "Drivers & Hardware",
                     "description":  "Clean GPU driver removal",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "CrystalDewWorld.CrystalDiskInfo",
                     "name":  "CrystalDiskInfo",
                     "wingetId":  "CrystalDewWorld.CrystalDiskInfo",
                     "category":  "Drivers & Hardware",
                     "description":  "SSD/HDD health monitor",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "REALiX.HWiNFO",
                     "name":  "HWiNFO",
                     "wingetId":  "REALiX.HWiNFO",
                     "category":  "Drivers & Hardware",
                     "description":  "System monitoring & sensors",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "CPUID.CPU-Z",
                     "name":  "CPU-Z",
                     "wingetId":  "CPUID.CPU-Z",
                     "category":  "Drivers & Hardware",
                     "description":  "CPU & system info",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Guru3D.Afterburner",
                     "name":  "MSI Afterburner",
                     "wingetId":  "Guru3D.Afterburner",
                     "category":  "Drivers & Hardware",
                     "description":  "GPU overclocking & overlay",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Nvidia.NvidiaApp",
                     "name":  "NVIDIA App",
                     "wingetId":  null,
                     "category":  "Drivers & Hardware",
                     "description":  "NVIDIA drivers & settings",
                     "source":  null,
                     "downloadUrl":  "https://us.download.nvidia.com/nvapp/client/11.0.8.299/NVIDIA_app_v11.0.8.299.exe",
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  "https://www.nvidia.com/en-us/software/nvidia-app/",
                     "resolvePattern":  "https?://us\\.download\\.nvidia\\.com/nvapp/[^\"' ]+\\.exe"
                 },
                 {
                     "id":  "AMD.Adrenalin",
                     "name":  "AMD Adrenalin Edition",
                     "wingetId":  null,
                     "category":  "Drivers & Hardware",
                     "description":  "AMD drivers & settings",
                     "source":  null,
                     "downloadUrl":  "https://drivers.amd.com/drivers/installer/26.10/whql/amd-software-adrenalin-edition-26.7.1-minimalsetup-260724_web.exe",
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  "https://www.amd.com/en/support/download/drivers.html",
                     "resolvePattern":  "https?://drivers\\.amd\\.com/drivers/installer/[^\"' ]+\\.exe"
                 },
                 {
                     "id":  "AMD.RyzenMaster",
                     "name":  "AMD Ryzen Master",
                     "wingetId":  null,
                     "category":  "Drivers & Hardware",
                     "description":  "AMD CPU overclocking",
                     "source":  null,
                     "downloadUrl":  "https://drivers.amd.com/drivers/amd_ryzen_master_3.1.1.5502.exe",
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  "https://www.amd.com/en/products/software/ryzen-master.html",
                     "resolvePattern":  "https?://drivers\\.amd\\.com/drivers/amd_ryzen_master_[^\"' ]+\\.exe"
                 },
                 {
                     "id":  "TechPowerUp.GPU-Z",
                     "name":  "GPU-Z",
                     "wingetId":  "TechPowerUp.GPU-Z",
                     "category":  "Drivers & Hardware",
                     "description":  "GPU information",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Rem0o.FanControl",
                     "name":  "FanControl",
                     "wingetId":  "Rem0o.FanControl",
                     "category":  "Drivers & Hardware",
                     "description":  "Custom fan curves",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "OpenRGB.OpenRGB",
                     "name":  "OpenRGB",
                     "wingetId":  "OpenRGB.OpenRGB",
                     "category":  "Drivers & Hardware",
                     "description":  "Unified RGB control",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Resplendence.LatencyMon",
                     "name":  "LatencyMon",
                     "wingetId":  "Resplendence.LatencyMon",
                     "category":  "Drivers & Hardware",
                     "description":  "DPC latency analyzer",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "Logitech.OptionsPlus",
                     "name":  "Logi Options+",
                     "wingetId":  "Logitech.OptionsPlus",
                     "category":  "Drivers & Hardware",
                     "description":  "Logitech device settings",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "RazerInc.RazerInstaller.Synapse4",
                     "name":  "Razer Synapse 4",
                     "wingetId":  "RazerInc.RazerInstaller.Synapse4",
                     "category":  "Drivers & Hardware",
                     "description":  "Razer device settings",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 },
                 {
                     "id":  "SteelSeries.GG",
                     "name":  "SteelSeries GG",
                     "wingetId":  "SteelSeries.GG",
                     "category":  "Drivers & Hardware",
                     "description":  "SteelSeries engine & Moments",
                     "source":  null,
                     "downloadUrl":  null,
                     "zipUrl":  null,
                     "scriptUrl":  null,
                     "resolvePageUrl":  null,
                     "resolvePattern":  null
                 }
             ],
    "source":  {
                   "repo":  "https://github.com/Moscoviumdebloat/Moscovium.git",
                   "commit":  "ad56ca1",
                   "syncedUtc":  "2026-09-06T10:57:32.3675869Z"
               }
}
'@

    function Get-CatalogJson {
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Embedded,
            [Parameter(Mandatory)][string]$FileName
        )

        if (-not [string]::IsNullOrWhiteSpace($Embedded)) { return $Embedded }

        $roots = @()
        if ($PSScriptRoot) { $roots += (Join-Path $PSScriptRoot '..\data') }
        if ($PSCommandPath) { $roots += (Join-Path (Split-Path -Parent $PSCommandPath) 'data') }
        $roots += (Join-Path (Get-Location).Path 'data')

        foreach ($root in $roots) {
            $candidate = Join-Path $root $FileName
            if (Test-Path -LiteralPath $candidate) {
                return (Get-Content -LiteralPath $candidate -Raw -Encoding UTF8)
            }
        }

        throw "Catalog '$FileName' is neither embedded in this build nor present in data/. Run tools/Sync-Catalog.ps1 then build.ps1."
    }

    function Initialize-Catalog {
        $tweakData = Get-CatalogJson -Embedded $EmbeddedTweaksJson -FileName 'tweaks.json' | ConvertFrom-Json
        $appData   = Get-CatalogJson -Embedded $EmbeddedAppsJson   -FileName 'apps.json'   | ConvertFrom-Json

        $Ctx.Tweaks          = @($tweakData.tweaks)
        $Ctx.TweakCategories = @($tweakData.categories)
        $Ctx.Apps            = @($appData.apps)
        $Ctx.AppCategories   = @($appData.categories)

        Write-Log ("Catalog loaded: {0} tweaks, {1} apps (GUI commit {2})" -f `
            $Ctx.Tweaks.Count, $Ctx.Apps.Count, $tweakData.source.commit)
    }

    # -----------------------------------------------------------------------------
    # Name resolution
    #
    # Everywhere a user names tweaks or apps they may pass an exact name, a category,
    # a wildcard, a substring, or "all". Resolution is shared so -Apply, -Revert,
    # -Install and the menus all accept the same vocabulary.
    # -----------------------------------------------------------------------------

    function Resolve-Tweak {
        # AllowNull because an empty array unrolls to $null when passed as an
        # argument, which a Mandatory parameter would otherwise reject.
        param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]]$Names)

        $matched = [System.Collections.Generic.List[object]]::new()
        $unknown = [System.Collections.Generic.List[string]]::new()

        foreach ($name in $Names) {
            $term = $name.Trim()
            if (-not $term) { continue }

            if ($term -eq 'all' -or $term -eq '*') {
                foreach ($t in $Ctx.Tweaks) { $matched.Add($t) }
                continue
            }

            # Exact name wins outright, so a tweak whose name is a substring of
            # another is still addressable.
            $exact = @($Ctx.Tweaks | Where-Object { $_.name -eq $term })
            if ($exact.Count -eq 1) { $matched.Add($exact[0]); continue }

            $byCategory = @($Ctx.Tweaks | Where-Object { $_.category -eq $term })
            if ($byCategory.Count -gt 0) {
                foreach ($t in $byCategory) { $matched.Add($t) }
                continue
            }

            $fuzzy = @($Ctx.Tweaks | Where-Object {
                (Test-NameMatch -Value $_.name -Pattern $term) -or
                (Test-NameMatch -Value $_.category -Pattern $term)
            })

            if ($fuzzy.Count -gt 0) {
                foreach ($t in $fuzzy) { $matched.Add($t) }
            }
            else {
                $unknown.Add($term)
            }
        }

        [pscustomobject]@{
            # Distinct by name, preserving first-seen order.
            Matched = @($matched | Group-Object -Property name | ForEach-Object { $_.Group[0] })
            Unknown = @($unknown)
        }
    }

    function Resolve-App {
        # AllowNull because an empty array unrolls to $null when passed as an
        # argument, which a Mandatory parameter would otherwise reject.
        param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]]$Names)

        $matched = [System.Collections.Generic.List[object]]::new()
        $unknown = [System.Collections.Generic.List[string]]::new()

        foreach ($name in $Names) {
            $term = $name.Trim()
            if (-not $term) { continue }

            if ($term -eq 'all' -or $term -eq '*') {
                foreach ($a in $Ctx.Apps) { $matched.Add($a) }
                continue
            }

            $exact = @($Ctx.Apps | Where-Object { $_.id -eq $term -or $_.name -eq $term })
            if ($exact.Count -ge 1) { $matched.Add($exact[0]); continue }

            $byCategory = @($Ctx.Apps | Where-Object { $_.category -eq $term })
            if ($byCategory.Count -gt 0) {
                foreach ($a in $byCategory) { $matched.Add($a) }
                continue
            }

            $fuzzy = @($Ctx.Apps | Where-Object {
                (Test-NameMatch -Value $_.name -Pattern $term) -or
                (Test-NameMatch -Value $_.id   -Pattern $term) -or
                (Test-NameMatch -Value $_.category -Pattern $term)
            })

            if ($fuzzy.Count -gt 0) {
                foreach ($a in $fuzzy) { $matched.Add($a) }
            }
            else {
                $unknown.Add($term)
            }
        }

        [pscustomobject]@{
            Matched = @($matched | Group-Object -Property id | ForEach-Object { $_.Group[0] })
            Unknown = @($unknown)
        }
    }

# ===== src/05-Theme.ps1 ================================================

    # =============================================================================
    # Theme: terminal capability detection, glyphs, palette, and the drawing
    # primitives everything else renders through.
    #
    # Two hard constraints shape this file.
    #
    # 1. src/ must stay pure ASCII (build.ps1 enforces it, because the bundle ships
    #    without a BOM and Windows PowerShell 5.1 would decode it as ANSI). So every
    #    box-drawing character is built from its code point at runtime, never typed
    #    as a literal.
    #
    # 2. No ANSI escape sequences. Legacy conhost on a fresh Windows install does not
    #    process them by default, and a debloat tool is exactly the thing people run
    #    on a fresh install. Everything here uses Write-Host's 16 colours, which
    #    render identically in conhost and Windows Terminal, and a foreground and
    #    background pair is enough for a real selection bar.
    #
    # Unicode still needs the console output encoding to be UTF-8, so that is set on
    # startup and restored on exit - and only when we have decided to use it.
    # =============================================================================

    function ConvertTo-Char {
        param([Parameter(Mandatory)][int]$CodePoint)
        [string][char]$CodePoint
    }

    # Windows Terminal and PowerShell 7 handle UTF-8 output reliably. Legacy conhost
    # on an OEM code page does not, and would render box drawing as question marks.
    function Test-UnicodeCapable {
        try {
            if ([Console]::IsOutputRedirected) { return $false }
            if ($env:WT_SESSION) { return $true }
            if ($env:TERM_PROGRAM -eq 'vscode') { return $true }
            if ($PSVersionTable.PSVersion.Major -ge 6) { return $true }
            if ([Console]::OutputEncoding.CodePage -eq 65001) { return $true }
        }
        catch { }
        return $false
    }

    function New-GlyphSet {
        param([Parameter(Mandatory)][bool]$Unicode)

        if (-not $Unicode) {
            return @{
                Ok = '+'; Err = 'x'; Warn = '!'; Info = '.'; Step = '>'; Bullet = '-'
                Checked = '[x]'; Unchecked = '[ ]'; Partial = '[~]'; Action = '[>]'
                Pointer = '>'; Sep = '|'
                HLine = '-'; VLine = '|'
                TopLeft = '+'; TopRight = '+'; BottomLeft = '+'; BottomRight = '+'
                BarFull = '#'; BarEmpty = '.'
                Dot = '*'; Arrow = '->'
                Spinner = @('|', '/', '-', '\')
            }
        }

        @{
            Ok          = ConvertTo-Char 0x2713   # check mark
            Err         = ConvertTo-Char 0x2717   # ballot x
            Warn        = ConvertTo-Char 0x25B2   # black up-pointing triangle
            Info        = ConvertTo-Char 0x00B7   # middle dot
            Step        = ConvertTo-Char 0x203A   # single right angle quotation
            Bullet      = ConvertTo-Char 0x2022   # bullet
            Checked     = ConvertTo-Char 0x25C9   # fisheye
            Unchecked   = ConvertTo-Char 0x25CB   # white circle
            Partial     = ConvertTo-Char 0x25D0   # circle with left half black
            Action      = ConvertTo-Char 0x25B8   # black right-pointing small triangle
            Pointer     = ConvertTo-Char 0x276F   # heavy right angle quotation
            Sep         = ConvertTo-Char 0x00B7
            HLine       = ConvertTo-Char 0x2500
            VLine       = ConvertTo-Char 0x2502
            TopLeft     = ConvertTo-Char 0x256D
            TopRight    = ConvertTo-Char 0x256E
            BottomLeft  = ConvertTo-Char 0x2570
            BottomRight = ConvertTo-Char 0x256F
            BarFull     = ConvertTo-Char 0x2588   # full block
            BarEmpty    = ConvertTo-Char 0x2591   # light shade
            Dot         = ConvertTo-Char 0x25CF   # black circle
            Arrow       = ConvertTo-Char 0x2192
            # Braille spinner: eight dots cycling, reads as smooth rotation.
            Spinner     = @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F |
                            ForEach-Object { ConvertTo-Char $_ })
        }
    }

    function New-Palette {
        @{
            Accent      = [ConsoleColor]::Cyan
            AccentDim   = [ConsoleColor]::DarkCyan
            Ok          = [ConsoleColor]::Green
            Warn        = [ConsoleColor]::Yellow
            Err         = [ConsoleColor]::Red
            Text        = [ConsoleColor]::Gray
            Bright      = [ConsoleColor]::White
            Muted       = [ConsoleColor]::DarkGray
            HighlightFg = [ConsoleColor]::White
            HighlightBg = [ConsoleColor]::DarkCyan
            SelectedFg  = [ConsoleColor]::Green
        }
    }

    function New-Theme {
        param([switch]$Ascii)

        $unicode = (-not $Ascii) -and (Test-UnicodeCapable)

        [pscustomobject]@{
            Unicode = $unicode
            Glyph   = New-GlyphSet -Unicode $unicode
            Color   = New-Palette
        }
    }

    function Get-Glyph {
        param([Parameter(Mandatory)][string]$Name)
        $Ctx.Theme.Glyph[$Name]
    }

    function Get-Color {
        param([Parameter(Mandatory)][string]$Name)
        $Ctx.Theme.Color[$Name]
    }

    # Box drawing only renders if the console can encode it. Returns the previous
    # encoding so the caller can put it back; native tools like winget are decoded
    # through this same setting, so leaving it changed would be rude.
    function Initialize-ConsoleEncoding {
        if (-not $Ctx.Theme.Unicode) { return $null }

        try {
            $previous = [Console]::OutputEncoding
            if ($previous.CodePage -ne 65001) {
                [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
                return $previous
            }
        }
        catch {
            # A host that will not let us set it also will not render the glyphs.
            $Ctx.Theme = New-Theme -Ascii
        }

        return $null
    }

    function Restore-ConsoleEncoding {
        param($Previous)
        if ($Previous) {
            try { [Console]::OutputEncoding = $Previous } catch { }
        }
    }

    # -----------------------------------------------------------------------------
    # Drawing
    # -----------------------------------------------------------------------------

    function Get-RuleWidth {
        $width = 78
        try {
            $available = $Host.UI.RawUI.WindowSize.Width - 4
            if ($available -gt 20) { $width = [Math]::Min(78, $available) }
        }
        catch { }
        return $width
    }

    # A titled horizontal rule:  --- Privacy & Telemetry ------------------ 7
    function Write-Rule {
        param(
            [AllowEmptyString()][string]$Title = '',
            [AllowEmptyString()][string]$Suffix = '',
            [ConsoleColor]$TitleColor = [ConsoleColor]::White,
            # Suppresses the leading blank line, for rules that close a block rather
            # than open one.
            [switch]$Tight
        )

        $line = Get-Glyph 'HLine'
        $width = Get-RuleWidth

        if (-not $Tight) { Write-Line '' }

        if (-not $Title) {
            Write-Line ('  ' + ($line * $width)) -Color (Get-Color 'Muted')
            return
        }

        $lead = $line * 3
        $used = 2 + $lead.Length + 1 + $Title.Length + 1
        $suffixText = if ($Suffix) { ' ' + $Suffix } else { '' }
        $fill = [Math]::Max(3, $width - ($used - 2) - $suffixText.Length)

        Write-Line "  $lead " -Color (Get-Color 'Muted') -NoNewline
        Write-Line $Title -Color $TitleColor -NoNewline
        Write-Line (' ' + ($line * $fill)) -Color (Get-Color 'Muted') -NoNewline

        if ($suffixText) { Write-Line $suffixText -Color (Get-Color 'Muted') -NoNewline }
        Write-Line ''
    }

    # A row of "  a  .  b  .  c  " status chips.
    function Write-Chips {
        param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Chips)

        if ($Chips.Count -eq 0) { return }

        $separator = '   ' + (Get-Glyph 'Sep') + '   '

        Write-Line '  ' -NoNewline
        for ($i = 0; $i -lt $Chips.Count; $i++) {
            if ($i -gt 0) { Write-Line $separator -Color (Get-Color 'Muted') -NoNewline }

            $chip = $Chips[$i]
            if ($chip.Glyph) {
                Write-Line ($chip.Glyph + ' ') -Color $chip.Color -NoNewline
            }
            Write-Line $chip.Text -Color $(if ($chip.Dim) { Get-Color 'Muted' } else { $chip.Color }) -NoNewline
        }
        Write-Line ''
    }

    function New-Chip {
        param(
            [Parameter(Mandatory)][string]$Text,
            [ConsoleColor]$Color = [ConsoleColor]::Gray,
            [string]$Glyph = '',
            [switch]$Dim
        )
        [pscustomobject]@{ Text = $Text; Color = $Color; Glyph = $Glyph; Dim = [bool]$Dim }
    }

    # -----------------------------------------------------------------------------
    # Live progress
    #
    # Both of these rewrite the current line with a carriage return, so they are
    # suppressed when output is redirected - a log file should not collect 400
    # copies of a progress bar.
    # -----------------------------------------------------------------------------

    function Write-InlineLine {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

        if (-not $Ctx.Animate) { return }

        $width = 100
        try { $width = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 1) } catch { }

        $text = if ($Text.Length -gt $width) { $Text.Substring(0, $width) } else { $Text.PadRight($width) }
        Write-Host ("`r" + $text) -NoNewline
    }

    function Clear-InlineLine {
        if (-not $Ctx.Animate) { return }

        $width = 100
        try { $width = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 1) } catch { }
        Write-Host ("`r" + (' ' * $width) + "`r") -NoNewline
    }

    function Write-ProgressBar {
        param(
            [Parameter(Mandatory)][string]$Label,
            [Parameter(Mandatory)][double]$Fraction,
            [AllowEmptyString()][string]$Detail = '',
            [int]$Width = 26
        )

        $Fraction = [Math]::Max(0.0, [Math]::Min(1.0, $Fraction))

        # The GUI drives a real progress bar from the same call sites.
        if ($Ctx.ProgressSink) { & $Ctx.ProgressSink $Label $Fraction $Detail; return }
        if (-not $Ctx.Animate) { return }

        $filled = [int][Math]::Round($Width * $Fraction)

        $bar = ((Get-Glyph 'BarFull') * $filled) + ((Get-Glyph 'BarEmpty') * ($Width - $filled))
        $percent = '{0,3:N0}%' -f ($Fraction * 100)

        Write-InlineLine ("    {0}  {1}  {2}{3}" -f $Label, $bar, $percent, $(if ($Detail) { "   $Detail" } else { '' }))
    }

    function Write-Activity {
        param(
            [Parameter(Mandatory)][string]$Message,
            [Parameter(Mandatory)][int]$Tick
        )

        # Indeterminate work: report it as a pulsing bar in the GUI.
        if ($Ctx.ProgressSink) { & $Ctx.ProgressSink $Message (-1.0) ''; return }
        if (-not $Ctx.Animate) { return }

        $frames = @(Get-Glyph 'Spinner')
        $frame = $frames[$Tick % $frames.Count]
        Write-InlineLine "    $frame  $Message"
    }

# ===== src/10-Registry.ps1 =============================================

    # =============================================================================
    # Registry read/write plus the snapshot format that makes tweaks reversible.
    #
    # The GUI applies tweaks one way only. The CLI records the prior state of every
    # value it touches before writing, so -Revert can put it back exactly: restore
    # the old value, delete values that did not exist, and drop keys we created if
    # they end up empty again.
    #
    # Uses the .NET registry API rather than the PowerShell provider for exact
    # control over value kinds, and pins the 64-bit view so a 32-bit host does not
    # silently land in WOW6432Node.
    # =============================================================================

    function Resolve-RegistryPath {
        param([Parameter(Mandatory)][string]$FullPath)

        $separator = $FullPath.IndexOf('\')
        if ($separator -lt 0) { throw "Registry path '$FullPath' has no subkey." }

        $hiveName = $FullPath.Substring(0, $separator)
        $subPath  = $FullPath.Substring($separator + 1)

        $hive = switch ($hiveName.ToUpperInvariant()) {
            'HKEY_LOCAL_MACHINE'  { [Microsoft.Win32.RegistryHive]::LocalMachine }
            'HKLM'                { [Microsoft.Win32.RegistryHive]::LocalMachine }
            'HKEY_CURRENT_USER'   { [Microsoft.Win32.RegistryHive]::CurrentUser }
            'HKCU'                { [Microsoft.Win32.RegistryHive]::CurrentUser }
            'HKEY_CLASSES_ROOT'   { [Microsoft.Win32.RegistryHive]::ClassesRoot }
            'HKCR'                { [Microsoft.Win32.RegistryHive]::ClassesRoot }
            'HKEY_USERS'          { [Microsoft.Win32.RegistryHive]::Users }
            'HKU'                 { [Microsoft.Win32.RegistryHive]::Users }
            default { throw "Unsupported registry hive '$hiveName' in '$FullPath'." }
        }

        [pscustomobject]@{
            Hive     = $hive
            SubPath  = $subPath
            FullPath = $FullPath
            # HKLM and HKU are machine-wide; HKCU is not.
            NeedsAdmin = ($hive -eq [Microsoft.Win32.RegistryHive]::LocalMachine) -or
                         ($hive -eq [Microsoft.Win32.RegistryHive]::ClassesRoot) -or
                         ($hive -eq [Microsoft.Win32.RegistryHive]::Users)
        }
    }

    function Open-RegistryBase {
        param([Parameter(Mandatory)][Microsoft.Win32.RegistryHive]$Hive)
        [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    }

    function ConvertTo-RegistryValueKind {
        param([Parameter(Mandatory)][string]$Type)

        switch ($Type.ToUpperInvariant()) {
            'DWORD'  { [Microsoft.Win32.RegistryValueKind]::DWord }
            'QWORD'  { [Microsoft.Win32.RegistryValueKind]::QWord }
            'STRING' { [Microsoft.Win32.RegistryValueKind]::String }
            'EXPANDSTRING' { [Microsoft.Win32.RegistryValueKind]::ExpandString }
            'BINARY' { [Microsoft.Win32.RegistryValueKind]::Binary }
            default  { throw "Unsupported registry value type '$Type'." }
        }
    }

    function ConvertTo-TypedRegistryValue {
        param([Parameter(Mandatory)][string]$Type, [AllowNull()]$Value)

        switch ($Type.ToUpperInvariant()) {
            'DWORD'  { return [int]$Value }
            'QWORD'  { return [long]$Value }
            default  { if ($null -eq $Value) { return '' } else { return [string]$Value } }
        }
    }

    # Captures enough state to undo a single value write.
    function Get-RegistryValueSnapshot {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Name)

        $target = Resolve-RegistryPath -FullPath $Path
        $base = $null
        $key = $null

        try {
            $base = Open-RegistryBase -Hive $target.Hive
            $key  = $base.OpenSubKey($target.SubPath, $false)

            if ($null -eq $key) {
                return [pscustomobject]@{
                    path = $Path; name = $Name; keyExisted = $false; existed = $false; type = $null; value = $null
                }
            }

            # GetValue with $null default distinguishes "absent" from "present and empty".
            $current = $key.GetValue($Name, $null)
            if ($null -eq $current) {
                return [pscustomobject]@{
                    path = $Path; name = $Name; keyExisted = $true; existed = $false; type = $null; value = $null
                }
            }

            $kind = $key.GetValueKind($Name)
            return [pscustomobject]@{
                path = $Path; name = $Name; keyExisted = $true; existed = $true
                type = $kind.ToString(); value = $current
            }
        }
        finally {
            if ($key)  { $key.Dispose() }
            if ($base) { $base.Dispose() }
        }
    }

    function Set-RegistryValue {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
            [Parameter(Mandatory)][string]$Type,
            [AllowNull()]$Value
        )

        $target = Resolve-RegistryPath -FullPath $Path
        $base = $null
        $key = $null

        try {
            $base = Open-RegistryBase -Hive $target.Hive
            $key  = $base.CreateSubKey($target.SubPath, $true)
            if ($null -eq $key) { throw "Cannot open or create key '$Path'." }

            $key.SetValue($Name, (ConvertTo-TypedRegistryValue -Type $Type -Value $Value), (ConvertTo-RegistryValueKind -Type $Type))
        }
        finally {
            if ($key)  { $key.Dispose() }
            if ($base) { $base.Dispose() }
        }
    }

    function Remove-RegistryValue {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Name)

        $target = Resolve-RegistryPath -FullPath $Path
        $base = $null
        $key = $null

        try {
            $base = Open-RegistryBase -Hive $target.Hive
            $key  = $base.OpenSubKey($target.SubPath, $true)
            if ($null -eq $key) { return }

            $key.DeleteValue($Name, $false)
        }
        finally {
            if ($key)  { $key.Dispose() }
            if ($base) { $base.Dispose() }
        }
    }

    # Deletes a key only when it is empty. Used on revert to clean up keys the tweak
    # created; never touches a key that already held anything.
    function Remove-EmptyRegistryKey {
        param([Parameter(Mandatory)][string]$Path)

        $target = Resolve-RegistryPath -FullPath $Path
        $base = $null

        try {
            $base = Open-RegistryBase -Hive $target.Hive

            $key = $base.OpenSubKey($target.SubPath, $false)
            if ($null -eq $key) { return $false }

            $isEmpty = ($key.SubKeyCount -eq 0) -and ($key.ValueCount -eq 0)
            $key.Dispose()
            if (-not $isEmpty) { return $false }

            $base.DeleteSubKey($target.SubPath, $false)
            return $true
        }
        catch {
            Write-Log "Could not remove empty key '$Path': $($_.Exception.Message)" 'WARN'
            return $false
        }
        finally {
            if ($base) { $base.Dispose() }
        }
    }

    # True when the live registry already holds the value a tweak wants.
    function Test-RegistryValueApplied {
        param([Parameter(Mandatory)]$Desired)

        $snapshot = Get-RegistryValueSnapshot -Path $Desired.path -Name $Desired.name
        if (-not $snapshot.existed) { return $false }

        $expected = ConvertTo-TypedRegistryValue -Type $Desired.type -Value $Desired.value

        # Compare as strings so DWord 0 read back as Int32 still matches the JSON value.
        return ([string]$snapshot.value -eq [string]$expected)
    }

    # -----------------------------------------------------------------------------
    # Backups
    # -----------------------------------------------------------------------------

    function New-BackupRecord {
        [pscustomobject]@{
            version   = $Ctx.Version
            createdUtc = (Get-Date).ToUniversalTime().ToString('o')
            entries   = @{}
        }
    }

    function Save-BackupRecord {
        param([Parameter(Mandatory)]$Record)

        if ($Record.entries.Count -eq 0) { return $null }

        Initialize-State
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        $path  = Join-Path $Ctx.BackupDir "backup-$stamp.json"

        $json = $Record | ConvertTo-Json -Depth 10
        [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding $false))

        Write-Log "Backup written: $path"
        return $path
    }

    # Newest first. Callers must wrap this in @(): PowerShell unrolls a returned
    # array, so zero backups come back as $null and one comes back as a bare object.
    function Get-BackupRecords {
        if (-not (Test-Path -LiteralPath $Ctx.BackupDir)) { return @() }

        @(Get-ChildItem -LiteralPath $Ctx.BackupDir -Filter 'backup-*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property Name -Descending |
            ForEach-Object {
                try {
                    [pscustomobject]@{
                        File   = $_.FullName
                        Record = (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
                    }
                }
                catch {
                    Write-Log "Skipping unreadable backup '$($_.FullName)': $($_.Exception.Message)" 'WARN'
                }
            })
    }

    # Most recent snapshot taken for a given tweak, or $null if it was never applied
    # through this CLI.
    function Find-TweakBackup {
        param([Parameter(Mandatory)][string]$TweakName)

        foreach ($backup in @(Get-BackupRecords)) {
            $entries = $backup.Record.entries
            if ($null -eq $entries) { continue }

            # ConvertFrom-Json yields a PSCustomObject, so look the name up as a property.
            $entry = $entries.PSObject.Properties | Where-Object { $_.Name -eq $TweakName } | Select-Object -First 1
            if ($entry) {
                return [pscustomobject]@{ File = $backup.File; Entry = $entry.Value }
            }
        }

        return $null
    }

# ===== src/20-Tweaks.ps1 ===============================================

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

# ===== src/30-Apps.ps1 =================================================

    # =============================================================================
    # Installing catalog apps.
    #
    # Four install shapes, mirroring the GUI's SetupApp record:
    #   winget    - the common case
    #   download  - a direct installer URL, optionally re-resolved from a vendor page
    #   zip       - archive whose bundled setup executable is run
    #   script    - a remote PowerShell bootstrap (irm <url> | iex)
    #
    # 'script' entries are remote code execution by design, so they always require an
    # explicit confirmation that prints the URL first.
    # =============================================================================

    # winget's "nothing to do" results are non-zero exit codes rather than errors.
    $WingetBenignExitCodes = @(
        -1978335135,  # 0x8A150061 package already installed
        -1978335189,  # 0x8A15002B no applicable upgrade
        -1978335212   # 0x8A150014 no applicable installer, usually an arch mismatch
    )

    function Test-WingetAvailable {
        $command = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
        if (-not $command) { return $false }

        try {
            & winget.exe --version 2>&1 | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
        catch { return $false }
    }

    function Assert-Winget {
        if (Test-WingetAvailable) { return $true }

        Write-Err 'winget is not available on this machine.'
        Write-Info 'Install "App Installer" from the Microsoft Store, or see https://aka.ms/getwinget'
        return $false
    }

    function Invoke-Winget {
        param(
            [Parameter(Mandatory)][string[]]$Arguments,
            [switch]$Quiet,
            [string]$Activity
        )

        Write-Log "winget $($Arguments -join ' ')"

        if ($Quiet -and -not $Activity) {
            & winget.exe @Arguments 2>&1 | Out-Null
        }
        elseif ($Activity) {
            # winget is quiet for long stretches during a download. Advancing a
            # spinner on each line it does emit keeps the run visibly alive without
            # dumping its raw output over ours.
            $tick = 0
            & winget.exe @Arguments 2>&1 | ForEach-Object {
                $tick++
                $line = ([string]$_).Trim()
                # Its progress bars come through as runs of block characters.
                if ($line -and $line.Length -lt 60 -and $line -notmatch '^[\W_]+$') {
                    Write-Activity -Message "$Activity   $line" -Tick $tick
                }
                else {
                    Write-Activity -Message $Activity -Tick $tick
                }
            }
            Clear-InlineLine
        }
        else {
            & winget.exe @Arguments 2>&1 | ForEach-Object { Write-Info $_ }
        }

        $code = $LASTEXITCODE
        return [pscustomobject]@{
            ExitCode = $code
            Success  = ($code -eq 0) -or ($WingetBenignExitCodes -contains $code)
            Benign   = ($WingetBenignExitCodes -contains $code)
        }
    }

    function Test-AppInstalled {
        param([Parameter(Mandatory)]$App)

        if (-not $App.wingetId) { return $false }

        $result = Invoke-Winget -Quiet -Arguments @(
            'list', '--id', $App.wingetId, '--exact',
            '--accept-source-agreements', '--disable-interactivity'
        )
        return ($result.ExitCode -eq 0)
    }

    function Update-WingetSource {
        Write-Step 'Refreshing winget sources'
        $result = Invoke-Winget -Quiet -Arguments @('source', 'update', '--accept-source-agreements')
        if (-not $result.Success) { Write-Warn "winget source update returned $($result.ExitCode)." }
    }

    # Scrapes a vendor page for the current installer link, falling back to the
    # pinned URL in the catalog when the page layout changes.
    function Resolve-LatestDownloadUrl {
        param(
            [Parameter(Mandatory)][string]$PageUrl,
            [Parameter(Mandatory)][string]$Pattern,
            [Parameter(Mandatory)][string]$Fallback
        )

        try {
            $response = Invoke-WebRequest -Uri $PageUrl -UseBasicParsing -TimeoutSec 30 -Headers @{
                'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Moscovium-CLI'
            }

            $match = [regex]::Match($response.Content, $Pattern, 'IgnoreCase')
            if ($match.Success) { return $match.Value.Trim() }

            Write-Warn 'Vendor page did not match the expected pattern; using the pinned link.'
        }
        catch {
            Write-Warn "Could not check for a newer link ($($_.Exception.Message)); using the pinned link."
        }

        return $Fallback
    }

    function Get-DownloadPath {
        param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$AppName)

        $leaf = ''
        try { $leaf = [IO.Path]::GetFileName(([Uri]$Url).LocalPath) } catch { }
        if (-not $leaf) { $leaf = 'installer.exe' }

        # The URL-encoded names some vendors use (Install%20Termius.exe) must be
        # decoded, then stripped of anything illegal in a file name.
        $leaf = [Uri]::UnescapeDataString($leaf)
        foreach ($bad in [IO.Path]::GetInvalidFileNameChars()) { $leaf = $leaf.Replace($bad, '_') }

        $dir = Join-Path $Ctx.StateDir 'downloads'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        Join-Path $dir $leaf
    }

    function Format-Bytes {
        param([Parameter(Mandatory)][long]$Bytes)

        if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
        if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
        if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
        return "$Bytes B"
    }

    # Streams the response so a real progress bar can be drawn. Invoke-WebRequest
    # gives no progress callback, and its own progress bar makes large downloads
    # roughly an order of magnitude slower on Windows PowerShell 5.1.
    function Save-RemoteFile {
        param(
            [Parameter(Mandatory)][string]$Url,
            [Parameter(Mandatory)][string]$Destination,
            [string]$Label = 'downloading'
        )

        # TLS 1.2 is not the default in 5.1 and several vendor CDNs refuse anything older.
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

        $request = [Net.HttpWebRequest]::Create($Url)
        $request.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Moscovium-CLI'
        $request.Timeout = 60000
        $request.ReadWriteTimeout = 600000
        $request.AllowAutoRedirect = $true

        $response = $null
        $stream = $null
        $output = $null

        try {
            $response = $request.GetResponse()
            $total = $response.ContentLength          # -1 when the server omits it
            $stream = $response.GetResponseStream()
            $output = [IO.File]::Create($Destination)

            $buffer = New-Object byte[] 131072
            $read = 0
            $done = [long]0
            $started = [Diagnostics.Stopwatch]::StartNew()
            $lastDraw = [long]0

            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $output.Write($buffer, 0, $read)
                $done += $read

                # Redraw at most every 100ms; repainting per 128 KB chunk would spend
                # more time on the console than on the download.
                if ($started.ElapsedMilliseconds - $lastDraw -ge 100) {
                    $lastDraw = $started.ElapsedMilliseconds
                    $speed = if ($started.Elapsed.TotalSeconds -gt 0) { $done / $started.Elapsed.TotalSeconds } else { 0 }

                    if ($total -gt 0) {
                        Write-ProgressBar -Label $Label -Fraction ($done / $total) `
                            -Detail ('{0} / {1}   {2}/s' -f (Format-Bytes $done), (Format-Bytes $total), (Format-Bytes ([long]$speed)))
                    }
                    else {
                        Write-Activity -Message ('{0}   {1}   {2}/s' -f $Label, (Format-Bytes $done), (Format-Bytes ([long]$speed))) `
                            -Tick ([int]($started.ElapsedMilliseconds / 100))
                    }
                }
            }

            $output.Close(); $output = $null
            Clear-InlineLine
        }
        catch {
            throw "Download failed: $($_.Exception.Message)"
        }
        finally {
            if ($output) { $output.Dispose() }
            if ($stream) { $stream.Dispose() }
            if ($response) { $response.Dispose() }
        }

        if (-not (Test-Path -LiteralPath $Destination)) { throw "Download produced no file at '$Destination'." }

        $size = (Get-Item -LiteralPath $Destination).Length
        if ($size -lt 1024) { throw "Downloaded file is only $size bytes; the link is probably wrong." }

        return $size
    }

    function Install-FromDownload {
        param([Parameter(Mandatory)]$App)

        $url = $App.downloadUrl
        if ($App.resolvePageUrl -and $App.resolvePattern) {
            Write-Step "Checking $($App.name) for a newer installer"
            $url = Resolve-LatestDownloadUrl -PageUrl $App.resolvePageUrl -Pattern $App.resolvePattern -Fallback $App.downloadUrl
        }

        $destination = Get-DownloadPath -Url $url -AppName $App.name
        Write-Step "Downloading $($App.name)"
        Write-Info $url

        $size = Save-RemoteFile -Url $url -Destination $destination -Label $App.name
        Write-Info ('{0} -> {1}' -f (Format-Bytes $size), $destination)

        Write-Step "Running installer for $($App.name)"
        $process = Start-Process -FilePath $destination -Wait -PassThru -ErrorAction Stop

        # Vendor installers are inconsistent about exit codes; 3010 is "needs reboot".
        if ($process.ExitCode -notin @(0, 3010)) {
            throw "Installer exited with code $($process.ExitCode)."
        }
        if ($process.ExitCode -eq 3010) { Write-Warn "$($App.name) installed but wants a reboot." }
    }

    function Install-FromZip {
        param([Parameter(Mandatory)]$App)

        $tempRoot = Join-Path $Ctx.StateDir ('zip-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

        try {
            $zipPath = Join-Path $tempRoot 'package.zip'
            Write-Step "Downloading $($App.name)"
            Write-Info $App.zipUrl
            Save-RemoteFile -Url $App.zipUrl -Destination $zipPath -Label $App.name | Out-Null

            $extractPath = Join-Path $tempRoot 'extracted'
            Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

            $installer = Find-ZipInstaller -Root $extractPath
            if (-not $installer) { throw "No installer executable found inside the archive." }

            Write-Step "Running $(Split-Path -Leaf $installer)"
            $process = Start-Process -FilePath $installer -Wait -PassThru -ErrorAction Stop
            if ($process.ExitCode -notin @(0, 3010)) { throw "Installer exited with code $($process.ExitCode)." }
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Find-ZipInstaller {
        param([Parameter(Mandatory)][string]$Root)

        foreach ($name in @('setup.exe', 'install.exe', 'installer.exe')) {
            $hit = Get-ChildItem -LiteralPath $Root -Filter $name -Recurse -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }

        $hit = Get-ChildItem -LiteralPath $Root -Filter 'install*.exe' -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }

        # Some archives are just the application; run the only executable present.
        $hit = Get-ChildItem -LiteralPath $Root -Filter '*.exe' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }

        return $null
    }

    function Install-FromScript {
        param([Parameter(Mandatory)]$App)

        # Shares Invoke-RemoteScript with the toolbox: a bootstrap script gets its own
        # process rather than running inside this one, for the reasons documented
        # there. It waits, so the install has finished before we report on it.
        $ran = Invoke-RemoteScript -Url $App.scriptUrl -Label $App.name

        if (-not $ran) { $Ctx.Skipped++ }
        return $ran
    }

    function Install-App {
        param([Parameter(Mandatory)]$App)

        if ($Ctx.DryRun) {
            Write-Status -Glyph (Get-Glyph 'Info') -Color (Get-Color 'Warn') -Message $App.name -MessageColor (Get-Color 'Warn')

            $how = if ($App.scriptUrl)        { "run script $($App.scriptUrl)" }
                   elseif ($App.zipUrl)       { "download and extract $($App.zipUrl)" }
                   elseif ($App.downloadUrl)  { "download $($App.downloadUrl)" }
                   else                       { "winget install --id $($App.wingetId)" }

            Write-Info "would $how"
            $Ctx.Skipped++
            return
        }

        try {
            if ($App.scriptUrl) {
                if (Install-FromScript -App $App) { Write-Ok $App.name; $Ctx.Applied++ }
                return
            }

            if ($App.zipUrl)      { Install-FromZip      -App $App; Write-Ok $App.name; $Ctx.Applied++; return }
            if ($App.downloadUrl) { Install-FromDownload -App $App; Write-Ok $App.name; $Ctx.Applied++; return }

            if (-not $App.wingetId) { throw 'Catalog entry has no installation method.' }

            Write-Step "Installing $($App.name) ($($App.wingetId))"

            $arguments = @(
                'install', '--id', $App.wingetId, '--exact', '--silent',
                '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
            )
            if ($App.source) { $arguments += @('--source', $App.source) }

            $result = Invoke-Winget -Arguments $arguments -Activity "installing $($App.name)"

            if ($result.Benign) {
                Write-Ok "$($App.name) - already installed"
                $Ctx.Skipped++
            }
            elseif ($result.Success) {
                Write-Ok $App.name
                $Ctx.Applied++
            }
            else {
                throw "winget exited with code $($result.ExitCode)."
            }
        }
        catch {
            Write-Err "$($App.name) - $($_.Exception.Message)"
            $Ctx.Failed++
        }
    }

    function Invoke-AppInstall {
        param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Apps)

        if ($Apps.Count -eq 0) {
            Write-Warn 'No apps selected.'
            return
        }

        # Only winget-backed entries need winget; a list of pure downloads should
        # still work on a machine without App Installer.
        if (@($Apps | Where-Object { $_.wingetId }).Count -gt 0) {
            if (-not (Assert-Winget)) { return }
            if (-not $Ctx.DryRun) { Update-WingetSource }
        }

        Write-SectionHeading "Installing $($Apps.Count) app$(if ($Apps.Count -ne 1) { 's' })"

        foreach ($app in $Apps) { Install-App -App $app }

        Write-RunSummary
    }

    function Invoke-UpgradeAll {
        if (-not (Assert-Winget)) { return }

        if ($Ctx.DryRun) {
            Write-Warn 'Dry run: would run winget upgrade --all.'
            return
        }

        Write-SectionHeading 'Upgrading all winget packages'
        $result = Invoke-Winget -Arguments @(
            'upgrade', '--all', '--silent',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
        )

        if ($result.Success) { Write-Ok 'Upgrade pass complete.' }
        else { Write-Warn "winget upgrade returned $($result.ExitCode). Some packages may need attention." }
    }

    function Show-AppCatalog {
        param([string]$Filter)

        foreach ($category in $Ctx.AppCategories) {
            $inCategory = @($Ctx.Apps | Where-Object {
                $_.category -eq $category -and (
                    -not $Filter -or
                    (Test-NameMatch -Value $_.name -Pattern $Filter) -or
                    (Test-NameMatch -Value $_.id -Pattern $Filter) -or
                    (Test-NameMatch -Value ([string]$_.description) -Pattern $Filter)
                )
            })

            if ($inCategory.Count -eq 0) { continue }

            Write-SectionHeading "$category ($($inCategory.Count))"

            foreach ($app in $inCategory) {
                Write-Line '  - ' -Color DarkGray -NoNewline
                Write-Line $app.name.PadRight(34) -Color White -NoNewline
                Write-Line ([string]$app.description) -Color DarkGray
                Write-Line ('      ' + $app.id) -Color DarkGray
            }
        }
    }

# ===== src/40-Toolbox.ps1 ==============================================

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

    $EmbeddedWinutilConfigJson = @'
{
    "WPFTweaks":  [
                      "WPFTweaksWifi",
                      "WPFTweaksRightClickMenu",
                      "WPFTweaksActivity",
                      "WPFTweaksStorage",
                      "WPFTweaksConsumerFeatures",
                      "WPFTweaksDVR",
                      "WPFTweaksTele",
                      "WPFTweaksEndTaskOnTaskbar",
                      "WPFTweaksRemoveCopilot",
                      "WPFTweaksLoc",
                      "WPFTweaksDisableExplorerAutoDiscovery",
                      "WPFTweaksPowershell7Tele",
                      "WPFTweaksUTC",
                      "WPFTweaksRecallOff",
                      "WPFTweaksDisableBGapps"
                  ],
    "Install":  [

                ],
    "WPFInstall":  [

                   ],
    "WPFFeature":  [

                   ]
}
'@

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
            Write-Status -Glyph (Get-Glyph 'Info') -Color (Get-Color 'Warn') -Message $action.Name -MessageColor (Get-Color 'Warn')
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

# ===== src/50-Profile.ps1 ==============================================

    # =============================================================================
    # Setup profiles.
    #
    # Same JSON shape as the GUI's SetupProfile record, so a profile saved in the
    # desktop app runs here and vice versa. Property names are matched
    # case-insensitively because the GUI's serializer and this one disagree on
    # casing depending on version.
    # =============================================================================

    $ProfileVersion = 1

    function Get-ProfileProperty {
        param(
            [Parameter(Mandatory)]$SetupProfile,
            [Parameter(Mandatory)][string]$Name,
            $Default = $null
        )

        $property = $SetupProfile.PSObject.Properties |
            Where-Object { $_.Name -eq $Name } |
            Select-Object -First 1

        if (-not $property) {
            $property = $SetupProfile.PSObject.Properties |
                Where-Object { $_.Name -ieq $Name } |
                Select-Object -First 1
        }

        if ($property -and $null -ne $property.Value) { return $property.Value }
        return $Default
    }

    function New-SetupProfile {
        param(
            [string[]]$Apps = @(),
            [string[]]$Tweaks = @(),
            [switch]$RunWindowsUpdate,
            [switch]$UpgradeAllApps,
            [switch]$InstallVCRuntimes,
            [switch]$RunChrisTitus,
            [switch]$RunRaphi
        )

        [pscustomobject]@{
            Version           = $ProfileVersion
            WingetApps        = @($Apps)
            Tweaks            = @($Tweaks)
            RunWindowsUpdate  = [bool]$RunWindowsUpdate
            UpgradeAllApps    = [bool]$UpgradeAllApps
            InstallVCRuntimes = [bool]$InstallVCRuntimes
            RunChrisTitus     = [bool]$RunChrisTitus
            RunRaphi          = [bool]$RunRaphi
        }
    }

    function Save-SetupProfile {
        param(
            [Parameter(Mandatory)]$SetupProfile,
            [Parameter(Mandatory)][string]$Path
        )

        $full = $Path
        if (-not [IO.Path]::IsPathRooted($full)) { $full = Join-Path (Get-Location).Path $full }

        $dir = Split-Path -Parent $full
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $json = $SetupProfile | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($full, $json, (New-Object Text.UTF8Encoding $false))

        Write-Ok "Profile saved to $full"
        return $full
    }

    function Import-SetupProfile {
        param([Parameter(Mandatory)][string]$Path)

        if (-not (Test-Path -LiteralPath $Path)) { throw "Profile not found: $Path" }

        $setupProfile = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json

        $version = Get-ProfileProperty -SetupProfile $setupProfile -Name 'Version' -Default 1
        if ([int]$version -gt $ProfileVersion) {
            Write-Warn "Profile is version $version but this build understands version $ProfileVersion. Unknown fields will be ignored."
        }

        return $setupProfile
    }

    # The GUI bundles a VC runtimes archive; winget carries the same redistributables
    # and keeps them current, so the CLI installs them by package id instead.
    function Get-VCRuntimePackageIds {
        @(
            'Microsoft.VCRedist.2015+.x64'
            'Microsoft.VCRedist.2015+.x86'
            'Microsoft.VCRedist.2013.x64'
            'Microsoft.VCRedist.2013.x86'
            'Microsoft.VCRedist.2012.x64'
            'Microsoft.VCRedist.2012.x86'
            'Microsoft.VCRedist.2010.x64'
            'Microsoft.VCRedist.2010.x86'
            'Microsoft.VCRedist.2008.x64'
            'Microsoft.VCRedist.2008.x86'
            'Microsoft.VCRedist.2005.x64'
            'Microsoft.VCRedist.2005.x86'
        )
    }

    function Install-VCRuntimes {
        if (-not (Assert-Winget)) { return }

        Write-SectionHeading 'Visual C++ runtimes'

        if ($Ctx.DryRun) {
            foreach ($id in Get-VCRuntimePackageIds) { Write-Info "would install $id" }
            return
        }

        foreach ($id in Get-VCRuntimePackageIds) {
            $result = Invoke-Winget -Quiet -Arguments @(
                'install', '--id', $id, '--exact', '--silent',
                '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
            )

            if ($result.Benign)      { Write-Info "$id - already present" }
            elseif ($result.Success) { Write-Ok $id }
            else                     { Write-Warn "$id - winget returned $($result.ExitCode)" }
        }
    }

    function Invoke-WindowsUpdate {
        Write-SectionHeading 'Windows Update'

        if (-not $Ctx.IsAdmin) {
            Write-Err 'Windows Update needs administrator rights.'
            return
        }

        if ($Ctx.DryRun) {
            Write-Info 'would install the PSWindowsUpdate module and run Get-WindowsUpdate -Install -AcceptAll'
            return
        }

        Write-Warn 'This installs the PSWindowsUpdate module from the PowerShell Gallery, then installs all pending updates.'
        if (-not (Confirm-Action 'Continue?')) { return }

        try {
            if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
                Write-Step 'Installing PSWindowsUpdate'
                Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
                Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
            }

            Import-Module PSWindowsUpdate -ErrorAction Stop
            Write-Step 'Checking for updates'

            # -AutoReboot off: rebooting is the user's decision, not ours.
            Get-WindowsUpdate -Install -AcceptAll -IgnoreReboot -Verbose:$false -ErrorAction Stop |
                ForEach-Object { Write-Info $_ }

            Write-Ok 'Windows Update pass complete.'
        }
        catch {
            Write-Err "Windows Update failed: $($_.Exception.Message)"
        }
    }

    function Invoke-SetupProfile {
        param([Parameter(Mandatory)][string]$Path)

        $setupProfile = Import-SetupProfile -Path $Path

        $appIds = @(Get-ProfileProperty -SetupProfile $setupProfile -Name 'WingetApps' -Default @())
        $tweakNames = @(Get-ProfileProperty -SetupProfile $setupProfile -Name 'Tweaks' -Default @())

        Write-SectionHeading "Profile: $(Split-Path -Leaf $Path)"
        Write-Info "$($appIds.Count) app(s), $($tweakNames.Count) tweak(s)"

        $flags = @()
        foreach ($name in @('RunWindowsUpdate', 'UpgradeAllApps', 'InstallVCRuntimes', 'RunChrisTitus', 'RunRaphi')) {
            if (Get-ProfileProperty -SetupProfile $setupProfile -Name $name -Default $false) { $flags += $name }
        }
        if ($flags.Count -gt 0) { Write-Info "extras: $($flags -join ', ')" }

        if (-not $Ctx.DryRun -and -not (Confirm-Action 'Run this profile?' -DefaultYes)) {
            Write-Warn 'Cancelled.'
            return
        }

        # Order matters: a restore point and tweaks first, then apps, then the
        # long-running update passes.
        if ($tweakNames.Count -gt 0) {
            $resolved = Resolve-Tweak -Names $tweakNames
            foreach ($miss in $resolved.Unknown) { Write-Warn "Profile names an unknown tweak: $miss" }
            Invoke-Tweaks -Tweaks $resolved.Matched -Mode Apply
        }

        if (Get-ProfileProperty -SetupProfile $setupProfile -Name 'InstallVCRuntimes' -Default $false) {
            Install-VCRuntimes
        }

        if ($appIds.Count -gt 0) {
            $resolved = Resolve-App -Names $appIds
            foreach ($miss in $resolved.Unknown) { Write-Warn "Profile names an unknown app: $miss" }
            Invoke-AppInstall -Apps $resolved.Matched
        }

        if (Get-ProfileProperty -SetupProfile $setupProfile -Name 'RunChrisTitus' -Default $false) {
            Invoke-ToolboxAction -Id 'winutil-preset'
        }

        if (Get-ProfileProperty -SetupProfile $setupProfile -Name 'RunRaphi' -Default $false) {
            Invoke-ToolboxAction -Id 'raphi-auto'
        }

        if (Get-ProfileProperty -SetupProfile $setupProfile -Name 'UpgradeAllApps' -Default $false) {
            Invoke-UpgradeAll
        }

        if (Get-ProfileProperty -SetupProfile $setupProfile -Name 'RunWindowsUpdate' -Default $false) {
            Invoke-WindowsUpdate
        }

        Write-Line ''
        Write-Ok 'Profile complete.'
    }

# ===== src/60-Menu.ps1 =================================================

    # =============================================================================
    # Interactive menus.
    #
    # This is what `irm moscovium.win | iex` lands in, so it has to work in a plain
    # console with no arguments. Show-Selector drives every list; when the host
    # cannot read individual keypresses it degrades to a numbered prompt rather than
    # failing.
    # =============================================================================

    function Get-ConsoleWidth {
        try {
            $width = $Host.UI.RawUI.WindowSize.Width
            if ($width -gt 20) { return $width }
        }
        catch { }
        return 100
    }

    function Get-ConsoleHeight {
        try {
            $height = $Host.UI.RawUI.WindowSize.Height
            if ($height -gt 10) { return $height }
        }
        catch { }
        return 30
    }

    # Rendering a frame in one pass and padding each line to the console width lets
    # us repaint from the cursor home position without the flicker of Clear-Host.
    function Write-Frame {
        param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Lines, [ref]$PreviousHeight)

        $width = (Get-ConsoleWidth) - 1

        $homed = $false
        try {
            [Console]::SetCursorPosition(0, 0)
            $homed = $true
        }
        catch { Clear-Host }

        foreach ($line in $Lines) {
            $text = [string]$line.Text
            if ($text.Length -gt $width) { $text = $text.Substring(0, $width) }
            # Padding to the full width is what turns a background colour into a
            # solid selection bar rather than a coloured word.
            $text = $text.PadRight($width)

            if (-not $Ctx.UseColor) { Write-Host $text; continue }

            $splat = @{ Object = $text }
            if ($line.Color)      { $splat.ForegroundColor = $line.Color }
            if ($line.Background) { $splat.BackgroundColor = $line.Background }
            Write-Host @splat
        }

        # Erase whatever the previous, taller frame left behind.
        if ($homed -and $PreviousHeight) {
            for ($i = $Lines.Count; $i -lt $PreviousHeight.Value; $i++) {
                Write-Host (' ' * $width)
            }
        }
        if ($PreviousHeight) { $PreviousHeight.Value = $Lines.Count }
    }

    function New-FrameLine {
        param([AllowEmptyString()][string]$Text = '', $Color = $null, $Background = $null)
        [pscustomobject]@{ Text = $Text; Color = $Color; Background = $Background }
    }

    function Read-MenuKey {
        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        [pscustomobject]@{
            Code = $key.VirtualKeyCode
            Char = $key.Character
        }
    }

    # Numbered fallback for hosts without keypress support (redirected stdin, ISE).
    function Show-SelectorFallback {
        param(
            [Parameter(Mandatory)][object[]]$Items,
            [Parameter(Mandatory)][scriptblock]$Label,
            [Parameter(Mandatory)][string]$Title,
            [switch]$SingleSelect
        )

        Write-SectionHeading $Title

        for ($i = 0; $i -lt $Items.Count; $i++) {
            Write-Line ("  {0,3}. " -f ($i + 1)) -Color DarkGray -NoNewline
            Write-Line (& $Label $Items[$i])
        }

        Write-Line ''
        $hint = if ($SingleSelect) { 'Enter a number' } else { 'Enter numbers separated by commas, or "all"' }
        Write-Line "  $hint (blank to cancel): " -Color Yellow -NoNewline

        $answer = Read-Host
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return [pscustomobject]@{ Confirmed = $false; Selected = @() }
        }

        if ($answer.Trim() -eq 'all' -and -not $SingleSelect) {
            return [pscustomobject]@{ Confirmed = $true; Selected = @($Items) }
        }

        $selected = [System.Collections.Generic.List[object]]::new()
        foreach ($token in ($answer -split ',')) {
            $index = 0
            if ([int]::TryParse($token.Trim(), [ref]$index) -and $index -ge 1 -and $index -le $Items.Count) {
                $selected.Add($Items[$index - 1])
                if ($SingleSelect) { break }
            }
            else {
                Write-Warn "Ignoring '$($token.Trim())'."
            }
        }

        [pscustomobject]@{ Confirmed = ($selected.Count -gt 0); Selected = @($selected) }
    }

    # Indices of $Items whose label (plus sublabel) match the current filter, in
    # order. An empty filter matches everything.
    function Get-VisibleIndex {
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
            [AllowEmptyString()][string]$Filter,
            [Parameter(Mandatory)][scriptblock]$Label,
            [scriptblock]$Sublabel
        )

        @(
            for ($i = 0; $i -lt $Items.Count; $i++) {
                if (-not $Filter) { $i; continue }

                $text = [string](& $Label $Items[$i])
                if ($Sublabel) { $text += ' ' + [string](& $Sublabel $Items[$i]) }

                if (Test-NameMatch -Value $text -Pattern $Filter) { $i }
            }
        )
    }

    # Clamps the cursor into range and scrolls the window just far enough to keep it
    # visible. Split out from the key loop so the off-by-ones are testable.
    function Get-ScrollWindow {
        param(
            [Parameter(Mandatory)][int]$Cursor,
            [Parameter(Mandatory)][int]$Offset,
            [Parameter(Mandatory)][int]$Count,
            [Parameter(Mandatory)][int]$Viewport
        )

        if ($Count -le 0) { return [pscustomobject]@{ Cursor = 0; Offset = 0 } }

        if ($Cursor -ge $Count) { $Cursor = $Count - 1 }
        if ($Cursor -lt 0) { $Cursor = 0 }

        if ($Cursor -lt $Offset) { $Offset = $Cursor }
        if ($Cursor -ge $Offset + $Viewport) { $Offset = $Cursor - $Viewport + 1 }

        $maxOffset = [Math]::Max(0, $Count - $Viewport)
        if ($Offset -gt $maxOffset) { $Offset = $maxOffset }
        if ($Offset -lt 0) { $Offset = 0 }

        [pscustomobject]@{ Cursor = $Cursor; Offset = $Offset }
    }

    function Show-Selector {
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
            [Parameter(Mandatory)][scriptblock]$Label,
            [scriptblock]$Sublabel,
            [Parameter(Mandatory)][string]$Title,
            [string]$Subtitle = '',
            [switch]$SingleSelect
        )

        if ($Items.Count -eq 0) {
            Write-Warn 'Nothing to show here.'
            return [pscustomobject]@{ Confirmed = $false; Selected = @() }
        }

        if (-not (Test-Interactive)) {
            return Show-SelectorFallback -Items $Items -Label $Label -Title $Title -SingleSelect:$SingleSelect
        }

        $selected = [System.Collections.Generic.HashSet[int]]::new()
        $cursor = 0
        $offset = 0
        $filter = ''
        $previousHeight = 0

        # Clear once up front. Write-Frame repaints by homing the cursor to (0,0),
        # which is the top of the *buffer* - in a scrolled conhost window that is
        # off-screen. Clearing resets the buffer so (0,0) is the top of the visible
        # window, and every frame is sized to fit without scrolling, so it stays that
        # way for as long as the selector is open.
        Clear-Host

        while ($true) {
            # @() is required: PowerShell unrolls a returned array, so a filter that
            # matches one item would hand back a bare int and one that matches none
            # would hand back $null - and .Count on either throws under StrictMode.
            $visible = @(Get-VisibleIndex -Items $Items -Filter $filter -Label $Label -Sublabel $Sublabel)

            $viewport = [Math]::Max(5, (Get-ConsoleHeight) - 10)
            $view = Get-ScrollWindow -Cursor $cursor -Offset $offset -Count $visible.Count -Viewport $viewport
            $cursor = $view.Cursor
            $offset = $view.Offset

            # Same width as Write-Rule, so the selector lines up with section rules.
            $rule = (Get-Glyph 'HLine') * (Get-RuleWidth)

            $lines = [System.Collections.Generic.List[object]]::new()
            $lines.Add((New-FrameLine))
            $lines.Add((New-FrameLine ('  ' + $Title) (Get-Color 'Accent')))
            if ($Subtitle) { $lines.Add((New-FrameLine ('  ' + $Subtitle) (Get-Color 'Muted'))) }
            $lines.Add((New-FrameLine ('  ' + $rule) (Get-Color 'Muted')))

            if ($visible.Count -eq 0) {
                $lines.Add((New-FrameLine "     no match for '$filter'" (Get-Color 'Warn')))
            }

            $last = [Math]::Min($offset + $viewport, $visible.Count)
            for ($row = $offset; $row -lt $last; $row++) {
                $index = $visible[$row]
                $isCursor = ($row -eq $cursor)
                $isSelected = $selected.Contains($index)

                $marker = if ($SingleSelect) { ' ' }
                          elseif ($isSelected) { Get-Glyph 'Checked' }
                          else { Get-Glyph 'Unchecked' }

                $pointer = if ($isCursor) { Get-Glyph 'Pointer' } else { ' ' }
                $text = '  {0} {1} {2}' -f $pointer, $marker, (& $Label $Items[$index])

                if ($Sublabel) {
                    $extra = (& $Sublabel $Items[$index])
                    if ($extra) { $text = $text.PadRight(48) + $extra }
                }

                if ($isCursor) {
                    # A padded full-width line plus a background colour is a real
                    # selection bar - the whole row inverts, not just the text.
                    $lines.Add((New-FrameLine $text (Get-Color 'HighlightFg') (Get-Color 'HighlightBg')))
                }
                elseif ($isSelected) {
                    $lines.Add((New-FrameLine $text (Get-Color 'SelectedFg')))
                }
                else {
                    $lines.Add((New-FrameLine $text (Get-Color 'Text')))
                }
            }

            $lines.Add((New-FrameLine ('  ' + $rule) (Get-Color 'Muted')))

            $dot = Get-Glyph 'Sep'
            $position = if ($visible.Count -gt 0) { "$($cursor + 1)/$($visible.Count)" } else { '0/0' }
            $status = "  $position"
            if (-not $SingleSelect) { $status += "   $dot   $($selected.Count) selected" }
            if ($filter) { $status += "   $dot   filter: $filter" }
            $lines.Add((New-FrameLine $status (Get-Color 'Muted')))

            $keys = if ($SingleSelect) {
                "  up/down move   $dot   enter choose   $dot   / filter   $dot   esc back"
            }
            else {
                "  up/down move   $dot   space toggle   $dot   a all   $dot   n none   $dot   i invert   $dot   / filter   $dot   enter confirm   $dot   esc back"
            }
            $lines.Add((New-FrameLine $keys (Get-Color 'Muted')))

            Write-Frame -Lines $lines.ToArray() -PreviousHeight ([ref]$previousHeight)

            $key = Read-MenuKey

            switch ($key.Code) {
                38 { if ($visible.Count) { $cursor = ($cursor - 1 + $visible.Count) % $visible.Count }; continue }  # up
                40 { if ($visible.Count) { $cursor = ($cursor + 1) % $visible.Count }; continue }                    # down
                33 { $cursor = [Math]::Max(0, $cursor - $viewport); continue }                                       # page up
                34 { $cursor = [Math]::Min($visible.Count - 1, $cursor + $viewport); continue }                      # page down
                36 { $cursor = 0; continue }                                                                        # home
                35 { $cursor = $visible.Count - 1; continue }                                                        # end

                27 {  # escape
                    Clear-Host
                    return [pscustomobject]@{ Confirmed = $false; Selected = @() }
                }

                13 {  # enter
                    Clear-Host
                    if ($SingleSelect) {
                        if ($visible.Count -eq 0) { return [pscustomobject]@{ Confirmed = $false; Selected = @() } }
                        return [pscustomobject]@{ Confirmed = $true; Selected = @($Items[$visible[$cursor]]) }
                    }
                    $chosen = @($selected | Sort-Object | ForEach-Object { $Items[$_] })
                    return [pscustomobject]@{ Confirmed = $true; Selected = $chosen }
                }

                8 {  # backspace trims the filter
                    if ($filter.Length -gt 0) { $filter = $filter.Substring(0, $filter.Length - 1) }
                    continue
                }
            }

            switch -CaseSensitive ($key.Char) {
                ' ' {
                    if (-not $SingleSelect -and $visible.Count -gt 0) {
                        $index = $visible[$cursor]
                        if ($selected.Contains($index)) { [void]$selected.Remove($index) }
                        else { [void]$selected.Add($index) }
                    }
                    continue
                }
                '/' {
                    # Prompt on the last line rather than repainting the whole frame.
                    Write-Line ''
                    Write-Line '  filter: ' -Color Yellow -NoNewline
                    $filter = Read-Host
                    $cursor = 0; $offset = 0
                    continue
                }
                default {
                    if ($SingleSelect) { continue }
                    switch -Regex ([string]$key.Char) {
                        '^[aA]$' { foreach ($i in $visible) { [void]$selected.Add($i) }; continue }
                        '^[nN]$' { $selected.Clear(); continue }
                        '^[iI]$' {
                            foreach ($i in $visible) {
                                if ($selected.Contains($i)) { [void]$selected.Remove($i) } else { [void]$selected.Add($i) }
                            }
                            continue
                        }
                    }
                }
            }
        }
    }

    # -----------------------------------------------------------------------------
    # Screens
    # -----------------------------------------------------------------------------

    function Select-Category {
        param(
            [Parameter(Mandatory)][string[]]$Categories,
            [Parameter(Mandatory)][string]$Title,
            [Parameter(Mandatory)][scriptblock]$Counter
        )

        $options = @(
            [pscustomobject]@{ Name = 'All'; IsAll = $true }
        ) + @($Categories | ForEach-Object { [pscustomobject]@{ Name = $_; IsAll = $false } })

        $result = Show-Selector -Items $options -Title $Title -SingleSelect `
            -Subtitle 'Pick a category to narrow the list' `
            -Label { param($o) $o.Name } `
            -Sublabel { param($o) "$(& $Counter $o) item(s)" }

        if (-not $result.Confirmed) { return $null }
        return $result.Selected[0]
    }

    function Show-TweakMenu {
        $category = Select-Category -Categories $Ctx.TweakCategories -Title 'Tweaks' -Counter {
            param($o)
            if ($o.IsAll) { $Ctx.Tweaks.Count } else { @($Ctx.Tweaks | Where-Object { $_.category -eq $o.Name }).Count }
        }
        if (-not $category) { return }

        $pool = if ($category.IsAll) { $Ctx.Tweaks } else { @($Ctx.Tweaks | Where-Object { $_.category -eq $category.Name }) }

        # Status is read once up front: 40 tweaks is ~90 registry reads, and doing it
        # per keypress would make the list feel sluggish.
        $statuses = @{}
        foreach ($tweak in $pool) { $statuses[$tweak.name] = Get-TweakStatus -Tweak $tweak }

        $result = Show-Selector -Items $pool -Title "Tweaks - $($category.Name)" `
            -Subtitle 'Space to select, Enter to continue' `
            -Label { param($t) $t.name } `
            -Sublabel {
                param($t)
                switch ($statuses[$t.name]) {
                    'Applied'    { 'applied' }
                    'Partial'    { 'partial' }
                    'Action'     { 'action' }
                    default      { '' }
                }
            }

        if (-not $result.Confirmed -or $result.Selected.Count -eq 0) { return }

        $mode = Show-Selector -Items @(
            [pscustomobject]@{ Name = 'Apply';  Mode = 'Apply' }
            [pscustomobject]@{ Name = 'Revert'; Mode = 'Revert' }
        ) -Title "$($result.Selected.Count) tweak(s) selected" -SingleSelect `
            -Subtitle 'Revert restores the values Moscovium recorded before applying' `
            -Label { param($m) $m.Name }

        if (-not $mode.Confirmed) { return }

        Write-Banner
        foreach ($tweak in $result.Selected) { Write-Info $tweak.name }

        if (Confirm-Action "$($mode.Selected[0].Mode) these $($result.Selected.Count) tweak(s)?" -DefaultYes) {
            Invoke-Tweaks -Tweaks $result.Selected -Mode $mode.Selected[0].Mode
        }

        Wait-ForKey
    }

    function Show-AppMenu {
        $category = Select-Category -Categories $Ctx.AppCategories -Title 'Apps' -Counter {
            param($o)
            if ($o.IsAll) { $Ctx.Apps.Count } else { @($Ctx.Apps | Where-Object { $_.category -eq $o.Name }).Count }
        }
        if (-not $category) { return }

        $pool = if ($category.IsAll) { $Ctx.Apps } else { @($Ctx.Apps | Where-Object { $_.category -eq $category.Name }) }

        $result = Show-Selector -Items $pool -Title "Apps - $($category.Name)" `
            -Subtitle 'Space to select, / to search, Enter to install' `
            -Label { param($a) $a.name } `
            -Sublabel { param($a) [string]$a.description }

        if (-not $result.Confirmed -or $result.Selected.Count -eq 0) { return }

        Write-Banner
        foreach ($app in $result.Selected) { Write-Info $app.name }

        if (Confirm-Action "Install these $($result.Selected.Count) app(s)?" -DefaultYes) {
            Invoke-AppInstall -Apps $result.Selected
        }

        Wait-ForKey
    }

    function Show-ToolboxMenu {
        $actions = Get-ToolboxActions

        $result = Show-Selector -Items $actions -Title 'Toolbox' -SingleSelect `
            -Subtitle 'One-shot actions and classic control panels' `
            -Label { param($a) $a.Name } `
            -Sublabel { param($a) if ($a.Admin) { 'admin' } else { '' } }

        if (-not $result.Confirmed) { return }

        Write-Banner
        Invoke-ToolboxAction -Id $result.Selected[0].Id
        Wait-ForKey
    }

    function Show-ProfileMenu {
        $options = @(
            [pscustomobject]@{ Name = 'Run a profile';   Action = 'run' }
            [pscustomobject]@{ Name = 'Build and save a profile'; Action = 'save' }
        )

        $choice = Show-Selector -Items $options -Title 'Profiles' -SingleSelect `
            -Subtitle 'Profiles are interchangeable with the Moscovium desktop app' `
            -Label { param($o) $o.Name }

        if (-not $choice.Confirmed) { return }

        Write-Banner

        if ($choice.Selected[0].Action -eq 'run') {
            Write-Line '  Path to profile .json: ' -Color Yellow -NoNewline
            $path = Read-Host
            if ($path) {
                try { Invoke-SetupProfile -Path $path.Trim('"') }
                catch { Write-Err $_.Exception.Message }
            }
            Wait-ForKey
            return
        }

        $tweakPick = Show-Selector -Items $Ctx.Tweaks -Title 'Profile: tweaks' `
            -Subtitle 'Choose the tweaks this profile should apply' `
            -Label { param($t) $t.name } -Sublabel { param($t) $t.category }

        $appPick = Show-Selector -Items $Ctx.Apps -Title 'Profile: apps' `
            -Subtitle 'Choose the apps this profile should install' `
            -Label { param($a) $a.name } -Sublabel { param($a) $a.category }

        $extras = Show-Selector -Items @(
            [pscustomobject]@{ Name = 'Install Visual C++ runtimes'; Key = 'InstallVCRuntimes' }
            [pscustomobject]@{ Name = 'Upgrade all winget apps';     Key = 'UpgradeAllApps' }
            [pscustomobject]@{ Name = 'Open WinUtil with preset';    Key = 'RunChrisTitus' }
            [pscustomobject]@{ Name = 'Run Win11Debloat preset';     Key = 'RunRaphi' }
            [pscustomobject]@{ Name = 'Run Windows Update';          Key = 'RunWindowsUpdate' }
        ) -Title 'Profile: extras' -Subtitle 'Optional steps, run after tweaks and apps' -Label { param($e) $e.Name }

        $chosenKeys = @($extras.Selected | ForEach-Object { $_.Key })

        $setupProfile = New-SetupProfile `
            -Tweaks @($tweakPick.Selected | ForEach-Object { $_.name }) `
            -Apps   @($appPick.Selected   | ForEach-Object { $_.id }) `
            -InstallVCRuntimes:($chosenKeys -contains 'InstallVCRuntimes') `
            -UpgradeAllApps:($chosenKeys    -contains 'UpgradeAllApps') `
            -RunChrisTitus:($chosenKeys     -contains 'RunChrisTitus') `
            -RunRaphi:($chosenKeys          -contains 'RunRaphi') `
            -RunWindowsUpdate:($chosenKeys  -contains 'RunWindowsUpdate')

        Write-Banner
        Write-Line '  Save profile as (path): ' -Color Yellow -NoNewline
        $path = Read-Host

        if ($path) {
            try { Save-SetupProfile -SetupProfile $setupProfile -Path $path.Trim('"') }
            catch { Write-Err $_.Exception.Message }
        }

        Wait-ForKey
    }

    function Wait-ForKey {
        Write-Line ''
        Write-Line '  Press any key to return to the menu...' -Color DarkGray -NoNewline

        if (Test-Interactive) { [void](Read-MenuKey) } else { [void](Read-Host) }
        Clear-Host
    }

    function Show-MainMenu {
        $options = @(
            [pscustomobject]@{ Name = 'Tweaks';   Hint = "$($Ctx.Tweaks.Count) registry tweaks, apply or revert"; Action = 'tweaks' }
            [pscustomobject]@{ Name = 'Apps';     Hint = "$($Ctx.Apps.Count) curated packages";                    Action = 'apps' }
            [pscustomobject]@{ Name = 'Toolbox';  Hint = 'Debloat scripts, network, boot, control panels';         Action = 'toolbox' }
            [pscustomobject]@{ Name = 'Profiles'; Hint = 'Save or run a setup checklist';                          Action = 'profiles' }
            [pscustomobject]@{ Name = 'Status';   Hint = 'What is currently applied on this machine';              Action = 'status' }
            [pscustomobject]@{ Name = 'GUI';      Hint = 'Open the same thing as a window';                       Action = 'gui' }
            [pscustomobject]@{ Name = 'Quit';     Hint = '';                                                       Action = 'quit' }
        )

        while ($true) {
            $admin = if ($Ctx.IsAdmin) { 'elevated' } else { 'not elevated - HKLM tweaks will be skipped' }
            $subtitle = "Moscovium CLI v$($Ctx.Version)   |   $admin"
            if ($Ctx.DryRun) { $subtitle += '   |   DRY RUN' }

            $result = Show-Selector -Items $options -Title 'Moscovium' -SingleSelect `
                -Subtitle $subtitle `
                -Label { param($o) $o.Name } `
                -Sublabel { param($o) $o.Hint }

            if (-not $result.Confirmed) { return }

            switch ($result.Selected[0].Action) {
                'tweaks'   { Show-TweakMenu }
                'apps'     { Show-AppMenu }
                'toolbox'  { Show-ToolboxMenu }
                'profiles' { Show-ProfileMenu }
                'status'   { Write-Banner; Show-TweakStatus; Wait-ForKey }
                'gui'      { Clear-Host; Show-Gui | Out-Null; Clear-Host }
                'quit'     { return }
            }
        }
    }

# ===== src/70-Gui.ps1 ==================================================

    # =============================================================================
    # GUI mode.
    #
    # A WPF window that is a second front-end on the same engine, not a second
    # implementation. Every button ends up in Invoke-Tweaks, Invoke-AppInstall,
    # Invoke-ToolboxAction or Invoke-SetupProfile - the identical functions the CLI
    # calls - with $Ctx.Sink, $Ctx.ProgressSink and $Ctx.ConfirmSink redirecting
    # their output into the log pane, progress bar and dialogs.
    #
    # WPF ships with .NET Framework, so this still needs nothing installed and still
    # works from `irm ... | iex`.
    #
    # -----------------------------------------------------------------------------
    # Why there is not a single .GetNewClosure() in this file
    # -----------------------------------------------------------------------------
    # Event handlers fire after the function that registered them has returned, so
    # the obvious move is to capture state with .GetNewClosure(). That breaks here,
    # and only in the shipped bundle:
    #
    #   .GetNewClosure() binds the script block to a new dynamic module. Command
    #   lookup from inside that module falls back to the *global* scope - it does not
    #   see the enclosing one. The bundle runs everything inside `& { ... }`, so
    #   every engine function lives in that wrapper scope, and a closure cannot call
    #   any of them. Running from src/ hides this, because there the functions are at
    #   script scope, which a closure can reach.
    #
    #   A plain script block is the mirror image: it resolves functions and enclosing
    #   variables fine, but not the locals of a function that has already returned.
    #
    # So: plain script blocks everywhere, and no handler depends on a dead function's
    # locals. Per-window state hangs off $Ctx.Gui, which lives in the wrapper scope
    # and stays reachable, and per-row state is read back from $sender.
    #
    # The XAML is ASCII only, like the rest of src/, and lives in data/gui.xaml.
    # =============================================================================

    # Populated by build.ps1 from data/gui.xaml. Empty in the source tree, where
    # Get-GuiXaml falls back to reading that file - the same arrangement as the
    # catalogs, and for the same reason: a here-string cannot survive being indented
    # into the bundle's script block.
    $EmbeddedGuiXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Moscovium" Height="760" Width="1120" MinHeight="560" MinWidth="900"
        WindowStartupLocation="CenterScreen" Background="#FF16161A">

  <Window.Resources>
    <SolidColorBrush x:Key="Bg"      Color="#FF16161A"/>
    <SolidColorBrush x:Key="Panel"   Color="#FF1E1E24"/>
    <SolidColorBrush x:Key="Panel2"  Color="#FF24242C"/>
    <SolidColorBrush x:Key="Line"    Color="#FF32323C"/>
    <SolidColorBrush x:Key="Text"    Color="#FFE4E4EA"/>
    <SolidColorBrush x:Key="Muted"   Color="#FF8E8E9C"/>
    <SolidColorBrush x:Key="Accent"  Color="#FF4FC3F7"/>
    <SolidColorBrush x:Key="Ok"      Color="#FF7BD88F"/>
    <SolidColorBrush x:Key="Warn"    Color="#FFF0C674"/>
    <SolidColorBrush x:Key="Err"     Color="#FFF07178"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" CornerRadius="5" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#FF2E2E38"/>
                <Setter TargetName="Chrome" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#FF19566B"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
    </Style>

    <!-- The stock check box is a small light square and is the loudest reminder
         that this is a themed Win32 app rather than a designed one. -->
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="18" Height="18" CornerRadius="5"
                      Background="#FF1B1B23" BorderBrush="#FF3E3E4A" BorderThickness="1.4"
                      VerticalAlignment="Center">
                <Path x:Name="Tick" Width="10" Height="10" Stretch="Uniform" Opacity="0"
                      HorizontalAlignment="Center" VerticalAlignment="Center"
                      Data="M 0,5 L 4,9 L 11,1" Stroke="#FF0B1218" StrokeThickness="2.4"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
              </Border>
              <ContentPresenter x:Name="Label" Margin="9,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="Tick" Property="Opacity" Value="1"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Status badge: a tinted pill rather than loose coloured text. -->
    <Style x:Key="Pill" TargetType="Border">
      <Setter Property="CornerRadius" Value="9"/>
      <Setter Property="Padding" Value="9,2"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="10,0,2,0"/>
    </Style>

    <Style x:Key="GroupHeading" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="7,5"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="CaretBrush" Value="{StaticResource Text}"/>
    </Style>

    <!-- The stock ComboBox and ScrollBar chrome is light, and ignores Background,
         so both need a template to sit on a dark window. -->
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Chrome" Background="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#FF19566B"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Chrome" Background="{StaticResource Panel2}" BorderBrush="{StaticResource Line}"
                            BorderThickness="1" CornerRadius="5">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"
                            Data="M 0 0 L 8 0 L 4 5 Z" Fill="{StaticResource Muted}"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="Chrome" Property="BorderBrush" Value="{StaticResource Accent}"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Margin="11,0,28,0" VerticalAlignment="Center" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True"
                     Focusable="False" PopupAnimation="Fade">
                <Border Background="{StaticResource Panel2}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                        CornerRadius="5" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                        MaxHeight="320" Margin="0,2,0,0">
                  <ScrollViewer>
                    <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Placeholder text: a TextBlock behind the box, shown only while empty. -->
    <Style x:Key="Watermark" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="11,0,0,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="IsHitTestVisible" Value="False"/>
    </Style>

    <Style x:Key="ScrollThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="Chrome" Background="#FF3A3A46" CornerRadius="3" Margin="3,0"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#FF525263"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Style="{StaticResource ScrollThumb}"/>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="Height" Value="10"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="NavItem" TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="16,11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Chrome" Background="Transparent" BorderThickness="3,0,0,0" BorderBrush="Transparent">
              <ContentPresenter Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#FF24242C"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#FF24242C"/>
                <Setter TargetName="Chrome" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- header -->
    <Border Grid.Row="0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1">
      <Grid Margin="20,14">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="MOSCOVIUM" FontSize="19" FontWeight="SemiBold" Foreground="{StaticResource Accent}"/>
          <TextBlock x:Name="VersionText" Text="v0.0.0" FontSize="12" Foreground="{StaticResource Muted}"
                     VerticalAlignment="Center" Margin="10,3,0,0"/>
          <Border Background="{StaticResource Panel2}" CornerRadius="9" Padding="9,3" Margin="16,0,0,0">
            <TextBlock x:Name="CatalogChip" Text="" FontSize="11" Foreground="{StaticResource Muted}"/>
          </Border>
          <Border x:Name="ElevChipBorder" Background="{StaticResource Panel2}" CornerRadius="9" Padding="9,3" Margin="8,0,0,0">
            <TextBlock x:Name="ElevChip" Text="" FontSize="11" Foreground="{StaticResource Warn}"/>
          </Border>
        </StackPanel>

        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <CheckBox x:Name="DryRunToggle" Content="Dry run" Margin="0,0,16,0"
                    ToolTip="Show what would change without changing anything"/>
          <Button x:Name="BtnElevate" Content="Restart as admin"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- body -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="188"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
        <ListBox x:Name="NavList" Background="Transparent" BorderThickness="0" Margin="0,10,0,0"
                 ItemContainerStyle="{StaticResource NavItem}">
          <ListBoxItem Content="Tweaks" IsSelected="True"/>
          <ListBoxItem Content="Apps"/>
          <ListBoxItem Content="Toolbox"/>
          <ListBoxItem Content="Profiles"/>
        </ListBox>
      </Border>

      <Grid Grid.Column="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="*" MinHeight="180"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="200"/>
        </Grid.RowDefinitions>

        <!-- pages share this cell; only one is visible at a time -->
        <Grid Grid.Row="0" Margin="20,16,20,0">

          <Grid x:Name="TweaksPanel">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="Registry tweaks" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,10"/>
            <DockPanel Grid.Row="1" Margin="0,0,0,10" LastChildFill="False">
              <Grid Width="230" DockPanel.Dock="Left" Margin="0,0,8,0">
                <TextBox x:Name="TweakSearch" ToolTip="Filter by name, description or category"/>
                <TextBlock Text="Search tweaks">
                  <TextBlock.Style>
                    <Style TargetType="TextBlock" BasedOn="{StaticResource Watermark}">
                      <Setter Property="Visibility" Value="Collapsed"/>
                      <Style.Triggers>
                        <DataTrigger Binding="{Binding Text, ElementName=TweakSearch}" Value="">
                          <Setter Property="Visibility" Value="Visible"/>
                        </DataTrigger>
                      </Style.Triggers>
                    </Style>
                  </TextBlock.Style>
                </TextBlock>
              </Grid>
              <ComboBox x:Name="TweakCategory" Width="180" DockPanel.Dock="Left" Margin="0,0,8,0"/>
              <Button x:Name="BtnTweakAll" Content="All" DockPanel.Dock="Left"/>
              <Button x:Name="BtnTweakNone" Content="None" DockPanel.Dock="Left"/>
              <Button x:Name="BtnRevert" Content="Revert selected" DockPanel.Dock="Right" Margin="8,0,0,0"/>
              <Button x:Name="BtnApply" Content="Apply selected" DockPanel.Dock="Right" Style="{StaticResource Primary}"/>
            </DockPanel>
            <Border Grid.Row="2" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                    BorderThickness="1" CornerRadius="6">
              <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="6">
                <StackPanel x:Name="TweakRows"/>
              </ScrollViewer>
            </Border>
          </Grid>

          <Grid x:Name="AppsPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="Applications" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,10"/>
            <DockPanel Grid.Row="1" Margin="0,0,0,10" LastChildFill="False">
              <Grid Width="230" DockPanel.Dock="Left" Margin="0,0,8,0">
                <TextBox x:Name="AppSearch" ToolTip="Filter by name, id or description"/>
                <TextBlock Text="Search apps">
                  <TextBlock.Style>
                    <Style TargetType="TextBlock" BasedOn="{StaticResource Watermark}">
                      <Setter Property="Visibility" Value="Collapsed"/>
                      <Style.Triggers>
                        <DataTrigger Binding="{Binding Text, ElementName=AppSearch}" Value="">
                          <Setter Property="Visibility" Value="Visible"/>
                        </DataTrigger>
                      </Style.Triggers>
                    </Style>
                  </TextBlock.Style>
                </TextBlock>
              </Grid>
              <ComboBox x:Name="AppCategory" Width="180" DockPanel.Dock="Left" Margin="0,0,8,0"/>
              <Button x:Name="BtnAppNone" Content="None" DockPanel.Dock="Left"/>
              <Button x:Name="BtnInstall" Content="Install selected" DockPanel.Dock="Right" Style="{StaticResource Primary}"/>
            </DockPanel>
            <Border Grid.Row="2" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                    BorderThickness="1" CornerRadius="6">
              <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="6">
                <StackPanel x:Name="AppRows"/>
              </ScrollViewer>
            </Border>
          </Grid>

          <Grid x:Name="ToolboxPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="Toolbox" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,10"/>
            <Border Grid.Row="1" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                    BorderThickness="1" CornerRadius="6">
              <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="6">
                <StackPanel x:Name="ToolboxRows"/>
              </ScrollViewer>
            </Border>
          </Grid>

          <Grid x:Name="ProfilesPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="Setup profiles" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,6"/>
            <TextBlock Grid.Row="1" TextWrapping="Wrap" Foreground="{StaticResource Muted}" Margin="0,0,0,14"
                       Text="A profile is a saved checklist of tweaks and apps. The format matches the Moscovium desktop app, so profiles move between them."/>
            <StackPanel Grid.Row="2">
              <TextBlock Text="Profile file" Foreground="{StaticResource Muted}" Margin="0,0,0,6"/>
              <DockPanel LastChildFill="True" Margin="0,0,0,14">
                <Button x:Name="BtnBrowseProfile" Content="Browse" DockPanel.Dock="Right" Margin="8,0,0,0"/>
                <TextBox x:Name="ProfilePath"/>
              </DockPanel>
              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnRunProfile" Content="Run profile" Style="{StaticResource Primary}"/>
                <Button x:Name="BtnSaveProfile" Content="Save current selection"/>
              </StackPanel>
            </StackPanel>
          </Grid>

        </Grid>

        <GridSplitter Grid.Row="1" Height="4" HorizontalAlignment="Stretch" Background="{StaticResource Line}"
                      VerticalAlignment="Center" Margin="0,10,0,0"/>

        <Border Grid.Row="2" Background="#FF101014" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <DockPanel Grid.Row="0" Margin="20,8,20,4" LastChildFill="False">
              <TextBlock Text="Output" Foreground="{StaticResource Muted}" FontSize="11" DockPanel.Dock="Left"/>
              <Button x:Name="BtnClearLog" Content="Clear" DockPanel.Dock="Right" Padding="9,2" Margin="0"/>
            </DockPanel>
            <RichTextBox x:Name="LogBox" Grid.Row="1" Margin="14,0,14,10" Background="Transparent"
                         Foreground="{StaticResource Text}" BorderThickness="0" IsReadOnly="True"
                         FontFamily="Consolas" FontSize="12"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
          </Grid>
        </Border>
      </Grid>
    </Grid>

    <!-- status bar -->
    <Border Grid.Row="2" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
      <Grid Margin="20,9">
        <TextBlock x:Name="StatusText" Text="Ready" Foreground="{StaticResource Muted}" FontSize="12" VerticalAlignment="Center"/>
        <ProgressBar x:Name="Progress" Width="260" Height="6" HorizontalAlignment="Right" VerticalAlignment="Center"
                     Background="{StaticResource Panel2}" Foreground="{StaticResource Accent}" BorderThickness="0"
                     Visibility="Hidden"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

    function Get-GuiXaml {
        if (-not [string]::IsNullOrWhiteSpace($EmbeddedGuiXaml)) { return $EmbeddedGuiXaml }

        $roots = @()
        if ($PSScriptRoot) { $roots += (Join-Path $PSScriptRoot '..\data') }
        if ($PSCommandPath) { $roots += (Join-Path (Split-Path -Parent $PSCommandPath) 'data') }
        $roots += (Join-Path (Get-Location).Path 'data')

        foreach ($root in $roots) {
            $candidate = Join-Path $root 'gui.xaml'
            if (Test-Path -LiteralPath $candidate) { return (Get-Content -LiteralPath $candidate -Raw -Encoding UTF8) }
        }

        throw 'The GUI layout is neither embedded in this build nor present at data/gui.xaml.'
    }

    # -----------------------------------------------------------------------------
    # Host requirements
    # -----------------------------------------------------------------------------

    function Test-StaApartment {
        try { return ([Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA) }
        catch { return $false }
    }

    function Import-WpfAssembly {
        foreach ($name in @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml', 'System.Windows.Forms')) {
            Add-Type -AssemblyName $name -ErrorAction Stop
        }
    }

    # WPF cannot run on an MTA thread. powershell.exe is STA; pwsh is not, so a run
    # started there is relaunched into an STA host rather than failing.
    function Invoke-StaRelaunch {
        param([hashtable]$BoundParameters = @{})

        Write-Warn 'The GUI needs an STA thread, and this PowerShell host is running MTA.'

        $command = Get-RelaunchCommand -BoundParameters $BoundParameters
        $host51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        Write-Step 'Relaunching in an STA host'
        Write-Log "STA relaunch: $command"

        try {
            Start-Process -FilePath $host51 -ArgumentList @(
                '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-Command', $command
            ) -ErrorAction Stop | Out-Null
            return $true
        }
        catch {
            Write-Err "Could not start an STA host: $($_.Exception.Message)"
            return $false
        }
    }

    # -----------------------------------------------------------------------------
    # Small WPF helpers
    # -----------------------------------------------------------------------------

    # Console colours mapped onto the window's palette, so log output reads the same
    # as it does in the terminal.
    function ConvertTo-Brush {
        param($Color)

        $hex = switch ([string]$Color) {
            'Green'      { '#FF7BD88F' }
            'DarkGreen'  { '#FF5FA86F' }
            'Yellow'     { '#FFF0C674' }
            'DarkYellow' { '#FFD0A354' }
            'Red'        { '#FFF07178' }
            'DarkRed'    { '#FFC05058' }
            'Cyan'       { '#FF4FC3F7' }
            'DarkCyan'   { '#FF3A93BC' }
            'White'      { '#FFF4F4F8' }
            'Gray'       { '#FFC8C8D2' }
            'DarkGray'   { '#FF8E8E9C' }
            default      { '#FFE4E4EA' }
        }

        New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
    }

    # Lets the window repaint and handle input during a long synchronous run. The
    # engine functions are ordinary blocking PowerShell, so without this the window
    # would freeze for the length of an install.
    function Invoke-UiEvents {
        $frame = New-Object Windows.Threading.DispatcherFrame
        $callback = [Windows.Threading.DispatcherOperationCallback] {
            param($state)
            $state.Continue = $false
            return $null
        }
        [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
            [Windows.Threading.DispatcherPriority]::Background, $callback, $frame) | Out-Null
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    }

    function New-HexBrush {
        param([Parameter(Mandatory)][string]$Hex)
        New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex))
    }

    # Row background, decided from ticked + hovered together so neither clobbers the
    # other. Reached from $sender rather than a captured $border, because handlers
    # outlive the function that built the row: CheckBox -> Grid -> Border.
    function Set-GuiRowVisual {
        param([Parameter(Mandatory)]$Border, [switch]$Hover)

        $box = $Border.Child.Children[0]

        if ($box.IsChecked -eq $true) { $Border.Background = New-HexBrush '#FF16323E' }
        elseif ($Hover)               { $Border.Background = New-HexBrush '#FF212129' }
        else                          { $Border.Background = [Windows.Media.Brushes]::Transparent }
    }

    # A tinted pill for a row's status, instead of loose coloured text.
    function New-GuiPill {
        param(
            [Parameter(Mandatory)][string]$Text,
            [Parameter(Mandatory)][string]$Foreground,
            [Parameter(Mandatory)][string]$Background
        )

        $pill = New-Object Windows.Controls.Border
        $pill.CornerRadius = New-Object Windows.CornerRadius 9
        $pill.Padding = New-Object Windows.Thickness 9, 2, 9, 2
        $pill.Margin = New-Object Windows.Thickness 10, 0, 2, 0
        $pill.VerticalAlignment = 'Center'
        $pill.Background = New-HexBrush $Background

        $label = New-Object Windows.Controls.TextBlock
        $label.Text = $Text
        $label.FontSize = 10.5
        $label.Foreground = New-HexBrush $Foreground
        $pill.Child = $label

        return $pill
    }

    # A category divider inside a list, so 40 tweaks read as five groups.
    function New-GuiGroupHeader {
        param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][int]$Count, [switch]$First)

        $panel = New-Object Windows.Controls.DockPanel
        $panel.Margin = New-Object Windows.Thickness 4, $(if ($First) { 2 } else { 14 }), 4, 5
        $panel.LastChildFill = $true

        # Not $count: parameter variables keep their declared type, so assigning a
        # TextBlock to it fails the [int] conversion.
        $badge = New-Object Windows.Controls.TextBlock
        $badge.Text = [string]$Count
        $badge.FontSize = 11
        $badge.Foreground = New-HexBrush '#FF6E6E7E'
        [Windows.Controls.DockPanel]::SetDock($badge, 'Right')
        $panel.Children.Add($badge) | Out-Null

        $label = New-Object Windows.Controls.TextBlock
        $label.Text = $Title.ToUpperInvariant()
        $label.FontSize = 10.5
        $label.FontWeight = 'SemiBold'
        $label.Foreground = New-HexBrush '#FF8E8E9C'
        [Windows.Controls.DockPanel]::SetDock($label, 'Left')
        $panel.Children.Add($label) | Out-Null

        $rule = New-Object Windows.Controls.Border
        $rule.Height = 1
        $rule.Background = New-HexBrush '#FF2C2C36'
        $rule.VerticalAlignment = 'Center'
        $rule.Margin = New-Object Windows.Thickness 10, 1, 10, 0
        $panel.Children.Add($rule) | Out-Null

        return $panel
    }

    # Keeps the action buttons honest about how much is selected, and disabled when
    # nothing is.
    function Update-GuiActionState {
        if (-not $Ctx.Gui) { return }

        $ui = $Ctx.Gui.Ui
        $tweaks = @(Get-CheckedItem -Rows $Ctx.Gui.Rows.Tweaks).Count
        $apps = @(Get-CheckedItem -Rows $Ctx.Gui.Rows.Apps).Count

        $ui.BtnApply.Content  = if ($tweaks) { "Apply $tweaks" } else { 'Apply selected' }
        $ui.BtnRevert.Content = if ($tweaks) { "Revert $tweaks" } else { 'Revert selected' }
        $ui.BtnApply.IsEnabled = ($tweaks -gt 0)
        $ui.BtnRevert.IsEnabled = ($tweaks -gt 0)

        $ui.BtnInstall.Content = if ($apps) { "Install $apps" } else { 'Install selected' }
        $ui.BtnInstall.IsEnabled = ($apps -gt 0)
    }

    # One row: a checkbox, a primary label, a secondary line, and a status chip.
    # The catalog item rides along in .Tag so selection can be read back directly.
    function New-GuiRow {
        param(
            [Parameter(Mandatory)]$Item,
            [Parameter(Mandatory)][string]$Primary,
            [AllowEmptyString()][string]$Secondary = '',
            [AllowEmptyString()][string]$Status = '',
            [string]$StatusBrush = '#FF9C9CAC',
            [string]$StatusFill = '#FF262630',
            [switch]$NoCheckBox
        )

        $border = New-Object Windows.Controls.Border
        $border.Padding = New-Object Windows.Thickness 8, 6, 8, 6
        $border.CornerRadius = New-Object Windows.CornerRadius 4
        $border.Margin = New-Object Windows.Thickness 0, 0, 0, 2

        # checkbox | text (fills) | status chip
        $grid = New-Object Windows.Controls.Grid
        foreach ($unit in @([Windows.GridUnitType]::Auto, [Windows.GridUnitType]::Star, [Windows.GridUnitType]::Auto)) {
            $column = New-Object Windows.Controls.ColumnDefinition
            $column.Width = New-Object Windows.GridLength 1, $unit
            $grid.ColumnDefinitions.Add($column)
        }

        $check = New-Object Windows.Controls.CheckBox
        $check.VerticalAlignment = 'Center'
        $check.Margin = New-Object Windows.Thickness 0, 0, 10, 0
        $check.Foreground = ConvertTo-Brush 'Gray'
        $check.Tag = $Item
        if ($NoCheckBox) { $check.Visibility = 'Collapsed' }

        # A tick is easy to lose in a list of 127, so tint the whole row - and keep
        # the action buttons' counts in step.
        $check.Add_Checked({
            param($sender, $e)
            Set-GuiRowVisual -Border $sender.Parent.Parent
            Update-GuiActionState
        })
        $check.Add_Unchecked({
            param($sender, $e)
            Set-GuiRowVisual -Border $sender.Parent.Parent
            Update-GuiActionState
        })

        [Windows.Controls.Grid]::SetColumn($check, 0)
        $grid.Children.Add($check) | Out-Null

        $stack = New-Object Windows.Controls.StackPanel
        [Windows.Controls.Grid]::SetColumn($stack, 1)

        $title = New-Object Windows.Controls.TextBlock
        $title.Text = $Primary
        $title.Foreground = ConvertTo-Brush 'White'
        $title.FontSize = 13
        $stack.Children.Add($title) | Out-Null

        if ($Secondary) {
            $sub = New-Object Windows.Controls.TextBlock
            $sub.Text = $Secondary
            $sub.Foreground = ConvertTo-Brush 'DarkGray'
            $sub.FontSize = 11
            $sub.TextWrapping = 'Wrap'
            $sub.Margin = New-Object Windows.Thickness 0, 1, 0, 0
            $stack.Children.Add($sub) | Out-Null
        }

        $grid.Children.Add($stack) | Out-Null

        if ($Status) {
            $pill = New-GuiPill -Text $Status -Foreground $StatusBrush -Background $StatusFill
            [Windows.Controls.Grid]::SetColumn($pill, 2)
            $grid.Children.Add($pill) | Out-Null
        }

        $border.Child = $grid

        # Clicking anywhere on the row toggles it, not just the 18px checkbox.
        $border.Add_MouseLeftButtonUp({
            param($sender, $e)
            $box = $sender.Child.Children[0]
            if ($box.Visibility -eq 'Visible') { $box.IsChecked = -not $box.IsChecked }
        })

        $border.Add_MouseEnter({ param($sender, $e) Set-GuiRowVisual -Border $sender -Hover })
        $border.Add_MouseLeave({ param($sender, $e) Set-GuiRowVisual -Border $sender })

        [pscustomobject]@{ Element = $border; CheckBox = $check; Item = $Item }
    }

    function Get-CheckedItem {
        param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
        @($Rows | Where-Object { $_.CheckBox.IsChecked -eq $true } | ForEach-Object { $_.Item })
    }

    # -----------------------------------------------------------------------------
    # Row population
    #
    # Functions rather than script blocks, so handlers can call them by name. They
    # read the window out of $Ctx.Gui, which outlives New-GuiWindow.
    # -----------------------------------------------------------------------------

    function Update-GuiTweakRow {
        if (-not $Ctx.Gui) { return }
        $ui = $Ctx.Gui.Ui

        $ui.TweakRows.Children.Clear()
        $built = [System.Collections.Generic.List[object]]::new()

        $search = [string]$ui.TweakSearch.Text
        $category = [string]$ui.TweakCategory.SelectedItem
        $first = $true

        # Walk categories rather than the flat list, so the rows arrive grouped.
        foreach ($group in $Ctx.TweakCategories) {
            if ($category -and $category -ne 'All categories' -and $group -ne $category) { continue }

            $matching = @($Ctx.Tweaks | Where-Object {
                $_.category -eq $group -and (
                    -not $search -or
                    (Test-NameMatch -Value $_.name -Pattern $search) -or
                    (Test-NameMatch -Value $_.description -Pattern $search) -or
                    (Test-NameMatch -Value $_.category -Pattern $search))
            })

            if ($matching.Count -eq 0) { continue }

            $ui.TweakRows.Children.Add((New-GuiGroupHeader -Title $group -Count $matching.Count -First:$first)) | Out-Null
            $first = $false

            foreach ($tweak in $matching) {
                $status = Get-TweakStatus -Tweak $tweak
                $label, $ink, $fill = switch ($status) {
                    'Applied' { 'applied', '#FF7BD88F', '#FF1B3226' }
                    'Partial' { 'partial', '#FFF0C674', '#FF332C18' }
                    'Action'  { 'action',  '#FF4FC3F7', '#FF16303C' }
                    default   { '',        '#FF9C9CAC', '#FF262630' }
                }

                $row = New-GuiRow -Item $tweak -Primary $tweak.name -Secondary $tweak.description `
                    -Status $label -StatusBrush $ink -StatusFill $fill
                $ui.TweakRows.Children.Add($row.Element) | Out-Null
                $built.Add($row)
            }
        }

        $Ctx.Gui.Rows.Tweaks = @($built)
        Update-GuiActionState
    }

    function Update-GuiAppRow {
        if (-not $Ctx.Gui) { return }
        $ui = $Ctx.Gui.Ui

        $ui.AppRows.Children.Clear()
        $built = [System.Collections.Generic.List[object]]::new()

        $search = [string]$ui.AppSearch.Text
        $category = [string]$ui.AppCategory.SelectedItem
        $first = $true

        foreach ($group in $Ctx.AppCategories) {
            if ($category -and $category -ne 'All categories' -and $group -ne $category) { continue }

            $matching = @($Ctx.Apps | Where-Object {
                $_.category -eq $group -and (
                    -not $search -or
                    (Test-NameMatch -Value $_.name -Pattern $search) -or
                    (Test-NameMatch -Value $_.id -Pattern $search) -or
                    (Test-NameMatch -Value ([string]$_.description) -Pattern $search))
            })

            if ($matching.Count -eq 0) { continue }

            $ui.AppRows.Children.Add((New-GuiGroupHeader -Title $group -Count $matching.Count -First:$first)) | Out-Null
            $first = $false

            foreach ($app in $matching) {
                # Anything but winget is worth flagging: it means a vendor download
                # or, for a script, remote code.
                $how, $ink, $fill = if ($app.scriptUrl)      { 'script',   '#FFF0C674', '#FF332C18' }
                                    elseif ($app.zipUrl)     { 'archive',  '#FF9C9CAC', '#FF262630' }
                                    elseif ($app.downloadUrl){ 'download', '#FF9C9CAC', '#FF262630' }
                                    else                     { 'winget',   '#FF6E7E8C', '#FF20262C' }

                $row = New-GuiRow -Item $app -Primary $app.name -Secondary ([string]$app.description) `
                    -Status $how -StatusBrush $ink -StatusFill $fill
                $ui.AppRows.Children.Add($row.Element) | Out-Null
                $built.Add($row)
            }
        }

        $Ctx.Gui.Rows.Apps = @($built)
        Update-GuiActionState
    }

    function Update-GuiToolboxRow {
        if (-not $Ctx.Gui) { return }
        $ui = $Ctx.Gui.Ui

        $ui.ToolboxRows.Children.Clear()
        $built = [System.Collections.Generic.List[object]]::new()

        # Group by what the action actually does, so "runs a third-party script" is
        # never mistaken for "opens a control panel".
        $groups = @(
            @{ Title = 'Third-party debloat scripts'; Ids = @('winutil', 'winutil-preset', 'raphi', 'raphi-auto') }
            @{ Title = 'System tuning';               Ids = @('network-better', 'network-default', 'dynamictick-off', 'dynamictick-on', 'priority-22', 'priority-default') }
            @{ Title = 'Classic control panels';      Ids = @('control-panel', 'services', 'mouse', 'keyboard', 'sound') }
        )

        $all = @(Get-ToolboxActions)

        # Anything a future catalog adds that the grouping above does not know about
        # still gets shown, under Other.
        $known = @($groups | ForEach-Object { $_.Ids })
        $rest = @($all | Where-Object { $known -notcontains $_.Id })
        if ($rest.Count -gt 0) { $groups += @{ Title = 'Other'; Ids = @($rest | ForEach-Object { $_.Id }) } }

        $first = $true

        foreach ($group in $groups) {
            $members = @($all | Where-Object { $group.Ids -contains $_.Id })
            if ($members.Count -eq 0) { continue }

            $ui.ToolboxRows.Children.Add((New-GuiGroupHeader -Title $group.Title -Count $members.Count -First:$first)) | Out-Null
            $first = $false

            foreach ($action in $members) {
                $row = New-GuiRow -Item $action -Primary $action.Name -Secondary $action.Description -NoCheckBox

                # One click runs it; a checkbox would imply batching, which these are not.
                $run = New-Object Windows.Controls.Button
                $run.Content = 'Run'
                $run.Padding = New-Object Windows.Thickness 12, 4, 12, 4
                $run.Margin = New-Object Windows.Thickness 8, 0, 0, 0
                $run.VerticalAlignment = 'Center'
                $run.Tag = $action.Id
                [Windows.Controls.Grid]::SetColumn($run, 2)

                $run.Add_Click({
                    param($sender, $e)
                    $id = [string]$sender.Tag
                    Invoke-GuiWork -Label "toolbox: $id" -Work { Invoke-ToolboxAction -Id $id }
                })

                $row.Element.Child.Children.Add($run) | Out-Null

                $ui.ToolboxRows.Children.Add($row.Element) | Out-Null
                $built.Add($row)
            }
        }

        $Ctx.Gui.Rows.Toolbox = @($built)
    }

    # Nav rows carry a count on the right, so the sidebar says how much is behind
    # each page without opening it.
    function Set-GuiNavContent {
        param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][string]$Text, [int]$Count = -1)

        $panel = New-Object Windows.Controls.DockPanel
        $panel.LastChildFill = $true

        if ($Count -ge 0) {
            $badge = New-Object Windows.Controls.TextBlock
            $badge.Text = [string]$Count
            $badge.FontSize = 11
            $badge.Foreground = New-HexBrush '#FF6E6E7E'
            $badge.VerticalAlignment = 'Center'
            [Windows.Controls.DockPanel]::SetDock($badge, 'Right')
            $panel.Children.Add($badge) | Out-Null
        }

        $label = New-Object Windows.Controls.TextBlock
        $label.Text = $Text
        $label.FontSize = 14

        # The global TextBlock style pins a Foreground, which would break the
        # inheritance the nav's selected/unselected colours rely on. Bind to the
        # owning ListBoxItem so the label tracks selection.
        $binding = New-Object Windows.Data.Binding 'Foreground'
        $source = New-Object Windows.Data.RelativeSource ([Windows.Data.RelativeSourceMode]::FindAncestor)
        $source.AncestorType = [Windows.Controls.ListBoxItem]
        $binding.RelativeSource = $source
        [void]$label.SetBinding([Windows.Controls.TextBlock]::ForegroundProperty, $binding)

        $panel.Children.Add($label) | Out-Null

        $Item.Content = $panel
    }

    # A drawn window icon, so the title bar and taskbar are not the generic
    # PowerShell one. Cheaper than shipping an .ico through the single-file bundle.
    function New-GuiIcon {
        $visual = New-Object Windows.Media.DrawingVisual
        $dc = $visual.RenderOpen()
        try {
            $accent = New-HexBrush '#FF4FC3F7'
            $dc.DrawRoundedRectangle($accent, $null, (New-Object Windows.Rect 0, 0, 32, 32), 7, 7)

            # A stylised M, stroked rather than typeset, so no font is involved.
            $pen = New-Object Windows.Media.Pen ((New-HexBrush '#FF0B1218'), 3.4)
            $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'; $pen.LineJoin = 'Round'
            $geometry = [Windows.Media.Geometry]::Parse('M 8,23 L 8,9 L 16,18 L 24,9 L 24,23')
            $dc.DrawGeometry($null, $pen, $geometry)
        }
        finally { $dc.Close() }

        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap(32, 32, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($visual)
        return $bitmap
    }

    # -----------------------------------------------------------------------------
    # The window
    # -----------------------------------------------------------------------------

    # Builds and wires the window without showing it. Split out from Show-Gui so the
    # whole thing can be constructed, populated and rendered to an image in a test
    # without a human clicking anything.
    function New-GuiWindow {
        param([hashtable]$BoundParameters = @{})

        $reader = New-Object Xml.XmlNodeReader ([xml](Get-GuiXaml))
        $window = [Windows.Markup.XamlReader]::Load($reader)

        # Pull every x:Name into a lookup so handlers read as $ui.BtnApply.
        $ui = @{}
        foreach ($name in @(
            'VersionText', 'CatalogChip', 'ElevChip', 'ElevChipBorder', 'DryRunToggle', 'BtnElevate',
            'NavList', 'TweaksPanel', 'AppsPanel', 'ToolboxPanel', 'ProfilesPanel',
            'TweakSearch', 'TweakCategory', 'TweakRows', 'BtnApply', 'BtnRevert', 'BtnTweakAll', 'BtnTweakNone',
            'AppSearch', 'AppCategory', 'AppRows', 'BtnInstall', 'BtnAppNone',
            'ToolboxRows',
            'ProfilePath', 'BtnBrowseProfile', 'BtnRunProfile', 'BtnSaveProfile',
            'LogBox', 'BtnClearLog', 'StatusText', 'Progress')) {
            $ui[$name] = $window.FindName($name)
        }

        # ---- log pane ----------------------------------------------------------
        $document = New-Object Windows.Documents.FlowDocument
        # Wide enough that rules and status lines never wrap, without the permanent
        # horizontal scrollbar a fixed large width would cause. Tracked on resize.
        $document.PageWidth = 900
        $paragraph = New-Object Windows.Documents.Paragraph
        $paragraph.Margin = New-Object Windows.Thickness 0
        $paragraph.LineHeight = 15
        $document.Blocks.Add($paragraph)
        $ui.LogBox.Document = $document

        # ---- shared state ------------------------------------------------------
        # Everything a handler needs, parked somewhere it can still reach once this
        # function has returned. See the note at the top of the file.
        $Ctx.Gui = [pscustomobject]@{
            Window    = $window
            Ui        = $ui
            Paragraph = $paragraph
            Rows      = [pscustomobject]@{ Tweaks = @(); Apps = @(); Toolbox = @() }
            Bound     = $BoundParameters
            Glyphs    = $Ctx.Theme.Glyph
        }

        # The console glyph set may have fallen back to ASCII because conhost cannot
        # encode box drawing. WPF has no such problem, so the log pane always gets the
        # good glyphs; the console's set is restored when the window closes.
        $Ctx.Theme.Glyph = New-GlyphSet -Unicode $true

        $ui.LogBox.Add_SizeChanged({
            param($sender, $e)
            if ($sender.Document) { $sender.Document.PageWidth = [Math]::Max(600, $sender.ActualWidth - 24) }
        })

        # Redirecting Write-Line is what lets every engine function report into the
        # window without knowing the window exists.
        $Ctx.Sink = {
            param($text, $color, $newline)
            if (-not $Ctx.Gui) { return }

            $run = New-Object Windows.Documents.Run ([string]$text)
            if ($color) { $run.Foreground = ConvertTo-Brush $color }
            $Ctx.Gui.Paragraph.Inlines.Add($run)
            if ($newline) { $Ctx.Gui.Paragraph.Inlines.Add((New-Object Windows.Documents.LineBreak)) }

            $Ctx.Gui.Ui.LogBox.ScrollToEnd()
            Invoke-UiEvents
        }

        $Ctx.ProgressSink = {
            param($label, $fraction, $detail)
            if (-not $Ctx.Gui) { return }

            $bar = $Ctx.Gui.Ui.Progress
            $bar.Visibility = 'Visible'

            if ($fraction -lt 0) {
                $bar.IsIndeterminate = $true
            }
            else {
                $bar.IsIndeterminate = $false
                $bar.Value = [Math]::Round($fraction * 100)
            }

            $Ctx.Gui.Ui.StatusText.Text = if ($detail) { "$label   $detail" } else { [string]$label }
            Invoke-UiEvents
        }

        $Ctx.ConfirmSink = {
            param($message, $defaultYes)

            $default = if ($defaultYes) { [Windows.MessageBoxResult]::Yes } else { [Windows.MessageBoxResult]::No }
            $owner = if ($Ctx.Gui) { $Ctx.Gui.Window } else { $null }

            $answer = [Windows.MessageBox]::Show($owner, [string]$message, 'Moscovium',
                [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question, $default)

            return ($answer -eq [Windows.MessageBoxResult]::Yes)
        }

        try { $window.Icon = New-GuiIcon } catch { Write-Log "Window icon failed: $($_.Exception.Message)" 'WARN' }

        # ---- navigation labels -------------------------------------------------
        $navCounts = @($Ctx.Tweaks.Count, $Ctx.Apps.Count, @(Get-ToolboxActions).Count, -1)
        $navNames = @('Tweaks', 'Apps', 'Toolbox', 'Profiles')
        for ($i = 0; $i -lt $ui.NavList.Items.Count -and $i -lt $navNames.Count; $i++) {
            Set-GuiNavContent -Item $ui.NavList.Items[$i] -Text $navNames[$i] -Count $navCounts[$i]
        }

        # ---- keyboard ----------------------------------------------------------
        $window.Add_PreviewKeyDown({
            param($sender, $e)
            if (-not $Ctx.Gui) { return }
            $ui = $Ctx.Gui.Ui

            $box = if ($ui.AppsPanel.Visibility -eq 'Visible') { $ui.AppSearch }
                   elseif ($ui.TweaksPanel.Visibility -eq 'Visible') { $ui.TweakSearch }
                   else { $null }

            $ctrl = [Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control

            if ($ctrl -and $e.Key -eq [Windows.Input.Key]::F) {
                if ($box) { [void]$box.Focus(); $box.SelectAll() }
                $e.Handled = $true
            }
            elseif ($e.Key -eq [Windows.Input.Key]::Escape) {
                if ($box -and $box.Text) { $box.Text = ''; $e.Handled = $true }
            }
        })

        # ---- header ------------------------------------------------------------
        $ui.VersionText.Text = "v$($Ctx.Version)"
        $ui.CatalogChip.Text = "$($Ctx.Tweaks.Count) tweaks   $($Ctx.Apps.Count) apps"

        if ($Ctx.IsAdmin) {
            $ui.ElevChip.Text = 'elevated'
            $ui.ElevChip.Foreground = ConvertTo-Brush 'Green'
            $ui.BtnElevate.Visibility = 'Collapsed'
        }
        else {
            $ui.ElevChip.Text = 'not elevated'
        }

        $ui.DryRunToggle.IsChecked = $Ctx.DryRun
        $ui.DryRunToggle.Add_Click({ param($sender, $e) $Ctx.DryRun = [bool]$sender.IsChecked })

        $ui.BtnElevate.Add_Click({
            param($sender, $e)
            if (Invoke-SelfElevate -BoundParameters $Ctx.Gui.Bound) { $Ctx.Gui.Window.Close() }
        })

        $ui.BtnClearLog.Add_Click({ if ($Ctx.Gui) { $Ctx.Gui.Paragraph.Inlines.Clear() } })

        # ---- navigation --------------------------------------------------------
        $ui.NavList.Add_SelectionChanged({
            param($sender, $e)
            if (-not $Ctx.Gui) { return }

            $panels = @($Ctx.Gui.Ui.TweaksPanel, $Ctx.Gui.Ui.AppsPanel, $Ctx.Gui.Ui.ToolboxPanel, $Ctx.Gui.Ui.ProfilesPanel)
            for ($i = 0; $i -lt $panels.Count; $i++) {
                $panels[$i].Visibility = if ($i -eq $sender.SelectedIndex) { 'Visible' } else { 'Collapsed' }
            }
        })

        # ---- filters -----------------------------------------------------------
        $ui.TweakCategory.Items.Add('All categories') | Out-Null
        foreach ($c in $Ctx.TweakCategories) { $ui.TweakCategory.Items.Add($c) | Out-Null }
        $ui.TweakCategory.SelectedIndex = 0

        $ui.AppCategory.Items.Add('All categories') | Out-Null
        foreach ($c in $Ctx.AppCategories) { $ui.AppCategory.Items.Add($c) | Out-Null }
        $ui.AppCategory.SelectedIndex = 0

        $ui.TweakSearch.Add_TextChanged({ Update-GuiTweakRow })
        $ui.TweakCategory.Add_SelectionChanged({ Update-GuiTweakRow })
        $ui.AppSearch.Add_TextChanged({ Update-GuiAppRow })
        $ui.AppCategory.Add_SelectionChanged({ Update-GuiAppRow })

        $ui.BtnTweakAll.Add_Click({ foreach ($r in $Ctx.Gui.Rows.Tweaks) { $r.CheckBox.IsChecked = $true } })
        $ui.BtnTweakNone.Add_Click({ foreach ($r in $Ctx.Gui.Rows.Tweaks) { $r.CheckBox.IsChecked = $false } })
        $ui.BtnAppNone.Add_Click({ foreach ($r in $Ctx.Gui.Rows.Apps) { $r.CheckBox.IsChecked = $false } })

        # ---- actions -----------------------------------------------------------
        $ui.BtnApply.Add_Click({
            $selected = Get-CheckedItem -Rows $Ctx.Gui.Rows.Tweaks
            if ($selected.Count -eq 0) { $Ctx.Gui.Ui.StatusText.Text = 'Nothing selected.'; return }

            Invoke-GuiWork -Label 'applying tweaks' -Work { Invoke-Tweaks -Tweaks $selected -Mode Apply }
            Update-GuiTweakRow
        })

        $ui.BtnRevert.Add_Click({
            $selected = Get-CheckedItem -Rows $Ctx.Gui.Rows.Tweaks
            if ($selected.Count -eq 0) { $Ctx.Gui.Ui.StatusText.Text = 'Nothing selected.'; return }

            Invoke-GuiWork -Label 'reverting tweaks' -Work { Invoke-Tweaks -Tweaks $selected -Mode Revert }
            Update-GuiTweakRow
        })

        $ui.BtnInstall.Add_Click({
            $selected = Get-CheckedItem -Rows $Ctx.Gui.Rows.Apps
            if ($selected.Count -eq 0) { $Ctx.Gui.Ui.StatusText.Text = 'Nothing selected.'; return }

            Invoke-GuiWork -Label 'installing apps' -Work { Invoke-AppInstall -Apps $selected }
        })

        # ---- profiles ----------------------------------------------------------
        $ui.BtnBrowseProfile.Add_Click({
            $dialog = New-Object Windows.Forms.OpenFileDialog
            $dialog.Filter = 'Moscovium profile (*.json)|*.json|All files (*.*)|*.*'
            if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $Ctx.Gui.Ui.ProfilePath.Text = $dialog.FileName }
        })

        $ui.BtnRunProfile.Add_Click({
            $path = [string]$Ctx.Gui.Ui.ProfilePath.Text
            if (-not $path) { $Ctx.Gui.Ui.StatusText.Text = 'Choose a profile first.'; return }

            Invoke-GuiWork -Label 'running profile' -Work { Invoke-SetupProfile -Path $path }
            Update-GuiTweakRow
        })

        $ui.BtnSaveProfile.Add_Click({
            $dialog = New-Object Windows.Forms.SaveFileDialog
            $dialog.Filter = 'Moscovium profile (*.json)|*.json'
            $dialog.FileName = 'moscovium-profile.json'
            if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }

            $target = $dialog.FileName
            $setupProfile = New-SetupProfile `
                -Tweaks @(Get-CheckedItem -Rows $Ctx.Gui.Rows.Tweaks | ForEach-Object { $_.name }) `
                -Apps   @(Get-CheckedItem -Rows $Ctx.Gui.Rows.Apps   | ForEach-Object { $_.id })

            Invoke-GuiWork -Label 'saving profile' -Work { Save-SetupProfile -SetupProfile $setupProfile -Path $target | Out-Null }
            $Ctx.Gui.Ui.ProfilePath.Text = $target
        })

        # Put the console back the way we found it.
        $window.Add_Closed({
            param($sender, $e)
            if ($Ctx.Gui) { $Ctx.Theme.Glyph = $Ctx.Gui.Glyphs }
            $Ctx.Gui = $null
            $Ctx.Sink = $null
            $Ctx.ProgressSink = $null
            $Ctx.ConfirmSink = $null
        })

        # ---- go ----------------------------------------------------------------
        Update-GuiTweakRow
        Update-GuiAppRow
        Update-GuiToolboxRow

        $ui.StatusText.Text = 'Ready'

        Write-Rule -Title 'Moscovium' -Suffix "v$($Ctx.Version)"
        Write-Info "$($Ctx.Tweaks.Count) tweaks, $($Ctx.Apps.Count) apps loaded."
        if (-not $Ctx.IsAdmin) { Write-Warn 'Not elevated - machine-wide tweaks will be skipped.' }

        [pscustomobject]@{
            Window = $window
            Ui     = $ui
            Rows   = $Ctx.Gui.Rows
        }
    }

    function Show-Gui {
        param([hashtable]$BoundParameters = @{})

        if (-not (Test-StaApartment)) {
            if (Invoke-StaRelaunch -BoundParameters $BoundParameters) {
                Write-Ok 'GUI launched in a separate STA window.'
                return 0
            }
            return 1
        }

        try { Import-WpfAssembly }
        catch {
            Write-Err "WPF is not available on this machine: $($_.Exception.Message)"
            return 1
        }

        $gui = New-GuiWindow -BoundParameters $BoundParameters
        $gui.Window.ShowDialog() | Out-Null
        return 0
    }

    # Runs an engine call with the action buttons disabled and the progress bar
    # live, so a long install cannot be started twice and the window still repaints.
    function Invoke-GuiWork {
        param(
            [Parameter(Mandatory)][string]$Label,
            [Parameter(Mandatory)][scriptblock]$Work
        )

        if (-not $Ctx.Gui) { & $Work; return }

        $ui = $Ctx.Gui.Ui
        $buttons = @('BtnApply', 'BtnRevert', 'BtnInstall', 'BtnRunProfile', 'BtnSaveProfile')
        foreach ($name in $buttons) { $ui[$name].IsEnabled = $false }

        $ui.StatusText.Text = $Label
        $ui.Progress.Visibility = 'Visible'
        $ui.Progress.IsIndeterminate = $true
        Invoke-UiEvents

        try { & $Work }
        catch { Write-Err $_.Exception.Message }
        finally {
            foreach ($name in $buttons) { $ui[$name].IsEnabled = $true }
            $ui.Progress.IsIndeterminate = $false
            $ui.Progress.Visibility = 'Hidden'
            $ui.StatusText.Text = 'Ready'
            Invoke-UiEvents
        }
    }

# ===== src/90-Main.ps1 =================================================

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

    $Ctx = New-MoscoviumContext -Version $BuildVersion -SourceUrl $Source -BuildStamp $BuildStamp `
        -DryRun:(Test-Flag 'DryRun') `
        -AssumeYes:(Test-Flag 'Yes') `
        -NoColor:(Test-Flag 'NoColor') `
        -Ascii:(Test-Flag 'Ascii')

    Initialize-State

    # Box drawing needs a UTF-8 console. Native tools are decoded through the
    # same setting, so it is put back before we return.
    $previousEncoding = Initialize-ConsoleEncoding

    try {
        $exitCode = Invoke-Main -Bound $BoundParameters
        if ($exitCode -ne 0) { $global:LASTEXITCODE = $exitCode }
    }
    catch {
        Write-Host ''
        Write-Host "  Moscovium stopped: $($_.Exception.Message)" -ForegroundColor Red
        try { Write-Log "FATAL: $($_ | Out-String)" 'ERROR' } catch { }
        $global:LASTEXITCODE = 1
    }
    finally {
        Restore-ConsoleEncoding -Previous $previousEncoding
    }

} $PSBoundParameters '1.2.0' $SourceUrl '80f6fd927c'