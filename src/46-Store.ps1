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
