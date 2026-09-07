<#
.SYNOPSIS
    Regenerates data/tweaks.json and data/apps.json from the Moscovium GUI's C# source.

.DESCRIPTION
    The GUI (github.com/Moscoviumdebloat/Moscovium) is the source of truth for both
    catalogs. Rather than hand-maintaining a second copy, this reads
    Models/AppTweak.cs and Models/SetupProfile.cs and emits the JSON the CLI embeds
    at build time. Run it after pulling GUI changes, then re-run build.ps1.

.PARAMETER GuiPath
    Path to a checkout of the Moscovium GUI repo. If omitted, the repo is cloned
    to a temp folder.

.PARAMETER Ref
    Git ref to clone when GuiPath is not supplied. Defaults to the default branch.

.EXAMPLE
    ./tools/Sync-Catalog.ps1 -GuiPath ../Moscovium
#>

[CmdletBinding()]
param(
    [string]$GuiPath,
    [string]$Ref,
    [string]$OutputPath = (Join-Path $PSScriptRoot '../data')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'CsParse.ps1')

$RepoUrl = 'https://github.com/Moscoviumdebloat/Moscovium.git'

# Catalog entries from the GUI that the CLI does not carry.
#
# Both exist to circumvent licensing: MAS bootstraps Windows/Office activation,
# and the StartAllBack entry pairs with the GUI's trial-reset script. Everything
# else in the GUI's catalogs is ported verbatim. Delete an id from this list and
# re-run to include it.
$ExcludedAppIds = @(
    'Massgrave.MAS'
)

function Resolve-GuiSource {
    if ($GuiPath) {
        $resolved = (Resolve-Path $GuiPath).Path
        if (-not (Test-Path (Join-Path $resolved 'Models/AppTweak.cs'))) {
            throw "No Models/AppTweak.cs under '$resolved'. Is that the Moscovium GUI repo?"
        }
        return [pscustomobject]@{ Path = $resolved; Temporary = $false }
    }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ("moscovium-gui-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    Write-Host "Cloning $RepoUrl ..." -ForegroundColor DarkGray

    # Only the two model files matter, so keep the clone shallow and skip the
    # ~400 binary asset files (cursors, bundled installers) entirely.
    $cloneArgs = @('clone', '--depth', '1', '--filter=blob:none', '--sparse', '--quiet')
    if ($Ref) { $cloneArgs += @('--branch', $Ref) }
    $cloneArgs += @($RepoUrl, $temp)

    & git @cloneArgs
    if ($LASTEXITCODE -ne 0) { throw "git clone failed with exit code $LASTEXITCODE." }

    & git -C $temp sparse-checkout set Models --quiet
    if ($LASTEXITCODE -ne 0) { throw "git sparse-checkout failed with exit code $LASTEXITCODE." }

    [pscustomobject]@{ Path = $temp; Temporary = $true }
}

# DWord/QWord values are numeric in the registry; String values stay text.
# The C# side writes `(long)1` for QWord, so strip any cast before converting.
function ConvertTo-RegValue {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][string]$Type
    )

    $raw = ConvertFrom-CsString -Token $Token

    switch ($Type.ToUpperInvariant()) {
        'DWORD' { return [int]($raw -replace '^\(\w+\)\s*', '') }
        'QWORD' { return [long]($raw -replace '^\(\w+\)\s*', '') }
        default { return [string]$raw }
    }
}

function Read-TweakCatalog {
    param([Parameter(Mandatory)][string]$SourceFile)

    # -Encoding UTF8 matters: without it, 5.1 reads a BOM-less file as ANSI and
    # every arrow and en dash in the source becomes mojibake.
    $text = Get-Content -LiteralPath $SourceFile -Raw -Encoding UTF8

    $tweakBlock = Get-CsInitializer -Text $text -AnchorPattern 'List<AppTweak>\s+Tweaks\s*=\s*new\(\)'
    $catBlock   = Get-CsInitializer -Text $text -AnchorPattern 'List<string>\s+Categories\s*=\s*new\(\)'

    $categories = @(Split-CsList -Text $catBlock | ForEach-Object { ConvertFrom-CsString -Token $_ })

    $tweaks = foreach ($entry in Split-CsList -Text $tweakBlock) {
        $ctor = ConvertFrom-CsCtor -Entry $entry.Trim()
        $p    = $ctor.Positional

        if ($p.Count -lt 3) { throw "Tweak entry has too few arguments: $($entry.Trim())" }

        $name        = ConvertFrom-CsString -Token $p[0]
        $description = ConvertFrom-CsString -Token $p[1]
        $category    = ConvertFrom-CsString -Token $p[2]

        # Kind arrives either as a named argument (Kind: "PowerPlan") or, in
        # principle, as the 5th positional. Registry is the C# default.
        $kind = 'Registry'
        if ($ctor.Named.ContainsKey('Kind')) { $kind = ConvertFrom-CsString -Token $ctor.Named['Kind'] }
        elseif ($p.Count -ge 5)              { $kind = ConvertFrom-CsString -Token $p[4] }

        $registry = @()
        $regArg = $null
        if ($p.Count -ge 4 -and $p[3] -match 'List<RegValue>') { $regArg = $p[3] }
        elseif ($ctor.Named.ContainsKey('Registry'))           { $regArg = $ctor.Named['Registry'] }

        if ($regArg) {
            $listBlock = (Get-CsBlock -Text $regArg -From 0).Content
            $registry = @(
                foreach ($rv in Split-CsList -Text $listBlock) {
                    $rvCtor = ConvertFrom-CsCtor -Entry $rv.Trim()
                    $rp = $rvCtor.Positional
                    if ($rp.Count -ne 4) { throw "RegValue expects 4 arguments, got $($rp.Count): $($rv.Trim())" }

                    $type = ConvertFrom-CsString -Token $rp[2]

                    [ordered]@{
                        path  = ConvertFrom-CsString -Token $rp[0]
                        name  = ConvertFrom-CsString -Token $rp[1]
                        type  = $type
                        value = ConvertTo-RegValue -Token $rp[3] -Type $type
                    }
                }
            )
        }

        [ordered]@{
            name        = $name
            description = $description
            category    = $category
            kind        = $kind
            registry    = $registry
        }
    }

    [ordered]@{
        categories = $categories
        tweaks     = @($tweaks)
    }
}

function Read-GuideCatalog {
    param([Parameter(Mandatory)][string]$SourceFile)

    # -Encoding UTF8 matters: without it, 5.1 reads a BOM-less file as ANSI and
    # every arrow and en dash in the source becomes mojibake.
    $text = Get-Content -LiteralPath $SourceFile -Raw -Encoding UTF8

    $guideBlock = Get-CsInitializer -Text $text -AnchorPattern 'List<Guide>\s+Guides\s*=\s*new\(\)'
    $catBlock   = Get-CsInitializer -Text $text -AnchorPattern 'List<string>\s+Categories\s*=\s*new\(\)'

    $categories = @(Split-CsList -Text $catBlock | ForEach-Object { ConvertFrom-CsString -Token $_ })

    # record Guide(string Title, string Category, string Summary, List<string> Steps)
    $guides = foreach ($entry in Split-CsList -Text $guideBlock) {
        $ctor = ConvertFrom-CsCtor -Entry $entry.Trim()
        $p = $ctor.Positional

        if ($p.Count -lt 4) { throw "Guide entry has too few arguments: $($entry.Trim())" }

        $stepsBlock = (Get-CsBlock -Text $p[3] -From 0).Content
        $steps = @(Split-CsList -Text $stepsBlock | ForEach-Object { ConvertFrom-CsString -Token $_ })

        [ordered]@{
            title    = ConvertFrom-CsString -Token $p[0]
            category = ConvertFrom-CsString -Token $p[1]
            summary  = ConvertFrom-CsString -Token $p[2]
            steps    = $steps
        }
    }

    [ordered]@{
        categories = $categories
        guides     = @($guides)
    }
}

function Read-AppCatalog {
    param([Parameter(Mandatory)][string]$SourceFile)

    # -Encoding UTF8 matters: without it, 5.1 reads a BOM-less file as ANSI and
    # every arrow and en dash in the source becomes mojibake.
    $text = Get-Content -LiteralPath $SourceFile -Raw -Encoding UTF8

    $appBlock = Get-CsInitializer -Text $text -AnchorPattern 'List<SetupApp>\s+Apps\s*=\s*new\(\)'
    $catBlock = Get-CsInitializer -Text $text -AnchorPattern 'List<string>\s+Categories\s*=\s*new\(\)'

    $categories = @(Split-CsList -Text $catBlock | ForEach-Object { ConvertFrom-CsString -Token $_ })

    # Positional order matches the SetupApp record declaration.
    $order = @('Id', 'Name', 'WingetId', 'Category', 'Description', 'Source',
               'DownloadUrl', 'ZipUrl', 'ScriptUrl', 'ResolvePageUrl', 'ResolvePattern')

    $skipped = [System.Collections.Generic.List[string]]::new()

    $apps = foreach ($entry in Split-CsList -Text $appBlock) {
        $ctor = ConvertFrom-CsCtor -Entry $entry.Trim()

        $fields = @{}
        for ($i = 0; $i -lt $ctor.Positional.Count; $i++) {
            if ($i -ge $order.Count) { throw "Too many positional arguments in: $($entry.Trim())" }
            $fields[$order[$i]] = ConvertFrom-CsString -Token $ctor.Positional[$i]
        }
        foreach ($key in $ctor.Named.Keys) {
            if ($order -notcontains $key) { throw "Unknown SetupApp argument '$key' in: $($entry.Trim())" }
            $fields[$key] = ConvertFrom-CsString -Token $ctor.Named[$key]
        }

        if ($ExcludedAppIds -contains $fields['Id']) {
            $skipped.Add($fields['Id'])
            continue
        }

        $record = [ordered]@{}
        foreach ($key in $order) {
            $camel = $key.Substring(0, 1).ToLowerInvariant() + $key.Substring(1)
            $value = $null
            if ($fields.ContainsKey($key) -and $fields[$key] -ne 'null') { $value = $fields[$key] }
            if ([string]::IsNullOrEmpty($value)) { $value = $null }
            $record[$camel] = $value
        }
        $record
    }

    foreach ($id in $skipped) {
        Write-Host "  excluded $id (see `$ExcludedAppIds)" -ForegroundColor DarkYellow
    }

    # A typo in the exclusion list would silently ship the entry it was meant to
    # drop, so fail rather than let that pass unnoticed.
    $missing = @($ExcludedAppIds | Where-Object { $skipped -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "Excluded id(s) not found in the GUI catalog: $($missing -join ', '). Update `$ExcludedAppIds."
    }

    [ordered]@{
        categories = $categories
        apps       = @($apps)
    }
}

# ConvertTo-Json in Windows PowerShell 5.1 escapes non-ASCII and some ASCII
# punctuation as \uXXXX. That is valid JSON but makes diffs unreadable, so
# unescape the printable range back to literal characters.
function ConvertTo-ReadableJson {
    param([Parameter(Mandatory)]$InputObject, [int]$Depth = 12)

    $json = $InputObject | ConvertTo-Json -Depth $Depth
    [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', {
        param($m)
        $code = [Convert]::ToInt32($m.Groups[1].Value, 16)
        # Leave real control characters and quotes/backslashes escaped.
        if ($code -lt 0x20 -or $code -eq 0x22 -or $code -eq 0x5C) { return $m.Value }
        [string][char]$code
    })
}

function Save-Catalog {
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    # UTF-8 without BOM and LF-only: the build script embeds these verbatim, and
    # ConvertTo-Json emits CRLF, which would otherwise leave the file with mixed
    # endings and make every regeneration a noisy diff.
    $json = (ConvertTo-ReadableJson -InputObject $Catalog) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $json + "`n", (New-Object Text.UTF8Encoding $false))
    Write-Host ("  {0,-14} {1}" -f $Label, $Path) -ForegroundColor DarkGray
}

$source = Resolve-GuiSource
try {
    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $OutputPath = (Resolve-Path $OutputPath).Path

    $sha = (& git -C $source.Path rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $sha) { $sha = 'unknown' }

    Write-Host "Syncing catalogs from Moscovium GUI @ $sha" -ForegroundColor Cyan

    $tweaks = Read-TweakCatalog -SourceFile (Join-Path $source.Path 'Models/AppTweak.cs')
    $apps   = Read-AppCatalog   -SourceFile (Join-Path $source.Path 'Models/SetupProfile.cs')
    $guides = Read-GuideCatalog -SourceFile (Join-Path $source.Path 'Models/Guides.cs')

    $provenance = [ordered]@{
        repo      = $RepoUrl
        commit    = $sha
        syncedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $tweaks['source'] = $provenance
    $apps['source']   = $provenance

    Save-Catalog -Catalog $tweaks -Path (Join-Path $OutputPath 'tweaks.json') -Label 'tweaks.json'
    Save-Catalog -Catalog $apps   -Path (Join-Path $OutputPath 'apps.json')   -Label 'apps.json'
    Save-Catalog -Catalog $guides -Path (Join-Path $OutputPath 'guides.json') -Label 'guides.json'

    Write-Host ("Done: {0} tweaks, {1} apps, {2} guides." -f $tweaks.tweaks.Count, $apps.apps.Count, $guides.guides.Count) -ForegroundColor Green
}
finally {
    if ($source.Temporary -and (Test-Path $source.Path)) {
        Remove-Item -LiteralPath $source.Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}
