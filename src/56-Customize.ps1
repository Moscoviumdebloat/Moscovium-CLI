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
# The trial reset IS now ported - it lives in src/40-Toolbox.ps1 as the
# startallback-reset action. Installing StartAllBack is here; its licence
# terms are its own business after that.
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
