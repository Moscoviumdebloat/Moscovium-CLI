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
