# =============================================================================
# Guides: the manual optimisation walkthroughs from the desktop app.
#
# These are the things a tool cannot do for you - BIOS settings, driver control
# panels, router configuration - so the catalog is pure text and the only job
# here is presenting it. Generated from Models/Guides.cs by Sync-Catalog.ps1 and
# embedded by build.ps1, exactly like the tweak and app catalogs.
# =============================================================================

$EmbeddedGuidesJson = ''

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
