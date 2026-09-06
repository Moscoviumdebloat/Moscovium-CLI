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

$EmbeddedTweaksJson = ''
$EmbeddedAppsJson = ''

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
