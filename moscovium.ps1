<#
    Moscovium CLI v1.0.0
    Windows debloat and setup toolbox - the command line companion to
    https://github.com/Moscoviumdebloat/Moscovium

        irm https://moscovium.win | iex

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
    param($Bound, [string]$BuildVersion, [string]$Source)

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
            Write-Line '  . ' -Color DarkYellow -NoNewline
            Write-Line "$($Tweak.name)" -Color DarkYellow

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
            Write-Line '  . ' -Color DarkYellow -NoNewline
            Write-Line "$($Tweak.name)" -Color DarkYellow
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

            Write-SectionHeading $category

            foreach ($tweak in $inCategory) {
                $status = Get-TweakStatus -Tweak $tweak

                $glyph, $color = switch ($status) {
                    'Applied'    { '[x]', 'Green' }
                    'Partial'    { '[~]', 'Yellow' }
                    'NotApplied' { '[ ]', 'DarkGray' }
                    'Action'     { '[>]', 'DarkCyan' }
                    default      { '[?]', 'DarkGray' }
                }

                # The longest catalog name is 43 characters; pad past it so the
                # status column never runs into the name.
                Write-Line "  $glyph " -Color $color -NoNewline
                Write-Line $tweak.name.PadRight(46) -NoNewline
                Write-Line $status -Color $color
            }
        }

        Write-Line ''
        Write-Info 'Legend: [x] applied  [~] partially applied  [ ] not applied  [>] one-shot action'
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
            [switch]$Quiet
        )

        Write-Log "winget $($Arguments -join ' ')"

        if ($Quiet) {
            & winget.exe @Arguments 2>&1 | Out-Null
        }
        else {
            # Let winget render its own progress; it is better than anything we would
            # print, and the exit code is still available afterwards.
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

    function Save-RemoteFile {
        param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Destination)

        # TLS 1.2 is not the default in Windows PowerShell 5.1 and several vendor
        # CDNs refuse anything older.
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

        $progress = $ProgressPreference
        try {
            # Invoke-WebRequest's progress bar makes large downloads roughly an order
            # of magnitude slower in 5.1.
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 600 -Headers @{
                'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Moscovium-CLI'
            }
        }
        finally {
            $ProgressPreference = $progress
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

        $size = Save-RemoteFile -Url $url -Destination $destination
        Write-Info ('{0:N1} MB -> {1}' -f ($size / 1MB), $destination)

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
            Save-RemoteFile -Url $App.zipUrl -Destination $zipPath | Out-Null

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
        # there. -Wait because an install should finish before we report on it.
        $ran = Invoke-RemoteScript -Url $App.scriptUrl -Label $App.name -Wait

        if (-not $ran) { $Ctx.Skipped++ }
        return $ran
    }

    function Install-App {
        param([Parameter(Mandatory)]$App)

        if ($Ctx.DryRun) {
            Write-Line '  . ' -Color DarkYellow -NoNewline
            Write-Line $App.name -Color DarkYellow

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

            $result = Invoke-Winget -Arguments $arguments -Quiet

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
            [string[]]$ScriptArguments = @()
        )

        $safeUrl = $Url -replace "'", "''"

        if (-not $ScriptArguments -or $ScriptArguments.Count -eq 0) {
            return "irm '$safeUrl' | iex"
        }

        # Switches pass through bare; values get quoted, since paths contain spaces.
        $rendered = foreach ($argument in $ScriptArguments) {
            if ($argument -match '^-[A-Za-z]') { $argument }
            else { "'" + ($argument -replace "'", "''") + "'" }
        }

        "& ([scriptblock]::Create((irm '$safeUrl'))) $($rendered -join ' ')"
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
            [string[]]$ScriptArguments = @(),
            [switch]$Wait
        )

        $command = New-RemoteScriptCommand -Url $Url -ScriptArguments $ScriptArguments

        $where = if ($Ctx.IsAdmin) { 'a new window, elevated as you already are' }
                 else { 'a new window, which will ask for administrator rights' }

        Write-Line ''
        Write-Warn "$Label runs a script published by a third party:"
        Write-Line "      $Url" -Color White
        Write-Info 'Moscovium does not review or pin the contents of that script.'
        Write-Line ''
        Write-Info "It will run in $where as:"
        Write-Line "      $command" -Color Gray

        if (-not (Confirm-Action "Run it now?")) {
            Write-Warn "$Label - skipped."
            return $false
        }

        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
        # Keep the window open afterwards so the user can read what happened; an
        # install we are waiting on should close on its own instead.
        if (-not $Wait) { $arguments += '-NoExit' }
        $arguments += @('-Command', $command)

        $start = @{
            FilePath     = Get-PowerShellHost
            ArgumentList = $arguments
            ErrorAction  = 'Stop'
        }
        # Already elevated: the child inherits it. Otherwise ask, rather than letting
        # the script discover it is unelevated and relaunch itself.
        if (-not $Ctx.IsAdmin) { $start.Verb = 'RunAs' }
        if ($Wait) { $start.Wait = $true; $start.PassThru = $true }

        Write-Step "Launching $Label"
        Write-Log "remote script: $command"

        $process = Start-Process @start

        if ($Wait) {
            if ($process -and $process.ExitCode -ne 0) {
                Write-Warn "$Label exited with code $($process.ExitCode)."
                return $false
            }
            Write-Ok "$Label finished."
        }
        else {
            Write-Ok "$Label is running in its own window."
        }

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
            $text = $text.PadRight($width)

            if ($line.Color -and $Ctx.UseColor) { Write-Host $text -ForegroundColor $line.Color }
            else { Write-Host $text }
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
        param([AllowEmptyString()][string]$Text = '', $Color = $null)
        [pscustomobject]@{ Text = $Text; Color = $Color }
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

            $lines = [System.Collections.Generic.List[object]]::new()
            $lines.Add((New-FrameLine))
            $lines.Add((New-FrameLine "  $Title" 'Cyan'))
            if ($Subtitle) { $lines.Add((New-FrameLine "  $Subtitle" 'DarkGray')) }
            $lines.Add((New-FrameLine))

            if ($visible.Count -eq 0) {
                $lines.Add((New-FrameLine "    no match for '$filter'" 'DarkYellow'))
            }

            $last = [Math]::Min($offset + $viewport, $visible.Count)
            for ($row = $offset; $row -lt $last; $row++) {
                $index = $visible[$row]
                $isCursor = ($row -eq $cursor)

                $marker = if ($SingleSelect) { '  ' }
                          elseif ($selected.Contains($index)) { '[x]' }
                          else { '[ ]' }

                $pointer = if ($isCursor) { '>' } else { ' ' }
                $text = ' {0} {1} {2}' -f $pointer, $marker, (& $Label $Items[$index])

                if ($Sublabel) {
                    $extra = (& $Sublabel $Items[$index])
                    if ($extra) { $text = $text.PadRight(46) + $extra }
                }

                $color = if ($isCursor) { 'Black' } elseif ($selected.Contains($index)) { 'Green' } else { 'Gray' }

                if ($isCursor -and $Ctx.UseColor) {
                    # No background control in this frame model, so mark the cursor
                    # row with brightness instead of a highlight bar.
                    $lines.Add((New-FrameLine $text 'White'))
                }
                else {
                    $lines.Add((New-FrameLine $text $color))
                }
            }

            $lines.Add((New-FrameLine))

            $position = if ($visible.Count -gt 0) { "$($cursor + 1)/$($visible.Count)" } else { '0/0' }
            $status = "  $position"
            if (-not $SingleSelect) { $status += "   selected: $($selected.Count)" }
            if ($filter) { $status += "   filter: $filter" }
            $lines.Add((New-FrameLine $status 'DarkGray'))

            $keys = if ($SingleSelect) {
                '  up/down move   enter choose   / filter   esc back'
            }
            else {
                '  up/down move   space toggle   a all   n none   i invert   / filter   enter confirm   esc back'
            }
            $lines.Add((New-FrameLine $keys 'DarkGray'))

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
                'quit'     { return }
            }
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
            Write-Line $Ctx.Version
            return 0
        }

        Initialize-Catalog

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

    $Ctx = New-MoscoviumContext -Version $BuildVersion -SourceUrl $Source `
        -DryRun:(Test-Flag 'DryRun') `
        -AssumeYes:(Test-Flag 'Yes') `
        -NoColor:(Test-Flag 'NoColor')

    Initialize-State

    if (-not (Test-Flag 'NoBanner') -and -not (Test-Flag 'Version') -and -not (Test-Flag 'Help')) {
        Write-Banner
    }

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

} $PSBoundParameters '1.0.0' $SourceUrl