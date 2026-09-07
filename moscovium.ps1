<#
    Moscovium CLI v1.2.0
    Windows debloat and setup toolbox - the command line companion to
    https://github.com/Moscoviumdebloat/Moscovium

        irm https://moscovium.win | iex

    Build a1f0fc265f  (a digest of src/ and data/ - same sources, same id).
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
    [switch]  $Tasks,
    [string]  $InstallManager,
    [string]  $Customize,
    [string[]]$Guide,
    [string[]]$SetSetting,
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
            Guides     = @()
            GuideCategories = @()
            StoreApps  = @()
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
        Write-Line ''
        foreach ($line in @(Get-WordmarkLines)) { Write-Line $line.Text -Color $line.Color }

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
                   "syncedUtc":  "2026-09-07T00:37:01.3039384Z"
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
                   "syncedUtc":  "2026-09-07T00:37:01.3039384Z"
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
                # Sparkline ramp, lowest to highest. Eight levels either way, so a
                # graph has the same resolution on both consoles.
                Spark = @('_', '.', ',', '-', '=', '+', '*', '#')
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
            # Lower blocks, one eighth to full - the sparkline ramp the history
            # graphs draw with. U+2581 rather than U+2580 as the floor: a graph of
            # zeroes should still show a baseline.
            Spark       = @(0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588 |
                            ForEach-Object { ConvertTo-Char $_ })
        }
    }

    function New-Palette {
        @{
            # Purple, to match the window. Magenta and DarkMagenta are as close as
            # the sixteen console colours get; conhost draws both as violet.
            Accent      = [ConsoleColor]::Magenta
            AccentDim   = [ConsoleColor]::DarkMagenta
            Ok          = [ConsoleColor]::Green
            Warn        = [ConsoleColor]::Yellow
            Err         = [ConsoleColor]::Red
            Text        = [ConsoleColor]::Gray
            Bright      = [ConsoleColor]::White
            Muted       = [ConsoleColor]::DarkGray
            HighlightFg = [ConsoleColor]::White
            HighlightBg = [ConsoleColor]::DarkMagenta
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

    # The wordmark, as lines already paired with their colour.
    #
    # Shared, so the splash and the menu header cannot drift apart - the menu used
    # to print a plain word where the splash printed this.
    #
    # Plain ASCII only: it has to render in a legacy conhost window on code page
    # 437, not just Windows Terminal. The backtick on the fourth line is part of the
    # letterform, not a PowerShell escape - these are single-quoted strings, so it
    # is taken literally.
    function Get-WordmarkLines {
        $art = @(
            '   __  __                                   _',
            '  |  \/  |  ___   ___   ___   ___  __   __ (_) _   _  _ __ ___  ',
            '  | |\/| | / _ \ / __| / __| / _ \ \ \ / / | || | | || ''_ ` _ \ ',
            '  | |  | || (_) |\__ \| (__ | (_) | \ V /  | || |_| || | | | | |',
            '  |_|  |_| \___/ |___/ \___| \___/   \_/   |_| \__,_||_| |_| |_|'
        )

        # Top-down gradient, Magenta -> DarkMagenta. Only sixteen colours are in
        # play and neither is a true purple, but conhost draws both as violet and it
        # needs no ANSI support.
        #
        # No White at the top: the first line is the thin roof of the letterforms,
        # and a white roof over purple letters reads as a rendering fault rather
        # than a highlight. Every line is purple.
        $ramp = @(
            [ConsoleColor]::Magenta
            [ConsoleColor]::Magenta
            [ConsoleColor]::Magenta
            [ConsoleColor]::DarkMagenta
            [ConsoleColor]::DarkMagenta
        )

        for ($i = 0; $i -lt $art.Count; $i++) {
            [pscustomobject]@{
                Text  = $art[$i]
                Color = $ramp[[Math]::Min($i, $ramp.Count - 1)]
            }
        }
    }

    # The widest line, so a caller can tell whether the window can hold the art
    # before drawing it into a fixed-height frame.
    function Get-WordmarkWidth {
        $widest = 0
        foreach ($line in @(Get-WordmarkLines)) {
            if ($line.Text.Length -gt $widest) { $widest = $line.Text.Length }
        }
        return $widest
    }

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
            [string]$Label = 'downloading',
            # Guards against a link that now returns an HTML error page. Config files
            # are legitimately tiny, so callers can lower it.
            [int]$MinimumBytes = 1024
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
        if ($size -lt $MinimumBytes) { throw "Downloaded file is only $size bytes; the link is probably wrong." }

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

        # An .msi is not executable: Start-Process on one goes through the shell
        # association, and -Wait then returns when the *shell* hands off rather than
        # when the install finishes, with an exit code that means nothing. msiexec
        # directly gives a real wait and a real code. Interactive, like the .exe
        # path - this launches the vendor's installer, it does not silence it.
        if ([IO.Path]::GetExtension($destination) -ieq '.msi') {
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', ('"' + $destination + '"')) `
                -Wait -PassThru -ErrorAction Stop
        }
        else {
            $process = Start-Process -FilePath $destination -Wait -PassThru -ErrorAction Stop
        }

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
    $EmbeddedWinutilOneClickJson = @'
[
  "WPFTweaksRestorePoint",
  "WPFTweaksActivity",
  "WPFTweaksConsumerFeatures",
  "WPFTweaksDisableExplorerAutoDiscovery",
  "WPFTweaksWPBT",
  "WPFTweaksLocation",
  "WPFTweaksServices",
  "WPFTweaksTelemetry",
  "WPFTweaksDeliveryOptimization",
  "WPFTweaksDeleteTempFiles",
  "WPFTweaksEndTaskOnTaskbar",
  "WPFTweaksDisableStoreSearch",
  "WPFTweaksRevertStartMenu",
  "WPFTweaksWidget",
  "WPFTweaksRemoveOneDrive",
  "WPFTweaksWindowsAI",
  "WPFTweaksRightClickMenu",
  "WPFTweaksEdgeDebloat",
  "WPFTweaksBraveDebloat",
  "WPFTweaksDisableBGapps"
]
'@
    $EmbeddedRaphiOneClickJson = @'
{
  "Version": "1.0",
  "Apps": [
    "Default"
  ],
  "Tweaks": [
    { "Name": "RemoveGamingApps", "Value": true },

    { "Name": "DisableTelemetry", "Value": true },
    { "Name": "DisableSuggestions", "Value": true },
    { "Name": "DisableLockscreenTips", "Value": true },
    { "Name": "DisableDesktopSpotlight", "Value": true },
    { "Name": "DisableFindMyDevice", "Value": true },
    { "Name": "DisableEdgeAds", "Value": true },
    { "Name": "DisableBraveBloat", "Value": true },
    { "Name": "DisableSettings365Ads", "Value": true },
    { "Name": "DisableSettingsHome", "Value": true },

    { "Name": "DisableBing", "Value": true },
    { "Name": "DisableStoreSearchSuggestions", "Value": true },
    { "Name": "DisableStartRecommended", "Value": true },
    { "Name": "DisableStartPhoneLink", "Value": true },
    { "Name": "ClearStartAllUsers", "Value": true },

    { "Name": "DisableCopilot", "Value": true },
    { "Name": "DisableRecall", "Value": true },
    { "Name": "DisableClickToDo", "Value": true },
    { "Name": "DisableAISvcAutoStart", "Value": true },
    { "Name": "DisablePaintAI", "Value": true },
    { "Name": "DisableNotepadAI", "Value": true },
    { "Name": "DisableEdgeAI", "Value": true },

    { "Name": "DisableDeviceAutoAppDownload", "Value": true },
    { "Name": "PreventUpdateAutoReboot", "Value": true },

    { "Name": "TaskbarAlignLeft", "Value": true },
    { "Name": "HideSearchTb", "Value": true },
    { "Name": "HideTaskview", "Value": true },
    { "Name": "DisableWidgets", "Value": true },
    { "Name": "HideChat", "Value": true },

    { "Name": "EnableDarkMode", "Value": true },

    { "Name": "ExplorerToThisPC", "Value": true },
    { "Name": "ShowKnownFileExt", "Value": true },
    { "Name": "HideHome", "Value": true },
    { "Name": "HideGallery", "Value": true },

    { "Name": "DisableDVR", "Value": true },
    { "Name": "DisableGameBarIntegration", "Value": true },

    { "Name": "DisableMouseAcceleration", "Value": true },
    { "Name": "DisableStickyKeys", "Value": true },
    { "Name": "DisableDragTray", "Value": true },
    { "Name": "DisableFastStartup", "Value": true }
  ],
  "Deployment": [
    { "Name": "CreateRestorePoint", "Value": true },
    { "Name": "SkipRegistryBackup", "Value": false },
    { "Name": "RestartExplorer", "Value": true },
    { "Name": "UserSelectionIndex", "Value": 0 },
    { "Name": "AppRemovalScopeIndex", "Value": 0 }
  ]
}
'@

    function Get-ToolboxActions {
        @(
            # Standalone: this one has its own front door - the GUI's landing page
            # and the CLI's first menu entry - so the toolbox lists leave it out
            # rather than burying it among the one-shot actions. Still addressable
            # as -Toolbox oneclick, and still shown by -List toolbox.
            [pscustomobject]@{
                Id = 'oneclick'; Name = 'One-click debloat box'; Admin = $true; Standalone = $true
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

    # The actions that belong in a list of one-shot actions - everything without a
    # front door of its own. Tested by property presence, not by value, because
    # Set-StrictMode makes reading an absent property on the other entries throw.
    function Get-ToolboxListActions {
        @(Get-ToolboxActions | Where-Object { -not $_.PSObject.Properties['Standalone'] })
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
    function Get-PresetJson {
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
            [Parameter(Mandatory)][string]$DataFile,
            [Parameter(Mandatory)][string]$Label
        )

        if (-not [string]::IsNullOrWhiteSpace($Json)) { return $Json }

        $candidate = $null
        if ($PSScriptRoot) { $candidate = Join-Path $PSScriptRoot (Join-Path '..\data' $DataFile) }
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Get-Content -LiteralPath $candidate -Raw -Encoding UTF8)
        }

        throw "The $Label preset is not embedded in this build."
    }

    function Get-PresetConfigPath {
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
            [Parameter(Mandatory)][string]$DataFile,
            [Parameter(Mandatory)][string]$Label
        )

        $text = Get-PresetJson -Json $Json -DataFile $DataFile -Label $Label

        Initialize-State
        $path = Join-Path $Ctx.StateDir $DataFile
        [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
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

    # The six steps, as data. One source of truth: the CLI prints this before
    # asking, the GUI's landing page draws it, and Invoke-OneClickDebloat walks it.
    #
    # Data only, deliberately - no script blocks. A block built here would go
    # looking for this function's locals long after it had returned. See the note
    # at the top of 70-Gui.ps1.
    function Get-OneClickSteps {
        $winutil = Get-PresetJson -Json $EmbeddedWinutilOneClickJson -DataFile 'winutil-oneclick.json' -Label 'WinUtil one-click'
        $raphi   = Get-PresetJson -Json $EmbeddedRaphiOneClickJson -DataFile 'raphi-oneclick.json' -Label 'Win11Debloat one-click'

        $winutilCount = @(($winutil | ConvertFrom-Json)).Count
        $raphiCount   = @(($raphi | ConvertFrom-Json).Tweaks).Count

        @(
            [pscustomobject]@{
                Id = 'winutil'
                Title = "WinUtil with $winutilCount tweaks preselected"
                Detail = 'christitus.com/win - opens its window, and you press Run Tweaks'
            }
            [pscustomobject]@{
                Id = 'raphi'
                Title = "Win11Debloat with $raphiCount tweaks"
                Detail = 'debloat.raphi.re - silent, nothing to click. This is what removes Bing from search.'
            }
            [pscustomobject]@{
                Id = 'updates-security'
                Title = 'Windows Update set to security-only'
                Detail = 'Feature updates deferred 365 days, quality updates 4, no reboots while signed in'
            }
            [pscustomobject]@{
                Id = 'network-better'
                Title = 'TCP autotuning disabled'
                Detail = 'netsh int tcp set global autotuninglevel=disabled'
            }
            [pscustomobject]@{
                Id = 'priority-22'
                Title = 'Win32PrioritySeparation set to 22'
                Detail = 'Favours the foreground app. Needs a reboot.'
            }
            [pscustomobject]@{
                Id = 'dynamictick-off'
                Title = 'Dynamic tick disabled'
                Detail = 'bcdedit /set disabledynamictick yes. Needs a reboot.'
            }
        )
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
        $steps = @(Get-OneClickSteps)

        Write-Line ''
        Write-Info "The box runs $($steps.Count) steps, in this order:"
        for ($i = 0; $i -lt $steps.Count; $i++) {
            Write-Line ("      {0}. {1}" -f ($i + 1), $steps[$i].Title) -Color White
            if ($steps[$i].Detail) { Write-Line "         $($steps[$i].Detail)" -Color DarkGray }
        }

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
            for ($i = 0; $i -lt $steps.Count; $i++) {
                $step = $steps[$i]

                Write-Line ''
                Write-Rule -Title ("Step {0} of {1} - {2}" -f ($i + 1), $steps.Count, $step.Title)

                try {
                    $ok = switch ($step.Id) {
                        'winutil' {
                            Invoke-RemoteScript -Url 'https://christitus.com/win' -Label 'WinUtil (one-click preset)' `
                                -ScriptArguments @('-Config', (Get-WinutilOneClickPath))
                        }
                        'raphi' {
                            Invoke-RemoteScript -Url 'https://debloat.raphi.re/' -Label 'Win11Debloat (one-click preset)' `
                                -ScriptArguments @('-Silent', '-Config', (Get-RaphiOneClickPath))
                        }
                        'updates-security' { Set-SecurityUpdatePolicy; $true }
                        default { Invoke-ToolboxStep -Id $step.Id }
                    }

                    if (-not $ok) { $failed.Add($step.Title) }
                }
                catch {
                    Write-Err "$($step.Title) - $($_.Exception.Message)"
                    $failed.Add($step.Title)
                }
            }
        }
        finally {
            $Ctx.AssumeYes = $previousAssumeYes
        }

        Write-Line ''
        if ($failed.Count -eq 0) {
            Write-Ok "All $($steps.Count) steps finished."
        }
        else {
            Write-Warn "$($failed.Count) of $($steps.Count) steps did not complete: $(@($failed) -join ', ')"
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

# ===== src/44-Guides.ps1 ===============================================

    # =============================================================================
    # Guides: the manual optimisation walkthroughs from the desktop app.
    #
    # These are the things a tool cannot do for you - BIOS settings, driver control
    # panels, router configuration - so the catalog is pure text and the only job
    # here is presenting it. Generated from Models/Guides.cs by Sync-Catalog.ps1 and
    # embedded by build.ps1, exactly like the tweak and app catalogs.
    # =============================================================================

    $EmbeddedGuidesJson = @'
{
    "categories":  [
                       "Drivers & GPU",
                       "BIOS",
                       "Windows",
                       "Hardware",
                       "Network"
                   ],
    "guides":  [
                   {
                       "title":  "NVIDIA GPU Optimization",
                       "category":  "Drivers & GPU",
                       "summary":  "Tune the NVIDIA App / Control Panel for maximum gaming performance.",
                       "steps":  [
                                     "Install the NVIDIA App via PC Setup Automation (or download it from nvidia.com) and sign in.",
                                     "Open Settings (gear icon) and make sure 'Driver Updates' is set to Latest and the latest Game Ready driver is installed.",
                                     "Go to Graphics \u2192 Global Settings.",
                                     "Power management mode \u2192 Prefer maximum performance (prevents the GPU from downclocking).",
                                     "Low Latency Mode \u2192 Ultra (reduces input latency in shooters; if you see stutter, try On instead).",
                                     "Texture filtering - Quality \u2192 High quality.",
                                     "Vertical sync \u2192 Off (enable in-game only if you get screen tearing).",
                                     "Threaded optimization \u2192 Auto.",
                                     "Monitor Technology \u2192 G-SYNC if your monitor supports it (set together with V-Sync On + low latency in games).",
                                     "In the Games tab, add per-game profiles: for esports titles force 'Prefer maximum performance' and disable any anti-aliasing you don't need.",
                                     "Optional: enable ReBAR (Resizable BAR) in BIOS for a few extra FPS - see the BIOS guide.",
                                     "Check temperatures with HWiNFO after changes - anything under 85 C under load is fine."
                                 ]
                   },
                   {
                       "title":  "AMD GPU Optimization",
                       "category":  "Drivers & GPU",
                       "summary":  "Tune Radeon Software / Adrenalin for gaming performance.",
                       "steps":  [
                                     "Install AMD Adrenalin Edition via PC Setup Automation (or from amd.com) and open Radeon Software.",
                                     "Open the Performance tab \u2192 Tuning.",
                                     "Click 'Tuning Control' \u2192 select the Performance preset (applies balanced overclocks automatically).",
                                     "Under Graphics: turn Anti-Lag on (only in the game, not globally, for best results).",
                                     "Radeon Chill \u2192 off for competitive shooters (it caps FPS to save power).",
                                     "Set 'Power Limit' slider to the max value (+10-20%) if thermals allow.",
                                     "Enable Smart Access Memory (SAM) in BIOS - see the BIOS guide - for a solid FPS uplift.",
                                     "Enable FreeSync on your monitor in Display settings if supported.",
                                     "For 'Radeon Boost', test in-game: it lowers resolution during fast mouse movement for FPS, but can look blurry.",
                                     "Monitor temps/voltages with HWiNFO; keep junction temp below 95 C."
                                 ]
                   },
                   {
                       "title":  "BIOS Setup for Performance",
                       "category":  "BIOS",
                       "summary":  "Critical firmware settings for CPU, GPU and memory performance.",
                       "steps":  [
                                     "Update your BIOS from the motherboard manufacturer's site (ASUS/MSI/Gigabyte/ASRock) - newer AGESA/microcode versions fix bugs and add features. Check your exact board model first (msinfo32 \u2192 System Model).",
                                     "Reboot and press DEL/F2 to enter BIOS.",
                                     "Enable XMP (Intel) or EXPO (AMD) in the memory settings to run your RAM at its rated speed.",
                                     "Enable Resizable BAR / Smart Access Memory (usually under PCIe settings) - pairs with an up-to-date GPU driver.",
                                     "On AMD: find 'CPPC' / 'CPPC Preferred Cores' and enable it (Windows then schedules threads on your best cores).",
                                     "For latency-sensitive gaming: set Global C-State Control \u2192 Disabled (costs a bit of idle power).",
                                     "Enable SVM (AMD virtualization) or Intel VT-x if you use WSL2, Docker or Android emulators.",
                                     "Set fan curves to a more aggressive profile in the hardware monitor section if temps allow.",
                                     "Save and exit (F10). On first boot, check in Task Manager that the RAM speed shows your rated MHz."
                                 ]
                   },
                   {
                       "title":  "Windows Latency & Stability",
                       "category":  "Windows",
                       "summary":  "OS-level settings that reduce stutter, latency and background interference.",
                       "steps":  [
                                     "Disable Fast Startup: Control Panel \u2192 Power Options \u2192 Choose what the power buttons do \u2192 uncheck 'Turn on fast startup'. Fast startup can cause driver/update issues after shutdown.",
                                     "Enable Game Mode: Settings \u2192 Gaming \u2192 Game Mode \u2192 On (lets Windows prioritize games).",
                                     "In the same Gaming page, set Xbox Game Bar to Off if you never use it.",
                                     "Hardware-accelerated GPU scheduling: apply the matching tweak in the Debloat Tweaks page (on for GTX 10-series+/RX 5000+ and newer).",
                                     "Per-game Fullscreen Optimizations: right-click the game .exe \u2192 Properties \u2192 Compatibility \u2192 check 'Disable fullscreen optimizations' for older/anticheat-sensitive games.",
                                     "Set a fixed pagefile: System \u2192 Advanced system settings \u2192 Performance \u2192 Advanced \u2192 Virtual memory \u2192 custom size = 1.5x your RAM (e.g. 24 GB for 16 GB RAM), on the fastest SSD.",
                                     "Install the latest chipset drivers from the motherboard vendor (this one step fixes more stutter than any tweak).",
                                     "Close background apps (Discord, browsers, RGB software) while playing competitive titles, or set them to Game Mode aware.",
                                     "Keep the PC on Balanced power plan if you have a modern CPU with CPPC2/boost handling; only switch to High Performance (available as a tweak) on older hardware."
                                 ]
                   },
                   {
                       "title":  "Monitoring & Overclocking",
                       "category":  "Hardware",
                       "summary":  "Verify performance, temps and stability before pushing any hardware.",
                       "steps":  [
                                     "Install HWiNFO (in PC Setup Automation) \u2192 run Sensors-only mode \u2192 enable logging (clock, temps, voltage) before benchmarking.",
                                     "Install MSI Afterburner (in PC Setup Automation) \u2192 enable the on-screen display (RivaTuner RTSS) for in-game FPS/temps/clock overlay.",
                                     "Install FanControl (in PC Setup Automation) to build custom fan curves based on GPU or CPU temperature.",
                                     "Run a baseline: Cinebench (CPU), 3DMark Time Spy (GPU) - note the scores and temperatures.",
                                     "CPU overclock: only via AMD Ryzen Master / Intel XTU, or BIOS. Increase by small steps (e.g. +50 MHz or per-core), stress test 30 min after every step, stop at the first instability.",
                                     "GPU overclock: in Afterburner raise core clock +25 MHz steps, then memory +100 MHz steps, stress with 3DMark/Heaven after each step.",
                                     "Undervolting is often better than overclocking: a -50 to -80 mV curve on the GPU gives the same clocks at lower temps.",
                                     "If temperatures exceed 85 C (GPU) or 90 C (CPU) at stock settings, fix cooling first - thermal paste, case airflow - before any overclocking.",
                                     "Use LatencyMon (in PC Setup Automation) to confirm no driver is causing high DPC latency (red bars = problem driver)."
                                 ]
                   },
                   {
                       "title":  "Network Optimization",
                       "category":  "Network",
                       "summary":  "Lower latency and jitter for online gaming.",
                       "steps":  [
                                     "Use a wired (Ethernet) connection whenever possible - Wi-Fi adds latency and jitter.",
                                     "Update the LAN/Wi-Fi driver from the motherboard or adapter vendor (not Windows Update only).",
                                     "Switch DNS to a fast public resolver: Settings \u2192 Network & Internet \u2192 your connection \u2192 DNS \u2192 manual \u2192 1.1.1.1 and 1.0.0.1 (Cloudflare) or 8.8.8.8/8.8.4.4 (Google).",
                                     "Apply the 'Prefer IPv4 over IPv6' and 'Disable Teredo' tweaks from the Debloat Tweaks page if your ISP's IPv6 is unreliable.",
                                     "Disable Delivery Optimization (also a tweak) so Windows never uploads updates on your bandwidth.",
                                     "In the router: enable QoS and prioritize your PC's MAC address; disable any SQM-unaware traffic shaping if your line is fine.",
                                     "Check bufferbloat at waveform.com/bufferbloat - if the grade is poor, enable SQM/fQ-CoDel in your router if available.",
                                     "Close bandwidth hogs while gaming (Steam downloads, cloud sync, Windows Update).",
                                     "Optional: set the game to high priority once via Task Manager \u2192 Details \u2192 right-click \u2192 Set priority (Windows already handles this via Game Mode)."
                                 ]
                   }
               ]
}
'@

    function Initialize-GuideCatalog {
        # Loaded lazily: a -Status run has no reason to parse them.
        if ($Ctx.Guides.Count -gt 0) { return }

        $data = Get-CatalogJson -Embedded $EmbeddedGuidesJson -FileName 'guides.json' | ConvertFrom-Json

        $Ctx.Guides = @($data.guides)
        $Ctx.GuideCategories = @($data.categories)
    }

    function Resolve-Guide {
        param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]]$Names)

        Initialize-GuideCatalog

        $matched = [System.Collections.Generic.List[object]]::new()
        $unknown = [System.Collections.Generic.List[string]]::new()

        foreach ($name in $Names) {
            $term = $name.Trim()
            if (-not $term) { continue }

            if ($term -eq 'all' -or $term -eq '*') {
                foreach ($g in $Ctx.Guides) { $matched.Add($g) }
                continue
            }

            $exact = @($Ctx.Guides | Where-Object { $_.title -eq $term })
            if ($exact.Count -eq 1) { $matched.Add($exact[0]); continue }

            $fuzzy = @($Ctx.Guides | Where-Object {
                (Test-NameMatch -Value $_.title -Pattern $term) -or
                (Test-NameMatch -Value $_.category -Pattern $term) -or
                (Test-NameMatch -Value $_.summary -Pattern $term)
            })

            if ($fuzzy.Count -gt 0) { foreach ($g in $fuzzy) { $matched.Add($g) } }
            else { $unknown.Add($term) }
        }

        [pscustomobject]@{
            Matched = @($matched | Group-Object -Property title | ForEach-Object { $_.Group[0] })
            Unknown = @($unknown)
        }
    }

    function Show-GuideCatalog {
        Initialize-GuideCatalog

        foreach ($category in $Ctx.GuideCategories) {
            $inCategory = @($Ctx.Guides | Where-Object { $_.category -eq $category })
            if ($inCategory.Count -eq 0) { continue }

            Write-SectionHeading $category -Suffix "$($inCategory.Count)"

            foreach ($guide in $inCategory) {
                Write-Line '  - ' -Color (Get-Color 'Muted') -NoNewline
                Write-Line $guide.title -Color (Get-Color 'Bright')
                Write-Info (ConvertTo-DisplayText $guide.summary)
                Write-Info "$(@($guide.steps).Count) steps"
            }
        }

        Write-Line ''
        Write-Info 'Read one with:  -Guide "<title>"'
    }

    function Show-Guide {
        param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Guides)

        if ($Guides.Count -eq 0) {
            Write-Warn 'No guide selected.'
            return
        }

        foreach ($guide in $Guides) {
            Write-SectionHeading $guide.title -Suffix $guide.category
            Write-Line ''
            Write-Line "  $(ConvertTo-DisplayText $guide.summary)" -Color (Get-Color 'Text')
            Write-Line ''

            $steps = @($guide.steps)
            for ($i = 0; $i -lt $steps.Count; $i++) {
                $number = '{0,3}. ' -f ($i + 1)
                Write-Line "  $number" -Color (Get-Color 'Accent') -NoNewline

                # Wrap to the rule width, indented under the number so the step reads
                # as one block rather than running back to the margin.
                foreach ($line in (Format-WrappedText -Text (ConvertTo-DisplayText $steps[$i]) -Width ((Get-RuleWidth) - 8) -Indent 7)) {
                    Write-Line $line
                }
            }
        }
    }

    # The guide text comes from the desktop app and contains real typography -
    # arrows, en dashes, curly quotes. WPF renders those happily; a console on an OEM
    # code page turns them into mojibake, so swap them for ASCII when the theme has
    # already told us Unicode is not safe here.
    function ConvertTo-DisplayText {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

        if ($Ctx.Theme.Unicode) { return $Text }

        # Pairs, not a hashtable: an OrderedDictionary with integer keys indexes by
        # position, so $map[0x2192] asks for element 8594 rather than the arrow.
        $map = @(
            @(0x2192, '->'), @(0x2190, '<-'), @(0x21D2, '=>')
            @(0x2013, '-'),  @(0x2014, '-'),  @(0x2212, '-')
            @(0x2018, "'"),  @(0x2019, "'")
            @(0x201C, '"'),  @(0x201D, '"')
            @(0x2026, '...'), @(0x00A0, ' ')
            @(0x00B0, ' deg'), @(0x00D7, 'x'), @(0x2022, '*')
        )

        foreach ($pair in $map) { $Text = $Text.Replace([string][char][int]$pair[0], [string]$pair[1]) }

        # Anything still outside ASCII would render as a question mark at best.
        [regex]::Replace($Text, '[^\x00-\x7F]', '?')
    }

    # Word-wraps to $Width, indenting every line after the first by $Indent. The
    # first line is returned without indent because the caller has already written a
    # step number there.
    function Format-WrappedText {
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
            [int]$Width = 70,
            [int]$Indent = 0
        )

        if ($Width -lt 20) { $Width = 20 }

        $lines = [System.Collections.Generic.List[string]]::new()
        $current = ''

        foreach ($word in ($Text -split '\s+' | Where-Object { $_ })) {
            if (-not $current) { $current = $word; continue }

            if (($current.Length + 1 + $word.Length) -le $Width) { $current = "$current $word" }
            else { $lines.Add($current); $current = $word }
        }
        if ($current) { $lines.Add($current) }

        $pad = ' ' * $Indent
        $out = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($i -eq 0) { $out.Add($lines[$i]) } else { $out.Add($pad + $lines[$i]) }
        }

        @($out)
    }

# ===== src/46-Store.ps1 ================================================

    # =============================================================================
    # App store: community apps published as GitHub releases.
    #
    # The desktop app lists every public repo in two organisations, takes the newest
    # release's .exe/.zip/.msi asset, and installs it under a configurable folder.
    # Same idea here, against the same two orgs.
    #
    # Distinct from the winget catalog in 30-Apps.ps1: that one is curated and
    # pinned, this one is whatever those orgs have published today.
    # =============================================================================

    $StoreOrganisations = @('Better-Dev-Team', 'Anti-Depressants-Dev-Team')

    function Get-StoreInstallRoot {
        $configured = Get-MoscoviumSetting -Name 'AppsInstallPath'
        if ($configured) { return $configured }
        Join-Path $Ctx.StateDir 'Apps'
    }

    function Invoke-GitHubApi {
        param([Parameter(Mandatory)][string]$Path)

        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

        $headers = @{
            'User-Agent' = 'Moscovium-CLI'
            'Accept'     = 'application/vnd.github+json'
        }

        # An optional token only raises the rate limit - 60/hour unauthenticated is
        # easy to hit when every repo costs a second request for its release.
        $token = Get-MoscoviumSetting -Name 'GitHubToken'
        if ($token) { $headers['Authorization'] = "Bearer $token" }

        Invoke-RestMethod -Uri "https://api.github.com$Path" -Headers $headers -TimeoutSec 45
    }

    # One catalog entry per public, non-archived repo that has a release with an
    # installable asset.
    function Get-StoreApp {
        param([switch]$Refresh)

        if (-not $Refresh -and $Ctx.StoreApps.Count -gt 0) { return $Ctx.StoreApps }

        $found = [System.Collections.Generic.List[object]]::new()

        foreach ($org in $StoreOrganisations) {
            Write-Step "Listing $org"

            $repos = $null
            try { $repos = Invoke-GitHubApi -Path "/orgs/$org/repos?type=public&per_page=100" }
            catch {
                Write-Warn "Could not list $org - $($_.Exception.Message)"
                continue
            }

            foreach ($repo in @($repos)) {
                if ($repo.archived) { continue }
                if ($repo.name -eq '.github') { continue }

                $release = $null
                try { $release = Invoke-GitHubApi -Path "/repos/$($repo.full_name)/releases/latest" }
                catch { }   # no releases yet is normal, not an error

                $asset = $null
                if ($release -and $release.assets) {
                    $asset = @($release.assets | Where-Object { $_.name -match '\.(exe|zip|msi)$' }) | Select-Object -First 1
                }

                $found.Add([pscustomobject]@{
                    Name        = $repo.name
                    Description = if ($repo.description) { [string]$repo.description } else { 'No description available.' }
                    Author      = $repo.owner.login
                    Version     = if ($release) { [string]$release.tag_name } else { 'no release' }
                    DownloadUrl = if ($asset) { [string]$asset.browser_download_url } else { '' }
                    AssetName   = if ($asset) { [string]$asset.name } else { '' }
                    RepoUrl     = [string]$repo.html_url
                })
            }
        }

        $Ctx.StoreApps = @($found | Sort-Object -Property Name)
        return $Ctx.StoreApps
    }

    function Install-StoreApp {
        param([Parameter(Mandatory)]$App)

        if (-not $App.DownloadUrl) {
            Write-Warn "$($App.Name) - no installable release asset. See $($App.RepoUrl)"
            $Ctx.Skipped++
            return
        }

        if ($Ctx.DryRun) {
            Write-Status -Glyph (Get-Glyph 'Info') -Color (Get-Color 'Warn') -Message $App.Name -MessageColor (Get-Color 'Warn')
            Write-Info "would download $($App.DownloadUrl)"
            $Ctx.Skipped++
            return
        }

        $root = Get-StoreInstallRoot
        $target = Join-Path $root $App.Name

        try {
            if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

            $file = Join-Path $target $App.AssetName
            Write-Step "Downloading $($App.Name) $($App.Version)"
            Write-Info $App.DownloadUrl
            Save-RemoteFile -Url $App.DownloadUrl -Destination $file -Label $App.Name | Out-Null

            if ($App.AssetName -match '\.zip$') {
                # A zip is the app itself here, not an installer wrapper: extract and
                # leave it in place rather than hunting for a setup.exe.
                Write-Step "Extracting to $target"
                Expand-Archive -LiteralPath $file -DestinationPath $target -Force
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
                Write-Ok "$($App.Name) - extracted to $target"
            }
            else {
                Write-Step "Running $($App.AssetName)"
                $process = Start-Process -FilePath $file -Wait -PassThru -ErrorAction Stop
                if ($process.ExitCode -notin @(0, 3010)) { throw "Installer exited with code $($process.ExitCode)." }
                Write-Ok $App.Name
            }

            $Ctx.Applied++
        }
        catch {
            Write-Err "$($App.Name) - $($_.Exception.Message)"
            $Ctx.Failed++
        }
    }

    function Invoke-StoreInstall {
        param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Apps)

        if ($Apps.Count -eq 0) {
            Write-Warn 'No store apps selected.'
            return
        }

        Write-SectionHeading "Installing $($Apps.Count) store app$(if ($Apps.Count -ne 1) { 's' })"
        Write-Info "into $(Get-StoreInstallRoot)"

        foreach ($app in $Apps) { Install-StoreApp -App $app }
        Write-RunSummary
    }

    function Show-StoreCatalog {
        $apps = @(Get-StoreApp)

        if ($apps.Count -eq 0) {
            Write-Warn 'No store apps found. GitHub may be rate-limiting; set a token with -SetSetting GitHubToken=<token>.'
            return
        }

        Write-SectionHeading 'App store' -Suffix "$($apps.Count)"

        foreach ($app in $apps) {
            Write-Line '  - ' -Color (Get-Color 'Muted') -NoNewline
            Write-Line $app.Name.PadRight(32) -Color (Get-Color 'Bright') -NoNewline
            Write-Line $app.Version -Color $(if ($app.DownloadUrl) { Get-Color 'Ok' } else { Get-Color 'Muted' })
            Write-Info $app.Description
        }
    }

# ===== src/48-Personalize.ps1 ==========================================

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

# ===== src/52-Tasks.ps1 ================================================

    # =============================================================================
    # Task manager engine: the sampling both front-ends draw from.
    #
    # btop-shaped - gauges and sparklines for CPU, memory, disk and network above a
    # sortable process table - but the numbers all come from raw performance
    # counters read through CIM.
    #
    # Why raw counters and not the formatted ones
    # -----------------------------------------------------------------------------
    # Win32_PerfFormattedData_* does its own two-sample wait inside the provider, so
    # a single query costs about 270ms. The Win32_PerfRawData_* equivalent is 9ms
    # and hands over the cumulative counters, leaving the delta arithmetic to us -
    # which we want anyway, because we are already keeping the previous sample for
    # the history graphs. Measured on this project's dev box:
    #
    #   Win32_PerfFormattedData_PerfOS_Processor   266 ms
    #   Win32_PerfRawData_PerfOS_Processor           9 ms
    #
    # The whole refresh - CPU, memory, disks, network, processes - lands around
    # 76ms, which is what makes a one-second interval comfortable in the window as
    # well as the console.
    #
    # Nothing here uses System.Diagnostics.PerformanceCounter: its category and
    # counter names are localised, so '\Processor(_Total)\% Processor Time' does not
    # exist on a German or Turkish install. CIM class and property names are not
    # localised.
    # =============================================================================

    $TaskCpuQuery = 'SELECT Name,PercentIdleTime,Timestamp_Sys100NS FROM Win32_PerfRawData_PerfOS_Processor'
    $TaskNetQuery = 'SELECT Name,BytesReceivedPersec,BytesSentPersec,Timestamp_Sys100NS,Frequency_Sys100NS FROM Win32_PerfRawData_Tcpip_NetworkInterface'
    # LastBootUpTime rides along on the memory query rather than costing a second
    # one: it is the same single-instance class, and the header wants an uptime.
    $TaskMemQuery = 'SELECT TotalVisibleMemorySize,FreePhysicalMemory,TotalVirtualMemorySize,FreeVirtualMemory,LastBootUpTime FROM Win32_OperatingSystem'
    $TaskDiskQuery = 'SELECT DeviceID,VolumeName,Size,FreeSpace FROM Win32_LogicalDisk WHERE DriveType=3'

    # -----------------------------------------------------------------------------
    # Formatting
    # -----------------------------------------------------------------------------

    # Short enough for a table column: 4 significant characters plus a unit letter.
    function Format-CompactBytes {
        param([AllowNull()]$Bytes)

        $value = 0.0
        if ($null -ne $Bytes) { $value = [double]$Bytes }
        if ($value -lt 0) { $value = 0.0 }

        $units = @('B', 'K', 'M', 'G', 'T', 'P')
        $index = 0
        while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
            $value = $value / 1024
            $index++
        }

        # Whole numbers below 10 units read better with a decimal; above 100 the
        # decimal is noise and costs a column.
        if ($index -eq 0 -or $value -ge 100) { return ('{0:N0}{1}' -f $value, $units[$index]) }
        return ('{0:N1}{1}' -f $value, $units[$index])
    }

    function Format-Rate {
        param([AllowNull()]$BytesPerSecond)
        return ((Format-CompactBytes $BytesPerSecond) + '/s')
    }

    # Seconds of CPU time as h:mm:ss, the way a process list shows it.
    function Format-CpuTime {
        param([AllowNull()]$Seconds)

        if ($null -eq $Seconds) { return '-' }
        $span = [TimeSpan]::FromSeconds([double]$Seconds)
        return ('{0}:{1:00}:{2:00}' -f [int]$span.TotalHours, $span.Minutes, $span.Seconds)
    }

    # The load bands the gauges and the process table colour by. Same thresholds in
    # both front-ends, so a red bar means the same thing in the window as it does in
    # the console.
    function Get-LoadBand {
        param([double]$Percent)

        if ($Percent -ge 85) { return 'high' }
        if ($Percent -ge 60) { return 'medium' }
        return 'low'
    }

    function Get-LoadColor {
        param([double]$Percent)

        switch (Get-LoadBand -Percent $Percent) {
            'high'   { return (Get-Color 'Err') }
            'medium' { return (Get-Color 'Warn') }
            default  { return (Get-Color 'Ok') }
        }
    }

    # -----------------------------------------------------------------------------
    # Drawing primitives
    # -----------------------------------------------------------------------------

    # A filled bar of $Width cells. Separate from Write-ProgressBar, which writes
    # straight to the host; this returns a string a frame line can hold.
    function New-MeterBar {
        param([double]$Percent, [int]$Width = 20)

        if ($Width -lt 1) { return '' }
        $clamped = [Math]::Max(0.0, [Math]::Min(100.0, $Percent))

        $filled = [int][Math]::Round(($clamped / 100.0) * $Width)
        if ($filled -gt $Width) { $filled = $Width }

        return ((Get-Glyph 'BarFull') * $filled) + ((Get-Glyph 'BarEmpty') * ($Width - $filled))
    }

    # A filled history graph $Height character rows tall.
    #
    # On a Unicode console every cell is a braille 2x4 dot matrix, so the effective
    # resolution is 2*Width by 4*Height - which is what makes this read as a curve
    # rather than a bar chart, and is the same trick btop uses. On a legacy console
    # it falls back to a column chart off the block ramp at 1x1 per cell.
    #
    # Returns an array of strings, top row first.
    function New-HistoryGraph {
        param(
            [AllowEmptyCollection()][double[]]$Values = @(),
            [int]$Width = 40,
            [int]$Height = 3,
            [double]$Maximum = 100
        )

        if ($Width -lt 1 -or $Height -lt 1) { return @() }
        if ($Maximum -le 0) { $Maximum = 1 }

        $braille = [bool]$Ctx.Theme.Unicode

        # Sub-columns per character cell: two for braille, one for blocks.
        $perCell = 1
        if ($braille) { $perCell = 2 }
        $subWidth = $Width * $perCell
        $subHeight = $Height * 4
        if (-not $braille) { $subHeight = $Height }

        # Newest sample on the right. When there is more history than the graph is
        # wide the oldest is dropped; when there is less it is stretched to fill.
        #
        # Stretching rather than left-padding is deliberate. A 92-cell braille
        # graph is 184 sub-columns, so at one sample a second a padded graph would
        # sit three minutes in a mostly empty box - which reads as broken. The
        # shape wobbles slightly as history accumulates and then settles, which is
        # the better trade.
        $recent = @($Values)
        if ($recent.Count -gt $subWidth) { $recent = @($recent[($recent.Count - $subWidth)..($recent.Count - 1)]) }

        # -1 marks a sub-column with nothing to draw, which stays blank rather than
        # reading as a measured zero.
        $heights = New-Object 'int[]' $subWidth
        for ($i = 0; $i -lt $subWidth; $i++) { $heights[$i] = -1 }

        if ($recent.Count -gt 0) {
            for ($i = 0; $i -lt $subWidth; $i++) {
                # Nearest sample at this fraction along the width.
                $source = 0
                if ($subWidth -gt 1 -and $recent.Count -gt 1) {
                    $source = [int][Math]::Round(($i / [double]($subWidth - 1)) * ($recent.Count - 1))
                }
                elseif ($recent.Count -gt 1) {
                    $source = $recent.Count - 1
                }

                $fraction = [Math]::Max(0.0, [Math]::Min(1.0, $recent[$source] / $Maximum))
                $filled = [int][Math]::Round($fraction * $subHeight)
                # Any non-zero reading gets at least one dot, so a busy-but-quiet
                # machine is not drawn as flat nothing.
                if ($filled -eq 0 -and $recent[$source] -gt 0) { $filled = 1 }
                $heights[$i] = $filled
            }
        }

        if (-not $braille) { return @(New-BlockGraph -Heights $heights -Width $Width -Height $Height) }

        # Braille dot numbering is column-major and does not run in reading order:
        #   1 4
        #   2 5
        #   3 6
        #   7 8
        # so the top-to-bottom bit order differs per half of the cell.
        $leftBits  = @(0x01, 0x02, 0x04, 0x40)
        $rightBits = @(0x08, 0x10, 0x20, 0x80)

        $rows = [System.Collections.Generic.List[string]]::new()
        for ($row = 0; $row -lt $Height; $row++) {
            $line = New-Object Text.StringBuilder

            for ($col = 0; $col -lt $Width; $col++) {
                $mask = 0

                for ($half = 0; $half -lt 2; $half++) {
                    $filled = $heights[($col * 2) + $half]
                    if ($filled -lt 0) { continue }

                    $bits = $rightBits
                    if ($half -eq 0) { $bits = $leftBits }

                    for ($sub = 0; $sub -lt 4; $sub++) {
                        # Row 0 sub-row 0 is the top of the graph, so measure from
                        # the bottom to decide whether this dot is under the line.
                        $fromBottom = $subHeight - (($row * 4) + $sub)
                        if ($fromBottom -le $filled) { $mask = $mask -bor $bits[$sub] }
                    }
                }

                [void]$line.Append((ConvertTo-Char (0x2800 + $mask)))
            }

            $rows.Add($line.ToString())
        }

        return @($rows)
    }

    # The legacy-console fallback: one block per cell, filled from the bottom.
    function New-BlockGraph {
        param(
            [Parameter(Mandatory)][int[]]$Heights,
            [Parameter(Mandatory)][int]$Width,
            [Parameter(Mandatory)][int]$Height
        )

        $full = Get-Glyph 'BarFull'
        $rows = [System.Collections.Generic.List[string]]::new()

        for ($row = 0; $row -lt $Height; $row++) {
            $line = New-Object Text.StringBuilder
            for ($col = 0; $col -lt $Width; $col++) {
                $fromBottom = $Height - $row
                if ($col -lt $Heights.Count -and $Heights[$col] -ge $fromBottom) { [void]$line.Append($full) }
                else { [void]$line.Append(' ') }
            }
            $rows.Add($line.ToString())
        }

        return @($rows)
    }

    # A history graph one line tall, oldest sample on the left. Scaled against
    # $Maximum rather than the data's own peak, so the shape means the same thing
    # from one frame to the next.
    function New-Sparkline {
        param(
            [AllowEmptyCollection()][double[]]$Values = @(),
            [int]$Width = 40,
            [double]$Maximum = 100
        )

        if ($Width -lt 1) { return '' }

        $ramp = @(Get-Glyph 'Spark')
        if ($ramp.Count -eq 0) { return '' }
        if ($Maximum -le 0) { $Maximum = 1 }

        # Right-aligned: the newest sample sits against the right edge and older
        # ones scroll off the left, so a partly filled history pads rather than
        # stretching a handful of samples across the whole width.
        $recent = @($Values)
        if ($recent.Count -gt $Width) { $recent = @($recent[($recent.Count - $Width)..($recent.Count - 1)]) }

        $cells = New-Object Text.StringBuilder
        [void]$cells.Append(' ' * [Math]::Max(0, $Width - $recent.Count))

        foreach ($value in $recent) {
            $fraction = [Math]::Max(0.0, [Math]::Min(1.0, $value / $Maximum))
            $level = [int][Math]::Round($fraction * ($ramp.Count - 1))
            if ($level -lt 0) { $level = 0 }
            if ($level -gt ($ramp.Count - 1)) { $level = $ramp.Count - 1 }
            [void]$cells.Append($ramp[$level])
        }

        return $cells.ToString()
    }

    # -----------------------------------------------------------------------------
    # Sampling
    # -----------------------------------------------------------------------------

    function Get-CpuRawSample {
        $sample = @{}
        foreach ($row in @(Get-CimInstance -Query $TaskCpuQuery -ErrorAction Stop)) {
            $sample[[string]$row.Name] = [pscustomobject]@{
                Idle  = [double]$row.PercentIdleTime
                Stamp = [double]$row.Timestamp_Sys100NS
            }
        }
        return $sample
    }

    # PercentIdleTime is a PERF_100NSEC_TIMER_INV counter: cumulative idle time in
    # 100ns ticks. Busy is its complement over the same span.
    #
    # The _Total instance is the *average* across cores, not the sum - so every
    # instance divides by the same timestamp delta. Verified against the formatted
    # counter: with this divisor _Total matches the mean of the per-core values to
    # the digit, and with a cores multiplier it does not.
    function Get-CpuLoad {
        param([Parameter(Mandatory)][AllowNull()]$Previous, [Parameter(Mandatory)]$Current)

        $total = 0.0
        $cores = [System.Collections.Generic.List[double]]::new()

        if ($null -eq $Previous) {
            return [pscustomobject]@{ Total = 0.0; Cores = @(); Ready = $false }
        }

        # '_Total' sorts before the digits, so pull the core names out and sort them
        # numerically - otherwise core 10 lands between core 1 and core 2.
        $coreNames = @($Current.Keys | Where-Object { $_ -ne '_Total' } | Sort-Object { [int]$_ })

        foreach ($name in (@('_Total') + $coreNames)) {
            if (-not $Current.ContainsKey($name) -or -not $Previous.ContainsKey($name)) { continue }

            $timeDelta = $Current[$name].Stamp - $Previous[$name].Stamp
            if ($timeDelta -le 0) { continue }

            $idleDelta = $Current[$name].Idle - $Previous[$name].Idle
            $busy = 100.0 - (100.0 * $idleDelta / $timeDelta)
            $busy = [Math]::Max(0.0, [Math]::Min(100.0, $busy))

            if ($name -eq '_Total') { $total = $busy } else { $cores.Add($busy) }
        }

        return [pscustomobject]@{ Total = $total; Cores = @($cores); Ready = $true }
    }

    function Get-MemorySample {
        $os = Get-CimInstance -Query $TaskMemQuery -ErrorAction Stop

        # Both are reported in kilobytes.
        $total = [double]$os.TotalVisibleMemorySize * 1024
        $free  = [double]$os.FreePhysicalMemory * 1024
        $used  = [Math]::Max(0.0, $total - $free)

        # Virtual here is physical plus the page file, so used virtual is the commit
        # charge. Windows has no swap partition to report, and commit is the number
        # that actually tells you whether the machine is in trouble.
        $commitTotal = [double]$os.TotalVirtualMemorySize * 1024
        $commitFree  = [double]$os.FreeVirtualMemory * 1024
        $commitUsed  = [Math]::Max(0.0, $commitTotal - $commitFree)

        $boot = $null
        try { $boot = [DateTime]$os.LastBootUpTime } catch { }

        [pscustomobject]@{
            Total          = $total
            Used           = $used
            Free           = $free
            Percent        = if ($total -gt 0) { 100.0 * $used / $total } else { 0.0 }
            CommitTotal    = $commitTotal
            CommitUsed     = $commitUsed
            CommitPercent  = if ($commitTotal -gt 0) { 100.0 * $commitUsed / $commitTotal } else { 0.0 }
            BootTime       = $boot
        }
    }

    function Format-Uptime {
        param([AllowNull()]$BootTime)

        if ($null -eq $BootTime) { return 'unknown' }

        $span = [DateTime]::Now - [DateTime]$BootTime
        if ($span.TotalSeconds -lt 0) { return 'unknown' }

        if ($span.Days -gt 0) { return ('{0}d {1}h' -f $span.Days, $span.Hours) }
        if ($span.Hours -gt 0) { return ('{0}h {1}m' -f $span.Hours, $span.Minutes) }
        return ('{0}m' -f $span.Minutes)
    }

    function Get-DiskSample {
        $disks = [System.Collections.Generic.List[object]]::new()

        foreach ($row in @(Get-CimInstance -Query $TaskDiskQuery -ErrorAction Stop)) {
            $size = [double]$row.Size
            if ($size -le 0) { continue }

            $free = [double]$row.FreeSpace
            $used = [Math]::Max(0.0, $size - $free)

            $disks.Add([pscustomobject]@{
                Name    = [string]$row.DeviceID
                Label   = [string]$row.VolumeName
                Total   = $size
                Used    = $used
                Free    = $free
                Percent = 100.0 * $used / $size
            })
        }

        return @($disks)
    }

    function Get-NetRawSample {
        $sample = @{}
        foreach ($row in @(Get-CimInstance -Query $TaskNetQuery -ErrorAction Stop)) {
            $sample[[string]$row.Name] = [pscustomobject]@{
                Received = [double]$row.BytesReceivedPersec
                Sent     = [double]$row.BytesSentPersec
                Stamp    = [double]$row.Timestamp_Sys100NS
                Frequency = [double]$row.Frequency_Sys100NS
            }
        }
        return $sample
    }

    # Despite the property names, the raw class reports cumulative byte totals, not
    # rates - so the per-second figure is ours to work out. Summed across every
    # interface, because a machine with Wi-Fi, Ethernet and a VPN adapter has three
    # and the interesting number is the total.
    function Get-NetworkLoad {
        param([Parameter(Mandatory)][AllowNull()]$Previous, [Parameter(Mandatory)]$Current)

        if ($null -eq $Previous) {
            return [pscustomobject]@{ Received = 0.0; Sent = 0.0; Ready = $false }
        }

        $received = 0.0
        $sent = 0.0

        foreach ($name in $Current.Keys) {
            if (-not $Previous.ContainsKey($name)) { continue }

            $frequency = $Current[$name].Frequency
            if ($frequency -le 0) { continue }

            $seconds = ($Current[$name].Stamp - $Previous[$name].Stamp) / $frequency
            if ($seconds -le 0) { continue }

            # A counter that went backwards means the adapter was reset; skip it
            # rather than reporting a negative rate.
            $deltaIn  = $Current[$name].Received - $Previous[$name].Received
            $deltaOut = $Current[$name].Sent - $Previous[$name].Sent
            if ($deltaIn -ge 0)  { $received += $deltaIn / $seconds }
            if ($deltaOut -ge 0) { $sent += $deltaOut / $seconds }
        }

        return [pscustomobject]@{ Received = $received; Sent = $sent; Ready = $true }
    }

    # Get-Process rather than Win32_PerfRawData_PerfProc_Process: it is cheaper
    # (29ms against 31ms), and its names are the real ones. The perf class
    # disambiguates same-named processes with a '#1' suffix and reports the _Total
    # pseudo-instance under pid 0, both of which would have to be undone.
    function Get-ProcessRawSample {
        $sample = @{}

        foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
            # Reading these can throw on a process this session cannot open, which
            # happens for protected processes when we are not elevated. A null CPU
            # time shows as '-' rather than a wrong number.
            $cpuSeconds = $null
            try { $cpuSeconds = [double]$proc.TotalProcessorTime.TotalSeconds } catch { }

            $threads = 0
            try { $threads = @($proc.Threads).Count } catch { }

            $sample[[int]$proc.Id] = [pscustomobject]@{
                Id         = [int]$proc.Id
                Name       = [string]$proc.ProcessName
                WorkingSet = [double]$proc.WorkingSet64
                Threads    = $threads
                CpuSeconds = $cpuSeconds
            }
        }

        return $sample
    }

    # CPU share of one process over the elapsed window: its own CPU seconds divided
    # by the wall seconds available across every core. A process pegging two cores
    # of an eight-core machine reads 25%, which is what Task Manager shows.
    function Get-ProcessLoad {
        param(
            [Parameter(Mandatory)][AllowNull()]$Previous,
            [Parameter(Mandatory)]$Current,
            [Parameter(Mandatory)][double]$ElapsedSeconds,
            [Parameter(Mandatory)][int]$Cores
        )

        $available = $ElapsedSeconds * [Math]::Max(1, $Cores)
        $rows = [System.Collections.Generic.List[object]]::new()

        foreach ($id in $Current.Keys) {
            $entry = $Current[$id]

            $percent = 0.0
            $known = $false

            if ($null -ne $Previous -and $Previous.ContainsKey($id) -and
                $null -ne $entry.CpuSeconds -and $null -ne $Previous[$id].CpuSeconds -and $available -gt 0) {

                $delta = $entry.CpuSeconds - $Previous[$id].CpuSeconds
                if ($delta -ge 0) {
                    $percent = [Math]::Max(0.0, [Math]::Min(100.0, 100.0 * $delta / $available))
                    $known = $true
                }
            }

            $rows.Add([pscustomobject]@{
                Id         = $entry.Id
                Name       = $entry.Name
                Cpu        = $percent
                CpuKnown   = $known
                WorkingSet = $entry.WorkingSet
                Threads    = $entry.Threads
                CpuSeconds = $entry.CpuSeconds
            })
        }

        return @($rows)
    }

    function Sort-TaskProcess {
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes,
            [string]$Key = 'cpu'
        )

        switch ($Key) {
            'mem'  { return @($Processes | Sort-Object -Property WorkingSet -Descending) }
            'pid'  { return @($Processes | Sort-Object -Property Id) }
            'name' { return @($Processes | Sort-Object -Property Name, Id) }
            # Working set breaks CPU ties, so the list does not reshuffle every
            # frame while everything sits at 0%.
            default { return @($Processes | Sort-Object -Property Cpu, WorkingSet -Descending) }
        }
    }

    function Select-TaskProcess {
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes,
            [AllowEmptyString()][string]$Filter = ''
        )

        if ([string]::IsNullOrWhiteSpace($Filter)) { return @($Processes) }

        $needle = $Filter.Trim()
        return @($Processes | Where-Object {
            $_.Name -like "*$needle*" -or [string]$_.Id -like "*$needle*"
        })
    }

    # -----------------------------------------------------------------------------
    # The monitor: one object holding the previous sample and the history rings
    # -----------------------------------------------------------------------------

    function New-TaskMonitor {
        param([int]$HistoryLength = 120)

        [pscustomobject]@{
            Cores         = [Math]::Max(1, [Environment]::ProcessorCount)
            HistoryLength = $HistoryLength

            # Previous raw samples, kept so the next refresh has a delta to work on.
            PreviousCpu   = $null
            PreviousNet   = $null
            PreviousProc  = $null
            PreviousStamp = $null

            Cpu           = [pscustomobject]@{ Total = 0.0; Cores = @(); Ready = $false }
            Memory        = $null
            Disks         = @()
            Network       = [pscustomobject]@{ Received = 0.0; Sent = 0.0; Ready = $false }
            Processes     = @()

            CpuHistory    = [System.Collections.Generic.List[double]]::new()
            MemHistory    = [System.Collections.Generic.List[double]]::new()
            RxHistory     = [System.Collections.Generic.List[double]]::new()
            TxHistory     = [System.Collections.Generic.List[double]]::new()

            SortKey       = 'cpu'
            Filter        = ''

            # Set once the second sample lands: until then there is no delta, so
            # every rate is 0 and saying so beats drawing a flat line as fact.
            Ready         = $false
            Errors        = @()
        }
    }

    function Add-TaskHistory {
        param([Parameter(Mandatory)]$History, [double]$Value, [int]$Limit)

        $History.Add($Value)
        while ($History.Count -gt $Limit) { $History.RemoveAt(0) }
    }

    # One refresh, in place. Each source is guarded on its own: a machine where the
    # network counters are missing still gets CPU, memory, disks and processes,
    # with the failure named in $Monitor.Errors rather than thrown.
    function Update-TaskMonitor {
        param([Parameter(Mandatory)]$Monitor)

        $now = [DateTime]::UtcNow
        $elapsed = 0.0
        if ($null -ne $Monitor.PreviousStamp) { $elapsed = ($now - $Monitor.PreviousStamp).TotalSeconds }

        $errors = [System.Collections.Generic.List[string]]::new()

        # ---- CPU ---------------------------------------------------------------
        try {
            $cpuRaw = Get-CpuRawSample
            $Monitor.Cpu = Get-CpuLoad -Previous $Monitor.PreviousCpu -Current $cpuRaw
            $Monitor.PreviousCpu = $cpuRaw

            if ($Monitor.Cpu.Ready) {
                Add-TaskHistory -History $Monitor.CpuHistory -Value $Monitor.Cpu.Total -Limit $Monitor.HistoryLength
            }
        }
        catch { $errors.Add("CPU counters unavailable: $($_.Exception.Message)") }

        # ---- memory ------------------------------------------------------------
        try {
            $Monitor.Memory = Get-MemorySample
            Add-TaskHistory -History $Monitor.MemHistory -Value $Monitor.Memory.Percent -Limit $Monitor.HistoryLength
        }
        catch { $errors.Add("Memory counters unavailable: $($_.Exception.Message)") }

        # ---- disks -------------------------------------------------------------
        try { $Monitor.Disks = @(Get-DiskSample) }
        catch { $errors.Add("Disk list unavailable: $($_.Exception.Message)") }

        # ---- network -----------------------------------------------------------
        try {
            $netRaw = Get-NetRawSample
            $Monitor.Network = Get-NetworkLoad -Previous $Monitor.PreviousNet -Current $netRaw
            $Monitor.PreviousNet = $netRaw

            if ($Monitor.Network.Ready) {
                Add-TaskHistory -History $Monitor.RxHistory -Value $Monitor.Network.Received -Limit $Monitor.HistoryLength
                Add-TaskHistory -History $Monitor.TxHistory -Value $Monitor.Network.Sent -Limit $Monitor.HistoryLength
            }
        }
        catch { $errors.Add("Network counters unavailable: $($_.Exception.Message)") }

        # ---- processes ---------------------------------------------------------
        try {
            $procRaw = Get-ProcessRawSample
            $rows = @(Get-ProcessLoad -Previous $Monitor.PreviousProc -Current $procRaw `
                -ElapsedSeconds $elapsed -Cores $Monitor.Cores)
            $Monitor.PreviousProc = $procRaw
            $Monitor.Processes = @(Sort-TaskProcess -Processes $rows -Key $Monitor.SortKey)
        }
        catch { $errors.Add("Process list unavailable: $($_.Exception.Message)") }

        $Monitor.Errors = @($errors)
        $Monitor.PreviousStamp = $now
        if ($elapsed -gt 0) { $Monitor.Ready = $true }

        return $Monitor
    }

    # The peak of a history ring, for scaling a graph that has no natural ceiling.
    # Network has no equivalent of "100%", so the graph scales to the busiest
    # moment still on screen, with a floor so an idle link is not all spikes.
    function Get-HistoryScale {
        param([Parameter(Mandatory)]$History, [double]$Minimum = 1)

        $peak = $Minimum
        foreach ($value in $History) { if ($value -gt $peak) { $peak = $value } }
        return $peak
    }

    # -----------------------------------------------------------------------------
    # Killing
    # -----------------------------------------------------------------------------

    # Windows marks a handful of processes critical: ending one bugchecks the
    # machine with CRITICAL_PROCESS_DIED rather than closing a program. The monitor
    # refuses those outright instead of asking, because there is no answer to that
    # prompt that leaves the machine running.
    function Test-CriticalProcess {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

        $critical = @(
            'system', 'idle', 'registry', 'memory compression', 'secure system',
            'csrss', 'smss', 'wininit', 'winlogon', 'services', 'lsass'
        )
        return ($critical -contains $Name.ToLowerInvariant())
    }

    function Stop-TaskProcess {
        param(
            [Parameter(Mandatory)][int]$Id,
            [Parameter(Mandatory)][AllowEmptyString()][string]$Name
        )

        if (Test-CriticalProcess -Name $Name) {
            Write-Err "$Name is a critical Windows process - ending it bugchecks the machine. Refusing."
            return $false
        }

        if ($Ctx.DryRun) {
            Write-Info "would kill $Name (pid $Id)"
            return $false
        }

        # No -DefaultYes: an accidental Enter should not end a process.
        if (-not (Confirm-Action "Kill $Name (pid $Id)? Unsaved work in it is lost.")) {
            Write-Warn "$Name (pid $Id) - left running."
            return $false
        }

        try {
            Stop-Process -Id $Id -Force -ErrorAction Stop
            Write-Ok "$Name (pid $Id) ended."
            Write-Log "killed process $Name ($Id)"
            return $true
        }
        catch {
            Write-Err "Could not end $Name (pid $Id): $($_.Exception.Message)"
            return $false
        }
    }

# ===== src/54-Packages.ps1 =============================================

    # =============================================================================
    # Package managers: detect them, and run their own installers.
    #
    # The interesting thing here is that the two installable ones need *opposite*
    # privileges, and both enforce it:
    #
    #   Chocolatey installs machine-wide to %PROGRAMDATA%\chocolatey, so it needs
    #   administrator.
    #
    #   Scoop installs per-user to ~\scoop and its installer *refuses* to run
    #   elevated - "Running the installer as administrator is disabled by default"
    #   - unless passed -RunAsAdmin, which changes it to a machine-wide install.
    #
    # Moscovium's window is always elevated and the CLI elevates for anything that
    # changes the machine, so Scoop cannot simply be run inline from either. What
    # happens instead is in Invoke-PackageManagerInstall.
    #
    # The install commands are stored verbatim from each project's own install page
    # rather than rebuilt from parts. Someone else's installer invocation is not
    # ours to improve, and printing the exact line a user would paste is the whole
    # point of showing it.
    # =============================================================================

    function Get-PackageManagers {
        @(
            [pscustomobject]@{
                Id = 'winget'
                Name = 'winget'
                Site = 'https://learn.microsoft.com/windows/package-manager/'
                Summary = 'Ships with Windows. Moscovium installs its whole app catalog through this one.'
                # Neither requires nor refuses elevation.
                Elevation = 'either'
                # Not ours to install: it arrives with App Installer from the
                # Microsoft Store, and scripting that around the Store is exactly
                # the kind of thing that breaks on the next Windows build.
                InstallCommand = ''
                GlobalCommand = ''
                InstallNote = 'Part of App Installer. Get it from the Microsoft Store if it is missing.'
            }
            [pscustomobject]@{
                Id = 'choco'
                Name = 'Chocolatey'
                Site = 'https://chocolatey.org/install'
                Summary = 'Machine-wide, in C:\ProgramData\chocolatey. The largest Windows package repository.'
                Elevation = 'admin'
                InstallCommand = 'Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString(''https://community.chocolatey.org/install.ps1''))'
                GlobalCommand = ''
                InstallNote = 'Needs administrator, and always installs machine-wide.'
            }
            [pscustomobject]@{
                Id = 'scoop'
                Name = 'Scoop'
                Site = 'https://scoop.sh'
                Summary = 'Per-user, in ~\scoop. No UAC prompts, and nothing lands on the PATH you did not ask for.'
                Elevation = 'user'
                InstallCommand = 'irm get.scoop.sh | iex'
                # The documented escape hatch for a machine-wide Scoop. Its own
                # docs call this the admin case, not the normal one.
                GlobalCommand = '& ([scriptblock]::Create((irm get.scoop.sh))) -RunAsAdmin'
                InstallNote = 'Its installer refuses to run elevated unless you ask for a machine-wide install.'
            }
        )
    }

    function Resolve-PackageManager {
        param([Parameter(Mandatory)][string]$Id)

        $managers = Get-PackageManagers

        $exact = @($managers | Where-Object { $_.Id -eq $Id })
        if ($exact.Count -eq 1) { return $exact[0] }

        $fuzzy = @($managers | Where-Object {
            (Test-NameMatch -Value $_.Id -Pattern $Id) -or (Test-NameMatch -Value $_.Name -Pattern $Id)
        })
        if ($fuzzy.Count -eq 1) { return $fuzzy[0] }

        if ($fuzzy.Count -gt 1) {
            Write-Err "'$Id' is ambiguous. Did you mean one of these?"
            foreach ($manager in $fuzzy) { Write-Info $manager.Id }
            return $null
        }

        Write-Err "Unknown package manager '$Id'. Known: $((Get-PackageManagers | ForEach-Object { $_.Id }) -join ', ')."
        return $null
    }

    # Where each manager lands, checked on disk as well as on the PATH.
    #
    # The PATH alone is not enough: a manager installed a minute ago by a child
    # process is on the *new* PATH, not this process's copy of it, so a fresh
    # install would keep reporting itself missing until Moscovium was restarted.
    function Get-PackageManagerStatus {
        param([Parameter(Mandatory)]$Manager)

        $command = $null
        $path = $null

        switch ($Manager.Id) {
            'winget' {
                $command = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
            }
            'choco' {
                $command = Get-Command -Name 'choco.exe' -ErrorAction SilentlyContinue
                if (-not $command) {
                    $root = $env:ChocolateyInstall
                    if ([string]::IsNullOrWhiteSpace($root)) { $root = Join-Path $env:ProgramData 'chocolatey' }
                    $candidate = Join-Path $root 'bin\choco.exe'
                    if (Test-Path -LiteralPath $candidate) { $path = $candidate }
                }
            }
            'scoop' {
                # Scoop is a PowerShell shim, so Get-Command has to look for the
                # command name rather than an .exe.
                $command = Get-Command -Name 'scoop' -ErrorAction SilentlyContinue
                if (-not $command) {
                    $root = $env:SCOOP
                    if ([string]::IsNullOrWhiteSpace($root)) { $root = Join-Path $env:USERPROFILE 'scoop' }
                    $candidate = Join-Path $root 'shims\scoop.ps1'
                    if (Test-Path -LiteralPath $candidate) { $path = $candidate }
                }
            }
        }

        if ($command) {
            $path = $command.Source
            if ([string]::IsNullOrWhiteSpace($path)) { $path = $command.Name }
        }

        [pscustomobject]@{
            Id        = $Manager.Id
            Installed = [bool]$path
            Path      = $path
            # True when it is on disk but not on this process's PATH - which means
            # it works in a new terminal and not in this one.
            OnPath    = [bool]$command
        }
    }

    function Get-PackageManagerReport {
        $report = [System.Collections.Generic.List[object]]::new()

        foreach ($manager in Get-PackageManagers) {
            $status = Get-PackageManagerStatus -Manager $manager
            $report.Add([pscustomobject]@{
                Manager   = $manager
                Installed = $status.Installed
                Path      = $status.Path
                OnPath    = $status.OnPath
            })
        }

        return @($report)
    }

    # Runs one manager's own installer, in a separate PowerShell process, after
    # printing the exact command.
    #
    # Separate process for the same three reasons the toolbox scripts get one: this
    # bundle runs under Set-StrictMode and $ErrorActionPreference = 'Stop' and child
    # scopes inherit both, neither installer is written to survive that, and both
    # want their own console. It is also the only way to get the elevation right,
    # since the two need opposite privileges.
    function Invoke-PackageManagerInstall {
        param(
            [Parameter(Mandatory)][string]$Id,
            # Scoop's documented machine-wide install. Ignored by anything else.
            [switch]$Global
        )

        $manager = Resolve-PackageManager -Id $Id
        if (-not $manager) { return $false }

        $status = Get-PackageManagerStatus -Manager $manager
        if ($status.Installed) {
            Write-Ok "$($manager.Name) is already installed - $($status.Path)"
            if (-not $status.OnPath) {
                Write-Info 'It is not on this session PATH yet. Open a new terminal to use it.'
            }
            return $true
        }

        if ([string]::IsNullOrWhiteSpace($manager.InstallCommand)) {
            Write-Warn "$($manager.Name) is not something Moscovium installs."
            Write-Info $manager.InstallNote
            Write-Line "      $($manager.Site)" -Color White
            return $false
        }

        $command = $manager.InstallCommand
        $elevated = ($manager.Elevation -eq 'admin')

        # Scoop's installer refuses to run elevated. Moscovium's window is always
        # elevated, and so is the CLI once it has relaunched itself for a mutating
        # action, so the per-user install genuinely cannot be launched from here -
        # a child process inherits the elevation and there is no reliable way to
        # drop it. Offer the machine-wide install its own docs describe, and hand
        # over the command for a normal window if that is not what was wanted.
        if ($manager.Elevation -eq 'user' -and $Ctx.IsAdmin -and -not $Global) {
            Write-Line ''
            Write-Warn "$($manager.Name) will not install per-user from an elevated window - its own installer blocks it."
            Write-Info 'To install it per-user, run this in a normal, non-elevated PowerShell:'
            Write-Line "      $($manager.InstallCommand)" -Color White
            Write-Line ''

            if ([string]::IsNullOrWhiteSpace($manager.GlobalCommand)) { return $false }

            Write-Info 'Or install it machine-wide from here instead, which is what its docs call the admin case.'
            if (-not (Confirm-Action "Install $($manager.Name) machine-wide instead?")) {
                Write-Warn "$($manager.Name) - skipped."
                return $false
            }

            $command = $manager.GlobalCommand
        }
        elseif ($Global -and -not [string]::IsNullOrWhiteSpace($manager.GlobalCommand)) {
            $command = $manager.GlobalCommand
            $elevated = $true
        }

        if ($Ctx.DryRun) {
            Write-Status -Glyph (Get-Glyph 'Info') -Color (Get-Color 'Warn') -Message $manager.Name -MessageColor (Get-Color 'Warn')
            Write-Info "would run: $command"
            return $false
        }

        $needsElevation = $elevated -and -not $Ctx.IsAdmin

        Write-Line ''
        Write-Warn "$($manager.Name) is installed by a script published by its own project:"
        Write-Line "      $($manager.Site)" -Color White
        Write-Info 'Moscovium does not review or pin the contents of that script.'
        Write-Line ''
        Write-Info 'Runs in a new window as:'
        Write-Line "      $command" -Color Gray

        if ($needsElevation) { Write-Info 'It will ask for administrator rights.' }
        elseif ($manager.Elevation -eq 'user') { Write-Info 'It runs as you, not elevated.' }

        if (-not (Confirm-Action "Install $($manager.Name) now?" -DefaultYes)) {
            Write-Warn "$($manager.Name) - skipped."
            return $false
        }

        # Held open on a terminating error only: a successful install prints its own
        # summary and a flashed-past failure is the one thing worth stopping for.
        $handler = "Write-Host ''; " +
                   "Write-Host ('Moscovium: the installer stopped with an error.') -ForegroundColor Red; " +
                   "Write-Host (`$_.Exception.Message) -ForegroundColor Red; " +
                   "Write-Host ''; " +
                   "Read-Host 'Press Enter to close this window'"

        $wrapped = "try { $command } catch { $handler }"

        $start = @{
            FilePath     = Get-PowerShellHost
            ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $wrapped)
            Wait         = $true
            PassThru     = $true
            ErrorAction  = 'Stop'
        }
        if ($needsElevation) { $start.Verb = 'RunAs' }

        Write-Step "Installing $($manager.Name) - this returns when the installer finishes"
        Write-Log "package manager install: $wrapped"

        try {
            $process = Start-Process @start
        }
        catch {
            Write-Err "Could not start the $($manager.Name) installer: $($_.Exception.Message)"
            return $false
        }

        if ($process -and $process.ExitCode -ne 0) {
            Write-Warn "The $($manager.Name) installer exited with code $($process.ExitCode)."
            return $false
        }

        # Re-check on disk rather than trusting the exit code: this process's PATH
        # is a copy taken at startup and will not have grown a new entry.
        $after = Get-PackageManagerStatus -Manager $manager
        if ($after.Installed) {
            Write-Ok "$($manager.Name) installed - $($after.Path)"
            Write-Info 'Open a new terminal before using it: this session PATH was set before it existed.'
            return $true
        }

        Write-Warn "The $($manager.Name) installer finished, but it is still not on disk where it was expected."
        return $false
    }

    function Show-PackageManagerCatalog {
        Write-SectionHeading 'Package managers'

        foreach ($entry in @(Get-PackageManagerReport)) {
            $manager = $entry.Manager

            $mark = Get-Glyph 'Unchecked'
            $color = Get-Color 'Muted'
            $state = 'not installed'

            if ($entry.Installed) {
                $mark = Get-Glyph 'Ok'
                $color = Get-Color 'Ok'
                $state = 'installed'
                if (-not $entry.OnPath) { $state = 'installed, needs a new terminal' }
            }

            # Padded: the ASCII glyph set spells these '[ ]' and '+', so an
            # unpadded mark puts every column after it out of line.
            Write-Line '  ' -NoNewline
            Write-Line $mark.PadRight(4) -Color $color -NoNewline
            Write-Line $manager.Id.PadRight(10) -Color White -NoNewline
            Write-Line $manager.Name.PadRight(14) -Color Gray -NoNewline
            Write-Line $state -Color $color

            Write-Info $manager.Summary
            if ($entry.Installed) { Write-Info $entry.Path }
            else { Write-Info $manager.InstallNote }
        }

        Write-Line ''
        Write-Info 'Install one with:  -InstallManager <id>'
    }

# ===== src/56-Customize.ps1 ============================================

    # =============================================================================
    # Customization: the desktop app's Customization page - shell replacements.
    #
    # The desktop app ships four vendor installers as bundled binaries and launches
    # them. A single script cannot carry binaries, so this fetches each one from its
    # vendor's *current* channel instead, then hands it to the same Install-App path
    # the app catalog uses - which is where dry-run, counters and error handling
    # already live.
    #
    # Vendor channel, not winget, and that was measured rather than assumed. All
    # four have winget packages, but ExplorerPatcher's was 22631.5335.68.2 when
    # GitHub's latest was 26100.8457.70.3 - and ExplorerPatcher is tied to the
    # Windows build (22631 is 23H2, 26100 is 24H2). Installing the stale one on a
    # 24H2 machine is exactly the failure ExplorerPatcher is notorious for. Using
    # what each vendor currently publishes is also what the desktop app does; it
    # just bundles the file instead of fetching it.
    #
    # Not ported: the StartAllBack trial reset, for the same reason MAS is not in
    # the catalog - it exists to circumvent licensing. Installing StartAllBack is
    # here; its licence terms are its own business after that.
    # =============================================================================

    function Get-CustomizationTools {
        # ARM64 gets the ARM build where the vendor publishes one; everything else
        # is x64, which is what the desktop app bundles.
        $arm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') -or ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64')

        $epAsset = '^ep_setup\.exe$'
        if ($arm) { $epAsset = '^ep_setup_arm64\.exe$' }

        $shellMsi = 'setup-x64\.msi'
        if ($arm) { $shellMsi = 'setup-arm64\.msi' }

        @(
            [pscustomobject]@{
                Id = 'openshell'
                Name = 'Open-Shell'
                Site = 'https://open-shell.github.io/Open-Shell-Menu/'
                Summary = 'Classic start menu for Windows 10 and 11.'
                # How the current installer URL is found. 'github' asks the API for
                # the latest release; 'page' scrapes a download page; 'redirect'
                # follows the vendor's stable link to wherever it points today.
                Source = 'github'
                Repo = 'Open-Shell/Open-Shell-Menu'
                AssetPattern = '^OpenShellSetup_.*\.exe$'
                PageUrl = ''
                LinkPattern = ''
                BaseUrl = ''
                RedirectUrl = ''
                # Installed-detection: an uninstall entry with this DisplayName, or
                # any of these files.
                DisplayName = 'Open-Shell'
                Paths = @((Join-Path $env:ProgramFiles 'Open-Shell\StartMenu.exe'))
                Note = ''
            }
            [pscustomobject]@{
                Id = 'nilesoft'
                Name = 'Nilesoft Shell'
                Site = 'https://nilesoft.org'
                Summary = 'Context menu customiser and shell extension - rebuild the right-click menu.'
                # GitHub releases carry no assets; nilesoft.org is the channel, and
                # its download page links the current version.
                Source = 'page'
                Repo = ''
                AssetPattern = ''
                PageUrl = 'https://nilesoft.org/download'
                LinkPattern = 'href="(/download/shell/[^"]+/' + $shellMsi + ')"'
                BaseUrl = 'https://nilesoft.org'
                RedirectUrl = ''
                DisplayName = 'Nilesoft Shell'
                Paths = @((Join-Path $env:ProgramFiles 'Nilesoft Shell\shell.exe'))
                Note = ''
            }
            [pscustomobject]@{
                Id = 'startallback'
                Name = 'StartAllBack'
                Site = 'https://www.startallback.com'
                Summary = 'Windows 11 taskbar and start menu fixes. Paid, with a 100-day trial.'
                # download.php is the vendor's stable link; it redirects to the
                # versioned setup on their CDN.
                Source = 'redirect'
                Repo = ''
                AssetPattern = ''
                PageUrl = ''
                LinkPattern = ''
                BaseUrl = ''
                RedirectUrl = 'https://www.startallback.com/download.php'
                DisplayName = 'StartAllBack'
                Paths = @((Join-Path $env:ProgramFiles 'StartAllBack\StartAllBackCfg.exe'))
                Note = 'The trial reset from the desktop app is not included - it circumvents licensing.'
            }
            [pscustomobject]@{
                Id = 'explorerpatcher'
                Name = 'ExplorerPatcher'
                Site = 'https://github.com/valinet/ExplorerPatcher'
                Summary = 'Taskbar and system tray tweaks. Tied to your Windows build - always the latest release.'
                Source = 'github'
                Repo = 'valinet/ExplorerPatcher'
                AssetPattern = $epAsset
                PageUrl = ''
                LinkPattern = ''
                BaseUrl = ''
                RedirectUrl = ''
                DisplayName = 'ExplorerPatcher'
                Paths = @((Join-Path $env:ProgramFiles 'ExplorerPatcher\ep_gui.dll'))
                Note = ''
            }
        )
    }

    function Resolve-CustomizationTool {
        param([Parameter(Mandatory)][string]$Id)

        $tools = Get-CustomizationTools

        $exact = @($tools | Where-Object { $_.Id -eq $Id })
        if ($exact.Count -eq 1) { return $exact[0] }

        $fuzzy = @($tools | Where-Object {
            (Test-NameMatch -Value $_.Id -Pattern $Id) -or (Test-NameMatch -Value $_.Name -Pattern $Id)
        })
        if ($fuzzy.Count -eq 1) { return $fuzzy[0] }

        if ($fuzzy.Count -gt 1) {
            Write-Err "'$Id' is ambiguous. Did you mean one of these?"
            foreach ($tool in $fuzzy) { Write-Info $tool.Id }
            return $null
        }

        Write-Err "Unknown customization tool '$Id'. Known: $((Get-CustomizationTools | ForEach-Object { $_.Id }) -join ', ')."
        return $null
    }

    # -----------------------------------------------------------------------------
    # Finding the current installer
    # -----------------------------------------------------------------------------

    # Follows a vendor's stable link to the file it points at today, so the download
    # gets the real file name (StartAllBack_3.9.25_setup.exe) rather than
    # 'download.php'. HEAD, so nothing is downloaded twice.
    function Resolve-RedirectUrl {
        param([Parameter(Mandatory)][string]$Url)

        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

        $request = [Net.HttpWebRequest]::Create($Url)
        $request.Method = 'HEAD'
        $request.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Moscovium-CLI'
        $request.AllowAutoRedirect = $true
        $request.Timeout = 30000

        $response = $null
        try {
            $response = $request.GetResponse()
            return [string]$response.ResponseUri.AbsoluteUri
        }
        finally {
            if ($response) { $response.Dispose() }
        }
    }

    function Resolve-CustomizationUrl {
        param([Parameter(Mandatory)]$Tool)

        switch ($Tool.Source) {
            'github' {
                $release = Invoke-GitHubApi -Path "/repos/$($Tool.Repo)/releases/latest"
                $asset = @($release.assets | Where-Object { $_.name -match $Tool.AssetPattern }) | Select-Object -First 1
                if (-not $asset) {
                    throw "The latest $($Tool.Name) release ($($release.tag_name)) has no asset matching $($Tool.AssetPattern)."
                }
                return [string]$asset.browser_download_url
            }
            'page' {
                try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
                $response = Invoke-WebRequest -Uri $Tool.PageUrl -UseBasicParsing -TimeoutSec 30 -Headers @{
                    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Moscovium-CLI'
                }
                $match = [regex]::Match($response.Content, $Tool.LinkPattern, 'IgnoreCase')
                if (-not $match.Success) {
                    throw "$($Tool.PageUrl) no longer links an installer where expected."
                }
                $link = $match.Groups[1].Value
                if ($link -match '^https?://') { return $link }
                return ($Tool.BaseUrl.TrimEnd('/') + '/' + $link.TrimStart('/'))
            }
            'redirect' {
                return (Resolve-RedirectUrl -Url $Tool.RedirectUrl)
            }
            default { throw "Tool '$($Tool.Id)' has an unknown source '$($Tool.Source)'." }
        }
    }

    # -----------------------------------------------------------------------------
    # Installed?
    # -----------------------------------------------------------------------------

    # Uninstall entries under both the 64-bit and 32-bit views plus the per-user
    # hive, matched on DisplayName. Read with the provider and checked through
    # PSObject.Properties: under StrictMode, $_.DisplayName on an entry that has no
    # DisplayName throws, and plenty of them do not.
    function Test-InstalledProgram {
        param([Parameter(Mandatory)][string]$DisplayNamePattern)

        $roots = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        )

        foreach ($root in $roots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($entry in @(Get-ItemProperty -Path (Join-Path $root '*') -ErrorAction SilentlyContinue)) {
                $property = $entry.PSObject.Properties['DisplayName']
                if ($null -eq $property) { continue }
                if ([string]$property.Value -like "*$DisplayNamePattern*") { return $true }
            }
        }

        return $false
    }

    function Test-CustomizationInstalled {
        param([Parameter(Mandatory)]$Tool)

        foreach ($path in @($Tool.Paths)) {
            if ($path -and (Test-Path -LiteralPath $path)) { return $true }
        }
        return (Test-InstalledProgram -DisplayNamePattern $Tool.DisplayName)
    }

    function Get-CustomizationReport {
        $report = [System.Collections.Generic.List[object]]::new()
        foreach ($tool in Get-CustomizationTools) {
            $report.Add([pscustomobject]@{
                Tool      = $tool
                Installed = (Test-CustomizationInstalled -Tool $tool)
            })
        }
        return @($report)
    }

    # -----------------------------------------------------------------------------
    # Installing
    # -----------------------------------------------------------------------------

    # Resolves the current installer, shows where it came from, asks, and hands an
    # app-shaped record to Install-App - so this shares the download, progress bar,
    # .exe/.msi launch, exit-code handling and counters with the app catalog rather
    # than growing a second copy of any of it.
    function Install-CustomizationTool {
        param([Parameter(Mandatory)][string]$Id)

        $tool = Resolve-CustomizationTool -Id $Id
        if (-not $tool) { return $false }

        if (Test-CustomizationInstalled -Tool $tool) {
            Write-Ok "$($tool.Name) is already installed."
            return $true
        }

        # No network in a dry run: it says what it would fetch and from where.
        if ($Ctx.DryRun) {
            $from = switch ($tool.Source) {
                'github'   { "the latest release of github.com/$($tool.Repo)" }
                'page'     { $tool.PageUrl }
                'redirect' { $tool.RedirectUrl }
            }
            Write-Status -Glyph (Get-Glyph 'Info') -Color (Get-Color 'Warn') -Message $tool.Name -MessageColor (Get-Color 'Warn')
            Write-Info "would download the installer from $from and run it"
            return $false
        }

        Write-Step "Finding the current $($tool.Name) installer"
        $url = $null
        try { $url = Resolve-CustomizationUrl -Tool $tool }
        catch {
            Write-Err "$($tool.Name) - $($_.Exception.Message)"
            return $false
        }

        Write-Line ''
        Write-Warn "$($tool.Name) is published by its own project; Moscovium does not review or pin it:"
        Write-Line "      $($tool.Site)" -Color White
        Write-Info 'Installer:'
        Write-Line "      $url" -Color Gray
        if ($tool.Note) { Write-Info $tool.Note }

        if (-not (Confirm-Action "Download and run the $($tool.Name) installer?" -DefaultYes)) {
            Write-Warn "$($tool.Name) - skipped."
            return $false
        }

        # Every property Install-App reads has to exist: StrictMode throws on an
        # absent one, and the catalog entries it normally gets carry all of these.
        $app = [pscustomobject]@{
            id             = $tool.Id
            name           = $tool.Name
            downloadUrl    = $url
            resolvePageUrl = $null
            resolvePattern = $null
            zipUrl         = $null
            scriptUrl      = $null
            wingetId       = $null
            source         = $null
        }

        $before = $Ctx.Applied
        Install-App -App $app
        return ($Ctx.Applied -gt $before)
    }

    function Show-CustomizationCatalog {
        Write-SectionHeading 'Customization'

        foreach ($entry in @(Get-CustomizationReport)) {
            $tool = $entry.Tool

            $mark = Get-Glyph 'Unchecked'
            $color = Get-Color 'Muted'
            $state = 'not installed'
            if ($entry.Installed) {
                $mark = Get-Glyph 'Ok'
                $color = Get-Color 'Ok'
                $state = 'installed'
            }

            # Padded: the ASCII glyph set spells these '[ ]' and '+', so an unpadded
            # mark puts every column after it out of line.
            Write-Line '  ' -NoNewline
            Write-Line $mark.PadRight(4) -Color $color -NoNewline
            Write-Line $tool.Id.PadRight(17) -Color White -NoNewline
            Write-Line $tool.Name.PadRight(17) -Color Gray -NoNewline
            Write-Line $state -Color $color

            Write-Info $tool.Summary
            if ($tool.Note) { Write-Info $tool.Note }
        }

        Write-Line ''
        Write-Info 'Install one with:  -Customize <id>'
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
            # A line can be one string in one colour, or a run of segments in
            # different colours - which is what a box with a coloured title, or a
            # meter whose cells shade from green to red, is made of. Segments are
            # written with -NoNewline and the row is padded once at the end, so the
            # result is still exactly one console line.
            if (@($line.Segments).Count -gt 0) {
                $used = 0

                foreach ($segment in @($line.Segments)) {
                    if ($used -ge $width) { break }

                    $text = [string]$segment.Text
                    if (($used + $text.Length) -gt $width) { $text = $text.Substring(0, $width - $used) }
                    if ($text.Length -eq 0) { continue }
                    $used += $text.Length

                    if (-not $Ctx.UseColor) { Write-Host $text -NoNewline; continue }

                    $splat = @{ Object = $text; NoNewline = $true }
                    if ($segment.Color)      { $splat.ForegroundColor = $segment.Color }
                    if ($segment.Background) { $splat.BackgroundColor = $segment.Background }
                    Write-Host @splat
                }

                if ($used -lt $width) { Write-Host (' ' * ($width - $used)) -NoNewline }
                Write-Host ''
                continue
            }

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

    # Segments is always present, even when empty: Set-StrictMode makes reading an
    # absent property throw, and Write-Frame checks it on every line.
    function New-FrameLine {
        param([AllowEmptyString()][string]$Text = '', $Color = $null, $Background = $null)
        [pscustomobject]@{ Text = $Text; Color = $Color; Background = $Background; Segments = @() }
    }

    function New-FrameSegment {
        param([AllowEmptyString()][string]$Text = '', $Color = $null, $Background = $null)
        [pscustomobject]@{ Text = $Text; Color = $Color; Background = $Background }
    }

    # A frame line built from coloured pieces. Text is kept in step with the
    # segments so callers that only want to measure or match a line still can -
    # the tests do, and so does the log pane.
    function New-FrameLineFromSegments {
        param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Segments)

        $text = -join @($Segments | ForEach-Object { [string]$_.Text })
        [pscustomobject]@{ Text = $text; Color = $null; Background = $null; Segments = @($Segments) }
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
            [switch]$SingleSelect,
            # Draw the wordmark instead of the plain title. The main menu is the
            # front page, so it gets the art; sub-menus want to say where you are.
            [switch]$Art
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

            # Recomputed every frame so a resize is picked up. A window too narrow
            # for the art falls back to the plain title rather than wrapping it into
            # nonsense, and the rows it costs come out of the list's viewport so the
            # frame still fits without scrolling.
            $wordmark = @()
            if ($Art -and (Get-ConsoleWidth) -ge ((Get-WordmarkWidth) + 2)) {
                $wordmark = @(Get-WordmarkLines)
            }
            $headerRows = if ($wordmark.Count -gt 0) { $wordmark.Count - 1 } else { 0 }

            $viewport = [Math]::Max(5, (Get-ConsoleHeight) - 10 - $headerRows)
            $view = Get-ScrollWindow -Cursor $cursor -Offset $offset -Count $visible.Count -Viewport $viewport
            $cursor = $view.Cursor
            $offset = $view.Offset

            # Same width as Write-Rule, so the selector lines up with section rules.
            $rule = (Get-Glyph 'HLine') * (Get-RuleWidth)

            $lines = [System.Collections.Generic.List[object]]::new()
            $lines.Add((New-FrameLine))
            if ($wordmark.Count -gt 0) {
                foreach ($line in $wordmark) { $lines.Add((New-FrameLine $line.Text $line.Color)) }
            }
            else {
                $lines.Add((New-FrameLine ('  ' + $Title) (Get-Color 'Accent')))
            }
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
        # Without the one-click box: it is the main menu's first entry instead.
        $actions = Get-ToolboxListActions

        $result = Show-Selector -Items $actions -Title 'Toolbox' -SingleSelect `
            -Subtitle 'One-shot actions and classic control panels' `
            -Label { param($a) $a.Name } `
            -Sublabel { param($a) if ($a.Admin) { 'admin' } else { '' } }

        if (-not $result.Confirmed) { return }

        Write-Banner
        Invoke-ToolboxAction -Id $result.Selected[0].Id
        Wait-ForKey
    }

    function Show-PackageMenu {
        while ($true) {
            # Rebuilt each pass so an install that just finished shows as installed
            # without leaving and coming back.
            $entries = @(Get-PackageManagerReport)

            $result = Show-Selector -Items $entries -Title 'Package managers' -SingleSelect `
                -Subtitle 'Chocolatey, Scoop and winget - install one, or see what is already here' `
                -Label { param($e) $e.Manager.Name } `
                -Sublabel {
                    param($e)
                    if (-not $e.Installed) { return 'not installed' }
                    if (-not $e.OnPath) { return 'installed - needs a new terminal' }
                    return 'installed'
                }

            if (-not $result.Confirmed) { return }

            Write-Banner
            Invoke-PackageManagerInstall -Id $result.Selected[0].Manager.Id | Out-Null
            Wait-ForKey
        }
    }

    function Show-CustomizationMenu {
        while ($true) {
            # Rebuilt each pass so an install that just finished shows as installed
            # without leaving and coming back.
            $entries = @(Get-CustomizationReport)

            $result = Show-Selector -Items $entries -Title 'Customization' -SingleSelect `
                -Subtitle 'Shell replacements, each fetched from its own vendor and installed by its own setup' `
                -Label { param($e) $e.Tool.Name } `
                -Sublabel { param($e) if ($e.Installed) { 'installed' } else { $e.Tool.Summary } }

            if (-not $result.Confirmed) { return }

            Write-Banner
            Install-CustomizationTool -Id $result.Selected[0].Tool.Id | Out-Null
            Wait-ForKey
        }
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
            # First, because it is the thing most people opened this for.
            [pscustomobject]@{ Name = 'One click'; Hint = 'The whole debloat pass - 6 steps, one prompt';         Action = 'oneclick' }
            [pscustomobject]@{ Name = 'Tweaks';   Hint = "$($Ctx.Tweaks.Count) registry tweaks, apply or revert"; Action = 'tweaks' }
            [pscustomobject]@{ Name = 'Apps';     Hint = "$($Ctx.Apps.Count) curated packages";                    Action = 'apps' }
            [pscustomobject]@{ Name = 'Toolbox';  Hint = 'Debloat scripts, network, boot, control panels';         Action = 'toolbox' }
            [pscustomobject]@{ Name = 'Profiles'; Hint = 'Save or run a setup checklist';                          Action = 'profiles' }
            [pscustomobject]@{ Name = 'Packages'; Hint = 'Install Chocolatey or Scoop';                             Action = 'packages' }
            [pscustomobject]@{ Name = 'Customize'; Hint = 'Open-Shell, Nilesoft Shell, StartAllBack, ExplorerPatcher';  Action = 'customize' }
            [pscustomobject]@{ Name = 'Tasks';    Hint = 'Live CPU, memory, disk, network and processes';          Action = 'tasks' }
            [pscustomobject]@{ Name = 'Status';   Hint = 'What is currently applied on this machine';              Action = 'status' }
            [pscustomobject]@{ Name = 'GUI';      Hint = 'Open the same thing as a window';                       Action = 'gui' }
            [pscustomobject]@{ Name = 'Quit';     Hint = '';                                                       Action = 'quit' }
        )

        while ($true) {
            $admin = if ($Ctx.IsAdmin) { 'elevated' } else { 'not elevated - HKLM tweaks will be skipped' }
            $subtitle = "Moscovium CLI v$($Ctx.Version)   |   $admin"
            if ($Ctx.DryRun) { $subtitle += '   |   DRY RUN' }

            $result = Show-Selector -Items $options -Title 'Moscovium' -SingleSelect -Art `
                -Subtitle $subtitle `
                -Label { param($o) $o.Name } `
                -Sublabel { param($o) $o.Hint }

            if (-not $result.Confirmed) { return }

            switch ($result.Selected[0].Action) {
                'oneclick' { Write-Banner; Invoke-ToolboxAction -Id 'oneclick'; Wait-ForKey }
                'tweaks'   { Show-TweakMenu }
                'apps'     { Show-AppMenu }
                'toolbox'  { Show-ToolboxMenu }
                'profiles' { Show-ProfileMenu }
                'packages' { Show-PackageMenu }
                'customize' { Show-CustomizationMenu }
                'tasks'    { Show-TaskManager }
                'status'   { Write-Banner; Show-TweakStatus; Wait-ForKey }
                'gui'      { Clear-Host; Show-Gui | Out-Null; Clear-Host }
                'quit'     { return }
            }
        }
    }

# ===== src/65-TaskView.ps1 =============================================

    # =============================================================================
    # Task manager, console front-end.
    #
    # btop's layout, drawn with Write-Frame: bordered boxes with the title in the
    # top edge, a braille history graph, meters whose cells shade green to red
    # along their own length, and a process table underneath.
    #
    # Two things make that possible without ANSI:
    #
    #   Frame segments. A frame line can carry several differently coloured pieces
    #   (see New-FrameLineFromSegments), which is what a box with a coloured title
    #   or a shaded meter is. Write-Frame writes them with -NoNewline and pads the
    #   row once at the end, so it is still one console line.
    #
    #   Measured layout. The gauges take what they need, the keys and status rows
    #   are reserved, and the process table gets the rest, so the frame never grows
    #   past the window - which would scroll it and break the home-the-cursor
    #   repaint for the rest of the session.
    # =============================================================================

    # Rows outside the boxes: the blank line, the title, the status line and the
    # keys, plus one spare.
    #
    # The spare row matters. Write-Frame prints one line per frame line, and a frame
    # exactly as tall as the window scrolls it by one on the final newline - which
    # moves the top of the buffer off-screen and breaks every later repaint.
    $TaskChromeRows = 5

    # -----------------------------------------------------------------------------
    # Keyboard
    #
    # [Console]::KeyAvailable, not $Host.UI.RawUI.KeyAvailable.
    #
    # RawUI's version reports any pending console input record - including focus
    # changes, window resizes and key-*up* events - while ReadKey('IncludeKeyDown')
    # accepts only key-down records. So RawUI can say a key is waiting when ReadKey
    # will block, and the monitor stops refreshing until a real key arrives. That
    # was the "it does not auto update" bug.
    #
    # The Console pair is consistent: both filter to real key presses. ConsoleKey's
    # numeric values are the virtual key codes, so the switch arms are unchanged.
    # -----------------------------------------------------------------------------

    function Test-TaskKeyboard {
        try {
            $null = [Console]::KeyAvailable
            return $true
        }
        catch { return $false }
    }

    function Read-TaskKey {
        $key = [Console]::ReadKey($true)
        [pscustomobject]@{
            Code = [int]$key.Key
            Char = $key.KeyChar
        }
    }

    # Anything typed before the monitor opened - the Enter that picked it out of the
    # menu, most often - would otherwise be spent on the first frame.
    function Clear-TaskKeyBuffer {
        try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } }
        catch { }
    }

    # Waits up to $TimeoutMs for a keypress, polling rather than blocking, so the
    # view refreshes on its own while nobody is typing.
    function Wait-TaskKey {
        param([int]$TimeoutMs = 1000)

        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            try { if ([Console]::KeyAvailable) { return (Read-TaskKey) } }
            catch { return $null }
            Start-Sleep -Milliseconds 30
        }
        return $null
    }

    # -----------------------------------------------------------------------------
    # Boxes
    # -----------------------------------------------------------------------------

    function Get-TaskSortLabel {
        param([Parameter(Mandatory)][string]$Key)

        switch ($Key) {
            'mem'  { return 'memory' }
            'pid'  { return 'pid' }
            'name' { return 'name' }
            default { return 'cpu' }
        }
    }

    # The key hint, on one line that has to fit an 80-column window.
    #
    # Write-Frame truncates at the window width, so anything longer loses its own
    # tail - and the tail here is 'esc back', the one key someone stuck in the
    # monitor needs. Hence single-space separators rather than the selector's
    # roomier three: this view has more keys to name than any other.
    function Get-TaskKeyHint {
        $dot = Get-Glyph 'Sep'
        $parts = @('up/down move', 'c/m/p/n sort', 'k kill', '/ filter', 'space pause', 'esc back')
        return ('  ' + ($parts -join " $dot "))
    }

    # '  |/- cpu -----------\|' - the title sits in the top edge, btop style.
    function New-TaskBoxTop {
        param(
            [Parameter(Mandatory)][string]$Title,
            [Parameter(Mandatory)][int]$Width,
            [string]$Trailing = ''
        )

        $line = Get-Glyph 'HLine'
        $border = Get-Color 'Muted'

        $segments = [System.Collections.Generic.List[object]]::new()
        $segments.Add((New-FrameSegment '  ' $border))
        $segments.Add((New-FrameSegment ((Get-Glyph 'TopLeft') + $line) $border))
        $segments.Add((New-FrameSegment " $Title " (Get-Color 'Accent')))

        # Anything the box wants to say on its own top edge - a peak, a total -
        # goes right-aligned before the corner.
        $tail = ''
        if ($Trailing) { $tail = " $Trailing " }

        # Everything between the two corners is $Width - 2 wide, same as the inner
        # width New-TaskBoxRow pads to. The two-space indent is outside the box and
        # must not be counted here - getting that wrong put the top edge two
        # characters short of the walls below it.
        $fillWidth = ($Width - 2) - 1 - ($Title.Length + 2) - $tail.Length
        if ($fillWidth -lt 0) { $fillWidth = 0 }

        $segments.Add((New-FrameSegment ($line * $fillWidth) $border))
        if ($tail) { $segments.Add((New-FrameSegment $tail (Get-Color 'Muted'))) }
        $segments.Add((New-FrameSegment (Get-Glyph 'TopRight') $border))

        return (New-FrameLineFromSegments -Segments @($segments))
    }

    function New-TaskBoxBottom {
        param([Parameter(Mandatory)][int]$Width)

        $border = Get-Color 'Muted'
        $inner = $Width - 2
        if ($inner -lt 0) { $inner = 0 }

        return (New-FrameLineFromSegments -Segments @(
            (New-FrameSegment '  ' $border)
            (New-FrameSegment ((Get-Glyph 'BottomLeft') + ((Get-Glyph 'HLine') * $inner) + (Get-Glyph 'BottomRight')) $border)
        ))
    }

    # Wraps content segments in the box's side walls, padding to the inner width so
    # the right wall lines up whatever the content did.
    function New-TaskBoxRow {
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Content,
            [Parameter(Mandatory)][int]$Width
        )

        $border = Get-Color 'Muted'
        $wall = Get-Glyph 'VLine'
        $inner = $Width - 2

        $segments = [System.Collections.Generic.List[object]]::new()
        $segments.Add((New-FrameSegment '  ' $border))
        $segments.Add((New-FrameSegment $wall $border))

        # Clamp here rather than trusting each caller to size its own text. Content
        # longer than the box would push the right wall off the end of the row, and
        # every box has some elastic piece - a detail string, a process name - that
        # can outgrow a narrow window. One place to get right.
        $used = 0
        foreach ($segment in @($Content)) {
            if ($used -ge $inner) { break }

            $text = [string]$segment.Text
            if (($used + $text.Length) -gt $inner) {
                $text = $text.Substring(0, $inner - $used)
                $segments.Add((New-FrameSegment $text $segment.Color $segment.Background))
                $used = $inner
                break
            }

            $used += $text.Length
            $segments.Add($segment)
        }

        if ($used -lt $inner) { $segments.Add((New-FrameSegment (' ' * ($inner - $used)))) }
        $segments.Add((New-FrameSegment $wall $border))

        return (New-FrameLineFromSegments -Segments @($segments))
    }

    # Meter cells coloured by their own position along the bar, not by the current
    # reading - so the right-hand end is red whether or not the value has reached
    # it, and the bar shows headroom as well as load. btop's trick.
    #
    # Runs of one colour are coalesced into a single segment: a 20-cell meter ends
    # up as three or four Write-Host calls rather than twenty.
    function New-TaskMeterSegments {
        param([double]$Percent, [Parameter(Mandatory)][int]$Width)

        if ($Width -lt 1) { return @() }

        $clamped = [Math]::Max(0.0, [Math]::Min(100.0, $Percent))
        $filled = [int][Math]::Round(($clamped / 100.0) * $Width)
        if ($filled -gt $Width) { $filled = $Width }

        $full = Get-Glyph 'BarFull'
        $empty = Get-Glyph 'BarEmpty'
        $dim = Get-Color 'Muted'

        $segments = [System.Collections.Generic.List[object]]::new()

        $runColor = $null
        $runLength = 0

        for ($i = 0; $i -lt $filled; $i++) {
            # Position of this cell along the bar, as a percentage.
            $color = Get-LoadColor -Percent ((($i + 1) / [double]$Width) * 100.0)

            if ($runLength -gt 0 -and $color -eq $runColor) { $runLength++; continue }
            if ($runLength -gt 0) { $segments.Add((New-FrameSegment ($full * $runLength) $runColor)) }
            $runColor = $color
            $runLength = 1
        }
        if ($runLength -gt 0) { $segments.Add((New-FrameSegment ($full * $runLength) $runColor)) }

        if ($filled -lt $Width) { $segments.Add((New-FrameSegment ($empty * ($Width - $filled)) $dim)) }

        return @($segments)
    }

    # -----------------------------------------------------------------------------
    # The boxes
    # -----------------------------------------------------------------------------

    # CPU: history graph, total meter, then a meter per core.
    function New-TaskCpuBox {
        param(
            [Parameter(Mandatory)]$Monitor,
            [Parameter(Mandatory)][int]$Width,
            [int]$GraphHeight = 3
        )

        $lines = [System.Collections.Generic.List[object]]::new()
        $inner = $Width - 2

        $peak = 0.0
        foreach ($value in $Monitor.CpuHistory) { if ($value -gt $peak) { $peak = $value } }

        $lines.Add((New-TaskBoxTop -Title 'cpu' -Width $Width -Trailing ('peak {0:N0}%' -f $peak)))

        if ($GraphHeight -gt 0) {
            $graphWidth = $inner - 2
            $graph = @(New-HistoryGraph -Values @($Monitor.CpuHistory) -Width $graphWidth -Height $GraphHeight -Maximum 100)

            # Top rows of the graph are the high readings, so they shade upward
            # through the load bands - the same idea as the meter cells.
            for ($row = 0; $row -lt $graph.Count; $row++) {
                $band = 100.0 * (($graph.Count - $row) / [double]$graph.Count)
                $lines.Add((New-TaskBoxRow -Width $Width -Content @(
                    (New-FrameSegment ' ' )
                    (New-FrameSegment $graph[$row] (Get-LoadColor -Percent $band))
                )))
            }
        }

        $meterWidth = [Math]::Max(10, [Math]::Min(34, $inner - 22))
        $lines.Add((New-TaskBoxRow -Width $Width -Content @(
            @((New-FrameSegment ' total ' (Get-Color 'Text')),
              (New-FrameSegment ('{0,4:N0}% ' -f $Monitor.Cpu.Total) (Get-LoadColor -Percent $Monitor.Cpu.Total))) +
            @(New-TaskMeterSegments -Percent $Monitor.Cpu.Total -Width $meterWidth)
        )))

        foreach ($line in @(New-TaskCoreRows -Monitor $Monitor -Width $Width)) { $lines.Add($line) }
        $lines.Add((New-TaskBoxBottom -Width $Width))

        return @($lines)
    }

    # One labelled meter per core, wrapped to the box. Past twelve cores the labels
    # would cost more rows than the process table, so it collapses to a single
    # dot-per-core strip off the graph ramp - dense, but it still shows which cores
    # are pinned.
    function New-TaskCoreRows {
        param([Parameter(Mandatory)]$Monitor, [Parameter(Mandatory)][int]$Width)

        $lines = [System.Collections.Generic.List[object]]::new()
        $cores = @($Monitor.Cpu.Cores)
        if ($cores.Count -eq 0) { return @($lines) }

        $inner = $Width - 2

        if ($cores.Count -gt 12) {
            $content = [System.Collections.Generic.List[object]]::new()
            $content.Add((New-FrameSegment (' {0,2} cores ' -f $cores.Count) (Get-Color 'Muted')))
            foreach ($core in $cores) {
                $content.Add((New-FrameSegment (Get-Glyph 'BarFull') (Get-LoadColor -Percent $core)))
            }
            $lines.Add((New-TaskBoxRow -Width $Width -Content @($content)))
            return @($lines)
        }

        # ' 0  15% ######....' - eleven characters of label plus the meter.
        $meterWidth = 8
        $cellWidth = 9 + $meterWidth + 2
        $perLine = [Math]::Max(1, [int](($inner - 1) / $cellWidth))

        for ($start = 0; $start -lt $cores.Count; $start += $perLine) {
            $content = [System.Collections.Generic.List[object]]::new()
            $content.Add((New-FrameSegment ' '))

            for ($i = $start; $i -lt [Math]::Min($start + $perLine, $cores.Count); $i++) {
                $content.Add((New-FrameSegment (' {0,-2}' -f $i) (Get-Color 'Muted')))
                $content.Add((New-FrameSegment ('{0,4:N0}% ' -f $cores[$i]) (Get-LoadColor -Percent $cores[$i])))
                foreach ($segment in @(New-TaskMeterSegments -Percent $cores[$i] -Width $meterWidth)) {
                    $content.Add($segment)
                }
                $content.Add((New-FrameSegment '  '))
            }

            $lines.Add((New-TaskBoxRow -Width $Width -Content @($content)))
        }

        return @($lines)
    }

    # Memory, disk and network in one box: three rows, each a label, a reading, a
    # meter and its detail. Kept as rows rather than side-by-side boxes so the
    # meters all start at the same column and can be compared at a glance.
    function New-TaskSystemBox {
        param([Parameter(Mandatory)]$Monitor, [Parameter(Mandatory)][int]$Width)

        $lines = [System.Collections.Generic.List[object]]::new()
        $inner = $Width - 2

        $lines.Add((New-TaskBoxTop -Title 'mem  disk  net' -Width $Width))

        $meterWidth = [Math]::Max(10, [Math]::Min(28, $inner - 46))
        $detailWidth = [Math]::Max(0, $inner - 14 - $meterWidth - 2)

        if ($Monitor.Memory) {
            $detail = '{0} of {1}   commit {2}' -f `
                (Format-CompactBytes $Monitor.Memory.Used), (Format-CompactBytes $Monitor.Memory.Total),
                (Format-CompactBytes $Monitor.Memory.CommitUsed)

            $lines.Add((New-TaskBoxRow -Width $Width -Content (
                @((New-FrameSegment ' mem  ' (Get-Color 'Text')),
                  (New-FrameSegment ('{0,4:N0}% ' -f $Monitor.Memory.Percent) (Get-LoadColor -Percent $Monitor.Memory.Percent))) +
                @(New-TaskMeterSegments -Percent $Monitor.Memory.Percent -Width $meterWidth) +
                @((New-FrameSegment ('  ' + $detail.PadRight($detailWidth)) (Get-Color 'Muted')))
            )))
        }

        # The fullest volume: that is the one about to cause a problem. The rest are
        # counted, not listed, so eight volumes cannot push out the process table.
        $disks = @($Monitor.Disks)
        if ($disks.Count -gt 0) {
            $worst = @($disks | Sort-Object -Property Percent -Descending)[0]

            $detail = '{0} {1} free of {2}' -f $worst.Name, (Format-CompactBytes $worst.Free), (Format-CompactBytes $worst.Total)
            if ($disks.Count -gt 1) { $detail += '   +{0} more' -f ($disks.Count - 1) }

            $lines.Add((New-TaskBoxRow -Width $Width -Content (
                @((New-FrameSegment ' disk ' (Get-Color 'Text')),
                  (New-FrameSegment ('{0,4:N0}% ' -f $worst.Percent) (Get-LoadColor -Percent $worst.Percent))) +
                @(New-TaskMeterSegments -Percent $worst.Percent -Width $meterWidth) +
                @((New-FrameSegment ('  ' + $detail.PadRight($detailWidth)) (Get-Color 'Muted')))
            )))
        }

        # Network has no ceiling to be a percentage of, so the meter is replaced by
        # a sparkline scaled to the busiest sample still on screen.
        $scale = Get-HistoryScale -History $Monitor.RxHistory `
            -Minimum (Get-HistoryScale -History $Monitor.TxHistory -Minimum 65536)
        $spark = New-Sparkline -Values @($Monitor.RxHistory) -Width $meterWidth -Maximum $scale

        $detail = 'down {0}   up {1}' -f (Format-Rate $Monitor.Network.Received), (Format-Rate $Monitor.Network.Sent)

        $lines.Add((New-TaskBoxRow -Width $Width -Content @(
            (New-FrameSegment ' net  ' (Get-Color 'Text'))
            (New-FrameSegment '      ' (Get-Color 'Muted'))
            (New-FrameSegment $spark (Get-Color 'Accent'))
            (New-FrameSegment ('  ' + $detail.PadRight($detailWidth)) (Get-Color 'Muted'))
        )))

        foreach ($problem in @($Monitor.Errors)) {
            $lines.Add((New-TaskBoxRow -Width $Width -Content @(
                (New-FrameSegment (' ' + $problem) (Get-Color 'Warn'))
            )))
        }

        $lines.Add((New-TaskBoxBottom -Width $Width))
        return @($lines)
    }

    # -----------------------------------------------------------------------------
    # Process table
    # -----------------------------------------------------------------------------

    # Column widths for a given box width. One place, so the header and the rows
    # cannot drift apart.
    function Get-TaskColumnLayout {
        param([Parameter(Mandatory)][int]$Width)

        $wide = $Width -ge 76
        $fixed = 30
        if ($wide) { $fixed = 44 }

        [pscustomobject]@{
            Wide = $wide
            Name = [Math]::Max(10, [Math]::Min(30, $Width - $fixed))
        }
    }

    function New-TaskTableHeader {
        param([Parameter(Mandatory)][int]$Width)

        $layout = Get-TaskColumnLayout -Width $Width
        $faint = Get-Color 'Faint'

        $text = ' ' + 'pid'.PadRight(8) + 'name'.PadRight($layout.Name) +
                'cpu%'.PadLeft(7) + 'memory'.PadLeft(9)
        if ($layout.Wide) { $text += 'thr'.PadLeft(6) + 'cpu time'.PadLeft(11) }

        return (New-TaskBoxRow -Width $Width -Content @((New-FrameSegment $text $faint)))
    }

    # One process row. The name is plain, the numbers carry the load colour, and
    # the cursor row inverts - so the eye lands on the busy processes without
    # having to read any of the figures.
    function New-TaskProcessRow {
        param(
            [Parameter(Mandatory)]$Process,
            [Parameter(Mandatory)][int]$Width,
            [switch]$Selected
        )

        $layout = Get-TaskColumnLayout -Width $Width

        $name = [string]$Process.Name
        if ($name.Length -gt $layout.Name) { $name = $name.Substring(0, $layout.Name - 1) + '.' }

        # A process we have only sampled once has no delta yet, and a dash is
        # honest where 0.0 would be a claim.
        $cpu = '-'
        if ($Process.CpuKnown) { $cpu = '{0:N1}' -f $Process.Cpu }

        if ($Selected) {
            $text = ' ' + ([string]$Process.Id).PadRight(8) + $name.PadRight($layout.Name) +
                    $cpu.PadLeft(7) + (Format-CompactBytes $Process.WorkingSet).PadLeft(9)
            if ($layout.Wide) {
                $text += ([string]$Process.Threads).PadLeft(6) + (Format-CpuTime $Process.CpuSeconds).PadLeft(11)
            }
            # A padded full-width run plus a background is a real selection bar.
            $inner = $Width - 2
            return (New-TaskBoxRow -Width $Width -Content @(
                (New-FrameSegment $text.PadRight($inner) (Get-Color 'HighlightFg') (Get-Color 'HighlightBg'))
            ))
        }

        $cpuColor = Get-Color 'Muted'
        if ($Process.CpuKnown -and $Process.Cpu -ge 1) { $cpuColor = Get-LoadColor -Percent $Process.Cpu }

        $segments = [System.Collections.Generic.List[object]]::new()
        $segments.Add((New-FrameSegment (' ' + ([string]$Process.Id).PadRight(8)) (Get-Color 'Faint')))
        $segments.Add((New-FrameSegment $name.PadRight($layout.Name) (Get-Color 'Text')))
        $segments.Add((New-FrameSegment $cpu.PadLeft(7) $cpuColor))
        $segments.Add((New-FrameSegment (Format-CompactBytes $Process.WorkingSet).PadLeft(9) (Get-Color 'Muted')))

        if ($layout.Wide) {
            $segments.Add((New-FrameSegment ([string]$Process.Threads).PadLeft(6) (Get-Color 'Faint')))
            $segments.Add((New-FrameSegment (Format-CpuTime $Process.CpuSeconds).PadLeft(11) (Get-Color 'Faint')))
        }

        return (New-TaskBoxRow -Width $Width -Content @($segments))
    }

    function New-TaskProcessBox {
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
            [Parameter(Mandatory)][int]$Cursor,
            [Parameter(Mandatory)][int]$Offset,
            [Parameter(Mandatory)][int]$Viewport,
            [Parameter(Mandatory)][int]$Width,
            [Parameter(Mandatory)]$Monitor
        )

        $lines = [System.Collections.Generic.List[object]]::new()

        $title = 'proc'
        $trailing = '{0} shown' -f $Rows.Count
        if ($Monitor.Filter) { $trailing = "{0} of {1}   filter: {2}" -f $Rows.Count, @($Monitor.Processes).Count, $Monitor.Filter }

        $lines.Add((New-TaskBoxTop -Title $title -Width $Width -Trailing $trailing))
        $lines.Add((New-TaskTableHeader -Width $Width))

        if ($Rows.Count -eq 0) {
            $lines.Add((New-TaskBoxRow -Width $Width -Content @(
                (New-FrameSegment ' nothing matches that filter' (Get-Color 'Warn'))
            )))
        }
        else {
            $last = [Math]::Min($Offset + $Viewport, $Rows.Count)
            for ($row = $Offset; $row -lt $last; $row++) {
                $lines.Add((New-TaskProcessRow -Process $Rows[$row] -Width $Width -Selected:($row -eq $Cursor)))
            }
        }

        $lines.Add((New-TaskBoxBottom -Width $Width))
        return @($lines)
    }

    # -----------------------------------------------------------------------------
    # The loop
    # -----------------------------------------------------------------------------

    # How tall the CPU graph can be. It is the first thing to give up rows on a
    # short window, because a graph is worth less than another process row.
    function Get-TaskGraphHeight {
        param([Parameter(Mandatory)][int]$ConsoleHeight)

        if ($ConsoleHeight -lt 26) { return 0 }
        if ($ConsoleHeight -lt 34) { return 2 }
        return 3
    }

    # The whole frame, so the loop and the tests build it the same way and the
    # "does it fit the window" invariant can be checked without a terminal.
    #
    # Returns the frame lines plus the viewport and cursor the layout settled on,
    # because the caller needs those back to interpret the next keypress.
    function New-TaskFrame {
        param(
            [Parameter(Mandatory)]$Monitor,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
            [Parameter(Mandatory)][int]$Width,
            [Parameter(Mandatory)][int]$ConsoleHeight,
            [int]$Cursor = 0,
            [int]$Offset = 0,
            [switch]$Paused
        )

        $cpuBox = @(New-TaskCpuBox -Monitor $Monitor -Width $Width -GraphHeight (Get-TaskGraphHeight -ConsoleHeight $ConsoleHeight))
        $systemBox = @(New-TaskSystemBox -Monitor $Monitor -Width $Width)

        # Everything except the process rows: the two boxes above, the process
        # box's own top, header and bottom, and the page chrome.
        $spent = $TaskChromeRows + $cpuBox.Count + $systemBox.Count + 3
        $viewport = [Math]::Max(3, $ConsoleHeight - $spent)

        $view = Get-ScrollWindow -Cursor $Cursor -Offset $Offset -Count $Rows.Count -Viewport $viewport

        $lines = [System.Collections.Generic.List[object]]::new()
        $lines.Add((New-FrameLine))

        # A title row, not the wordmark: five rows of ASCII art is five process
        # rows, and this screen is about the processes.
        $titleSegments = [System.Collections.Generic.List[object]]::new()
        $titleSegments.Add((New-FrameSegment '  tasks' (Get-Color 'Accent')))
        $titleSegments.Add((New-FrameSegment ("   {0} cores   {1} processes" -f $Monitor.Cores, @($Monitor.Processes).Count) (Get-Color 'Muted')))
        if ($Monitor.Memory) {
            $titleSegments.Add((New-FrameSegment ('   up ' + (Format-Uptime $Monitor.Memory.BootTime)) (Get-Color 'Muted')))
        }
        $titleSegments.Add((New-FrameSegment ('   sort: ' + (Get-TaskSortLabel -Key $Monitor.SortKey)) (Get-Color 'Faint')))
        if (-not $Monitor.Ready) { $titleSegments.Add((New-FrameSegment '   sampling' (Get-Color 'Faint'))) }
        if ($Paused) { $titleSegments.Add((New-FrameSegment '   PAUSED' (Get-Color 'Warn'))) }
        $lines.Add((New-FrameLineFromSegments -Segments @($titleSegments)))

        foreach ($line in $cpuBox) { $lines.Add($line) }
        foreach ($line in $systemBox) { $lines.Add($line) }
        foreach ($line in @(New-TaskProcessBox -Rows $Rows -Cursor $view.Cursor -Offset $view.Offset `
            -Viewport $viewport -Width $Width -Monitor $Monitor)) { $lines.Add($line) }

        $lines.Add((New-FrameLine (Get-TaskKeyHint) (Get-Color 'Muted')))

        [pscustomobject]@{
            Lines    = @($lines)
            Viewport = $viewport
            Cursor   = $view.Cursor
            Offset   = $view.Offset
        }
    }

    # The box width for a given console. Capped, because a meter stretched across a
    # 200-column terminal is harder to read than one that stops.
    function Get-TaskBoxWidth {
        param([Parameter(Mandatory)][int]$ConsoleWidth)
        return [Math]::Max(46, [Math]::Min(96, $ConsoleWidth - 4))
    }

    function Show-TaskManager {
        param([int]$IntervalMs = 1000)

        # A host that cannot read individual keys cannot drive a live view, and a
        # frame repainted where nobody can see it is worse than useless.
        if (-not (Test-Interactive) -or -not (Test-TaskKeyboard)) {
            Show-TaskSnapshot
            return
        }

        $monitor = New-TaskMonitor
        $cursor = 0
        $offset = 0
        $previousHeight = 0
        $paused = $false

        # Same reason as the selector: Write-Frame homes to the top of the buffer,
        # which in a scrolled window is off-screen. Clearing makes (0,0) the top of
        # what you can see, and a frame that always fits keeps it that way.
        Clear-Host
        Clear-TaskKeyBuffer

        # The first sample has nothing to difference against, so every rate reads
        # zero. Take it now and let the loop draw the second one.
        Update-TaskMonitor -Monitor $monitor | Out-Null

        while ($true) {
            if (-not $paused) { Update-TaskMonitor -Monitor $monitor | Out-Null }

            $rows = @(Select-TaskProcess -Processes @($monitor.Processes) -Filter $monitor.Filter)

            $frame = New-TaskFrame -Monitor $monitor -Rows $rows `
                -Width (Get-TaskBoxWidth -ConsoleWidth (Get-ConsoleWidth)) `
                -ConsoleHeight (Get-ConsoleHeight) `
                -Cursor $cursor -Offset $offset -Paused:$paused

            $cursor = $frame.Cursor
            $offset = $frame.Offset
            $viewport = $frame.Viewport

            Write-Frame -Lines $frame.Lines -PreviousHeight ([ref]$previousHeight)

            $key = Wait-TaskKey -TimeoutMs $IntervalMs
            if ($null -eq $key) { continue }

            switch ($key.Code) {
                38 { if ($rows.Count) { $cursor = [Math]::Max(0, $cursor - 1) }; continue }                   # up
                40 { if ($rows.Count) { $cursor = [Math]::Min($rows.Count - 1, $cursor + 1) }; continue }     # down
                33 { $cursor = [Math]::Max(0, $cursor - $viewport); continue }                                # page up
                34 { $cursor = [Math]::Min([Math]::Max(0, $rows.Count - 1), $cursor + $viewport); continue }  # page down
                36 { $cursor = 0; continue }                                                                  # home
                35 { $cursor = [Math]::Max(0, $rows.Count - 1); continue }                                    # end

                27 { Clear-Host; return }                                                                     # escape

                8 {
                    if ($monitor.Filter.Length -gt 0) {
                        $monitor.Filter = $monitor.Filter.Substring(0, $monitor.Filter.Length - 1)
                        $cursor = 0; $offset = 0
                    }
                    continue
                }
            }

            switch -Regex ([string]$key.Char) {
                '^[cC]$' { $monitor.SortKey = 'cpu';  $cursor = 0; $offset = 0; continue }
                '^[mM]$' { $monitor.SortKey = 'mem';  $cursor = 0; $offset = 0; continue }
                '^[pP]$' { $monitor.SortKey = 'pid';  $cursor = 0; $offset = 0; continue }
                '^[nN]$' { $monitor.SortKey = 'name'; $cursor = 0; $offset = 0; continue }
                '^[qQ]$' { Clear-Host; return }

                '^[kK]$' {
                    if ($rows.Count -eq 0) { continue }
                    $target = $rows[$cursor]

                    # Drop out of the frame to ask: the confirm prompt reads from
                    # the host, and a Read-Host inside a repainting frame would be
                    # overwritten before it could be answered.
                    Clear-Host
                    Write-Line ''
                    Stop-TaskProcess -Id $target.Id -Name $target.Name | Out-Null
                    Write-Line ''
                    Write-Info 'Press a key to go back to the monitor.'
                    Clear-TaskKeyBuffer
                    [void](Wait-TaskKey -TimeoutMs 15000)

                    Clear-Host
                    Clear-TaskKeyBuffer
                    $previousHeight = 0
                    # The ended process leaves a hole in the list, so resample
                    # rather than leaving the cursor on a row that is gone.
                    $monitor.PreviousStamp = $null
                    Update-TaskMonitor -Monitor $monitor | Out-Null
                    continue
                }

                '^/$' {
                    Write-Line ''
                    Write-Line '  filter: ' -Color Yellow -NoNewline
                    $monitor.Filter = [string](Read-Host)
                    $cursor = 0; $offset = 0
                    $previousHeight = 0
                    Clear-Host
                    Clear-TaskKeyBuffer
                    continue
                }

                '^ $' { $paused = -not $paused; continue }
            }
        }
    }

    # What -Tasks prints when there is no console to drive: one sample, no loop.
    # Also what a redirected run gets, so `-Tasks > tasks.txt` is useful instead of
    # spinning forever repainting a frame nobody can see.
    function Show-TaskSnapshot {
        param([int]$Top = 20)

        $monitor = New-TaskMonitor

        # Two samples a second apart: the first has nothing to difference against,
        # so without the second every CPU figure would be zero.
        Update-TaskMonitor -Monitor $monitor | Out-Null
        Start-Sleep -Milliseconds 1000
        Update-TaskMonitor -Monitor $monitor | Out-Null

        Write-SectionHeading 'Tasks'

        Write-Line ('  cpu    {0,5:N1}%   {1} cores' -f $monitor.Cpu.Total, $monitor.Cores) -Color (Get-LoadColor -Percent $monitor.Cpu.Total)

        if ($monitor.Memory) {
            Write-Line ('  mem    {0,5:N1}%   {1} of {2}   commit {3} of {4}' -f `
                $monitor.Memory.Percent, (Format-CompactBytes $monitor.Memory.Used), (Format-CompactBytes $monitor.Memory.Total),
                (Format-CompactBytes $monitor.Memory.CommitUsed), (Format-CompactBytes $monitor.Memory.CommitTotal)) `
                -Color (Get-LoadColor -Percent $monitor.Memory.Percent)
        }

        foreach ($disk in @($monitor.Disks)) {
            Write-Line ('  disk   {0,5:N1}%   {1} {2} free of {3}' -f `
                $disk.Percent, $disk.Name, (Format-CompactBytes $disk.Free), (Format-CompactBytes $disk.Total)) `
                -Color (Get-LoadColor -Percent $disk.Percent)
        }

        Write-Line ('  net            down {0}   up {1}' -f `
            (Format-Rate $monitor.Network.Received), (Format-Rate $monitor.Network.Sent)) -Color (Get-Color 'Accent')

        foreach ($problem in @($monitor.Errors)) { Write-Warn $problem }

        Write-Line ''
        Write-Line ('  {0,-8}{1,-30}{2,7}{3,9}{4,6}' -f 'pid', 'name', 'cpu%', 'memory', 'thr') -Color (Get-Color 'Faint')

        foreach ($proc in @(@($monitor.Processes) | Select-Object -First $Top)) {
            $cpu = '-'
            if ($proc.CpuKnown) { $cpu = '{0:N1}' -f $proc.Cpu }
            Write-Line ('  {0,-8}{1,-30}{2,7}{3,9}{4,6}' -f `
                $proc.Id, $proc.Name, $cpu, (Format-CompactBytes $proc.WorkingSet), $proc.Threads)
        }

        Write-Line ''
        Write-Info "Showing the top $Top of $(@($monitor.Processes).Count) processes by CPU."
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
        WindowStartupLocation="CenterScreen" Background="#FF000000"
        TextOptions.TextFormattingMode="Display">

  <Window.Resources>
    <!-- AMOLED: the canvas is true black, so an OLED panel leaves those pixels
         off. Surfaces lift off it in near-black purples rather than greys. -->
    <SolidColorBrush x:Key="Bg"        Color="#FF000000"/>
    <SolidColorBrush x:Key="Panel"     Color="#FF08060E"/>
    <SolidColorBrush x:Key="Panel2"    Color="#FF130E1F"/>
    <SolidColorBrush x:Key="PanelHi"   Color="#FF1C1430"/>
    <SolidColorBrush x:Key="Line"      Color="#FF261B3D"/>
    <SolidColorBrush x:Key="Text"      Color="#FFEDE8F7"/>
    <SolidColorBrush x:Key="Muted"     Color="#FF8B81A8"/>
    <SolidColorBrush x:Key="Faint"     Color="#FF5F5680"/>
    <SolidColorBrush x:Key="Accent"    Color="#FFB388FF"/>
    <SolidColorBrush x:Key="AccentDim" Color="#FF7D5CC0"/>
    <SolidColorBrush x:Key="Ok"        Color="#FF7EE0A6"/>
    <SolidColorBrush x:Key="Warn"      Color="#FFFFCB7A"/>
    <SolidColorBrush x:Key="Err"       Color="#FFFF7B94"/>

    <LinearGradientBrush x:Key="AccentFill" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#FF6E3FC4" Offset="0"/>
      <GradientStop Color="#FF4E2A94" Offset="1"/>
    </LinearGradientBrush>

    <LinearGradientBrush x:Key="AccentFillHot" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#FF8451DE" Offset="0"/>
      <GradientStop Color="#FF5F35AE" Offset="1"/>
    </LinearGradientBrush>

    <LinearGradientBrush x:Key="TitleInk" StartPoint="0,0" EndPoint="1,0">
      <GradientStop Color="#FFC9A6FF" Offset="0"/>
      <GradientStop Color="#FF8B5CF6" Offset="1"/>
    </LinearGradientBrush>

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
            <Border x:Name="Chrome" CornerRadius="6" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{StaticResource PanelHi}"/>
                <Setter TargetName="Chrome" Property="BorderBrush" Value="{StaticResource AccentDim}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource AccentFill}"/>
      <Setter Property="BorderBrush" Value="#FF8B5CF6"/>
      <Setter Property="Foreground" Value="#FFF6F1FF"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" CornerRadius="6" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{StaticResource AccentFillHot}"/>
                <Setter TargetName="Chrome" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.3"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
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
                      Background="#FF120C1E" BorderBrush="#FF33254F" BorderThickness="1.4"
                      VerticalAlignment="Center">
                <Path x:Name="Tick" Width="10" Height="10" Stretch="Uniform" Opacity="0"
                      HorizontalAlignment="Center" VerticalAlignment="Center"
                      Data="M 0,5 L 4,9 L 11,1" Stroke="#FF12071F" StrokeThickness="2.4"
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

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource AccentDim}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Chrome" CornerRadius="6" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="Chrome" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="BorderBrush" Value="{StaticResource AccentDim}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- The stock ComboBox and ScrollBar chrome is light, and ignores Background,
         so both need a template to sit on a dark window. -->
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Padding" Value="11,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Chrome" Background="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{StaticResource AccentFill}"/>
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
                            BorderThickness="1" CornerRadius="6">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,11,0"
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
              <ContentPresenter Margin="12,0,28,0" VerticalAlignment="Center" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True"
                     Focusable="False" PopupAnimation="Fade">
                <Border Background="{StaticResource Panel2}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                        CornerRadius="6" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                        MaxHeight="320" Margin="0,3,0,0">
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
      <Setter Property="Foreground" Value="{StaticResource Faint}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="13,0,0,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="IsHitTestVisible" Value="False"/>
    </Style>

    <Style x:Key="ScrollThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="Chrome" Background="#FF2E2148" CornerRadius="3" Margin="3,0"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#FF4B3576"/>
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
      <Setter Property="Padding" Value="18,12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Grid>
              <Border x:Name="Chrome" Background="Transparent" CornerRadius="0,7,7,0" Margin="0,1,10,1">
                <ContentPresenter Margin="{TemplateBinding Padding}"/>
              </Border>
              <Border x:Name="Marker" Width="3" HorizontalAlignment="Left" Margin="0,7"
                      CornerRadius="0,2,2,0" Background="Transparent"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#FF120C1E"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#FF1A1030"/>
                <Setter TargetName="Marker" Property="Background" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PageTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="17"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <!-- The process table. WPF's stock ListView chrome is light grey with a
         blue selection, which on this palette reads as a control from another
         application, so the item and the column header are both retemplated. -->
    <Style TargetType="ListView">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>

    <Style TargetType="ListViewItem">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Padding" Value="0,3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListViewItem">
            <Border x:Name="Chrome" Background="Transparent" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <GridViewRowPresenter Columns="{TemplateBinding GridView.ColumnCollection}"
                                    Content="{TemplateBinding Content}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#FF130E1F"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#FF2A1B4D"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Foreground" Value="{StaticResource Faint}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="GridViewColumnHeader">
            <Border Background="Transparent" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1"
                    Padding="6,5">
              <ContentPresenter HorizontalAlignment="Left"/>
            </Border>
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
      <Grid Margin="22,15">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="MOSCOVIUM" FontSize="20" FontWeight="SemiBold"
                     Foreground="{StaticResource TitleInk}"/>
          <TextBlock x:Name="VersionText" Text="v0.0.0" FontSize="12" Foreground="{StaticResource Faint}"
                     VerticalAlignment="Center" Margin="11,4,0,0"/>
        </StackPanel>

        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Border x:Name="DryRunBadge" Background="#FF2E2410" BorderBrush="#FF5A4620" BorderThickness="1"
                  CornerRadius="10" Padding="11,3" Margin="0,0,10,0" Visibility="Collapsed">
            <TextBlock Text="DRY RUN" FontSize="10.5" FontWeight="SemiBold" Foreground="{StaticResource Warn}"/>
          </Border>
          <Border Background="{StaticResource Panel2}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                  CornerRadius="10" Padding="11,3">
            <TextBlock x:Name="CatalogChip" Text="" FontSize="11" Foreground="{StaticResource Muted}"/>
          </Border>
        </StackPanel>
      </Grid>
    </Border>

    <!-- body -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="196"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
        <ListBox x:Name="NavList" Background="Transparent" BorderThickness="0" Margin="0,12,0,0"
                 ItemContainerStyle="{StaticResource NavItem}">
          <ListBoxItem Content="One click" IsSelected="True"/>
          <ListBoxItem Content="Tasks"/>
          <ListBoxItem Content="Tweaks"/>
          <ListBoxItem Content="Apps"/>
          <ListBoxItem Content="Package managers"/>
          <ListBoxItem Content="Store"/>
          <ListBoxItem Content="Toolbox"/>
          <ListBoxItem Content="Guides"/>
          <ListBoxItem Content="Personalise"/>
          <ListBoxItem Content="Customization"/>
          <ListBoxItem Content="Profiles"/>
          <ListBoxItem Content="Settings"/>
        </ListBox>
      </Border>

      <Grid Grid.Column="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="*" MinHeight="180"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="196"/>
        </Grid.RowDefinitions>

        <!-- pages share this cell; only one is visible at a time -->
        <Grid Grid.Row="0" Margin="22,18,22,0">

          <!-- the landing page: the whole debloat pass, one button -->
          <Grid x:Name="OneClickPanel">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
              <Border Width="3" Height="18" CornerRadius="2" Background="{StaticResource Accent}" Margin="0,0,10,0"/>
              <TextBlock Text="One-click debloat box" Style="{StaticResource PageTitle}"/>
            </StackPanel>

            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
              <Border Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                      BorderThickness="1" CornerRadius="10" Padding="26,19,26,16" Margin="0">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>

                  <StackPanel Grid.Column="0" Margin="0,0,22,0">
                    <TextBlock Text="Debloat this machine" FontSize="24" FontWeight="SemiBold"
                               Foreground="{StaticResource TitleInk}"/>
                    <TextBlock x:Name="OneClickBlurb" TextWrapping="Wrap" FontSize="13" Margin="0,7,0,0"
                               Foreground="{StaticResource Muted}"
                               Text="Six steps, one prompt. Everything is listed before anything runs."/>

                    <StackPanel x:Name="OneClickSteps" Margin="0,15,0,0"/>
                  </StackPanel>

                  <!-- The caution lives beside the button rather than under the
                       steps: down there it fell below the fold on an 760px
                       window, which is no use for a safety notice. -->
                  <StackPanel Grid.Column="1" VerticalAlignment="Top" Width="208">
                    <Button x:Name="BtnOneClick" Content="Run the box" Style="{StaticResource Primary}"
                            FontSize="15" Padding="0,13" HorizontalAlignment="Stretch"/>
                    <TextBlock TextWrapping="Wrap" FontSize="11" Margin="2,8,0,0"
                               Foreground="{StaticResource Faint}"
                               Text="Asks once, then runs all six without asking again."/>
                    <!-- The label says what it does, so no note under this one. -->
                    <Button x:Name="BtnOneClickToolbox" Content="Pick steps yourself" Margin="0,12,0,0"
                            Padding="0,8" HorizontalAlignment="Stretch"
                            ToolTip="Every step is also a separate action in the Toolbox"/>

                    <Border Background="{StaticResource Panel2}" BorderBrush="{StaticResource Line}"
                            BorderThickness="1" CornerRadius="7" Padding="12,9" Margin="0,14,0,0">
                      <StackPanel>
                        <TextBlock Text="Before you press it" FontSize="11.5" FontWeight="SemiBold"
                                   Foreground="{StaticResource Warn}"/>
                        <TextBlock TextWrapping="Wrap" FontSize="11" Margin="0,5,0,0" LineHeight="15"
                                   Foreground="{StaticResource Muted}"
                                   Text="Steps 1 and 2 run scripts published by other people. Both URLs are printed before anything runs."/>
                        <TextBlock TextWrapping="Wrap" FontSize="11" Margin="0,5,0,0" LineHeight="15"
                                   Foreground="{StaticResource Muted}"
                                   Text="Step 1 is not unattended - you press Run Tweaks in WinUtil's window."/>
                        <TextBlock TextWrapping="Wrap" FontSize="11" Margin="0,5,0,0" LineHeight="15"
                                   Foreground="{StaticResource Muted}"
                                   Text="Restore point first. Steps 5 and 6 need a reboot."/>
                      </StackPanel>
                    </Border>
                  </StackPanel>
                </Grid>
              </Border>
            </ScrollViewer>
          </Grid>

          <!-- Task manager. The meters and the per-core strip are drawn in code
               from the same sampler the console monitor uses; only the frame
               lives here. -->
          <Grid x:Name="TasksPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
              <Border Width="3" Height="18" CornerRadius="2" Background="{StaticResource Accent}" Margin="0,0,10,0"/>
              <TextBlock Text="Tasks" Style="{StaticResource PageTitle}"/>
              <TextBlock x:Name="TaskSummary" FontSize="11" Foreground="{StaticResource Faint}"
                         VerticalAlignment="Center" Margin="12,3,0,0"/>
            </StackPanel>

            <!-- Four meters across the top: CPU, memory, disk, network. -->
            <Grid Grid.Row="1" Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>

              <Border Grid.Column="0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                      BorderThickness="1" CornerRadius="8" Padding="12,8" Margin="0,0,5,0">
                <StackPanel>
                  <TextBlock Text="CPU" FontSize="10.5" Foreground="{StaticResource Faint}"/>
                  <TextBlock x:Name="CpuValue" Text="--" FontSize="20" Foreground="{StaticResource Text}" Margin="0,1,0,0"/>
                  <ProgressBar x:Name="CpuBar" Height="4" Minimum="0" Maximum="100" Margin="0,6,0,0"/>
                  <TextBlock x:Name="CpuDetail" Text="" FontSize="10.5" Foreground="{StaticResource Muted}"
                             Margin="0,6,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>

              <Border Grid.Column="1" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                      BorderThickness="1" CornerRadius="8" Padding="12,8" Margin="5,0,5,0">
                <StackPanel>
                  <TextBlock Text="MEMORY" FontSize="10.5" Foreground="{StaticResource Faint}"/>
                  <TextBlock x:Name="MemValue" Text="--" FontSize="20" Foreground="{StaticResource Text}" Margin="0,1,0,0"/>
                  <ProgressBar x:Name="MemBar" Height="4" Minimum="0" Maximum="100" Margin="0,6,0,0"/>
                  <TextBlock x:Name="MemDetail" Text="" FontSize="10.5" Foreground="{StaticResource Muted}"
                             Margin="0,6,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>

              <Border Grid.Column="2" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                      BorderThickness="1" CornerRadius="8" Padding="12,8" Margin="5,0,5,0">
                <StackPanel>
                  <TextBlock Text="DISK" FontSize="10.5" Foreground="{StaticResource Faint}"/>
                  <TextBlock x:Name="DiskValue" Text="--" FontSize="20" Foreground="{StaticResource Text}" Margin="0,1,0,0"/>
                  <ProgressBar x:Name="DiskBar" Height="4" Minimum="0" Maximum="100" Margin="0,6,0,0"/>
                  <TextBlock x:Name="DiskDetail" Text="" FontSize="10.5" Foreground="{StaticResource Muted}"
                             Margin="0,6,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>

              <Border Grid.Column="3" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                      BorderThickness="1" CornerRadius="8" Padding="12,8" Margin="5,0,0,0">
                <StackPanel>
                  <TextBlock Text="NETWORK" FontSize="10.5" Foreground="{StaticResource Faint}"/>
                  <TextBlock x:Name="NetValue" Text="--" FontSize="20" Foreground="{StaticResource Text}" Margin="0,1,0,0"/>
                  <!-- The history graph goes here, drawn as a polyline. -->
                  <Border Height="4" Margin="0,6,0,0"/>
                  <TextBlock x:Name="NetDetail" Text="" FontSize="10.5" Foreground="{StaticResource Muted}"
                             Margin="0,6,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
            </Grid>

            <!-- CPU history and the per-core strip. -->
            <Border Grid.Row="2" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                    BorderThickness="1" CornerRadius="8" Padding="12,8" Margin="0,0,0,10">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Canvas x:Name="CpuGraph" Grid.Column="0" Height="46" ClipToBounds="True"
                        HorizontalAlignment="Stretch" Background="Transparent"/>
                <StackPanel x:Name="CoreStrip" Grid.Column="1" Orientation="Horizontal" Margin="14,0,0,0"
                            VerticalAlignment="Bottom"/>
              </Grid>
            </Border>

            <!-- Process table. -->
            <Grid Grid.Row="3">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>

              <DockPanel Grid.Row="0" Margin="0,0,0,10" LastChildFill="False">
                <Grid Width="200" DockPanel.Dock="Left" Margin="0,0,8,0">
                  <TextBox x:Name="TaskSearch" ToolTip="Filter by process name or pid"/>
                  <TextBlock Text="Filter processes">
                    <TextBlock.Style>
                      <Style TargetType="TextBlock" BasedOn="{StaticResource Watermark}">
                        <Setter Property="Visibility" Value="Collapsed"/>
                        <Style.Triggers>
                          <DataTrigger Binding="{Binding Text, ElementName=TaskSearch}" Value="">
                            <Setter Property="Visibility" Value="Visible"/>
                          </DataTrigger>
                        </Style.Triggers>
                      </Style>
                    </TextBlock.Style>
                  </TextBlock>
                </Grid>
                <ComboBox x:Name="TaskSort" Width="150" DockPanel.Dock="Left" Margin="0,0,8,0"
                          ToolTip="Sort the process list"/>
                <Button x:Name="BtnTaskPause" Content="Pause" DockPanel.Dock="Left"
                        ToolTip="Stop refreshing so the list holds still"/>
                <Button x:Name="BtnTaskKill" Content="End process" DockPanel.Dock="Right" Margin="8,0,0,0"
                        ToolTip="End the selected process"/>
              </DockPanel>

              <Border Grid.Row="1" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                      BorderThickness="1" CornerRadius="8">
                <!-- A ListView rather than hand-built rows: the process list is
                     replaced wholesale every second, and virtualisation is what
                     keeps that cheap with 150-plus processes. -->
                <ListView x:Name="TaskRows" Background="Transparent" BorderThickness="0" Margin="4"
                          ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                  <ListView.View>
                    <GridView AllowsColumnReorder="False">
                      <GridViewColumn Header="PID" Width="70" DisplayMemberBinding="{Binding Id}"/>
                      <GridViewColumn Header="Name" Width="240" DisplayMemberBinding="{Binding Name}"/>
                      <GridViewColumn Header="CPU %" Width="80" DisplayMemberBinding="{Binding CpuText}"/>
                      <GridViewColumn Header="Memory" Width="100" DisplayMemberBinding="{Binding MemoryText}"/>
                      <GridViewColumn Header="Threads" Width="80" DisplayMemberBinding="{Binding Threads}"/>
                      <GridViewColumn Header="CPU time" Width="100" DisplayMemberBinding="{Binding TimeText}"/>
                    </GridView>
                  </ListView.View>
                </ListView>
              </Border>
            </Grid>
          </Grid>

          <Grid x:Name="TweaksPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
              <Border Width="3" Height="18" CornerRadius="2" Background="{StaticResource Accent}" Margin="0,0,10,0"/>
              <TextBlock Text="Registry tweaks" Style="{StaticResource PageTitle}"/>
            </StackPanel>
            <DockPanel Grid.Row="1" Margin="0,0,0,12" LastChildFill="False">
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
                    BorderThickness="1" CornerRadius="8">
              <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="7">
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
            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
              <Border Width="3" Height="18" CornerRadius="2" Background="{StaticResource Accent}" Margin="0,0,10,0"/>
              <TextBlock Text="Applications" Style="{StaticResource PageTitle}"/>
            </StackPanel>
            <DockPanel Grid.Row="1" Margin="0,0,0,12" LastChildFill="False">
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
                    BorderThickness="1" CornerRadius="8">
              <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="7">
                <StackPanel x:Name="AppRows"/>
              </ScrollViewer>
            </Border>
          </Grid>

          <Grid x:Name="ToolboxPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
              <Border Width="3" Height="18" CornerRadius="2" Background="{StaticResource Accent}" Margin="0,0,10,0"/>
              <TextBlock Text="Toolbox" Style="{StaticResource PageTitle}"/>
            </StackPanel>
            <Border Grid.Row="1" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                    BorderThickness="1" CornerRadius="8">
              <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="7">
                <StackPanel x:Name="ToolboxRows"/>
              </ScrollViewer>
            </Border>
          </Grid>

          <Grid x:Name="PackagesPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
              <Border Width="3" Height="18" CornerRadius="2" Background="{StaticResource Accent}" Margin="0,0,10,0"/>
              <TextBlock Text="Package managers" Style="{StaticResource PageTitle}"/>
            </StackPanel>

            <TextBlock Grid.Row="1" TextWrapping="Wrap" FontSize="12" Margin="0,0,0,10"
                       Foreground="{StaticResource Muted}"
                       Text="Each one is installed by running its own project's install script, in a new window, after Moscovium shows you the exact command."/>

            <!-- Scoop's installer refuses to run elevated, and this window
                 always is. The note says so rather than letting the button
                 fail with someone else's error message. -->
            <Border Grid.Row="2" Background="{StaticResource Panel2}" BorderBrush="{StaticResource Line}"
                    BorderThickness="1" CornerRadius="7" Padding="13,9" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock Text="Chocolatey and Scoop want opposite privileges" FontSize="11.5"
                           FontWeight="SemiBold" Foreground="{StaticResource Warn}"/>
                <TextBlock TextWrapping="Wrap" FontSize="11.5" Margin="0,4,0,0" LineHeight="16"
                           Foreground="{StaticResource Muted}"
                           Text="Chocolatey installs machine-wide and needs administrator. Scoop installs into your profile and its installer blocks itself from running elevated - and this window always is. Installing Scoop here offers the machine-wide variant its own docs describe; for the normal per-user install, Moscovium hands you the one-line command to paste into an ordinary PowerShell window."/>
              </StackPanel>
            </Border>

            <Border Grid.Row="3" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                    BorderThickness="1" CornerRadius="8">
              <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="7">
                <StackPanel x:Name="PackageRows"/>
              </ScrollViewer>
            </Border>
          </Grid>

          <Grid x:Name="StorePanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
              <Border Width="3" Height="18" CornerRadius="2" Background="{StaticResource Accent}" Margin="0,0,10,0"/>
              <TextBlock Text="App store" Style="{StaticResource PageTitle}"/>
            </StackPanel>
            <DockPanel Grid.Row="1" Margin="0,0,0,12" LastChildFill="False">
              <TextBlock DockPanel.Dock="Left" VerticalAlignment="Center" Foreground="{StaticResource Muted}"
                         FontSize="12" Margin="0,0,12,0"
                         Text="Community releases from the Moscovium dev organisations on GitHub."/>
              <Button x:Name="BtnStoreInstall" Content="Install selected" DockPanel.Dock="Right" Style="{StaticResource Primary}"/>
              <Button x:Name="BtnStoreRefresh" Content="Load" DockPanel.Dock="Right" Margin="8,0,0,0"/>
            </DockPanel>
            <Border Grid.Row="2" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                    BorderThickness="1" CornerRadius="8">
              <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="7">
                <StackPanel x:Name="StoreRows"/>
              </ScrollViewer>
            </Border>
          </Grid>

          <Grid x:Name="GuidesPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
              <Border Width="3" Height="18" CornerRadius="2" Background="{StaticResource Accent}" Margin="0,0,10,0"/>
              <TextBlock Text="Guides" Style="{StaticResource PageTitle}"/>
            </StackPanel>
            <TextBlock Grid.Row="1" Foreground="{StaticResource Muted}" FontSize="12" Margin="0,0,0,12" TextWrapping="Wrap"
                       Text="The parts no tool can do for you - BIOS, driver control panels, your router. Click a guide to open it."/>
            <Border Grid.Row="2" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                    BorderThickness="1" CornerRadius="8">
              <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="7">
                <StackPanel x:Name="GuideRows"/>
              </ScrollViewer>
            </Border>
          </Grid>

          <Grid x:Name="PersonalizePanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
              <Border Width="3" Height="18" CornerRadius="2" Background="{StaticResource Accent}" Margin="0,0,10,0"/>
              <TextBlock Text="Personalise" Style="{StaticResource PageTitle}"/>
            </StackPanel>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
              <StackPanel>

                <Border Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                        CornerRadius="8" Padding="16" Margin="0,0,0,12">
                  <StackPanel>
                    <TextBlock Text="Mouse cursors" FontSize="14" FontWeight="SemiBold" Margin="0,0,0,4"/>
                    <TextBlock Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,12"
                               Text="Point this at a folder of .cur / .ani files and it matches them to Windows cursor roles by file name. The desktop app's bundled packs are hundreds of binary files and cannot travel in a single script."/>
                    <StackPanel Orientation="Horizontal">
                      <Button x:Name="BtnCursorInstall" Content="Install from folder" Style="{StaticResource Primary}"/>
                      <Button x:Name="BtnCursorRestore" Content="Restore Windows defaults"/>
                    </StackPanel>
                  </StackPanel>
                </Border>

                <Border Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                        CornerRadius="8" Padding="16" Margin="0,0,0,12">
                  <StackPanel>
                    <TextBlock Text="Wallpaper" FontSize="14" FontWeight="SemiBold" Margin="0,0,0,12"/>
                    <StackPanel Orientation="Horizontal">
                      <ComboBox x:Name="WallpaperStyle" Width="150" Margin="0,0,8,0"/>
                      <Button x:Name="BtnWallpaper" Content="Choose image" Style="{StaticResource Primary}"/>
                    </StackPanel>
                  </StackPanel>
                </Border>

                <Border Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                        CornerRadius="8" Padding="16">
                  <StackPanel>
                    <TextBlock Text="Counter-Strike configs" FontSize="14" FontWeight="SemiBold" Margin="0,0,0,4"/>
                    <TextBlock x:Name="CsFolderText" Foreground="{StaticResource Muted}" FontSize="12"
                               TextWrapping="Wrap" Margin="0,0,0,12" Text="Looking for a cfg folder..."/>
                    <StackPanel Orientation="Horizontal">
                      <Button x:Name="BtnCsDefault" Content="Install yabosen.cfg" Style="{StaticResource Primary}"/>
                      <Button x:Name="BtnCsFile" Content="Install a .cfg"/>
                      <Button x:Name="BtnCsLaunch" Content="Copy launch options"/>
                    </StackPanel>
                  </StackPanel>
                </Border>

              </StackPanel>
            </ScrollViewer>
          </Grid>

          <Grid x:Name="SettingsPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
              <Border Width="3" Height="18" CornerRadius="2" Background="{StaticResource Accent}" Margin="0,0,10,0"/>
              <TextBlock Text="Settings" Style="{StaticResource PageTitle}"/>
            </StackPanel>
            <StackPanel Grid.Row="1">
              <TextBlock Text="Store install folder" Foreground="{StaticResource Faint}" FontSize="11" Margin="0,0,0,7"/>
              <DockPanel LastChildFill="True" Margin="0,0,0,16">
                <Button x:Name="BtnBrowseInstallPath" Content="Browse" DockPanel.Dock="Right" Margin="8,0,0,0"/>
                <TextBox x:Name="InstallPath"/>
              </DockPanel>

              <TextBlock Text="GitHub token (optional)" Foreground="{StaticResource Faint}" FontSize="11" Margin="0,0,0,7"/>
              <TextBlock Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,7"
                         Text="Only raises the API rate limit when loading the store. Unauthenticated GitHub allows 60 requests an hour, and each repo costs two."/>
              <PasswordBox x:Name="GitHubToken" Margin="0,0,0,16" Background="{StaticResource Panel2}"
                           Foreground="{StaticResource Text}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                           Padding="8,6" FontFamily="Segoe UI"/>

              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnSaveSettings" Content="Save" Style="{StaticResource Primary}"/>
                <Button x:Name="BtnOpenStateFolder" Content="Open data folder"/>
              </StackPanel>
            </StackPanel>
          </Grid>

          <Grid x:Name="CustomizationPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
              <Border Width="3" Height="18" CornerRadius="2" Background="{StaticResource Accent}" Margin="0,0,10,0"/>
              <TextBlock Text="Customization" Style="{StaticResource PageTitle}"/>
            </StackPanel>

            <TextBlock Grid.Row="1" TextWrapping="Wrap" FontSize="12" Margin="0,0,0,10"
                       Foreground="{StaticResource Muted}"
                       Text="Shell replacements. Each installer is fetched from its own vendor's current release and run as that vendor ships it, after Moscovium shows you the link."/>

            <!-- The desktop app also ships a StartAllBack trial reset. It is
                 not here, for the same reason MAS is not in the catalog. -->
            <Border Grid.Row="2" Background="{StaticResource Panel2}" BorderBrush="{StaticResource Line}"
                    BorderThickness="1" CornerRadius="7" Padding="13,9" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock Text="Why the vendor's own installer and not winget" FontSize="11.5"
                           FontWeight="SemiBold" Foreground="{StaticResource Warn}"/>
                <TextBlock TextWrapping="Wrap" FontSize="11.5" Margin="0,4,0,0" LineHeight="16"
                           Foreground="{StaticResource Muted}"
                           Text="ExplorerPatcher is tied to the exact Windows build, and winget's copy has lagged a whole feature release behind GitHub - installing that on a newer Windows is the failure ExplorerPatcher is known for. So every tool here comes from where its vendor publishes it today. StartAllBack is paid software with a 100-day trial; the trial reset the desktop app bundles is deliberately not included."/>
              </StackPanel>
            </Border>

            <Border Grid.Row="3" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}"
                    BorderThickness="1" CornerRadius="8">
              <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="7">
                <StackPanel x:Name="CustomizationRows"/>
              </ScrollViewer>
            </Border>
          </Grid>

          <Grid x:Name="ProfilesPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
              <Border Width="3" Height="18" CornerRadius="2" Background="{StaticResource Accent}" Margin="0,0,10,0"/>
              <TextBlock Text="Setup profiles" Style="{StaticResource PageTitle}"/>
            </StackPanel>
            <TextBlock Grid.Row="1" TextWrapping="Wrap" Foreground="{StaticResource Muted}" Margin="0,0,0,16"
                       Text="A profile is a saved checklist of tweaks and apps. The format matches the Moscovium desktop app, so profiles move between them."/>
            <StackPanel Grid.Row="2">
              <TextBlock Text="Profile file" Foreground="{StaticResource Faint}" FontSize="11" Margin="0,0,0,7"/>
              <DockPanel LastChildFill="True" Margin="0,0,0,16">
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
                      VerticalAlignment="Center" Margin="0,12,0,0"/>

        <Border Grid.Row="2" Background="#FF000000" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <DockPanel Grid.Row="0" Margin="22,9,22,4" LastChildFill="False">
              <TextBlock Text="OUTPUT" Foreground="{StaticResource Faint}" FontSize="10.5" FontWeight="SemiBold" DockPanel.Dock="Left"/>
              <Button x:Name="BtnClearLog" Content="Clear" DockPanel.Dock="Right" Padding="10,3" Margin="0"/>
            </DockPanel>
            <RichTextBox x:Name="LogBox" Grid.Row="1" Margin="16,0,16,10" Background="Transparent"
                         Foreground="{StaticResource Text}" BorderThickness="0" IsReadOnly="True"
                         FontFamily="Consolas" FontSize="12"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
          </Grid>
        </Border>
      </Grid>
    </Grid>

    <!-- status bar -->
    <Border Grid.Row="2" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
      <Grid Margin="22,10">
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

    # The GUI has two hard requirements the current host may not meet, and both are
    # fixed the same way - by relaunching:
    #
    #   STA    WPF cannot run on an MTA thread. powershell.exe is STA; pwsh is not.
    #   Admin  Nearly every tweak writes to HKLM. A non-elevated window would show a
    #          catalog it mostly cannot apply, so the window is always elevated and
    #          there is no in-app "restart as admin" to explain.
    #
    # Returns $true when a replacement was started and this run should stand down.
    function Invoke-GuiRelaunch {
        param([hashtable]$BoundParameters = @{})

        $needsSta = -not (Test-StaApartment)

        # A dry run writes nothing, so demanding a UAC prompt to preview a plan would
        # be theatre. The header badge makes it obvious which mode the window is in.
        $needsAdmin = (-not $Ctx.IsAdmin) -and (-not $Ctx.DryRun)

        if (-not $needsSta -and -not $needsAdmin) { return $false }

        $reasons = @()
        if ($needsAdmin) { $reasons += 'administrator rights' }
        if ($needsSta)   { $reasons += 'an STA thread' }
        Write-Step ("Reopening the GUI with " + ($reasons -join ' and '))

        $command = Get-RelaunchCommand -BoundParameters $BoundParameters
        # Always the 5.1 host: it is STA by default and always present.
        $host51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        $start = @{
            FilePath     = $host51
            ArgumentList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-Command', $command)
            ErrorAction  = 'Stop'
        }
        # UAC is the prompt; asking first would just be a dialog about a dialog.
        if ($needsAdmin) { $start.Verb = 'RunAs' }

        Write-Log "GUI relaunch: $command"

        try {
            Start-Process @start | Out-Null
            return $true
        }
        catch {
            # Almost always the user dismissing UAC.
            Write-Err "The GUI needs administrator rights and was not granted them: $($_.Exception.Message)"
            return $true
        }
    }

    # -----------------------------------------------------------------------------
    # Small WPF helpers
    # -----------------------------------------------------------------------------

    # Console colours mapped onto the window's palette, so log output reads the same
    # as it does in the terminal.
    function ConvertTo-Brush {
        param($Color)

        # The console's sixteen colours mapped onto the window's purple palette, so
        # log output reads as part of the same design rather than a terminal pasted
        # into it. Cyan is the CLI's accent, so it lands on the purple accent here.
        $hex = switch ([string]$Color) {
            'Green'      { '#FF7EE0A6' }
            'DarkGreen'  { '#FF56A87A' }
            'Yellow'     { '#FFFFCB7A' }
            'DarkYellow' { '#FFD1A055' }
            'Red'        { '#FFFF7B94' }
            'DarkRed'    { '#FFC2536B' }
            'Cyan'       { '#FFB388FF' }
            'DarkCyan'   { '#FF7D5CC0' }
            'Magenta'    { '#FFD8B4FE' }
            'DarkMagenta'{ '#FF9268D8' }
            'White'      { '#FFF3EFFC' }
            'Gray'       { '#FFC5BDDC' }
            'DarkGray'   { '#FF8B81A8' }
            default      { '#FFEDE8F7' }
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

        if ($box.IsChecked -eq $true) { $Border.Background = New-HexBrush '#FF1D1233' }
        elseif ($Hover)               { $Border.Background = New-HexBrush '#FF120C1E' }
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
        $badge.Foreground = New-HexBrush '#FF5F5680'
        [Windows.Controls.DockPanel]::SetDock($badge, 'Right')
        $panel.Children.Add($badge) | Out-Null

        $label = New-Object Windows.Controls.TextBlock
        $label.Text = $Title.ToUpperInvariant()
        $label.FontSize = 10.5
        $label.FontWeight = 'SemiBold'
        $label.Foreground = New-HexBrush '#FF8B81A8'
        [Windows.Controls.DockPanel]::SetDock($label, 'Left')
        $panel.Children.Add($label) | Out-Null

        $rule = New-Object Windows.Controls.Border
        $rule.Height = 1
        $rule.Background = New-HexBrush '#FF241A3A'
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

        $store = @(Get-CheckedItem -Rows $Ctx.Gui.Rows.Store).Count
        $ui.BtnStoreInstall.Content = if ($store) { "Install $store" } else { 'Install selected' }
        $ui.BtnStoreInstall.IsEnabled = ($store -gt 0)
    }

    # One row: a checkbox, a primary label, a secondary line, and a status chip.
    # The catalog item rides along in .Tag so selection can be read back directly.
    function New-GuiRow {
        param(
            [Parameter(Mandatory)]$Item,
            [Parameter(Mandatory)][string]$Primary,
            [AllowEmptyString()][string]$Secondary = '',
            [AllowEmptyString()][string]$Status = '',
            [string]$StatusBrush = '#FF8B81A8',
            [string]$StatusFill = '#FF150F22',
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
        $title.Foreground = New-HexBrush '#FFEDE8F7'
        $title.FontSize = 13
        $stack.Children.Add($title) | Out-Null

        if ($Secondary) {
            $sub = New-Object Windows.Controls.TextBlock
            $sub.Text = $Secondary
            $sub.Foreground = New-HexBrush '#FF8B81A8'
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
                    'Applied' { 'applied', '#FF7EE0A6', '#FF102A1E' }
                    'Partial' { 'partial', '#FFFFCB7A', '#FF2E2410' }
                    'Action'  { 'action',  '#FFB388FF', '#FF1E1436' }
                    default   { '',        '#FF8B81A8', '#FF150F22' }
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
                $how, $ink, $fill = if ($app.scriptUrl)      { 'script',   '#FFFFCB7A', '#FF2E2410' }
                                    elseif ($app.zipUrl)     { 'archive',  '#FF8B81A8', '#FF150F22' }
                                    elseif ($app.downloadUrl){ 'download', '#FF8B81A8', '#FF150F22' }
                                    else                     { 'winget',   '#FF7D5CC0', '#FF150F22' }

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
            @{ Title = 'System tuning';               Ids = @('updates-security', 'network-better', 'network-default', 'dynamictick-off', 'dynamictick-on', 'priority-22', 'priority-default') }
            @{ Title = 'Classic control panels';      Ids = @('control-panel', 'services', 'mouse', 'keyboard', 'sound') }
        )

        # The one-click box is not here: it has the landing page to itself.
        $all = @(Get-ToolboxListActions)

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

    # The landing page's step list. Built from the real presets rather than written
    # into the XAML, so the counts cannot drift from what the box actually runs.
    function Update-GuiOneClickSteps {
        if (-not $Ctx.Gui) { return }
        $ui = $Ctx.Gui.Ui

        $ui.OneClickSteps.Children.Clear()

        # A preset that failed to load is worth saying out loud, not worth crashing
        # the page over - the other eight nav pages still work.
        $steps = $null
        try { $steps = @(Get-OneClickSteps) }
        catch {
            $ui.OneClickBlurb.Text = "The presets could not be read: $($_.Exception.Message)"
            $ui.BtnOneClick.IsEnabled = $false
            return
        }

        $number = 0
        foreach ($step in $steps) {
            $number++

            $line = New-Object Windows.Controls.Grid
            $line.Margin = New-Object Windows.Thickness 0, 0, 0, 7
            foreach ($unit in @([Windows.GridUnitType]::Auto, [Windows.GridUnitType]::Star)) {
                $column = New-Object Windows.Controls.ColumnDefinition
                $column.Width = New-Object Windows.GridLength 1, $unit
                $line.ColumnDefinitions.Add($column)
            }

            $chip = New-Object Windows.Controls.Border
            $chip.Width = 24
            $chip.Height = 24
            $chip.CornerRadius = New-Object Windows.CornerRadius 12
            $chip.Background = New-HexBrush '#FF1C1430'
            $chip.BorderBrush = New-HexBrush '#FF261B3D'
            $chip.BorderThickness = New-Object Windows.Thickness 1
            $chip.VerticalAlignment = 'Top'

            $index = New-Object Windows.Controls.TextBlock
            $index.Text = [string]$number
            $index.FontSize = 11.5
            $index.Foreground = New-HexBrush '#FFB388FF'
            $index.HorizontalAlignment = 'Center'
            $index.VerticalAlignment = 'Center'
            $chip.Child = $index

            [Windows.Controls.Grid]::SetColumn($chip, 0)
            $line.Children.Add($chip) | Out-Null

            $text = New-Object Windows.Controls.StackPanel
            $text.Margin = New-Object Windows.Thickness 11, 1, 0, 0

            $title = New-Object Windows.Controls.TextBlock
            $title.Text = $step.Title
            $title.FontSize = 13
            $title.TextWrapping = 'Wrap'
            $title.Foreground = New-HexBrush '#FFEDE8F7'
            $text.Children.Add($title) | Out-Null

            if ($step.Detail) {
                $detail = New-Object Windows.Controls.TextBlock
                $detail.Text = $step.Detail
                $detail.FontSize = 11.5
                $detail.TextWrapping = 'Wrap'
                $detail.Foreground = New-HexBrush '#FF8B81A8'
                $detail.Margin = New-Object Windows.Thickness 0, 2, 0, 0
                $text.Children.Add($detail) | Out-Null
            }

            [Windows.Controls.Grid]::SetColumn($text, 1)
            $line.Children.Add($text) | Out-Null

            $ui.OneClickSteps.Children.Add($line) | Out-Null
        }
    }

    function Update-GuiPackageRow {
        if (-not $Ctx.Gui) { return }
        $ui = $Ctx.Gui.Ui

        $ui.PackageRows.Children.Clear()

        foreach ($entry in @(Get-PackageManagerReport)) {
            $manager = $entry.Manager

            $state = 'not installed'
            $ink, $fill = '#FF8B81A8', '#FF150F22'
            if ($entry.Installed) {
                $state = 'installed'
                $ink, $fill = '#FF7EE0A6', '#FF102A1E'
                # On disk but not on this process's PATH, which was copied at
                # startup - so it works in a new terminal and not in here.
                if (-not $entry.OnPath) {
                    $state = 'new terminal'
                    $ink, $fill = '#FFFFCB7A', '#FF2E2410'
                }
            }

            $secondary = $manager.Summary
            if ($entry.Installed -and $entry.Path) { $secondary = $entry.Path }

            $row = New-GuiRow -Item $manager -Primary "$($manager.Name)   $($manager.Site)" `
                -Secondary $secondary -Status $state -StatusBrush $ink -StatusFill $fill -NoCheckBox

            # winget arrives with App Installer from the Store; scripting around
            # the Store is the kind of thing that breaks on the next Windows build.
            if (-not [string]::IsNullOrWhiteSpace($manager.InstallCommand) -and -not $entry.Installed) {
                $install = New-Object Windows.Controls.Button
                $install.Content = 'Install'
                $install.Padding = New-Object Windows.Thickness 12, 4, 12, 4
                $install.Margin = New-Object Windows.Thickness 8, 0, 0, 0
                $install.VerticalAlignment = 'Center'
                $install.Tag = $manager.Id
                [Windows.Controls.Grid]::SetColumn($install, 2)

                $install.Add_Click({
                    param($sender, $e)
                    $id = [string]$sender.Tag
                    Invoke-GuiWork -Label "installing $id" -Work { Invoke-PackageManagerInstall -Id $id | Out-Null }
                    Update-GuiPackageRow
                })

                $row.Element.Child.Children.Add($install) | Out-Null
            }

            $ui.PackageRows.Children.Add($row.Element) | Out-Null
        }
    }

    function Update-GuiCustomizationRow {
        if (-not $Ctx.Gui) { return }
        $ui = $Ctx.Gui.Ui

        $ui.CustomizationRows.Children.Clear()

        foreach ($entry in @(Get-CustomizationReport)) {
            $tool = $entry.Tool

            $state = 'not installed'
            $ink, $fill = '#FF8B81A8', '#FF150F22'
            if ($entry.Installed) {
                $state = 'installed'
                $ink, $fill = '#FF7EE0A6', '#FF102A1E'
            }

            $secondary = $tool.Summary
            if ($tool.Note) { $secondary += '   ' + $tool.Note }

            $row = New-GuiRow -Item $tool -Primary "$($tool.Name)   $($tool.Site)" `
                -Secondary $secondary -Status $state -StatusBrush $ink -StatusFill $fill -NoCheckBox

            if (-not $entry.Installed) {
                $install = New-Object Windows.Controls.Button
                $install.Content = 'Install'
                $install.Padding = New-Object Windows.Thickness 12, 4, 12, 4
                $install.Margin = New-Object Windows.Thickness 8, 0, 0, 0
                $install.VerticalAlignment = 'Center'
                $install.Tag = $tool.Id
                [Windows.Controls.Grid]::SetColumn($install, 2)

                $install.Add_Click({
                    param($sender, $e)
                    $id = [string]$sender.Tag
                    Invoke-GuiWork -Label "installing $id" -Work { Install-CustomizationTool -Id $id | Out-Null }
                    Update-GuiCustomizationRow
                })

                $row.Element.Child.Children.Add($install) | Out-Null
            }

            $ui.CustomizationRows.Children.Add($row.Element) | Out-Null
        }
    }

    # -----------------------------------------------------------------------------
    # Task manager page
    #
    # The sampling is 52-Tasks.ps1's, unchanged - this only draws it. A
    # DispatcherTimer does the refreshing, which works because Show-Gui runs a real
    # message loop through ShowDialog; the cooperative Invoke-UiEvents pumping is
    # only for long synchronous work.
    # -----------------------------------------------------------------------------

    function Set-GuiTaskTimer {
        param([bool]$Running)

        if (-not $Ctx.Gui) { return }
        if (-not $Ctx.Gui.TaskTimer) { return }

        if (-not $Running) {
            $Ctx.Gui.TaskTimer.Stop()
            return
        }

        # A stale previous sample would difference this second's counters against
        # one from whenever the page was last open, which reads as a huge spike.
        $Ctx.Gui.Monitor.PreviousStamp = $null
        Update-GuiTaskSample
        $Ctx.Gui.TaskTimer.Start()
    }

    # Percent to brush, matching the console's load bands so a red bar means the
    # same thing in both front-ends.
    function Get-GuiLoadBrush {
        param([double]$Percent)

        switch (Get-LoadBand -Percent $Percent) {
            'high'   { return (New-HexBrush '#FFFF7B94') }
            'medium' { return (New-HexBrush '#FFFFCB7A') }
            default  { return (New-HexBrush '#FFB388FF') }
        }
    }

    # The CPU history, as a filled polygon on a Canvas. Redrawn from scratch each
    # tick: 120 points is nothing, and holding a Polyline's PointCollection across
    # ticks would mean tracking it as extra window state for no gain.
    function Update-GuiCpuGraph {
        param([Parameter(Mandatory)][AllowEmptyCollection()][double[]]$History)

        if (-not $Ctx.Gui) { return }
        $canvas = $Ctx.Gui.Ui.CpuGraph

        $canvas.Children.Clear()

        $width = [double]$canvas.ActualWidth
        $height = [double]$canvas.ActualHeight
        if ($width -le 1 -or $height -le 1) { return }
        if ($History.Count -lt 2) { return }

        # Scaled to the samples in hand rather than to a fixed time axis, so the
        # graph fills the panel from the first few ticks instead of drawing a stub
        # against the right edge for the first two minutes. The console sparkline
        # pads instead - it is one character per sample there, with nothing to
        # stretch. Oldest on the left either way.
        $step = $width / ($History.Count - 1)

        $points = New-Object Windows.Media.PointCollection
        $points.Add((New-Object Windows.Point (0, $height)))
        for ($i = 0; $i -lt $History.Count; $i++) {
            $x = $i * $step
            $y = $height - (([Math]::Max(0.0, [Math]::Min(100.0, $History[$i])) / 100.0) * $height)
            $points.Add((New-Object Windows.Point ($x, $y)))
        }
        $points.Add((New-Object Windows.Point ($width, $height)))

        $fill = New-Object Windows.Media.LinearGradientBrush
        $fill.StartPoint = New-Object Windows.Point (0, 0)
        $fill.EndPoint = New-Object Windows.Point (0, 1)
        $fill.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString('#66B388FF'), 0)))
        $fill.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.ColorConverter]::ConvertFromString('#08B388FF'), 1)))

        $area = New-Object Windows.Shapes.Polygon
        $area.Points = $points
        $area.Fill = $fill
        $canvas.Children.Add($area) | Out-Null

        # The line on top, without the two baseline points the fill needed.
        $edge = New-Object Windows.Shapes.Polyline
        $edgePoints = New-Object Windows.Media.PointCollection
        for ($i = 1; $i -lt ($points.Count - 1); $i++) { $edgePoints.Add($points[$i]) }
        $edge.Points = $edgePoints
        $edge.Stroke = New-HexBrush '#FFB388FF'
        $edge.StrokeThickness = 1.4
        $canvas.Children.Add($edge) | Out-Null
    }

    # One narrow vertical bar per core, tallest to the bottom - btop's core strip.
    function Update-GuiCoreStrip {
        param([Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Cores)

        if (-not $Ctx.Gui) { return }
        $strip = $Ctx.Gui.Ui.CoreStrip

        $strip.Children.Clear()
        if ($Cores.Count -eq 0) { return }

        # Wide bars for a couple of cores, hairlines for a threadripper.
        $barWidth = 10
        if ($Cores.Count -gt 8)  { $barWidth = 6 }
        if ($Cores.Count -gt 24) { $barWidth = 3 }

        foreach ($core in $Cores) {
            $column = New-Object Windows.Controls.Grid
            $column.Width = $barWidth
            $column.Height = 54
            $column.Margin = New-Object Windows.Thickness 0, 0, 2, 0

            $track = New-Object Windows.Controls.Border
            $track.Background = New-HexBrush '#FF130E1F'
            $track.CornerRadius = New-Object Windows.CornerRadius 2
            $column.Children.Add($track) | Out-Null

            $level = New-Object Windows.Controls.Border
            $level.VerticalAlignment = 'Bottom'
            $level.CornerRadius = New-Object Windows.CornerRadius 2
            $level.Background = Get-GuiLoadBrush -Percent $core
            # A floor of one pixel, so an idle core is still a mark rather than a gap.
            $level.Height = [Math]::Max(1.0, 54.0 * [Math]::Max(0.0, [Math]::Min(100.0, $core)) / 100.0)
            $column.Children.Add($level) | Out-Null

            $strip.Children.Add($column) | Out-Null
        }
    }

    # One refresh of the whole page.
    function Update-GuiTaskSample {
        if (-not $Ctx.Gui) { return }

        $ui = $Ctx.Gui.Ui
        $monitor = $Ctx.Gui.Monitor

        Update-TaskMonitor -Monitor $monitor | Out-Null

        # ---- meters ------------------------------------------------------------
        $ui.CpuValue.Text = '{0:N0}%' -f $monitor.Cpu.Total
        $ui.CpuValue.Foreground = Get-GuiLoadBrush -Percent $monitor.Cpu.Total
        $ui.CpuBar.Value = [Math]::Max(0.0, [Math]::Min(100.0, $monitor.Cpu.Total))
        $ui.CpuBar.Foreground = Get-GuiLoadBrush -Percent $monitor.Cpu.Total
        $ui.CpuDetail.Text = '{0} cores' -f $monitor.Cores

        if ($monitor.Memory) {
            $ui.MemValue.Text = '{0:N0}%' -f $monitor.Memory.Percent
            $ui.MemValue.Foreground = Get-GuiLoadBrush -Percent $monitor.Memory.Percent
            $ui.MemBar.Value = [Math]::Max(0.0, [Math]::Min(100.0, $monitor.Memory.Percent))
            $ui.MemBar.Foreground = Get-GuiLoadBrush -Percent $monitor.Memory.Percent
            $ui.MemDetail.Text = '{0} of {1}   commit {2}' -f `
                (Format-CompactBytes $monitor.Memory.Used), (Format-CompactBytes $monitor.Memory.Total),
                (Format-CompactBytes $monitor.Memory.CommitUsed)
        }

        # The fullest volume, because that is the one about to cause a problem.
        $disks = @($monitor.Disks)
        if ($disks.Count -gt 0) {
            $worst = @($disks | Sort-Object -Property Percent -Descending)[0]
            $ui.DiskValue.Text = '{0:N0}%' -f $worst.Percent
            $ui.DiskValue.Foreground = Get-GuiLoadBrush -Percent $worst.Percent
            $ui.DiskBar.Value = [Math]::Max(0.0, [Math]::Min(100.0, $worst.Percent))
            $ui.DiskBar.Foreground = Get-GuiLoadBrush -Percent $worst.Percent

            $extra = ''
            if ($disks.Count -gt 1) { $extra = '   +{0} more' -f ($disks.Count - 1) }
            $ui.DiskDetail.Text = '{0} {1} free{2}' -f $worst.Name, (Format-CompactBytes $worst.Free), $extra
        }

        # Headline is the combined rate; the split goes underneath, where the other
        # three cards put their detail.
        $ui.NetValue.Text = Format-Rate ($monitor.Network.Received + $monitor.Network.Sent)
        $ui.NetDetail.Text = 'down {0}   up {1}' -f `
            (Format-CompactBytes $monitor.Network.Received), (Format-CompactBytes $monitor.Network.Sent)

        Update-GuiCpuGraph -History @($monitor.CpuHistory)
        Update-GuiCoreStrip -Cores @($monitor.Cpu.Cores)

        # ---- process table -----------------------------------------------------
        $rows = @(Select-TaskProcess -Processes @($monitor.Processes) -Filter $monitor.Filter)

        # Keep whatever was selected selected across the refresh: the whole
        # ItemsSource is replaced every tick, and without this the row under the
        # cursor would deselect itself once a second.
        $selectedId = $null
        if ($ui.TaskRows.SelectedItem) { $selectedId = $ui.TaskRows.SelectedItem.Id }

        $view = [System.Collections.Generic.List[object]]::new()
        foreach ($proc in $rows) {
            $cpuText = '-'
            if ($proc.CpuKnown) { $cpuText = '{0:N1}' -f $proc.Cpu }

            $view.Add([pscustomobject]@{
                Id         = $proc.Id
                Name       = $proc.Name
                CpuText    = $cpuText
                MemoryText = Format-CompactBytes $proc.WorkingSet
                Threads    = $proc.Threads
                TimeText   = Format-CpuTime $proc.CpuSeconds
            })
        }

        $ui.TaskRows.ItemsSource = @($view)

        if ($null -ne $selectedId) {
            foreach ($item in $view) {
                if ($item.Id -eq $selectedId) { $ui.TaskRows.SelectedItem = $item; break }
            }
        }

        $summary = '{0} processes' -f @($monitor.Processes).Count
        if ($monitor.Memory) { $summary += '   up ' + (Format-Uptime $monitor.Memory.BootTime) }
        if (-not $monitor.Ready) { $summary += '   sampling' }
        if ($Ctx.Gui.TaskPaused) { $summary += '   PAUSED' }
        foreach ($problem in @($monitor.Errors)) { $summary += '   ' + $problem }
        $ui.TaskSummary.Text = $summary
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
            $badge.Foreground = New-HexBrush '#FF5F5680'
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
            $accent = New-HexBrush '#FFB388FF'
            $dc.DrawRoundedRectangle($accent, $null, (New-Object Windows.Rect 0, 0, 32, 32), 7, 7)

            # A stylised M, stroked rather than typeset, so no font is involved.
            $pen = New-Object Windows.Media.Pen ((New-HexBrush '#FF14082B'), 3.4)
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
    # Store, Guides, Personalise and Settings pages
    # -----------------------------------------------------------------------------

    function Update-GuiStoreRow {
        if (-not $Ctx.Gui) { return }
        $ui = $Ctx.Gui.Ui

        $ui.StoreRows.Children.Clear()
        $built = [System.Collections.Generic.List[object]]::new()

        foreach ($app in @($Ctx.StoreApps)) {
            $installable = [bool]$app.DownloadUrl
            $ink, $fill = if ($installable) { '#FF7EE0A6', '#FF102A1E' } else { '#FF8B81A8', '#FF150F22' }

            $row = New-GuiRow -Item $app -Primary "$($app.Name)  $($app.Author)" `
                -Secondary $app.Description -Status $app.Version -StatusBrush $ink -StatusFill $fill
            # Nothing to install means nothing to tick.
            if (-not $installable) { $row.CheckBox.IsEnabled = $false }

            $ui.StoreRows.Children.Add($row.Element) | Out-Null
            $built.Add($row)
        }

        $Ctx.Gui.Rows.Store = @($built)
        Update-GuiActionState
    }

    function Update-GuiGuideRow {
        if (-not $Ctx.Gui) { return }
        $ui = $Ctx.Gui.Ui

        Initialize-GuideCatalog
        $ui.GuideRows.Children.Clear()

        $first = $true
        foreach ($category in $Ctx.GuideCategories) {
            $inCategory = @($Ctx.Guides | Where-Object { $_.category -eq $category })
            if ($inCategory.Count -eq 0) { continue }

            $ui.GuideRows.Children.Add((New-GuiGroupHeader -Title $category -Count $inCategory.Count -First:$first)) | Out-Null
            $first = $false

            foreach ($guide in $inCategory) {
                $ui.GuideRows.Children.Add((New-GuiGuideCard -Guide $guide)) | Out-Null
            }
        }
    }

    # One collapsible guide: a clickable header, and the numbered steps underneath.
    function New-GuiGuideCard {
        param([Parameter(Mandatory)]$Guide)

        $outer = New-Object Windows.Controls.StackPanel
        $outer.Margin = New-Object Windows.Thickness 0, 0, 0, 3

        $header = New-Object Windows.Controls.Border
        $header.Padding = New-Object Windows.Thickness 10, 8, 10, 8
        $header.CornerRadius = New-Object Windows.CornerRadius 5
        $header.Cursor = 'Hand'
        $header.Background = [Windows.Media.Brushes]::Transparent

        $headerStack = New-Object Windows.Controls.StackPanel

        $title = New-Object Windows.Controls.TextBlock
        $title.Text = $Guide.title
        $title.FontSize = 13
        $title.Foreground = New-HexBrush '#FFEDE8F7'
        $headerStack.Children.Add($title) | Out-Null

        $summary = New-Object Windows.Controls.TextBlock
        $summary.Text = "$($Guide.summary)   -   $(@($Guide.steps).Count) steps"
        $summary.FontSize = 11
        $summary.TextWrapping = 'Wrap'
        $summary.Foreground = New-HexBrush '#FF8B81A8'
        $summary.Margin = New-Object Windows.Thickness 0, 1, 0, 0
        $headerStack.Children.Add($summary) | Out-Null

        $header.Child = $headerStack
        $outer.Children.Add($header) | Out-Null

        $steps = New-Object Windows.Controls.StackPanel
        $steps.Margin = New-Object Windows.Thickness 14, 4, 10, 12
        $steps.Visibility = 'Collapsed'

        $list = @($Guide.steps)
        for ($i = 0; $i -lt $list.Count; $i++) {
            $line = New-Object Windows.Controls.Grid
            foreach ($unit in @([Windows.GridUnitType]::Auto, [Windows.GridUnitType]::Star)) {
                $column = New-Object Windows.Controls.ColumnDefinition
                $column.Width = New-Object Windows.GridLength 1, $unit
                $line.ColumnDefinitions.Add($column)
            }

            $number = New-Object Windows.Controls.TextBlock
            $number.Text = '{0}.' -f ($i + 1)
            $number.FontSize = 12
            $number.MinWidth = 24
            $number.Foreground = New-HexBrush '#FFB388FF'
            $number.VerticalAlignment = 'Top'
            [Windows.Controls.Grid]::SetColumn($number, 0)
            $line.Children.Add($number) | Out-Null

            $text = New-Object Windows.Controls.TextBlock
            # WPF renders the source typography fine, so no transliteration here.
            $text.Text = [string]$list[$i]
            $text.FontSize = 12
            $text.TextWrapping = 'Wrap'
            $text.Foreground = New-HexBrush '#FFC5BDDC'
            $text.Margin = New-Object Windows.Thickness 6, 0, 0, 6
            [Windows.Controls.Grid]::SetColumn($text, 1)
            $line.Children.Add($text) | Out-Null

            $steps.Children.Add($line) | Out-Null
        }

        $outer.Children.Add($steps) | Out-Null

        # The steps panel is the sibling after the header, reached from $sender.
        $header.Add_MouseLeftButtonUp({
            param($sender, $e)
            $panel = $sender.Parent
            $body = $panel.Children[1]
            $body.Visibility = if ($body.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
        })
        $header.Add_MouseEnter({ param($sender, $e) $sender.Background = New-HexBrush '#FF120C1E' })
        $header.Add_MouseLeave({ param($sender, $e) $sender.Background = [Windows.Media.Brushes]::Transparent })

        return $outer
    }

    function Update-GuiCsFolderText {
        if (-not $Ctx.Gui) { return }

        $folders = @(Find-CsConfigFolder)
        $Ctx.Gui.Ui.CsFolderText.Text = if ($folders.Count -eq 0) {
            'No Counter-Strike cfg folder found. Is it installed through Steam?'
        }
        else {
            "Found $($folders.Count) cfg folder(s):" + [Environment]::NewLine + ($folders -join [Environment]::NewLine)
        }
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
            'VersionText', 'CatalogChip', 'DryRunBadge',
            'NavList', 'OneClickPanel', 'TasksPanel', 'TweaksPanel', 'AppsPanel', 'ToolboxPanel', 'ProfilesPanel',
            'StorePanel', 'GuidesPanel', 'PersonalizePanel', 'SettingsPanel',
            'PackagesPanel', 'PackageRows',
            'CustomizationPanel', 'CustomizationRows',
            'OneClickSteps', 'OneClickBlurb', 'BtnOneClick', 'BtnOneClickToolbox',
            'TaskSummary', 'CpuValue', 'CpuBar', 'CpuDetail', 'MemValue', 'MemBar', 'MemDetail',
            'DiskValue', 'DiskBar', 'DiskDetail', 'NetValue', 'NetDetail',
            'CpuGraph', 'CoreStrip', 'TaskRows', 'TaskSearch', 'TaskSort', 'BtnTaskPause', 'BtnTaskKill',
            'StoreRows', 'BtnStoreRefresh', 'BtnStoreInstall', 'GuideRows',
            'BtnCursorInstall', 'BtnCursorRestore', 'WallpaperStyle', 'BtnWallpaper',
            'CsFolderText', 'BtnCsDefault', 'BtnCsFile', 'BtnCsLaunch',
            'InstallPath', 'BtnBrowseInstallPath', 'GitHubToken', 'BtnSaveSettings', 'BtnOpenStateFolder',
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
            Rows      = [pscustomobject]@{ Tweaks = @(); Apps = @(); Toolbox = @(); Store = @() }
            # Filled in below. Lets a handler say which page it wants by name
            # instead of hard-coding an index into the sidebar.
            NavNames  = @()

            # Task manager state. It lives here rather than in the handlers for the
            # reason at the top of this file: a handler runs long after the function
            # that registered it returned, so it can only reach $Ctx.
            Monitor    = New-TaskMonitor
            TaskTimer  = $null
            TaskPaused = $false
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
        Initialize-GuideCatalog

        # Order has to match the ListBoxItems in the XAML and the $panels array in
        # the SelectionChanged handler. -1 means "no count worth showing".
        $navNames  = @('One click', 'Tasks', 'Tweaks', 'Apps', 'Package managers', 'Store', 'Toolbox', 'Guides', 'Personalise', 'Customization', 'Profiles', 'Settings')
        $navCounts = @(-1, -1, $Ctx.Tweaks.Count, $Ctx.Apps.Count, @(Get-PackageManagers).Count, -1, @(Get-ToolboxListActions).Count, $Ctx.Guides.Count, -1, @(Get-CustomizationTools).Count, -1, -1)

        # The item Content becomes a DockPanel below, so the labels are no longer
        # readable off the ListBox. Keep them where a handler can still find them.
        $Ctx.Gui.NavNames = $navNames

        if ($ui.NavList.Items.Count -ne $navNames.Count) {
            Write-Log "Nav has $($ui.NavList.Items.Count) items but $($navNames.Count) names." 'WARN'
        }

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

        # The window is always elevated, so there is nothing to report and no button
        # to offer. Dry run is a CLI flag only; surface it read-only when it is on,
        # so a dry run never looks like a real one.
        if ($Ctx.DryRun) { $ui.DryRunBadge.Visibility = 'Visible' }

        $ui.BtnClearLog.Add_Click({ if ($Ctx.Gui) { $Ctx.Gui.Paragraph.Inlines.Clear() } })

        # ---- navigation --------------------------------------------------------
        $ui.NavList.Add_SelectionChanged({
            param($sender, $e)
            if (-not $Ctx.Gui) { return }

            $panels = @($Ctx.Gui.Ui.OneClickPanel, $Ctx.Gui.Ui.TasksPanel, $Ctx.Gui.Ui.TweaksPanel,
                        $Ctx.Gui.Ui.AppsPanel, $Ctx.Gui.Ui.PackagesPanel, $Ctx.Gui.Ui.StorePanel,
                        $Ctx.Gui.Ui.ToolboxPanel, $Ctx.Gui.Ui.GuidesPanel, $Ctx.Gui.Ui.PersonalizePanel,
                        $Ctx.Gui.Ui.CustomizationPanel, $Ctx.Gui.Ui.ProfilesPanel, $Ctx.Gui.Ui.SettingsPanel)
            for ($i = 0; $i -lt $panels.Count; $i++) {
                $panels[$i].Visibility = if ($i -eq $sender.SelectedIndex) { 'Visible' } else { 'Collapsed' }
            }

            # Sampling costs a CIM round trip a second, so it only runs while the
            # page is on screen. Leaving the page stops the clock; coming back takes
            # a fresh baseline rather than differencing against a minutes-old one.
            Set-GuiTaskTimer -Running ($Ctx.Gui.Ui.TasksPanel.Visibility -eq 'Visible')
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

        # ---- task manager ------------------------------------------------------
        foreach ($label in @('CPU', 'Memory', 'PID', 'Name')) { $ui.TaskSort.Items.Add($label) | Out-Null }
        $ui.TaskSort.SelectedIndex = 0

        $ui.TaskSort.Add_SelectionChanged({
            param($sender, $e)
            if (-not $Ctx.Gui) { return }

            $Ctx.Gui.Monitor.SortKey = switch ([string]$sender.SelectedItem) {
                'Memory' { 'mem' }
                'PID'    { 'pid' }
                'Name'   { 'name' }
                default  { 'cpu' }
            }
            # Re-sort what we already have rather than waiting a whole tick.
            $Ctx.Gui.Monitor.Processes = @(Sort-TaskProcess -Processes @($Ctx.Gui.Monitor.Processes) -Key $Ctx.Gui.Monitor.SortKey)
            Update-GuiTaskSample
        })

        $ui.TaskSearch.Add_TextChanged({
            param($sender, $e)
            if (-not $Ctx.Gui) { return }
            $Ctx.Gui.Monitor.Filter = [string]$sender.Text
            Update-GuiTaskSample
        })

        $ui.BtnTaskPause.Add_Click({
            param($sender, $e)
            if (-not $Ctx.Gui) { return }

            $Ctx.Gui.TaskPaused = -not $Ctx.Gui.TaskPaused
            if ($Ctx.Gui.TaskPaused) {
                $Ctx.Gui.TaskTimer.Stop()
                $sender.Content = 'Resume'
            }
            else {
                $sender.Content = 'Pause'
                # Fresh baseline, same reason as Set-GuiTaskTimer.
                $Ctx.Gui.Monitor.PreviousStamp = $null
                Update-GuiTaskSample
                $Ctx.Gui.TaskTimer.Start()
            }
        })

        $ui.BtnTaskKill.Add_Click({
            param($sender, $e)
            if (-not $Ctx.Gui) { return }

            $selected = $Ctx.Gui.Ui.TaskRows.SelectedItem
            if (-not $selected) { $Ctx.Gui.Ui.StatusText.Text = 'Select a process first.'; return }

            # Hold the clock while the confirm dialog is up: a tick landing mid-modal
            # would replace the ItemsSource under the row being asked about.
            $wasRunning = $Ctx.Gui.TaskTimer.IsEnabled
            $Ctx.Gui.TaskTimer.Stop()

            try {
                Stop-TaskProcess -Id ([int]$selected.Id) -Name ([string]$selected.Name) | Out-Null
                $Ctx.Gui.Monitor.PreviousStamp = $null
                Update-GuiTaskSample
            }
            finally {
                if ($wasRunning -and -not $Ctx.Gui.TaskPaused) { $Ctx.Gui.TaskTimer.Start() }
            }
        })

        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds(1)
        $timer.Add_Tick({ Update-GuiTaskSample })
        $Ctx.Gui.TaskTimer = $timer

        # ---- actions -----------------------------------------------------------
        $ui.BtnOneClick.Add_Click({
            Invoke-GuiWork -Label 'one-click debloat box' -Work { Invoke-ToolboxAction -Id 'oneclick' }
            # Steps 3 to 6 write registry and boot state the Tweaks page reports on.
            Update-GuiTweakRow
        })

        # Not a duplicate of the nav: someone reading the landing page and deciding
        # they want fewer steps should not have to find the sidebar.
        $ui.BtnOneClickToolbox.Add_Click({
            if (-not $Ctx.Gui) { return }
            $index = [array]::IndexOf([string[]]@($Ctx.Gui.NavNames), 'Toolbox')
            if ($index -ge 0) { $Ctx.Gui.Ui.NavList.SelectedIndex = $index }
        })

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

        # ---- store -------------------------------------------------------------
        # Loaded on demand: listing two orgs and every repo's latest release is a
        # few dozen API calls, which has no business happening at window-open.
        $ui.BtnStoreRefresh.Add_Click({
            Invoke-GuiWork -Label 'loading store' -Work { Get-StoreApp -Refresh | Out-Null }
            Update-GuiStoreRow
            $Ctx.Gui.Ui.BtnStoreRefresh.Content = 'Reload'
        })

        $ui.BtnStoreInstall.Add_Click({
            $selected = Get-CheckedItem -Rows $Ctx.Gui.Rows.Store
            if ($selected.Count -eq 0) { $Ctx.Gui.Ui.StatusText.Text = 'Nothing selected.'; return }
            Invoke-GuiWork -Label 'installing store apps' -Work { Invoke-StoreInstall -Apps $selected }
        })

        # ---- personalise -------------------------------------------------------
        $ui.BtnCursorInstall.Add_Click({
            $dialog = New-Object Windows.Forms.FolderBrowserDialog
            $dialog.Description = 'Pick a folder containing .cur / .ani files'
            if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }

            $folder = $dialog.SelectedPath
            Invoke-GuiWork -Label 'installing cursors' -Work {
                Install-CursorScheme -Path $folder -SchemeName (Split-Path -Leaf $folder)
            }
        })

        $ui.BtnCursorRestore.Add_Click({
            Invoke-GuiWork -Label 'restoring cursors' -Work { Restore-DefaultCursor }
        })

        foreach ($style in @('Fill', 'Fit', 'Stretch', 'Tile', 'Center', 'Span')) {
            $ui.WallpaperStyle.Items.Add($style) | Out-Null
        }
        $ui.WallpaperStyle.SelectedIndex = 0

        $ui.BtnWallpaper.Add_Click({
            $dialog = New-Object Windows.Forms.OpenFileDialog
            $dialog.Filter = 'Images|*.jpg;*.jpeg;*.png;*.bmp;*.gif|All files (*.*)|*.*'
            if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }

            $image = $dialog.FileName
            $style = [string]$Ctx.Gui.Ui.WallpaperStyle.SelectedItem
            Invoke-GuiWork -Label 'setting wallpaper' -Work { Set-Wallpaper -Path $image -Style $style }
        })

        $ui.BtnCsDefault.Add_Click({
            Invoke-GuiWork -Label 'installing config' -Work { Install-CsConfig }
            Update-GuiCsFolderText
        })

        $ui.BtnCsFile.Add_Click({
            $dialog = New-Object Windows.Forms.OpenFileDialog
            $dialog.Filter = 'Counter-Strike config (*.cfg)|*.cfg'
            if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }

            $cfg = $dialog.FileName
            Invoke-GuiWork -Label 'installing config' -Work { Install-CsConfig -LocalPath $cfg }
        })

        $ui.BtnCsLaunch.Add_Click({
            $options = Get-CsLaunchOption
            [Windows.Clipboard]::SetText($options)
            $Ctx.Gui.Ui.StatusText.Text = "Copied: $options"
            Write-Ok "Launch options copied to the clipboard: $options"
        })

        # ---- settings ----------------------------------------------------------
        $ui.InstallPath.Text = Get-StoreInstallRoot
        if (Get-MoscoviumSetting -Name 'GitHubToken') { $ui.GitHubToken.Password = '' }

        $ui.BtnBrowseInstallPath.Add_Click({
            $dialog = New-Object Windows.Forms.FolderBrowserDialog
            $dialog.Description = 'Where store apps should be installed'
            if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $Ctx.Gui.Ui.InstallPath.Text = $dialog.SelectedPath }
        })

        $ui.BtnSaveSettings.Add_Click({
            $ui = $Ctx.Gui.Ui
            Set-MoscoviumSetting -Name 'AppsInstallPath' -Value ([string]$ui.InstallPath.Text)

            # An empty box means "leave the stored token alone", not "clear it" - the
            # box is never pre-filled with a secret, so blank is the normal state.
            $token = [string]$ui.GitHubToken.Password
            if ($token) {
                Set-MoscoviumSetting -Name 'GitHubToken' -Value $token
                $ui.GitHubToken.Password = ''
            }

            $ui.StatusText.Text = 'Settings saved.'
        })

        $ui.BtnOpenStateFolder.Add_Click({
            Initialize-State
            Start-Process -FilePath 'explorer.exe' -ArgumentList $Ctx.StateDir | Out-Null
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
            # The timer holds a reference to the dispatcher, so a running one keeps
            # the sampling going after the window is gone.
            if ($Ctx.Gui -and $Ctx.Gui.TaskTimer) { $Ctx.Gui.TaskTimer.Stop() }
            if ($Ctx.Gui) { $Ctx.Theme.Glyph = $Ctx.Gui.Glyphs }
            $Ctx.Gui = $null
            $Ctx.Sink = $null
            $Ctx.ProgressSink = $null
            $Ctx.ConfirmSink = $null
        })

        # ---- go ----------------------------------------------------------------
        Update-GuiOneClickSteps
        Update-GuiPackageRow
        Update-GuiCustomizationRow
        Update-GuiTweakRow
        Update-GuiAppRow
        Update-GuiToolboxRow
        Update-GuiGuideRow
        Update-GuiCsFolderText

        $ui.StatusText.Text = 'Ready'

        Write-Rule -Title 'Moscovium' -Suffix "v$($Ctx.Version)"
        Write-Info "$($Ctx.Tweaks.Count) tweaks, $($Ctx.Apps.Count) apps loaded."

        # No elevation notice: Show-Gui guarantees it, so saying so would be noise.
        if ($Ctx.DryRun) { Write-Warn 'Dry run - nothing will actually be changed.' }

        [pscustomobject]@{
            Window   = $window
            Ui       = $ui
            Rows     = $Ctx.Gui.Rows
            NavNames = $Ctx.Gui.NavNames
        }
    }

    function Show-Gui {
        param([hashtable]$BoundParameters = @{})

        # Elevated and STA or not at all - see Invoke-GuiRelaunch.
        if (Invoke-GuiRelaunch -BoundParameters $BoundParameters) { return 0 }

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
        $buttons = @('BtnOneClick', 'BtnApply', 'BtnRevert', 'BtnInstall', 'BtnStoreInstall', 'BtnStoreRefresh', 'BtnRunProfile', 'BtnSaveProfile')
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
        Write-Line '    -Tasks             live task manager: CPU, memory, disk, network, processes' -Color Gray
        Write-Line '    -Toolbox <id>      run a toolbox action (see -List toolbox)' -Color Gray
        Write-Line '    -InstallManager <id>  install a package manager: choco or scoop' -Color Gray
        Write-Line '    -Customize <id>    install Open-Shell, Nilesoft Shell, StartAllBack or ExplorerPatcher' -Color Gray
        Write-Line '    -Profile <path>    run a saved setup profile' -Color Gray
        Write-Line '    -SaveProfile <path>  write the current -Apply/-Install selection as a profile' -Color Gray
        Write-Line '    -List <what>       list tweaks, apps, toolbox, packages, or backups' -Color Gray
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
                '^packages?$' { Show-PackageManagerCatalog }
                '^managers?$' { Show-PackageManagerCatalog }
                '^custom'     { Show-CustomizationCatalog }
                '^categor'    {
                    Write-SectionHeading 'Tweak categories'
                    Format-Columns -Items $Ctx.TweakCategories
                    Write-SectionHeading 'App categories'
                    Format-Columns -Items $Ctx.AppCategories
                }
                default {
                    Write-Err "Don't know how to list '$item'. Try: tweaks, apps, toolbox, packages, customization, backups, categories."
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
        $mutating = @('Apply', 'Revert', 'Install', 'Toolbox', 'Customize', 'Profile', 'UpgradeAll', 'WindowsUpdate', 'VCRuntimes')
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

        # Deliberately not in $mutating above. Chocolatey's installer needs
        # administrator and gets its own elevated child process; Scoop's *refuses*
        # to run elevated, so pre-elevating Moscovium would make the per-user
        # install impossible. Each child process gets the privileges it needs.
        if (& $has 'InstallManager') {
            Invoke-PackageManagerInstall -Id $Bound['InstallManager'] | Out-Null
            $didSomething = $true
        }
        # In $mutating above: these are vendor installers writing to Program Files.
        if (& $has 'Customize') {
            Install-CustomizationTool -Id $Bound['Customize'] | Out-Null
            $didSomething = $true
        }

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

} $PSBoundParameters '1.2.0' $SourceUrl 'a1f0fc265f'