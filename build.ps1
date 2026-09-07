<#
.SYNOPSIS
    Bundles src/ and data/ into the single-file moscovium.ps1.

.DESCRIPTION
    The distributed artifact has to be one self-contained file, because the
    headline entry point is:

        irm https://moscovium.win | iex

    which has nowhere to put a second file. So this concatenates every src/*.ps1
    in name order, embeds the JSON catalogs as here-strings, and wraps the whole
    thing in a script block.

    The script block matters: `iex` runs its input in the *caller's* scope, so a
    bare concatenation would leave dozens of functions, a $Ctx variable and a
    modified $ErrorActionPreference behind in the user's session. Invoking a
    script block gives the run its own scope and leaves nothing behind.

.EXAMPLE
    ./build.ps1
    ./build.ps1 -Check     # verify moscovium.ps1 is up to date, for CI
#>

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'moscovium.ps1'),
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SrcDir  = Join-Path $PSScriptRoot 'src'
$DataDir = Join-Path $PSScriptRoot 'data'
$Version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()

# A short digest of everything that goes into the bundle.
#
# The point is being able to answer "is the copy I just piped into iex the one
# with the fix?" without diffing 300 KB. It is derived from the sources rather
# than from git, so it is deterministic - the same src/ and data/ always produce
# the same id, whether or not anything has been committed or pushed.
function Get-SourceBuildId {
    $inputs = @(Get-ChildItem -LiteralPath $SrcDir -Filter '*.ps1' -File) +
              @(Get-ChildItem -LiteralPath $DataDir -File)

    $parts = foreach ($file in ($inputs | Sort-Object -Property Name)) {
        $content = [string](Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8)
        # Normalise endings so the id does not depend on how the tree was checked out.
        $file.Name + "`n" + ($content -replace "`r`n", "`n")
    }

    $material = ($parts -join "`n") + "`n" + $Version

    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($material))
        return (($bytes[0..4] | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $hash.Dispose() }
}

$BuildId = Get-SourceBuildId

# Default URL the bundle re-fetches from when it needs to relaunch elevated.
$DefaultSourceUrl = 'https://raw.githubusercontent.com/Moscoviumdebloat/Moscovium-CLI/main/moscovium.ps1'

function Read-DataFile {
    param(
        [Parameter(Mandatory)][string]$Name,
        # XAML has no \uXXXX escape, so markup must be rejected rather than
        # escaped if it ever stops being ASCII.
        [switch]$MustBeAscii
    )

    $path = Join-Path $DataDir $Name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing $path. Run tools/Sync-Catalog.ps1 first."
    }

    $text = (Get-Content -LiteralPath $path -Raw -Encoding UTF8).TrimEnd()

    # A line consisting of '@ would terminate the here-string early. JSON never
    # produces one, but fail loudly rather than emit a broken bundle.
    if ($text -match '(?m)^\s*''@') {
        throw "$Name contains a line that would close the embedding here-string."
    }

    if ($MustBeAscii) {
        $bad = [regex]::Matches($text, '[^\x00-\x7F]')
        if ($bad.Count -gt 0) {
            throw "$Name contains $($bad.Count) non-ASCII character(s). Markup cannot be \u-escaped; use ASCII."
        }

        # A malformed colour is a XamlParseException at window-open time, which is
        # a long way from the typo. WPF accepts #RGB, #ARGB, #RRGGBB and #AARRGGBB;
        # anything else here is a slip.
        $colors = [regex]::Matches($text, '(?i)"(#[0-9a-f]+)"')
        foreach ($match in $colors) {
            $digits = $match.Groups[1].Value.Length - 1
            if ($digits -notin @(3, 4, 6, 8)) {
                throw "$Name has a malformed colour '$($match.Groups[1].Value)': $digits hex digits, expected 3, 4, 6 or 8."
            }
        }

        # A StaticResource naming a key that does not exist is the same kind of
        # bug as the malformed colour: nothing notices until the window opens,
        # and by then the message is a long way from the typo. {x:Type ...}
        # forms are skipped - those resolve against a type, not a key.
        $defined = @([regex]::Matches($text, 'x:Key="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        foreach ($match in [regex]::Matches($text, '\{StaticResource\s+([^}]+)\}')) {
            $key = $match.Groups[1].Value.Trim()
            if ($key -like '{x:Type*') { continue }
            if ($defined -notcontains $key) {
                throw "$Name references StaticResource '$key', which no x:Key defines."
            }
        }

        return $text
    }

    # The catalogs are generated from the GUI's C# strings, which may contain
    # non-ASCII text. data/ keeps it literal so diffs stay readable; the bundle
    # must not, so re-escape it here. ConvertFrom-Json decodes \uXXXX at runtime,
    # so this is lossless.
    return [regex]::Replace($text, '[^\x00-\x7F]', {
        param($m)
        '\u{0:x4}' -f [int][char]$m.Value
    })
}

# Replaces `$Name = ''` with a here-string holding $Content.
#
# Runs *after* the source has been indented into the script block, because a
# here-string's closing '@ must sit at column 0. The assignment keeps whatever
# indentation it had; the payload and terminator do not get any.
function Set-EmbeddedLiteral {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Content
    )

    # \r? because $ in multiline mode anchors before \n, leaving a stray \r that
    # [ \t]* will not consume.
    $pattern = "(?m)^([ \t]*)\`$$Name\s*=\s*''[ \t]*\r?$"
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) {
        throw "No placeholder assignment for `$$Name found in the source."
    }

    # A literal here-string: no $ expansion, no backtick escapes, so registry
    # paths and regex patterns survive untouched.
    $replacement = "$($match.Groups[1].Value)`$$Name = @'`n$Content`n'@"
    $Text.Substring(0, $match.Index) + $replacement + $Text.Substring($match.Index + $match.Length)
}

$header = @"
<#
    Moscovium CLI v$Version
    Windows debloat and setup toolbox - the command line companion to
    https://github.com/Moscoviumdebloat/Moscovium

        irm https://moscovium.win | iex

    Build $BuildId  (a digest of src/ and data/ - same sources, same id).
    Check with:  .\moscovium.ps1 -Version

    GENERATED FILE - do not edit.
    Built from src/ and data/ by build.ps1. Edit those and rebuild.
#>

[CmdletBinding()]
param(
    # Tweaks
    [string[]]`$Apply,
    [string[]]`$Revert,
    [switch]  `$Status,

    # Apps
    [string[]]`$Install,
    [switch]  `$UpgradeAll,
    [switch]  `$VCRuntimes,
    [switch]  `$WindowsUpdate,

    # Other actions
    [switch]  `$Gui,
    [switch]  `$Tasks,
    [string]  `$InstallManager,
    [string]  `$Customize,
    [string]  `$Cursor,
    [string]  `$Wallpaper,
    [string]  `$WallpaperStyle,
    [string]  `$CsConfig,
    [string[]]`$Guide,
    [string[]]`$SetSetting,
    [string]  `$Toolbox,
    [string]  `$Profile,
    [string]  `$SaveProfile,
    [string[]]`$List,
    [string]  `$Search,

    # Flags
    [switch]  `$DryRun,
    [switch]  `$Yes,
    [switch]  `$Elevate,
    [switch]  `$NoColor,
    [switch]  `$Ascii,
    [switch]  `$NoBanner,
    [switch]  `$Version,
    [switch]  `$Help,

    # URL this script re-downloads from when relaunching elevated.
    [string]  `$SourceUrl = '$DefaultSourceUrl'
)

# Everything runs inside this script block so that `iex`, which executes in the
# caller's scope, leaves no functions, variables or preference changes behind.
#
# None of these parameters are Mandatory: with no arguments `$PSBoundParameters is
# an empty dictionary, and PowerShell treats an empty collection as a missing
# mandatory argument and would prompt for it.
& {
    param(`$Bound, [string]`$BuildVersion, [string]`$Source, [string]`$BuildStamp)

    Set-StrictMode -Version Latest
    `$ErrorActionPreference = 'Stop'

    if (`$PSVersionTable.PSVersion.Major -lt 5) {
        Write-Host 'Moscovium CLI needs Windows PowerShell 5.1 or newer.' -ForegroundColor Red
        return
    }

    # `$PSBoundParameters is a Dictionary, not a hashtable; normalise it once.
    `$BoundParameters = @{}
    if (`$Bound) {
        foreach (`$key in `$Bound.Keys) { `$BoundParameters[`$key] = `$Bound[`$key] }
    }

    # ContainsKey alone would treat an explicit -DryRun:`$false as "on".
    function Test-Flag {
        param([string]`$Name)
        `$BoundParameters.ContainsKey(`$Name) -and [bool]`$BoundParameters[`$Name]
    }

"@

$footer = @"

    `$Ctx = New-MoscoviumContext -Version `$BuildVersion -SourceUrl `$Source -BuildStamp `$BuildStamp ``
        -DryRun:(Test-Flag 'DryRun') ``
        -AssumeYes:(Test-Flag 'Yes') ``
        -NoColor:(Test-Flag 'NoColor') ``
        -Ascii:(Test-Flag 'Ascii')

    Initialize-State

    # Box drawing needs a UTF-8 console. Native tools are decoded through the
    # same setting, so it is put back before we return.
    `$previousEncoding = Initialize-ConsoleEncoding

    try {
        `$exitCode = Invoke-Main -Bound `$BoundParameters
        if (`$exitCode -ne 0) { `$global:LASTEXITCODE = `$exitCode }
    }
    catch {
        Write-Host ''
        Write-Host "  Moscovium stopped: `$(`$_.Exception.Message)" -ForegroundColor Red
        try { Write-Log "FATAL: `$(`$_ | Out-String)" 'ERROR' } catch { }
        `$global:LASTEXITCODE = 1
    }
    finally {
        Restore-ConsoleEncoding -Previous `$previousEncoding
    }

} `$PSBoundParameters '$Version' `$SourceUrl '$BuildId'
"@

# -----------------------------------------------------------------------------

$sources = @(Get-ChildItem -LiteralPath $SrcDir -Filter '*.ps1' -File | Sort-Object -Property Name)
if ($sources.Count -eq 0) { throw "No source files in $SrcDir." }

$body = New-Object Text.StringBuilder

foreach ($file in $sources) {
    $text = (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8).TrimEnd()

    # No here-strings in src/. Every source line gets indented into the script
    # block below, and a here-string's terminator must sit at column 0 - so one
    # here swallows the rest of the bundle and surfaces as a parse error
    # thousands of lines away. Join an array of strings instead.
    #
    # The embedded catalogs are the exception, and they are inserted *after*
    # indenting for exactly this reason. See Set-EmbeddedLiteral.
    $hereString = [regex]::Match($text, "(?m)^\s*\S.*=\s*@[""'](?:\s*)$")
    if ($hereString.Success) {
        $line = ($text.Substring(0, $hereString.Index) -split "`n").Count
        throw "$($file.Name) line $line opens a here-string. Use an array joined with -join instead; see the note in build.ps1."
    }

    # Indent into the script block so the generated file reads as one unit.
    $indented = New-Object Text.StringBuilder
    foreach ($line in ($text -split "`r?`n")) {
        if ($line.Trim().Length -eq 0) { [void]$indented.AppendLine() }
        else { [void]$indented.AppendLine('    ' + $line) }
    }
    $text = $indented.ToString().TrimEnd()

    # Embedding happens after indenting: see Set-EmbeddedLiteral.
    if ($file.Name -eq '01-Catalog.ps1') {
        $text = Set-EmbeddedLiteral -Text $text -Name 'EmbeddedTweaksJson' -Content (Read-DataFile 'tweaks.json')
        $text = Set-EmbeddedLiteral -Text $text -Name 'EmbeddedAppsJson'   -Content (Read-DataFile 'apps.json')
    }
    if ($file.Name -eq '40-Toolbox.ps1') {
        $text = Set-EmbeddedLiteral -Text $text -Name 'EmbeddedWinutilConfigJson' -Content (Read-DataFile 'winutil-debloat.json')
        $text = Set-EmbeddedLiteral -Text $text -Name 'EmbeddedWinutilOneClickJson' -Content (Read-DataFile 'winutil-oneclick.json')
        $text = Set-EmbeddedLiteral -Text $text -Name 'EmbeddedRaphiOneClickJson' -Content (Read-DataFile 'raphi-oneclick.json')
    }
    if ($file.Name -eq '44-Guides.ps1') {
        $text = Set-EmbeddedLiteral -Text $text -Name 'EmbeddedGuidesJson' -Content (Read-DataFile 'guides.json')
    }
    if ($file.Name -eq '70-Gui.ps1') {
        $text = Set-EmbeddedLiteral -Text $text -Name 'EmbeddedGuiXaml' -Content (Read-DataFile 'gui.xaml' -MustBeAscii)
    }

    [void]$body.AppendLine()
    [void]$body.AppendLine("# ===== src/$($file.Name) " + ('=' * [Math]::Max(0, 60 - $file.Name.Length)))
    [void]$body.AppendLine()
    [void]$body.AppendLine($text)
}

# Normalise to LF so the published file hashes identically regardless of
# the machine that built it, and so `irm` never yields mixed endings.
$bundle = ($header + $body.ToString() + $footer) -replace "`r`n", "`n"

# The bundle ships without a BOM (Invoke-RestMethod would feed it straight to
# iex), and Windows PowerShell 5.1 reads a BOM-less script as ANSI, not UTF-8.
# Anything outside ASCII would therefore be corrupted when the file is run from
# disk. Catalog text is escaped on the way in; this catches src/.
$nonAscii = [regex]::Matches($bundle, '[^\x00-\x7F]')
if ($nonAscii.Count -gt 0) {
    $sample = ($nonAscii | ForEach-Object { $_.Value } | Select-Object -Unique -First 10 |
        ForEach-Object { 'U+{0:X4}' -f [int][char]$_ }) -join ', '

    # Report where, so the offending source file is obvious.
    $before = $bundle.Substring(0, $nonAscii[0].Index)
    $line = ($before -split "`n").Count

    throw "Bundle contains $($nonAscii.Count) non-ASCII character(s) ($sample), first at line $line. Replace them in src/ with ASCII equivalents."
}

# Parse before writing: a bundle that does not compile must never be published.
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseInput($bundle, [ref]$null, [ref]$parseErrors)

if ($parseErrors -and $parseErrors.Count -gt 0) {
    Write-Host "Generated bundle has $($parseErrors.Count) parse error(s):" -ForegroundColor Red
    foreach ($e in $parseErrors | Select-Object -First 20) {
        Write-Host ("  line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
    }
    throw 'Build aborted.'
}

if ($Check) {
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        Write-Host "$OutputPath does not exist. Run build.ps1." -ForegroundColor Red
        exit 1
    }

    $existing = (Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8)
    if ($existing.TrimEnd() -ne $bundle.TrimEnd()) {
        Write-Host "$OutputPath is stale. Run build.ps1 and commit the result." -ForegroundColor Red
        exit 1
    }

    Write-Host "$OutputPath is up to date." -ForegroundColor Green
    exit 0
}

# BOM-less UTF-8: Invoke-RestMethod would otherwise hand iex a leading U+FEFF.
[IO.File]::WriteAllText($OutputPath, $bundle, (New-Object Text.UTF8Encoding $false))

$size = (Get-Item -LiteralPath $OutputPath).Length
$lines = ($bundle -split "`n").Count

Write-Host ''
Write-Host "  Built $OutputPath" -ForegroundColor Green
Write-Host ("  v{0}  |  {1:N0} lines  |  {2:N1} KB  |  {3} source file(s)" -f $Version, $lines, ($size / 1KB), $sources.Count) -ForegroundColor DarkGray
Write-Host ''
