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
    # there. It waits, so the install has finished before we report on it.
    $ran = Invoke-RemoteScript -Url $App.scriptUrl -Label $App.name

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
