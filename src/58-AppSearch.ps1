# =============================================================================
# App search: one query across winget, Chocolatey and Scoop.
#
# Each of the three is reached the way it can actually be reached, which is not
# the same way for all three:
#
#   winget      Its CLI. There is no machine-readable output for `search` - no
#               --output json, checked on 1.29 - so the table is parsed. Column
#               positions come from the header rather than from column names,
#               because those are localised: a Spanish install prints
#               'Nombre  Id  Version  Coincidencia'.
#
#   Chocolatey  The community feed's OData endpoint. `choco search` hits the
#               same repository, so going straight to the feed means search
#               works whether or not Chocolatey is installed - which matters,
#               because searching for something is how you decide whether you
#               want the manager at all.
#
#   Scoop       The official Main and Extras bucket manifests, listed from
#               GitHub. Same reasoning: no install needed. A bucket listing is
#               names only, so Scoop results carry no version - fetching 4000
#               manifests to show one column would be absurd.
#
# Installing is deliberately not uniform either, and for the reason in
# 54-Packages: Chocolatey needs administrator and Scoop refuses it.
# =============================================================================

$ChocolateySearchUrl = 'https://community.chocolatey.org/api/v2/Search()'

# Main and Extras are the two buckets Scoop ships with; Extras needs adding
# before its apps can be installed, which Install-SearchResult handles.
$ScoopBuckets = @(
    [pscustomobject]@{ Name = 'main';   Repo = 'ScoopInstaller/Main';   Branch = 'master' }
    [pscustomobject]@{ Name = 'extras'; Repo = 'ScoopInstaller/Extras'; Branch = 'master' }
)

function Get-AppSearchManagers {
    @(
        [pscustomobject]@{
            Id = 'winget'; Name = 'winget'
            # Whether searching needs the manager on this machine, as opposed
            # to installing from it.
            NeedsLocal = $true
            Note = 'Ships with Windows.'
        }
        [pscustomobject]@{
            Id = 'choco'; Name = 'Chocolatey'
            NeedsLocal = $false
            Note = 'Searched through the community feed, so no install needed to look.'
        }
        [pscustomobject]@{
            Id = 'scoop'; Name = 'Scoop'
            NeedsLocal = $false
            Note = 'Official main and extras buckets. No version column - a bucket listing is names only.'
        }
    )
}

function New-SearchResult {
    param(
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][string]$Id,
        [AllowEmptyString()][string]$Name = '',
        [AllowEmptyString()][string]$Version = '',
        [AllowEmptyString()][string]$Detail = '',
        [AllowEmptyString()][string]$Bucket = ''
    )

    $display = $Name
    if ([string]::IsNullOrWhiteSpace($display)) { $display = $Id }

    [pscustomobject]@{
        Manager = $Manager
        Id      = $Id
        Name    = $display
        Version = $Version
        Detail  = $Detail
        Bucket  = $Bucket
    }
}

# -----------------------------------------------------------------------------
# winget
# -----------------------------------------------------------------------------

# winget's table, as rows of trimmed fields.
#
# The header line sits directly above a run of dashes, and a column begins at
# every non-space that follows two spaces. Deriving the boundaries that way
# rather than from the column names keeps this working on a non-English
# install, and slicing by position rather than splitting on whitespace keeps
# names with spaces in one piece - 'Advanced Archive Password Recovery' is one
# field, not five.
function Split-WingetTable {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $lines = @($Text -split "`r?`n")

    $dashIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-{5,}\s*$') { $dashIndex = $i; break }
    }
    # No dashes means no table: an empty result, or a message like 'No package
    # found matching input criteria.'
    if ($dashIndex -lt 1) { return @() }

    $header = $lines[$dashIndex - 1]
    $space = [char]' '

    $starts = [System.Collections.Generic.List[int]]::new()
    $starts.Add(0)
    for ($i = 2; $i -lt $header.Length; $i++) {
        if ($header[$i] -ne $space -and $header[$i - 1] -eq $space -and $header[$i - 2] -eq $space) {
            $starts.Add($i)
        }
    }

    $rows = [System.Collections.Generic.List[object]]::new()

    for ($i = $dashIndex + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $fields = [System.Collections.Generic.List[string]]::new()
        for ($column = 0; $column -lt $starts.Count; $column++) {
            $from = $starts[$column]
            if ($from -ge $line.Length) { $fields.Add(''); continue }

            $to = $line.Length
            if ($column -lt ($starts.Count - 1)) { $to = [Math]::Min($starts[$column + 1], $line.Length) }
            $fields.Add($line.Substring($from, $to - $from).Trim())
        }

        $rows.Add(@($fields))
    }

    return @($rows)
}

function Search-WingetPackage {
    param([Parameter(Mandatory)][string]$Query, [int]$Limit = 20)

    if (-not (Test-WingetAvailable)) { return @() }

    # --source winget pins it to the community repository, which also drops the
    # Source column and keeps the layout predictable. msstore results cannot be
    # installed non-interactively anyway.
    $arguments = @(
        'search', $Query, '--source', 'winget', '--count', [string]$Limit,
        '--accept-source-agreements', '--disable-interactivity'
    )

    $output = ''
    try { $output = (& winget.exe @arguments 2>&1 | Out-String) }
    catch { return @() }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($fields in @(Split-WingetTable -Text $output)) {
        # Name, Id, Version, then Match - which is why the id is field 1.
        if (@($fields).Count -lt 2) { continue }

        $id = $fields[1]
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        # When --count truncates the results winget prints a note *below* the
        # table - '<additional entries truncated due to result limit>' - and
        # slicing that by column positions yields a row whose id reads
        # 'entries truncated due'. A winget id never contains whitespace, so
        # that one rule drops the note without having to match its wording,
        # which is localised.
        #
        # The ellipsis check catches the other way a row can be unusable: an id
        # too long for its column comes back truncated, and installing a
        # truncated id would just fail.
        if ($id -match '\s') { continue }
        if ($id.Contains([char]0x2026)) { continue }

        $version = ''
        if (@($fields).Count -ge 3) { $version = $fields[2] }

        $results.Add((New-SearchResult -Manager 'winget' -Id $id -Name $fields[0] -Version $version))
    }

    return @($results)
}

# -----------------------------------------------------------------------------
# Chocolatey
# -----------------------------------------------------------------------------

function Search-ChocolateyPackage {
    param([Parameter(Mandatory)][string]$Query, [int]$Limit = 20)

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    # Doubled quotes escape the OData string literal; the URL escaping is on top
    # of that.
    $term = [Uri]::EscapeDataString(($Query -replace "'", "''"))
    $url = "$ChocolateySearchUrl" +
           "?searchTerm='$term'&targetFramework=''&includePrerelease=false" +
           "&`$filter=IsLatestVersion&`$top=$Limit"

    $document = $null
    try {
        $client = New-Object Net.WebClient
        $client.Headers.Add('User-Agent', 'Moscovium-CLI')
        $document = [xml]$client.DownloadString($url)
    }
    catch { throw "Chocolatey search failed: $($_.Exception.Message)" }

    $namespaces = New-Object Xml.XmlNamespaceManager $document.NameTable
    $namespaces.AddNamespace('a', 'http://www.w3.org/2005/Atom')
    $namespaces.AddNamespace('d', 'http://schemas.microsoft.com/ado/2007/08/dataservices')

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in @($document.SelectNodes('//a:entry', $namespaces))) {
        # The package id is the Atom <title>. There is no d:Id property on this
        # feed - d:Title is the human name ('7-Zip' for the id '7zip').
        $id = $entry.SelectSingleNode('a:title', $namespaces)
        if ($null -eq $id -or [string]::IsNullOrWhiteSpace($id.InnerText)) { continue }

        $version = $entry.SelectSingleNode('.//d:Version', $namespaces)
        $title = $entry.SelectSingleNode('.//d:Title', $namespaces)
        $summary = $entry.SelectSingleNode('a:summary', $namespaces)

        $name = ''
        if ($null -ne $title) { $name = $title.InnerText }

        $detail = ''
        if ($null -ne $summary) { $detail = ($summary.InnerText -replace '\s+', ' ').Trim() }

        $number = ''
        if ($null -ne $version) { $number = $version.InnerText }

        $results.Add((New-SearchResult -Manager 'choco' -Id $id.InnerText -Name $name -Version $number -Detail $detail))
    }

    return @($results)
}

# -----------------------------------------------------------------------------
# Scoop
# -----------------------------------------------------------------------------

# Every manifest name in the official buckets, cached on the context for the
# session: two GitHub calls and about 4000 names, which is not worth repeating
# per keystroke.
function Get-ScoopManifest {
    param([switch]$Refresh)

    if (-not $Refresh -and $null -ne $Ctx.ScoopManifests) { return @($Ctx.ScoopManifests) }

    $manifests = [System.Collections.Generic.List[object]]::new()

    foreach ($bucket in $ScoopBuckets) {
        $tree = Invoke-GitHubApi -Path "/repos/$($bucket.Repo)/git/trees/$($bucket.Branch)?recursive=1"

        # A truncated tree would silently hide apps, so say so rather than
        # returning a partial list as if it were complete.
        if ($tree.truncated) {
            Write-Warn "The $($bucket.Name) bucket listing came back truncated; some apps may be missing."
        }

        foreach ($node in @($tree.tree)) {
            if ([string]$node.path -notmatch '^bucket/(.+)\.json$') { continue }
            $manifests.Add([pscustomobject]@{
                Name   = $Matches[1]
                Bucket = $bucket.Name
            })
        }
    }

    $Ctx.ScoopManifests = @($manifests)
    return @($Ctx.ScoopManifests)
}

function Search-ScoopPackage {
    param([Parameter(Mandatory)][string]$Query, [int]$Limit = 20)

    $needle = $Query.Trim()
    if (-not $needle) { return @() }

    $manifests = @(Get-ScoopManifest)

    # An exact name first, then anything containing the query - so searching
    # '7zip' leads with 7zip rather than 7zip19.00-helper.
    $matched = @($manifests | Where-Object { $_.Name -eq $needle }) +
               @($manifests | Where-Object { $_.Name -ne $needle -and $_.Name -like "*$needle*" })

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($manifest in @($matched | Select-Object -First $Limit)) {
        # No version: a bucket listing is file names. Fetching 4000 manifests
        # to fill one column is not a trade worth making.
        $results.Add((New-SearchResult -Manager 'scoop' -Id $manifest.Name `
            -Detail "$($manifest.Bucket) bucket" -Bucket $manifest.Bucket))
    }

    return @($results)
}

# -----------------------------------------------------------------------------
# All three
# -----------------------------------------------------------------------------

# Each manager is guarded on its own: a Chocolatey feed that is down still
# leaves winget and Scoop results on screen, with the failure named rather than
# thrown.
function Search-AllPackages {
    param(
        [Parameter(Mandatory)][string]$Query,
        [string[]]$Managers = @('winget', 'choco', 'scoop'),
        [int]$Limit = 20
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($manager in @($Managers)) {
        try {
            switch ($manager) {
                'winget' {
                    if (-not (Test-WingetAvailable)) {
                        $errors.Add('winget is not on this machine, so it was not searched.')
                        continue
                    }
                    foreach ($result in @(Search-WingetPackage -Query $Query -Limit $Limit)) { $results.Add($result) }
                }
                'choco' {
                    foreach ($result in @(Search-ChocolateyPackage -Query $Query -Limit $Limit)) { $results.Add($result) }
                }
                'scoop' {
                    foreach ($result in @(Search-ScoopPackage -Query $Query -Limit $Limit)) { $results.Add($result) }
                }
                default { $errors.Add("Unknown manager '$manager'.") }
            }
        }
        catch { $errors.Add("$manager - $($_.Exception.Message)") }
    }

    [pscustomobject]@{
        Query   = $Query
        Results = @($results)
        Errors  = @($errors)
    }
}

# -----------------------------------------------------------------------------
# Installing a result
# -----------------------------------------------------------------------------

# The command each manager documents for installing one package.
function Get-SearchResultCommand {
    param([Parameter(Mandatory)]$Result)

    switch ($Result.Manager) {
        'winget' { return "winget install --id $($Result.Id) --exact" }
        'choco'  { return "choco install $($Result.Id) -y" }
        'scoop' {
            # Extras is not added by default, so an install from it needs the
            # bucket first. main is always there.
            if ($Result.Bucket -and $Result.Bucket -ne 'main') {
                return "scoop bucket add $($Result.Bucket); scoop install $($Result.Id)"
            }
            return "scoop install $($Result.Id)"
        }
        default { throw "No install command for manager '$($Result.Manager)'." }
    }
}

# winget goes through Install-App, which already has the download, progress,
# exit-code and counter handling. Chocolatey and Scoop get a child process with
# the privileges each one demands - see the note in 54-Packages.
function Install-SearchResult {
    param([Parameter(Mandatory)]$Result)

    if ($Result.Manager -eq 'winget') {
        $app = [pscustomobject]@{
            id             = $Result.Id
            name           = $Result.Name
            wingetId       = $Result.Id
            source         = 'winget'
            downloadUrl    = $null
            resolvePageUrl = $null
            resolvePattern = $null
            zipUrl         = $null
            scriptUrl      = $null
        }

        $before = $Ctx.Applied
        Install-App -App $app
        return ($Ctx.Applied -gt $before)
    }

    $manager = Resolve-PackageManager -Id $Result.Manager
    if (-not $manager) { return $false }

    $status = Get-PackageManagerStatus -Manager $manager
    if (-not $status.Installed) {
        Write-Err "$($manager.Name) is not installed, so it cannot install anything yet."
        Write-Info "Install it first: -InstallManager $($manager.Id)"
        return $false
    }

    $command = Get-SearchResultCommand -Result $Result

    if ($Ctx.DryRun) {
        Write-Status -Glyph (Get-Glyph 'Info') -Color (Get-Color 'Warn') -Message $Result.Id -MessageColor (Get-Color 'Warn')
        Write-Info "would run: $command"
        return $false
    }

    # Chocolatey needs administrator; Scoop installs per-user and objects to it.
    $elevated = ($Result.Manager -eq 'choco')
    if ($Result.Manager -eq 'scoop' -and $Ctx.IsAdmin) {
        Write-Line ''
        Write-Warn 'Scoop installs into your profile and does not want an elevated shell.'
        Write-Info 'Run this in a normal, non-elevated PowerShell:'
        Write-Line "      $command" -Color White
        return $false
    }

    $needsElevation = $elevated -and -not $Ctx.IsAdmin

    Write-Line ''
    Write-Info "Runs in a new window as:"
    Write-Line "      $command" -Color Gray
    if ($needsElevation) { Write-Info 'It will ask for administrator rights.' }

    if (-not (Confirm-Action "Install $($Result.Id) with $($manager.Name)?" -DefaultYes)) {
        Write-Warn "$($Result.Id) - skipped."
        return $false
    }

    # Held open on a terminating error only, so a failure is readable instead of
    # flashing past.
    $handler = "Write-Host ''; " +
               "Write-Host ('Moscovium: the install stopped with an error.') -ForegroundColor Red; " +
               "Write-Host (`$_.Exception.Message) -ForegroundColor Red; " +
               "Write-Host ''; " +
               "Read-Host 'Press Enter to close this window'"

    $start = @{
        FilePath     = Get-PowerShellHost
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "try { $command } catch { $handler }")
        Wait         = $true
        PassThru     = $true
        ErrorAction  = 'Stop'
    }
    if ($needsElevation) { $start.Verb = 'RunAs' }

    Write-Step "Installing $($Result.Id) with $($manager.Name)"
    Write-Log "app search install: $command"

    try { $process = Start-Process @start }
    catch {
        Write-Err "Could not start the installer: $($_.Exception.Message)"
        return $false
    }

    if ($process -and $process.ExitCode -ne 0) {
        Write-Warn "$($manager.Name) exited with code $($process.ExitCode)."
        return $false
    }

    Write-Ok "$($Result.Id) installed with $($manager.Name)."
    return $true
}

# -----------------------------------------------------------------------------
# Console output
# -----------------------------------------------------------------------------

# Pads to the column width, and truncates when the value is too long so the
# next column still starts where its header says it does. Chocolatey has
# versions like '16.02.0.20170209' that overran a 16-wide column and ran
# straight into the name.
function Format-SearchColumn {
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory)][int]$Width)

    if ($Width -lt 2) { return '' }
    if ($Text.Length -ge $Width) { return $Text.Substring(0, $Width - 2) + '. ' }
    return $Text.PadRight($Width)
}

function Get-SearchManagerColor {
    param([Parameter(Mandatory)][string]$Manager)

    switch ($Manager) {
        'winget' { return (Get-Color 'Accent') }
        'choco'  { return (Get-Color 'Warn') }
        'scoop'  { return (Get-Color 'Ok') }
        default  { return (Get-Color 'Text') }
    }
}

function Show-AppSearch {
    param(
        [Parameter(Mandatory)][string]$Query,
        [string[]]$Managers = @('winget', 'choco', 'scoop'),
        [int]$Limit = 20
    )

    Write-SectionHeading "Searching for '$Query'"
    Write-Info ('Managers: ' + (@($Managers) -join ', '))

    $search = Search-AllPackages -Query $Query -Managers $Managers -Limit $Limit

    foreach ($problem in @($search.Errors)) { Write-Warn $problem }

    $results = @($search.Results)
    if ($results.Count -eq 0) {
        Write-Warn "Nothing matched '$Query'."
        return
    }

    Write-Line ''
    Write-Line ('  ' + (Format-SearchColumn 'from' 8) + (Format-SearchColumn 'id' 34) +
                (Format-SearchColumn 'version' 16) + 'name') -Color (Get-Color 'Faint')

    foreach ($result in $results) {
        $version = $result.Version
        if (-not $version) { $version = '-' }

        Write-Line '  ' -NoNewline
        Write-Line (Format-SearchColumn $result.Manager 8) -Color (Get-SearchManagerColor -Manager $result.Manager) -NoNewline
        Write-Line (Format-SearchColumn $result.Id 34) -Color White -NoNewline
        Write-Line (Format-SearchColumn $version 16) -Color Gray -NoNewline
        Write-Line $result.Name -Color Gray
    }

    Write-Line ''
    Write-Info "$($results.Count) result(s). Install one with:  -Install <id>  for winget, or from the Search apps page."
}
