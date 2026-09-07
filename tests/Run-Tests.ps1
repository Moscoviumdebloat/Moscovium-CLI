<#
.SYNOPSIS
    Test suite for Moscovium CLI.

.DESCRIPTION
    Dot-sources the src/ function libraries and exercises them directly. The
    registry tests write only under HKCU\Software\MoscoviumCliTest, a scratch key
    created and removed by the suite; no real system setting is ever touched.

.EXAMPLE
    ./tests/Run-Tests.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$TestKey  = 'HKEY_CURRENT_USER\Software\MoscoviumCliTest'

$script:Passed = 0
$script:Failed = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()

function Test-Case {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)

    try {
        & $Body
        $script:Passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed++
        $script:Failures.Add("$Name -- $($_.Exception.Message)")
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkRed
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ([string]$Expected -ne [string]$Actual) {
        throw "expected '$Expected' but got '$Actual'$(if ($Because) { " ($Because)" })"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Because = 'condition was false')
    if (-not $Condition) { throw $Because }
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor Cyan
}

# -----------------------------------------------------------------------------
# Load the source libraries with a real context.
# -----------------------------------------------------------------------------

foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -Filter '*.ps1' | Sort-Object Name)) {
    . $file.FullName
}

$Ctx = New-MoscoviumContext -Version '0.0.0-test' -SourceUrl 'https://example.invalid/moscovium.ps1'
# Keep test state out of the user's real profile directory.
$Ctx.StateDir  = Join-Path ([IO.Path]::GetTempPath()) ('moscovium-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$Ctx.BackupDir = Join-Path $Ctx.StateDir 'backups'
$Ctx.LogFile   = Join-Path $Ctx.StateDir 'test.log'
Initialize-State

function Remove-TestKey {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser', 'Registry64')
    try { $base.DeleteSubKeyTree('Software\MoscoviumCliTest', $false) } catch { }
    finally { $base.Dispose() }
}

Remove-TestKey

try {

# -----------------------------------------------------------------------------
Write-Section 'Catalog'

Initialize-Catalog

Test-Case 'catalog loads tweaks and apps' {
    Assert-True ($Ctx.Tweaks.Count -gt 0) 'no tweaks loaded'
    Assert-True ($Ctx.Apps.Count -gt 0) 'no apps loaded'
}

Test-Case 'every tweak has a name, category and known kind' {
    $kinds = @('Registry', 'PowerPlan', 'RestorePoint', 'CleanDisk', 'CleanTemp')
    foreach ($tweak in $Ctx.Tweaks) {
        Assert-True ([bool]$tweak.name) 'tweak with no name'
        Assert-True ($Ctx.TweakCategories -contains $tweak.category) "unknown category '$($tweak.category)' on '$($tweak.name)'"
        Assert-True ($kinds -contains $tweak.kind) "unknown kind '$($tweak.kind)' on '$($tweak.name)'"
    }
}

Test-Case 'tweak names are unique' {
    $dupes = @($Ctx.Tweaks | Group-Object -Property name | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    Assert-Equal 0 $dupes.Count "duplicates: $($dupes -join ', ')"
}

Test-Case 'every registry value parses to a supported hive and type' {
    foreach ($tweak in $Ctx.Tweaks) {
        foreach ($value in @($tweak.registry)) {
            $null = Resolve-RegistryPath -FullPath $value.path
            $null = ConvertTo-RegistryValueKind -Type $value.type
        }
    }
}

Test-Case 'registry tweaks carry at least one value' {
    foreach ($tweak in ($Ctx.Tweaks | Where-Object { $_.kind -eq 'Registry' })) {
        Assert-True (@($tweak.registry).Count -gt 0) "'$($tweak.name)' has no registry values"
    }
}

Test-Case 'every app has an install method' {
    foreach ($app in $Ctx.Apps) {
        $has = $app.wingetId -or $app.downloadUrl -or $app.zipUrl -or $app.scriptUrl
        Assert-True ([bool]$has) "'$($app.name)' has no way to install"
    }
}

Test-Case 'app ids are unique' {
    $dupes = @($Ctx.Apps | Group-Object -Property id | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    Assert-Equal 0 $dupes.Count "duplicates: $($dupes -join ', ')"
}

Test-Case 'resolvePattern values are valid regexes that match their pinned url' {
    foreach ($app in ($Ctx.Apps | Where-Object { $_.resolvePattern })) {
        $regex = [regex]::new($app.resolvePattern)
        Assert-True ($regex.IsMatch($app.downloadUrl)) "'$($app.name)' pattern does not match its own pinned URL"
    }
}

# -----------------------------------------------------------------------------
Write-Section 'Name resolution'

Test-Case 'exact tweak name resolves to exactly one tweak' {
    $result = Resolve-Tweak -Names @('Dark Theme')
    Assert-Equal 1 $result.Matched.Count
    Assert-Equal 'Dark Theme' $result.Matched[0].name
}

Test-Case 'category name resolves to the whole category' {
    $expected = @($Ctx.Tweaks | Where-Object { $_.category -eq 'Advanced' }).Count
    $result = Resolve-Tweak -Names @('Advanced')
    Assert-Equal $expected $result.Matched.Count
}

Test-Case '"all" resolves to every tweak' {
    $result = Resolve-Tweak -Names @('all')
    Assert-Equal $Ctx.Tweaks.Count $result.Matched.Count
}

Test-Case 'resolvers tolerate an empty or absent name list' {
    # -SaveProfile without -Apply passes an empty array, which unrolls to $null
    # on the way into the parameter.
    Assert-Equal 0 (Resolve-Tweak -Names @()).Matched.Count
    Assert-Equal 0 (Resolve-Tweak -Names $null).Matched.Count
    Assert-Equal 0 (Resolve-App   -Names @()).Matched.Count
    Assert-Equal 0 (Resolve-App   -Names $null).Matched.Count
}

Test-Case 'unknown names are reported, not silently dropped' {
    $result = Resolve-Tweak -Names @('Dark Theme', 'this tweak does not exist')
    Assert-Equal 1 $result.Matched.Count
    Assert-Equal 1 $result.Unknown.Count
}

Test-Case 'repeated and overlapping names deduplicate' {
    $result = Resolve-Tweak -Names @('Dark Theme', 'Dark Theme', 'Explorer & Taskbar')
    $dupes = @($result.Matched | Group-Object -Property name | Where-Object { $_.Count -gt 1 })
    Assert-Equal 0 $dupes.Count
}

Test-Case 'wildcards match tweaks' {
    $result = Resolve-Tweak -Names @('Disable Te*')
    Assert-True ($result.Matched.Count -ge 2) 'expected Telemetry and Teredo'
}

Test-Case 'selector results survive @() conversion' {
    # Regression guard. On Windows PowerShell 5.1, New-Object returns its result
    # wrapped in a PSObject, and @() over a PSObject-wrapped List[object] throws
    # "Argument types do not match" -- while the same code over a List[string],
    # or over a list built with ::new(), works fine. That combination is exactly
    # what the menu selectors produce, so it only surfaced at runtime.
    #
    # Every generic collection in src/ is therefore built with ::new().
    $viaNewObject = New-Object System.Collections.Generic.List[object]
    $viaConstructor = [System.Collections.Generic.List[object]]::new()
    $viaNewObject.Add([pscustomobject]@{ A = 1 })
    $viaConstructor.Add([pscustomobject]@{ A = 1 })

    $newObjectThrows = $false
    try { $null = @($viaNewObject) } catch { $newObjectThrows = $true }

    # If this ever stops throwing the platform has been fixed, but ::new() must
    # keep working either way.
    Assert-Equal 1 @($viaConstructor).Count 'the ::new() form must survive @()'
    Assert-True ($newObjectThrows -or $true) 'documented platform behaviour'

    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -Filter '*.ps1')) {
        $offenders = Select-String -LiteralPath $file.FullName -Pattern 'New-Object\s+.?System\.Collections\.Generic'
        Assert-Equal 0 @($offenders).Count "$($file.Name) builds a generic collection with New-Object"
    }
}

Test-Case 'apps resolve by id, name and category' {
    Assert-Equal 1 (Resolve-App -Names @('7zip.7zip')).Matched.Count
    Assert-Equal 1 (Resolve-App -Names @('7-Zip')).Matched.Count

    $browsers = @($Ctx.Apps | Where-Object { $_.category -eq 'Browsers' }).Count
    Assert-Equal $browsers (Resolve-App -Names @('Browsers')).Matched.Count
}

# -----------------------------------------------------------------------------
Write-Section 'Registry engine (scratch key only)'

Test-Case 'snapshot reports a missing key as absent' {
    $snapshot = Get-RegistryValueSnapshot -Path $TestKey -Name 'Sample'
    Assert-Equal $false $snapshot.keyExisted
    Assert-Equal $false $snapshot.existed
}

Test-Case 'DWord round-trips through set and read' {
    Set-RegistryValue -Path $TestKey -Name 'Number' -Type 'DWord' -Value 42
    $snapshot = Get-RegistryValueSnapshot -Path $TestKey -Name 'Number'
    Assert-Equal $true $snapshot.existed
    Assert-Equal 'DWord' $snapshot.type
    Assert-Equal 42 $snapshot.value
}

Test-Case 'QWord round-trips and keeps its type' {
    Set-RegistryValue -Path $TestKey -Name 'Big' -Type 'QWord' -Value 1
    $snapshot = Get-RegistryValueSnapshot -Path $TestKey -Name 'Big'
    Assert-Equal 'QWord' $snapshot.type
    Assert-Equal 1 $snapshot.value
}

Test-Case 'default (unnamed) value round-trips' {
    Set-RegistryValue -Path "$TestKey\Default" -Name '' -Type 'String' -Value ''
    $snapshot = Get-RegistryValueSnapshot -Path "$TestKey\Default" -Name ''
    Assert-Equal $true $snapshot.existed
    Assert-Equal '' $snapshot.value
}

Test-Case 'Test-RegistryValueApplied compares against live state' {
    Set-RegistryValue -Path $TestKey -Name 'Flag' -Type 'DWord' -Value 1
    Assert-Equal $true  (Test-RegistryValueApplied -Desired ([pscustomobject]@{ path = $TestKey; name = 'Flag'; type = 'DWord'; value = 1 }))
    Assert-Equal $false (Test-RegistryValueApplied -Desired ([pscustomobject]@{ path = $TestKey; name = 'Flag'; type = 'DWord'; value = 0 }))
}

Test-Case 'Remove-EmptyRegistryKey refuses a key that still holds values' {
    $removed = Remove-EmptyRegistryKey -Path $TestKey
    Assert-Equal $false $removed
}

Test-Case 'Remove-EmptyRegistryKey removes a genuinely empty key' {
    Set-RegistryValue -Path "$TestKey\Empty" -Name 'Temp' -Type 'DWord' -Value 1
    Remove-RegistryValue -Path "$TestKey\Empty" -Name 'Temp'
    Assert-Equal $true (Remove-EmptyRegistryKey -Path "$TestKey\Empty")
    Assert-Equal $false (Get-RegistryValueSnapshot -Path "$TestKey\Empty" -Name 'Temp').keyExisted
}

# -----------------------------------------------------------------------------
Write-Section 'Apply and revert round-trip'

# A synthetic tweak covering all three interesting revert cases at once:
# overwriting an existing value, creating a new value in an existing key, and
# creating a value in a key that did not exist.
Set-RegistryValue -Path $TestKey -Name 'Existing' -Type 'DWord' -Value 7

$roundTrip = [pscustomobject]@{
    name = 'Scratch Tweak'
    description = 'test only'
    category = 'Advanced'
    kind = 'Registry'
    registry = @(
        [pscustomobject]@{ path = $TestKey;            name = 'Existing'; type = 'DWord';  value = 99 }
        [pscustomobject]@{ path = $TestKey;            name = 'Fresh';    type = 'String'; value = 'hello' }
        [pscustomobject]@{ path = "$TestKey\Made\Up"; name = 'Deep';     type = 'DWord';  value = 5 }
    )
}

Test-Case 'apply writes every value and records a backup' {
    $record = New-BackupRecord
    Invoke-TweakApply -Tweak $roundTrip -BackupRecord $record

    Assert-Equal 0 $Ctx.Failed 'apply reported a failure'
    Assert-Equal 99      (Get-RegistryValueSnapshot -Path $TestKey -Name 'Existing').value
    Assert-Equal 'hello' (Get-RegistryValueSnapshot -Path $TestKey -Name 'Fresh').value
    Assert-Equal 5       (Get-RegistryValueSnapshot -Path "$TestKey\Made\Up" -Name 'Deep').value

    Assert-True ($record.entries.ContainsKey('Scratch Tweak')) 'no backup entry written'
    Assert-True ([bool](Save-BackupRecord -Record $record)) 'backup file not saved'
}

Test-Case 'the backup records prior state accurately' {
    $backup = Find-TweakBackup -TweakName 'Scratch Tweak'
    Assert-True ($null -ne $backup) 'backup not found on disk'

    $byName = @{}
    foreach ($value in $backup.Entry.values) { $byName[$value.name] = $value }

    Assert-Equal $true  $byName['Existing'].existed
    Assert-Equal 7      $byName['Existing'].value
    Assert-Equal $false $byName['Fresh'].existed
    Assert-Equal $true  $byName['Fresh'].keyExisted
    Assert-Equal $false $byName['Deep'].keyExisted
}

Test-Case 'revert restores prior values, deletes new ones, and drops created keys' {
    $Ctx.Applied = 0; $Ctx.Failed = 0; $Ctx.Skipped = 0
    Invoke-TweakRevert -Tweak $roundTrip

    Assert-Equal 0 $Ctx.Failed 'revert reported a failure'

    # Pre-existing value is back to what it was.
    Assert-Equal 7 (Get-RegistryValueSnapshot -Path $TestKey -Name 'Existing').value

    # Value we introduced into a pre-existing key is gone, but the key stays.
    $fresh = Get-RegistryValueSnapshot -Path $TestKey -Name 'Fresh'
    Assert-Equal $false $fresh.existed
    Assert-Equal $true  $fresh.keyExisted

    # Key we created is gone entirely.
    Assert-Equal $false (Get-RegistryValueSnapshot -Path "$TestKey\Made\Up" -Name 'Deep').keyExisted
}

Test-Case 'dry run changes nothing' {
    $Ctx.DryRun = $true
    $Ctx.Applied = 0; $Ctx.Failed = 0; $Ctx.Skipped = 0
    try {
        Invoke-TweakApply -Tweak $roundTrip -BackupRecord (New-BackupRecord) | Out-Null
    }
    finally { $Ctx.DryRun = $false }

    Assert-Equal 7 (Get-RegistryValueSnapshot -Path $TestKey -Name 'Existing').value
    Assert-Equal $false (Get-RegistryValueSnapshot -Path $TestKey -Name 'Fresh').existed
}

Test-Case 'reverting a tweak with no backup is a skip, not a failure' {
    $Ctx.Applied = 0; $Ctx.Failed = 0; $Ctx.Skipped = 0
    $orphan = [pscustomobject]@{
        name = 'Never Applied Tweak'; description = ''; category = 'Advanced'
        kind = 'Registry'; registry = @([pscustomobject]@{ path = $TestKey; name = 'X'; type = 'DWord'; value = 1 })
    }
    Invoke-TweakRevert -Tweak $orphan

    Assert-Equal 0 $Ctx.Failed
    Assert-Equal 1 $Ctx.Skipped
}

# -----------------------------------------------------------------------------
Write-Section 'Guides and settings'

Initialize-GuideCatalog

Test-Case 'guides load with steps and known categories' {
    Assert-True ($Ctx.Guides.Count -gt 0) 'no guides loaded'

    foreach ($guide in $Ctx.Guides) {
        Assert-True ([bool]$guide.title) 'guide with no title'
        Assert-True ([bool]$guide.summary) "'$($guide.title)' has no summary"
        Assert-True ($Ctx.GuideCategories -contains $guide.category) "unknown category on '$($guide.title)'"
        Assert-True (@($guide.steps).Count -gt 0) "'$($guide.title)' has no steps"
    }
}

Test-Case 'guide text survived the C# source encoding' {
    # Get-Content defaults to the ANSI code page for a BOM-less file on 5.1,
    # which turns each UTF-8 arrow into the three characters U+00E2 U+2020 ...
    # Spelled by code point so this file stays ASCII.
    $all = ($Ctx.Guides | ForEach-Object { $_.steps }) -join ' '

    $mojibake = @(0x00E2, 0x00C3, 0xFFFD)   # a-circumflex, A-tilde, replacement char
    foreach ($code in $mojibake) {
        $char = [string][char][int]$code
        Assert-True (-not $all.Contains($char)) `
            ("guide text contains U+{0:X4}; check -Encoding UTF8 in Sync-Catalog" -f $code)
    }

    # And the real arrow should have made it through intact.
    Assert-True ($all.Contains([string][char]0x2192)) 'the arrows did not survive the sync'
}

Test-Case 'guides resolve by title, category and substring' {
    Assert-Equal 1 (Resolve-Guide -Names @('Network Optimization')).Matched.Count
    Assert-Equal 2 (Resolve-Guide -Names @('Drivers & GPU')).Matched.Count
    Assert-Equal $Ctx.Guides.Count (Resolve-Guide -Names @('all')).Matched.Count
    Assert-Equal 1 (Resolve-Guide -Names @('nothing like this exists')).Unknown.Count
}

Test-Case 'non-ASCII typography degrades to ASCII when the theme is plain' {
    $arrow = [string][char]0x2192
    $unicode = $Ctx.Theme.Unicode
    try {
        $Ctx.Theme.Unicode = $false
        Assert-Equal 'a -> b' (ConvertTo-DisplayText "a $arrow b")

        # Anything unmapped still has to leave the string ASCII.
        $shrug = [string][char]0x00AF
        Assert-True ((ConvertTo-DisplayText "x$shrug") -match '^[\x00-\x7F]+$') 'left a non-ASCII character behind'

        # A Unicode-capable console keeps the real character.
        $Ctx.Theme.Unicode = $true
        Assert-Equal "a $arrow b" (ConvertTo-DisplayText "a $arrow b")
    }
    finally { $Ctx.Theme.Unicode = $unicode }
}

Test-Case 'wrapping keeps every word and indents continuations' {
    $text = 'one two three four five six seven eight nine ten eleven twelve'
    $lines = @(Format-WrappedText -Text $text -Width 20 -Indent 4)

    Assert-True ($lines.Count -gt 1) 'nothing wrapped'
    Assert-Equal $text (($lines | ForEach-Object { $_.Trim() }) -join ' ')
    Assert-True (-not $lines[0].StartsWith(' ')) 'first line should not be indented'
    Assert-True ($lines[1].StartsWith('    ')) 'continuation should be indented'
}

Test-Case 'settings round-trip, and a token is never echoed' {
    Set-MoscoviumSetting -Name 'AppsInstallPath' -Value 'C:\Somewhere\Apps'
    Assert-Equal 'C:\Somewhere\Apps' (Get-MoscoviumSetting -Name 'AppsInstallPath')

    # Case-insensitive, like the profile reader.
    Assert-Equal 'C:\Somewhere\Apps' (Get-MoscoviumSetting -Name 'appsinstallpath')

    Set-MoscoviumSetting -Name 'AppsInstallPath' -Value ''
    Assert-True ($null -eq (Get-MoscoviumSetting -Name 'AppsInstallPath')) 'clearing a setting did not remove it'

    Assert-True ($null -eq (Get-MoscoviumSetting -Name 'NeverSetThis')) 'unset setting should be null'
}

Test-Case 'the cursor role map covers the Windows cursor registry values' {
    $roles = Get-CursorRoleMap
    foreach ($required in @('Arrow', 'IBeam', 'Wait', 'AppStarting', 'Hand', 'No', 'SizeAll')) {
        Assert-True ($roles.Contains($required)) "cursor role '$required' is missing"
        Assert-True (@($roles[$required]).Count -gt 0) "'$required' has no file-name stems to match"
    }
}

# -----------------------------------------------------------------------------
Write-Section 'Theme'

Test-Case 'both glyph sets define exactly the same names' {
    # A name present in one set but not the other renders as an empty string on
    # whichever console gets the other set.
    $unicode = New-GlyphSet -Unicode $true
    $ascii   = New-GlyphSet -Unicode $false

    $onlyUnicode = @($unicode.Keys | Where-Object { -not $ascii.ContainsKey($_) })
    $onlyAscii   = @($ascii.Keys   | Where-Object { -not $unicode.ContainsKey($_) })

    Assert-Equal 0 $onlyUnicode.Count "missing from the ASCII set: $($onlyUnicode -join ', ')"
    Assert-Equal 0 $onlyAscii.Count   "missing from the Unicode set: $($onlyAscii -join ', ')"
}

Test-Case 'no glyph is empty in either set' {
    foreach ($unicode in @($true, $false)) {
        $set = New-GlyphSet -Unicode $unicode
        foreach ($name in $set.Keys) {
            $value = $set[$name]
            $text = if ($value -is [array]) { -join $value } else { [string]$value }
            Assert-True ($text.Length -gt 0) "glyph '$name' is empty (unicode=$unicode)"
        }
    }
}

Test-Case 'the ASCII set really is ASCII' {
    # This is the set a legacy conhost gets; a stray box-drawing character in it
    # would render as a question mark.
    $ascii = New-GlyphSet -Unicode $false
    foreach ($name in $ascii.Keys) {
        $value = $ascii[$name]
        $text = if ($value -is [array]) { -join $value } else { [string]$value }
        Assert-True ($text -notmatch '[^\x00-\x7F]') "ASCII glyph '$name' contains a non-ASCII character"
    }
}

Test-Case 'the Unicode set really uses box drawing' {
    $unicode = New-GlyphSet -Unicode $true
    foreach ($name in @('HLine', 'Checked', 'Unchecked', 'Pointer', 'BarFull', 'Ok', 'Err')) {
        Assert-True ([string]$unicode[$name] -match '[^\x00-\x7F]') "'$name' did not switch to a Unicode glyph"
    }
}

Test-Case 'the spinner has multiple distinct frames in both sets' {
    foreach ($unicode in @($true, $false)) {
        $frames = @((New-GlyphSet -Unicode $unicode).Spinner)
        Assert-True ($frames.Count -ge 4) "only $($frames.Count) spinner frames (unicode=$unicode)"
        Assert-Equal $frames.Count @($frames | Select-Object -Unique).Count 'spinner frames repeat'
    }
}

Test-Case '-Ascii forces the plain theme regardless of the terminal' {
    Assert-Equal $false (New-Theme -Ascii).Unicode
    Assert-Equal '[x]' (New-Theme -Ascii).Glyph.Checked
}

Test-Case 'the wordmark is one shared block of pure ASCII' {
    $lines = @(Get-WordmarkLines)
    Assert-True ($lines.Count -ge 5) 'the wordmark lost lines'

    foreach ($line in $lines) {
        # conhost on code page 437 would mangle anything outside ASCII.
        Assert-True ($line.Text -notmatch '[^\x00-\x7F]') "wordmark line is not ASCII: $($line.Text)"
        Assert-True ($null -ne $line.Color) 'a wordmark line has no colour'
    }

    # The letterforms use a backtick and an apostrophe; both have to survive
    # single-quoting into the bundle intact.
    $joined = ($lines | ForEach-Object { $_.Text }) -join "`n"
    Assert-True ($joined.Contains('`')) 'the backtick in the letterform was eaten'
    Assert-True ($joined.Contains("'")) 'the apostrophe in the letterform was eaten'

    Assert-Equal (($lines | ForEach-Object { $_.Text.Length } | Measure-Object -Maximum).Maximum) (Get-WordmarkWidth)
}

Test-Case 'the wordmark and the accent are purple, not cyan' {
    $palette = New-Palette
    foreach ($name in @('Accent', 'AccentDim', 'HighlightBg')) {
        Assert-True ([string]$palette[$name] -match 'Magenta') "$name is $($palette[$name]), not a purple"
    }

    # Nothing anywhere should still be reaching for the old cyan.
    foreach ($value in $palette.Values) {
        Assert-True ([string]$value -notmatch 'Cyan') "the palette still holds $value"
    }
    # Every line, including the thin roof on line 1 - a white roof over purple
    # letters looked like a rendering fault.
    foreach ($line in @(Get-WordmarkLines)) {
        Assert-True ([string]$line.Color -match 'Magenta') "wordmark line is $($line.Color), not a purple"
    }
}

Test-Case 'the palette defines every colour the code asks for' {
    $palette = New-Palette
    foreach ($name in @('Accent', 'AccentDim', 'Ok', 'Warn', 'Err', 'Text', 'Bright', 'Muted',
                        'HighlightFg', 'HighlightBg', 'SelectedFg')) {
        Assert-True ($palette.ContainsKey($name)) "palette is missing '$name'"
        Assert-True ($palette[$name] -is [ConsoleColor]) "'$name' is not a ConsoleColor"
    }
}

Test-Case 'the selection bar uses a background colour, not just brightness' {
    # Write-Frame only paints a bar when the line carries a Background.
    $line = New-FrameLine 'row' ([ConsoleColor]::White) ([ConsoleColor]::DarkCyan)
    Assert-Equal 'DarkCyan' $line.Background
    Assert-Equal 'White' $line.Color

    $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/60-Menu.ps1') -Raw
    Assert-True ($source -match 'HighlightBg') 'the cursor row no longer uses the highlight background'
}

Test-Case 'rule width stays inside a sane range' {
    $width = Get-RuleWidth
    Assert-True ($width -ge 20 -and $width -le 78) "rule width $width is out of range"
}

Test-Case 'progress bar and spinner stay silent when output is redirected' {
    # They rewrite the current line, which would otherwise fill a log file.
    $animate = $Ctx.Animate
    try {
        $Ctx.Animate = $false
        Write-ProgressBar -Label 'x' -Fraction 0.5
        Write-Activity -Message 'x' -Tick 1
        Clear-InlineLine
    }
    finally { $Ctx.Animate = $animate }
}

# -----------------------------------------------------------------------------
Write-Section 'Menu geometry'

$menuItems = @(1..20 | ForEach-Object { [pscustomobject]@{ Name = "Item $_"; Note = "note$_" } })
$menuLabel = { param($o) $o.Name }
$menuSub   = { param($o) $o.Note }

Test-Case 'an empty filter shows every item' {
    Assert-Equal 20 @(Get-VisibleIndex -Items $menuItems -Filter '' -Label $menuLabel).Count
}

Test-Case 'a filter narrows to matching items and keeps their indices' {
    $visible = @(Get-VisibleIndex -Items $menuItems -Filter 'Item 1' -Label $menuLabel)
    # Item 1 and Item 10..19
    Assert-Equal 11 $visible.Count
    Assert-Equal 0 $visible[0]
    Assert-Equal 'Item 1' $menuItems[$visible[0]].Name
}

Test-Case 'the filter also searches the sublabel' {
    $visible = @(Get-VisibleIndex -Items $menuItems -Filter 'note7' -Label $menuLabel -Sublabel $menuSub)
    Assert-Equal 1 $visible.Count
    Assert-Equal 'Item 7' $menuItems[$visible[0]].Name
}

Test-Case 'a filter matching nothing yields no indices' {
    Assert-Equal 0 @(Get-VisibleIndex -Items $menuItems -Filter 'zzz' -Label $menuLabel).Count
}

Test-Case 'the scroll window keeps the cursor visible' {
    # Cursor at the top: no scroll.
    $w = Get-ScrollWindow -Cursor 0 -Offset 0 -Count 20 -Viewport 5
    Assert-Equal 0 $w.Cursor; Assert-Equal 0 $w.Offset

    # Cursor past the bottom edge: scroll just enough.
    $w = Get-ScrollWindow -Cursor 7 -Offset 0 -Count 20 -Viewport 5
    Assert-Equal 7 $w.Cursor; Assert-Equal 3 $w.Offset
    Assert-True ($w.Cursor -ge $w.Offset -and $w.Cursor -lt $w.Offset + 5) 'cursor outside the viewport'

    # Cursor above the window: scroll back up to it.
    $w = Get-ScrollWindow -Cursor 2 -Offset 10 -Count 20 -Viewport 5
    Assert-Equal 2 $w.Cursor; Assert-Equal 2 $w.Offset
}

Test-Case 'the scroll window never leaves blank space past the end' {
    $w = Get-ScrollWindow -Cursor 19 -Offset 0 -Count 20 -Viewport 5
    Assert-Equal 15 $w.Offset "offset $($w.Offset) would show rows past the last item"
}

Test-Case 'the scroll window handles a list shorter than the viewport' {
    $w = Get-ScrollWindow -Cursor 2 -Offset 0 -Count 3 -Viewport 10
    Assert-Equal 0 $w.Offset
    Assert-Equal 2 $w.Cursor
}

Test-Case 'the scroll window clamps an out-of-range cursor' {
    # Happens when a filter shrinks the list under a cursor that was further down.
    $w = Get-ScrollWindow -Cursor 18 -Offset 14 -Count 3 -Viewport 5
    Assert-Equal 2 $w.Cursor
    Assert-Equal 0 $w.Offset

    $w = Get-ScrollWindow -Cursor 5 -Offset 3 -Count 0 -Viewport 5
    Assert-Equal 0 $w.Cursor
    Assert-Equal 0 $w.Offset
}

# -----------------------------------------------------------------------------
Write-Section 'Profiles'

Test-Case 'profile round-trips through save and load' {
    $path = Join-Path $Ctx.StateDir 'profile.json'
    $original = New-SetupProfile -Tweaks @('Dark Theme', 'Show Hidden Files') -Apps @('7zip.7zip') -UpgradeAllApps

    Save-SetupProfile -SetupProfile $original -Path $path | Out-Null
    $loaded = Import-SetupProfile -Path $path

    # @() because a single-element list comes back unrolled to a bare string.
    Assert-Equal 2 @(Get-ProfileProperty -SetupProfile $loaded -Name 'Tweaks').Count
    Assert-Equal '7zip.7zip' @(Get-ProfileProperty -SetupProfile $loaded -Name 'WingetApps')[0]
    Assert-Equal $true  (Get-ProfileProperty -SetupProfile $loaded -Name 'UpgradeAllApps')
    Assert-Equal $false (Get-ProfileProperty -SetupProfile $loaded -Name 'RunWindowsUpdate')
}

Test-Case 'profile property lookup is case-insensitive' {
    $fromGui = [pscustomobject]@{ wingetApps = @('a', 'b'); tweaks = @('Dark Theme') }
    Assert-Equal 2 (Get-ProfileProperty -SetupProfile $fromGui -Name 'WingetApps').Count
}

Test-Case 'listing backups works with zero, one and many snapshots' {
    # Get-BackupRecords returns an array, which PowerShell unrolls: no backups
    # arrive as $null and one arrives as a bare object, so .Count throws unless
    # the call site wraps it.
    $emptyDir = Join-Path $Ctx.StateDir 'empty-backups'
    New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null

    $realBackupDir = $Ctx.BackupDir
    try {
        $Ctx.BackupDir = $emptyDir
        Assert-Equal 0 @(Get-BackupRecords).Count
        Show-Backups   # must not throw

        # One snapshot.
        $record = New-BackupRecord
        $record.entries['Solo Tweak'] = [pscustomobject]@{ kind = 'Registry'; values = @(); extra = $null }
        Save-BackupRecord -Record $record | Out-Null

        Assert-Equal 1 @(Get-BackupRecords).Count
        Show-Backups   # must not throw
    }
    finally { $Ctx.BackupDir = $realBackupDir }
}

Test-Case 'a saved profile stores resolved ids, not the flag text' {
    $path = Join-Path $Ctx.StateDir 'resolved.json'
    $expected = @($Ctx.Apps | Where-Object { $_.category -eq 'Browsers' }).Count

    $appIds = @((Resolve-App -Names @('Browsers')).Matched | ForEach-Object { $_.id })
    Save-SetupProfile -SetupProfile (New-SetupProfile -Apps $appIds) -Path $path | Out-Null

    $loaded = @(Get-ProfileProperty -SetupProfile (Import-SetupProfile -Path $path) -Name 'WingetApps')
    Assert-Equal $expected $loaded.Count 'category name was stored instead of the package ids'
    Assert-True ($loaded -notcontains 'Browsers') 'the category name leaked into the profile'
}

Test-Case 'profile names resolve against the catalog' {
    $path = Join-Path $Ctx.StateDir 'profile2.json'
    Save-SetupProfile -SetupProfile (New-SetupProfile -Tweaks @('Dark Theme') -Apps @('7zip.7zip')) -Path $path | Out-Null

    $loaded = Import-SetupProfile -Path $path
    $tweaks = Resolve-Tweak -Names @(Get-ProfileProperty -SetupProfile $loaded -Name 'Tweaks')
    $apps   = Resolve-App   -Names @(Get-ProfileProperty -SetupProfile $loaded -Name 'WingetApps')

    Assert-Equal 0 $tweaks.Unknown.Count
    Assert-Equal 0 $apps.Unknown.Count
}

# -----------------------------------------------------------------------------
Write-Section 'Toolbox'

Test-Case 'every toolbox action resolves to itself' {
    foreach ($action in Get-ToolboxActions) {
        $resolved = Resolve-ToolboxAction -Id $action.Id
        Assert-True ($null -ne $resolved) "'$($action.Id)' did not resolve"
        Assert-Equal $action.Id $resolved.Id
    }
}

Test-Case 'a remote script with no arguments is the canonical irm one-liner' {
    Assert-Equal "irm 'https://christitus.com/win' | iex" `
        (New-RemoteScriptCommand -Url 'https://christitus.com/win')
}

Test-Case 'a remote script with arguments uses the script-block form' {
    # iex cannot take parameters, so anything with arguments has to go through
    # [scriptblock]::Create - the form both WinUtil and Win11Debloat document.
    $command = New-RemoteScriptCommand -Url 'https://debloat.raphi.re/' -ScriptArguments @('-RunDefaults', '-Silent')
    Assert-Equal "& ([scriptblock]::Create((irm 'https://debloat.raphi.re/'))) -RunDefaults -Silent" $command
}

Test-Case 'remote script values are quoted, switches are not' {
    $command = New-RemoteScriptCommand -Url 'https://example.invalid/x' `
        -ScriptArguments @('-Config', 'C:\Program Files\a b.json')

    Assert-True ($command -like "*-Config 'C:\Program Files\a b.json'*") "path was not quoted: $command"
    Assert-True ($command -notlike "*'-Config'*") 'the switch itself was quoted'
}

Test-Case 'WinUtil is never passed the -Run switch it no longer has' {
    # The desktop app passes -Config <path> -Run. Current WinUtil declares only
    # -Config, -Preset and -Offline, so -Run is a parameter-binding failure -
    # which is exactly why the GUI's automated button does nothing.
    $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/40-Toolbox.ps1') -Raw
    Assert-True ($source -notmatch "'-Run'") 'src still passes -Run to WinUtil'

    $bundle = Get-Content -LiteralPath (Join-Path $RepoRoot 'moscovium.ps1') -Raw
    Assert-True ($bundle -notmatch "'-Run'") 'the built bundle still passes -Run to WinUtil'
}

Test-Case 'the error-pause wrapper is valid, quote-safe PowerShell' {
    $command = New-RemoteScriptCommand -Url 'https://christitus.com/win' `
        -ScriptArguments @('-Config', 'C:\a b\c.json') -PauseOnError

    # It is passed as a single -Command argument, so an embedded double quote
    # would be mangled by Start-Process's own quoting.
    Assert-True ($command -notmatch '"') "wrapper contains a double quote: $command"
    Assert-True ($command -match '^try \{') 'wrapper does not open with try'
    Assert-True ($command -match 'Read-Host') 'wrapper never pauses on failure'

    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($command, [ref]$null, [ref]$errors)
    Assert-Equal 0 @($errors).Count 'wrapper does not parse as PowerShell'
}

Test-Case 'the wrapper preserves the exact invocation it wraps' {
    foreach ($case in @(@{ A = @() }, @{ A = @('-Config', 'C:\x y\z.json') })) {
        $plain   = New-RemoteScriptCommand -Url 'https://example.invalid/s' -ScriptArguments $case.A
        $wrapped = New-RemoteScriptCommand -Url 'https://example.invalid/s' -ScriptArguments $case.A -PauseOnError
        Assert-True ($wrapped.Contains($plain)) "wrapper altered the command: $wrapped"
    }
}

Test-Case 'the launched window is not held open with -NoExit' {
    # -NoExit would leave a dead console behind after the user quits WinUtil.
    $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/40-Toolbox.ps1') -Raw
    Assert-True ($source -notmatch "'-NoExit'") 'the remote-script window still uses -NoExit'
}

Test-Case 'the run prompt defaults to yes' {
    $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/40-Toolbox.ps1') -Raw
    Assert-True ($source -match "Confirm-Action ""Run it now\?"" -DefaultYes") 'the run prompt does not default to yes'
}

Test-Case 'remote scripts are launched out of process, not invoked inline' {
    # Running them in this process would inherit Set-StrictMode -Version Latest
    # and $ErrorActionPreference = 'Stop', and would let WinUtil's bare `break`
    # unwind into our own loops.
    $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/40-Toolbox.ps1') -Raw

    Assert-True ($source -match 'Start-Process') 'Invoke-RemoteScript no longer starts a process'
    Assert-True ($source -notmatch '&\s*\$block') 'a remote script is still invoked inline'
    Assert-True ($source -match '-NoProfile') 'the child process does not use -NoProfile'
}

Test-Case 'licence-circumvention entries are absent from the catalog' {
    # MAS activation and the StartAllBack trial reset are deliberately not ported.
    foreach ($app in $Ctx.Apps) {
        Assert-True ($app.id -ne 'Massgrave.MAS') 'MAS activation entry is present'
        Assert-True (([string]$app.scriptUrl) -notmatch 'activated\.win') 'activation bootstrap is present'
    }
}

# -----------------------------------------------------------------------------
Write-Section 'One-click presets'

# These two files are read by other people's scripts, so the tests check them
# against those scripts' own rules rather than against our idea of the format.
$winutilOneClick = Join-Path $RepoRoot 'data/winutil-oneclick.json'
$raphiOneClick   = Join-Path $RepoRoot 'data/raphi-oneclick.json'

Test-Case 'the WinUtil preset is a flat array of unique WPFTweaks keys' {
    # WinUtil's current export is ($selectedApps + $selectedTweaks + ...) piped
    # to ConvertTo-Json, so a flat array is what its importer expects. The
    # PSCustomObject form still works, but only through its legacy branch.
    # ConvertFrom-Json emits a JSON array as ONE pipeline object, so @(pipeline)
    # yields a single Object[] element. Bind it first, then wrap.
    $parsed = Get-Content -LiteralPath $winutilOneClick -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @($parsed)

    Assert-True ($entries.Count -gt 0) 'the preset is empty'
    Assert-Equal $entries.Count (@($entries | Sort-Object -Unique).Count)

    foreach ($entry in $entries) {
        Assert-True ($entry -is [string]) "entry '$entry' is not a string"
        # Invoke-WPFImpex drops anything outside this set on import.
        Assert-True ($entry -match '^WPF(Install|Tweaks|Toggle|Feature|Appx)') `
            "'$entry' is not a selectable WinUtil checkbox name"
    }
}

Test-Case 'the WinUtil preset takes a restore point before anything else' {
    # ConvertFrom-Json emits a JSON array as ONE pipeline object, so @(pipeline)
    # yields a single Object[] element. Bind it first, then wrap.
    $parsed = Get-Content -LiteralPath $winutilOneClick -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @($parsed)
    Assert-Equal 'WPFTweaksRestorePoint' $entries[0]
}

Test-Case 'the Win11Debloat preset matches its own config schema' {
    # Mirrors Test-ConfigConsistency and Import-ConfigToParams in Win11Debloat.
    $config = Get-Content -LiteralPath $raphiOneClick -Raw -Encoding UTF8 | ConvertFrom-Json

    # Import-JsonFile rejects a Version other than the expected '1.0'.
    Assert-Equal '1.0' $config.Version
    Assert-True ($null -ne $config.Tweaks) 'the config has no Tweaks'

    foreach ($app in @($config.Apps)) {
        Assert-True ($app -is [string]) 'Apps entries must be strings'
    }

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($setting in @($config.Tweaks) + @($config.Deployment)) {
        Assert-True ($null -ne $setting.PSObject.Properties['Name']) 'a setting has no Name'
        Assert-True ($null -ne $setting.PSObject.Properties['Value']) 'a setting has no Value'
        Assert-True ($setting.Name -is [string]) 'a setting Name is not a string'
        Assert-True (-not [string]::IsNullOrWhiteSpace($setting.Name)) 'a setting Name is blank'
    }

    foreach ($tweak in @($config.Tweaks)) {
        # Import-ConfigToParams skips any tweak whose Value is not exactly $true.
        Assert-True ($tweak.Value -eq $true) "tweak '$($tweak.Name)' would be skipped on import"
        Assert-True (-not $names.Contains($tweak.Name)) "tweak '$($tweak.Name)' is listed twice"
        $names.Add($tweak.Name)
    }
}

Test-Case 'the Win11Debloat preset removes Bing from search' {
    # The reason this file exists at all: WinUtil has no Bing tweak, so the
    # removal has to come from Win11Debloat's DisableBing.
    $config = Get-Content -LiteralPath $raphiOneClick -Raw -Encoding UTF8 | ConvertFrom-Json
    $names = @($config.Tweaks | ForEach-Object { $_.Name })
    Assert-True ($names -contains 'DisableBing') 'DisableBing is missing'
}

Test-Case 'the Win11Debloat deployment block passes its consistency checks' {
    $config = Get-Content -LiteralPath $raphiOneClick -Raw -Encoding UTF8 | ConvertFrom-Json

    $lookup = @{}
    foreach ($setting in @($config.Deployment)) { $lookup[$setting.Name] = $setting.Value }

    foreach ($key in @('AppRemovalScopeIndex', 'UserSelectionIndex')) {
        if (-not $lookup.ContainsKey($key)) { continue }
        Assert-True ([int]$lookup[$key] -in @(0, 1, 2)) "$key must be 0, 1 or 2"
    }

    # Scope 1 needs user 0; scope 2 needs user 1 plus an OtherUsername.
    if ($lookup.ContainsKey('AppRemovalScopeIndex')) {
        $scope = [int]$lookup['AppRemovalScopeIndex']
        if ($scope -eq 1) { Assert-Equal 0 ([int]$lookup['UserSelectionIndex']) }
        if ($scope -eq 2) {
            Assert-Equal 1 ([int]$lookup['UserSelectionIndex'])
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$lookup['OtherUsername'])) `
                'scope 2 needs an OtherUsername'
        }
    }
}

Test-Case 'the box is its own front door, not a toolbox row' {
    # It is still addressable and still listed by -List toolbox; it is just not
    # one of the one-shot actions the Toolbox page and menu enumerate.
    $all = @(Get-ToolboxActions | ForEach-Object { $_.Id })
    $listed = @(Get-ToolboxListActions | ForEach-Object { $_.Id })

    Assert-True ($all -contains 'oneclick') 'oneclick is not a resolvable action'
    Assert-True ($listed -notcontains 'oneclick') 'oneclick is still listed among the one-shot actions'
    Assert-Equal ($all.Count - 1) $listed.Count

    $resolved = Resolve-ToolboxAction -Id 'oneclick'
    Assert-Equal 'oneclick' $resolved.Id
}

Test-Case 'the steps are one list, shared by both front-ends' {
    $steps = @(Get-OneClickSteps)
    Assert-Equal 6 $steps.Count

    # Ids the runner switches on, in the order they run.
    $expected = @('winutil', 'raphi', 'updates-security', 'network-better', 'priority-22', 'dynamictick-off')
    for ($i = 0; $i -lt $expected.Count; $i++) { Assert-Equal $expected[$i] $steps[$i].Id }

    foreach ($step in $steps) {
        Assert-True (-not [string]::IsNullOrWhiteSpace($step.Title)) "step '$($step.Id)' has no title"
    }
}

Test-Case 'the step titles carry the real preset counts' {
    # The landing page and the console plan both read these, so a preset edit
    # that did not reach the text would show up here.
    $winutilParsed = Get-Content -LiteralPath $winutilOneClick -Raw -Encoding UTF8 | ConvertFrom-Json
    $raphiParsed = Get-Content -LiteralPath $raphiOneClick -Raw -Encoding UTF8 | ConvertFrom-Json

    $steps = @(Get-OneClickSteps)
    Assert-True ($steps[0].Title -match "\b$(@($winutilParsed).Count)\b") "step 1 does not name $(@($winutilParsed).Count) tweaks"
    Assert-True ($steps[1].Title -match "\b$(@($raphiParsed.Tweaks).Count)\b") "step 2 does not name $(@($raphiParsed.Tweaks).Count) tweaks"
}

Test-Case 'reading the steps does not write anything to disk' {
    # The GUI draws this page at window-open, before the user has agreed to
    # anything, so counting tweaks must not spill preset files into StateDir.
    $probe = Join-Path ([IO.Path]::GetTempPath()) "moscovium-steps-$([guid]::NewGuid().ToString('N'))"
    $previous = $Ctx.StateDir
    $Ctx.StateDir = $probe

    try {
        Get-OneClickSteps | Out-Null
        Assert-True (-not (Test-Path -LiteralPath $probe)) 'reading the steps created the state directory'
    }
    finally {
        $Ctx.StateDir = $previous
        Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'the one-click box covers every step it advertises' {
    $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/40-Toolbox.ps1') -Raw

    foreach ($step in @('network-better', 'priority-22', 'dynamictick-off')) {
        Assert-True ($source -match "Invoke-ToolboxStep -Id '$step'") "the box never runs $step"
    }
    Assert-True ($source -match 'Set-SecurityUpdatePolicy') 'the box never sets update policy'
    Assert-True ($source -match 'Get-WinutilOneClickPath') 'the box never loads the WinUtil preset'
    Assert-True ($source -match 'Get-RaphiOneClickPath') 'the box never loads the Win11Debloat preset'
}

Test-Case 'both presets are embedded in the built bundle' {
    $bundle = Get-Content -LiteralPath (Join-Path $RepoRoot 'moscovium.ps1') -Raw

    foreach ($name in @('EmbeddedWinutilOneClickJson', 'EmbeddedRaphiOneClickJson')) {
        Assert-True ($bundle -match "\`$$name = @'") "$name is not embedded"
    }
    Assert-True ($bundle -match 'WPFTweaksRestorePoint') 'the WinUtil preset did not make it in'
    Assert-True ($bundle -match 'DisableBing') 'the Win11Debloat preset did not make it in'
}

Test-Case 'presets are written without a BOM' {
    # Win11Debloat parses its config with ConvertFrom-Json, which fails on a
    # BOM under Windows PowerShell 5.1.
    $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/40-Toolbox.ps1') -Raw
    Assert-True ($source -match 'New-Object Text\.UTF8Encoding \$false') 'presets may be written with a BOM'
}

# -----------------------------------------------------------------------------
Write-Section 'Package managers'

Test-Case 'every package manager resolves to itself' {
    foreach ($manager in Get-PackageManagers) {
        $resolved = Resolve-PackageManager -Id $manager.Id
        Assert-True ($null -ne $resolved) "'$($manager.Id)' did not resolve"
        Assert-Equal $manager.Id $resolved.Id
    }

    # Names work too, so -InstallManager Chocolatey does the obvious thing.
    Assert-Equal 'choco' (Resolve-PackageManager -Id 'Chocolatey').Id
    Assert-Equal 'scoop' (Resolve-PackageManager -Id 'Scoop').Id
}

Test-Case 'the install commands are the ones each project documents' {
    $byId = @{}
    foreach ($manager in Get-PackageManagers) { $byId[$manager.Id] = $manager }

    # Verbatim from https://chocolatey.org/install - the TLS line matters on
    # older builds, and rebuilding someone else's installer invocation from
    # parts is not our business.
    $choco = $byId['choco'].InstallCommand
    Assert-True ($choco -match 'community\.chocolatey\.org/install\.ps1') 'the Chocolatey URL is wrong'
    Assert-True ($choco -match 'Set-ExecutionPolicy Bypass -Scope Process -Force') 'the execution policy prelude is missing'
    Assert-True ($choco -match 'SecurityProtocol -bor 3072') 'the TLS 1.2 prelude is missing'

    # Verbatim from https://scoop.sh
    Assert-Equal 'irm get.scoop.sh | iex' $byId['scoop'].InstallCommand

    # The documented admin escape hatch, and the only place -RunAsAdmin appears.
    Assert-True ($byId['scoop'].GlobalCommand -match '-RunAsAdmin') 'the machine-wide Scoop command is missing'
    Assert-True ($byId['choco'].GlobalCommand -eq '') 'Chocolatey has no separate machine-wide command'

    # winget is not ours to install: it arrives with App Installer from the
    # Store, and scripting around the Store breaks on the next Windows build.
    Assert-Equal '' $byId['winget'].InstallCommand
    Assert-True ($byId['winget'].InstallNote -match 'App Installer') 'the winget note does not say where it comes from'

    foreach ($manager in Get-PackageManagers) {
        Assert-True ($manager.Site -match '^https://') "$($manager.Id) has no https site"
        Assert-True (-not [string]::IsNullOrWhiteSpace($manager.Summary)) "$($manager.Id) has no summary"
    }
}

Test-Case 'the two installable managers need opposite privileges' {
    # This is the whole reason the page carries a warning and the installer
    # branches: Chocolatey requires elevation, Scoop refuses it.
    $byId = @{}
    foreach ($manager in Get-PackageManagers) { $byId[$manager.Id] = $manager }

    Assert-Equal 'admin'  $byId['choco'].Elevation
    Assert-Equal 'user'   $byId['scoop'].Elevation
    Assert-Equal 'either' $byId['winget'].Elevation
}

Test-Case 'status is read off disk, not just off the PATH' {
    # A manager installed a minute ago by a child process is on the *new* PATH,
    # not this process's copy of it - so a PATH-only check would keep reporting
    # a fresh install as missing until Moscovium was restarted.
    $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/54-Packages.ps1') -Raw
    Assert-True ($source -match 'Test-Path -LiteralPath \$candidate') 'status never looks on disk'

    foreach ($entry in @(Get-PackageManagerReport)) {
        Assert-True ($null -ne $entry.Manager) 'a report row has no manager'
        Assert-True ($entry.Installed -is [bool]) 'Installed is not a boolean'
        Assert-True ($entry.OnPath -is [bool]) 'OnPath is not a boolean'
        # On disk is the weaker claim, so anything on the PATH is also on disk.
        if ($entry.OnPath) { Assert-True $entry.Installed 'on the PATH but reported as not installed' }
        if ($entry.Installed) { Assert-True (-not [string]::IsNullOrWhiteSpace($entry.Path)) 'installed with no path' }
    }

    # winget ships with Windows 10 1809 and later, so it is a safe live check.
    $winget = @(Get-PackageManagerReport | Where-Object { $_.Manager.Id -eq 'winget' })[0]
    Assert-True $winget.Installed 'winget was not detected on a machine that has it'
}

Test-Case 'a dry run prints the command and installs nothing' {
    $previousDryRun = $Ctx.DryRun
    $Ctx.DryRun = $true

    try {
        foreach ($id in @('choco', 'scoop')) {
            # $false means "did not install", which is what a dry run should
            # report - it must never come back claiming success.
            Assert-True (-not (Invoke-PackageManagerInstall -Id $id)) "$id reported an install during a dry run"
        }
    }
    finally { $Ctx.DryRun = $previousDryRun }
}

Test-Case 'Scoop refuses to install per-user from an elevated session' {
    # Moscovium's window is always elevated and the CLI elevates for mutating
    # actions, so this is the path most people will hit. It has to explain
    # itself rather than letting Scoop's own installer fail with Deny-Install.
    $previousAdmin = $Ctx.IsAdmin
    $previousSink = $Ctx.ConfirmSink
    $previousDryRun = $Ctx.DryRun

    $asked = [System.Collections.Generic.List[string]]::new()
    $Ctx.IsAdmin = $true
    $Ctx.DryRun = $false
    # Answering no means nothing is launched, so this test installs nothing.
    $Ctx.ConfirmSink = { param($message, $defaultYes) $asked.Add([string]$message); return $false }

    try {
        Assert-True (-not (Invoke-PackageManagerInstall -Id 'scoop')) 'an elevated per-user Scoop install claimed success'

        # Exactly one question, and it is the machine-wide one - not the
        # ordinary "install it now?", which would have run the blocked command.
        Assert-Equal 1 $asked.Count
        Assert-True ($asked[0] -match 'machine-wide') "the question asked was: $($asked[0])"

        # Chocolatey has no such conflict: elevated is what it wants, so it
        # goes straight to the normal confirmation.
        $asked.Clear()
        Assert-True (-not (Invoke-PackageManagerInstall -Id 'choco')) 'declining still reported an install'
        Assert-Equal 1 $asked.Count
        Assert-True ($asked[0] -match 'Install Chocolatey now') "the question asked was: $($asked[0])"
    }
    finally {
        $Ctx.IsAdmin = $previousAdmin
        $Ctx.ConfirmSink = $previousSink
        $Ctx.DryRun = $previousDryRun
    }
}

Test-Case 'an unknown manager is reported, not silently ignored' {
    Assert-True ($null -eq (Resolve-PackageManager -Id 'definitely-not-a-manager')) 'a nonsense id resolved'
    Assert-True (-not (Invoke-PackageManagerInstall -Id 'definitely-not-a-manager')) 'a nonsense id reported an install'
}

# -----------------------------------------------------------------------------
Write-Section 'Customization'

Test-Case 'every customization tool resolves to itself, by id and by name' {
    foreach ($tool in Get-CustomizationTools) {
        $resolved = Resolve-CustomizationTool -Id $tool.Id
        Assert-True ($null -ne $resolved) "'$($tool.Id)' did not resolve"
        Assert-Equal $tool.Id $resolved.Id
    }
    Assert-Equal 'openshell'       (Resolve-CustomizationTool -Id 'Open-Shell').Id
    Assert-Equal 'explorerpatcher' (Resolve-CustomizationTool -Id 'ExplorerPatcher').Id
    Assert-True ($null -eq (Resolve-CustomizationTool -Id 'not-a-tool')) 'a nonsense id resolved'
}

Test-Case 'the four tools from the desktop page are here, and the trial reset is not' {
    $ids = @(Get-CustomizationTools | ForEach-Object { $_.Id })
    foreach ($expected in @('openshell', 'nilesoft', 'startallback', 'explorerpatcher')) {
        Assert-True ($ids -contains $expected) "$expected is missing"
    }
    Assert-Equal 4 $ids.Count

    # The desktop page's fifth button runs StartAllBack.ps1 to reset the trial.
    # It circumvents licensing, same as MAS, and is deliberately not ported -
    # not as a tool, not as a hidden switch, not as a bundled script.
    $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/56-Customize.ps1') -Raw
    $code = (@($source -split "`r?`n" | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n")
    Assert-True ($code -notmatch 'StartAllBack\.ps1') 'the trial reset script is referenced'
    # No function, verb or command named reset - the Note *string* that says the
    # reset is excluded is allowed to say so.
    Assert-True ($code -notmatch '(?im)^function\s+\S*reset') 'a reset function exists'
    Assert-True ($code -notmatch '(?i)(Invoke|Start|Reset)-\S*(trial|licen)') 'something invokes a trial or licence reset'
    Assert-True ($ids -notcontains 'trialreset') 'a trial reset tool exists'
}

Test-Case 'every tool knows where it comes from and how to tell it is installed' {
    foreach ($tool in Get-CustomizationTools) {
        Assert-True ($tool.Site -match '^https://') "$($tool.Id) has no https site"
        Assert-True (-not [string]::IsNullOrWhiteSpace($tool.Summary)) "$($tool.Id) has no summary"
        Assert-True ($tool.Source -in @('github', 'page', 'redirect')) "$($tool.Id) has source '$($tool.Source)'"
        Assert-True (-not [string]::IsNullOrWhiteSpace($tool.DisplayName)) "$($tool.Id) has no DisplayName to detect"
        Assert-True (@($tool.Paths).Count -ge 1) "$($tool.Id) has no path to detect"

        switch ($tool.Source) {
            'github'   { Assert-True ($tool.Repo -match '^[^/]+/[^/]+$' -and $tool.AssetPattern) "$($tool.Id) github source is incomplete" }
            'page'     { Assert-True ($tool.PageUrl -and $tool.LinkPattern -and $tool.BaseUrl) "$($tool.Id) page source is incomplete" }
            'redirect' { Assert-True ([bool]$tool.RedirectUrl) "$($tool.Id) redirect source is incomplete" }
        }
    }
}

Test-Case 'ExplorerPatcher comes from GitHub, not winget' {
    # winget's ExplorerPatcher was 22631.5335.68.2 when GitHub's latest was
    # 26100.8457.70.3. It is tied to the Windows build - 22631 is 23H2, 26100 is
    # 24H2 - and installing the stale one on newer Windows is the failure it is
    # notorious for. The vendor's current release is the only safe channel.
    $ep = Resolve-CustomizationTool -Id 'explorerpatcher'
    Assert-Equal 'github' $ep.Source
    Assert-Equal 'valinet/ExplorerPatcher' $ep.Repo
    Assert-True ('ep_setup.exe' -match $ep.AssetPattern -or 'ep_setup_arm64.exe' -match $ep.AssetPattern) 'the asset pattern matches neither EP installer'
}

Test-Case 'each vendor channel resolves to a real installer today' {
    # Live: two GitHub API calls, one page scrape, one HEAD. The point of this
    # feature is fetching what the vendor publishes *now*, so a pinned fixture
    # would test nothing. If a vendor moves its files this is the test that says
    # so.
    foreach ($tool in Get-CustomizationTools) {
        $url = Resolve-CustomizationUrl -Tool $tool
        Assert-True ($url -match '^https://') "$($tool.Id) resolved to '$url'"
        Assert-True ($url -match '\.(exe|msi)$') "$($tool.Id) resolved to something that is not an installer: $url"
    }

    # The redirect has to land on the real file name, not 'download.php' - that
    # is what the download is saved as.
    $sab = Resolve-CustomizationUrl -Tool (Resolve-CustomizationTool -Id 'startallback')
    Assert-True ($sab -notmatch 'download\.php') "StartAllBack still points at the redirector: $sab"
}

Test-Case 'installed detection answers for every tool without throwing' {
    foreach ($entry in @(Get-CustomizationReport)) {
        Assert-True ($null -ne $entry.Tool) 'a report row has no tool'
        Assert-True ($entry.Installed -is [bool]) "$($entry.Tool.Id) Installed is not a boolean"
    }

    # The uninstall-key scan reads DisplayName through PSObject.Properties, so
    # an entry without one is skipped rather than thrown on under StrictMode.
    Assert-True ((Test-InstalledProgram -DisplayNamePattern 'ZZZ-no-such-program-ZZZ') -eq $false) 'a nonsense DisplayName matched'
}

Test-Case 'a dry run touches no network and installs nothing' {
    $previousDryRun = $Ctx.DryRun
    $Ctx.DryRun = $true
    try {
        foreach ($tool in Get-CustomizationTools) {
            # An already-installed tool answers $true before the dry-run branch
            # is reached - that is "nothing to do", not an install. StartAllBack
            # is installed on the dev box this was written on, so the test has
            # to expect whichever is true here rather than assume a clean box.
            $expected = Test-CustomizationInstalled -Tool $tool
            $result = Install-CustomizationTool -Id $tool.Id
            Assert-Equal $expected $result "$($tool.Id): installed=$expected but the dry run returned $result"
        }
    }
    finally { $Ctx.DryRun = $previousDryRun }
}

Test-Case 'the install record carries every property Install-App reads' {
    # StrictMode throws on an absent property. Install-App reads all of these
    # off catalog entries; a hand-built record has to carry the same set.
    $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/56-Customize.ps1') -Raw
    foreach ($property in @('scriptUrl', 'zipUrl', 'downloadUrl', 'wingetId', 'source', 'name', 'resolvePageUrl', 'resolvePattern')) {
        Assert-True ($source -match "\b$property\s*=") "the install record has no '$property'"
    }
}

Test-Case '.msi installers run through msiexec, not the shell association' {
    # Start-Process on an .msi hands off to the shell and returns when *that*
    # returns, with a meaningless exit code. msiexec waits for the install.
    $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/30-Apps.ps1') -Raw
    Assert-True ($source -match "GetExtension\(\`$destination\) -ieq '\.msi'") 'Install-FromDownload does not special-case .msi'
    Assert-True ($source -match "msiexec\.exe") 'Install-FromDownload never calls msiexec'
}

Test-Case 'no function is defined twice across src/' {
    # The bundle concatenates src/ in name order and PowerShell lets a later
    # definition silently replace an earlier one - which is how the task manager
    # briefly shipped its own Format-Bytes on top of the download progress one.
    $names = @{}
    foreach ($file in Get-ChildItem (Join-Path $RepoRoot 'src') -Filter *.ps1) {
        foreach ($match in [regex]::Matches((Get-Content -LiteralPath $file.FullName -Raw), '(?m)^function\s+([A-Za-z][\w-]*)')) {
            $name = $match.Groups[1].Value
            if ($names.ContainsKey($name)) { Assert-True $false "$name is defined in both $($names[$name]) and $($file.Name)" }
            $names[$name] = $file.Name
        }
    }
    Assert-True ($names.Count -gt 100) "only $($names.Count) functions found - the scan is broken"
}

if (Test-StaApartment) {
    Test-Case 'the window has a Customization page with one row per tool' {
        Import-WpfAssembly
        $gui = New-GuiWindow
        try {
            Assert-True ($null -ne $gui.Ui.CustomizationPanel) 'no customization panel'
            Assert-Equal @(Get-CustomizationTools).Count $gui.Ui.CustomizationRows.Children.Count
            Assert-True ($gui.NavNames -contains 'Customization') 'Customization is not in the sidebar'
            Assert-Equal 'Collapsed' ([string]$gui.Ui.CustomizationPanel.Visibility)
        }
        finally { $gui.Window.Close() }
    }
}

# -----------------------------------------------------------------------------
Write-Section 'Task manager'

Test-Case 'byte and time formatting stays inside a table column' {
    Assert-Equal '0B'    (Format-CompactBytes 0)
    Assert-Equal '512B'  (Format-CompactBytes 512)
    Assert-Equal '1.0K'  (Format-CompactBytes 1024)
    Assert-Equal '1.5K'  (Format-CompactBytes 1536)
    Assert-Equal '1.0M'  (Format-CompactBytes 1048576)
    Assert-Equal '1.0G'  (Format-CompactBytes 1073741824)

    # Above 100 the decimal is noise and costs a character.
    Assert-Equal '500G'  (Format-CompactBytes (500 * 1GB))

    # Negatives and nulls come from counters that reset; neither should throw.
    Assert-Equal '0B' (Format-CompactBytes -5)
    Assert-Equal '0B' (Format-CompactBytes $null)

    Assert-Equal '1.0K/s' (Format-Rate 1024)

    Assert-Equal '0:00:00' (Format-CpuTime 0)
    Assert-Equal '0:01:05' (Format-CpuTime 65)
    Assert-Equal '2:00:00' (Format-CpuTime 7200)
    Assert-Equal '-'       (Format-CpuTime $null)

    Assert-Equal 'unknown' (Format-Uptime $null)
    Assert-True ((Format-Uptime ([DateTime]::Now.AddDays(-3))) -match '^3d') 'three days did not format as days'
    Assert-True ((Format-Uptime ([DateTime]::Now.AddMinutes(-90))) -match '^1h') 'ninety minutes did not format as hours'
}

Test-Case 'load bands are the same in both front-ends' {
    Assert-Equal 'low'    (Get-LoadBand -Percent 0)
    Assert-Equal 'low'    (Get-LoadBand -Percent 59.9)
    Assert-Equal 'medium' (Get-LoadBand -Percent 60)
    Assert-Equal 'medium' (Get-LoadBand -Percent 84.9)
    Assert-Equal 'high'   (Get-LoadBand -Percent 85)
    Assert-Equal 'high'   (Get-LoadBand -Percent 100)
}

Test-Case 'a meter bar is exactly as wide as asked and clamps out-of-range' {
    foreach ($percent in @(0, 25, 50, 100)) {
        Assert-Equal 20 (New-MeterBar -Percent $percent -Width 20).Length
    }

    # A counter glitch must not produce a bar longer than its own column.
    Assert-Equal 20 (New-MeterBar -Percent 150 -Width 20).Length
    Assert-Equal 20 (New-MeterBar -Percent -10 -Width 20).Length

    $full = Get-Glyph 'BarFull'
    $empty = Get-Glyph 'BarEmpty'
    Assert-Equal ($full * 20) (New-MeterBar -Percent 100 -Width 20)
    Assert-Equal ($empty * 20) (New-MeterBar -Percent 0 -Width 20)
}

Test-Case 'a sparkline is fixed width with the newest sample on the right' {
    $ramp = @(Get-Glyph 'Spark')

    # Wider than the data: pads on the left so the newest sample keeps its
    # position from frame to frame.
    $line = New-Sparkline -Values @(0, 100) -Width 10 -Maximum 100
    Assert-Equal 10 $line.Length
    Assert-Equal '        ' $line.Substring(0, 8)
    Assert-Equal $ramp[0] $line.Substring(8, 1)
    Assert-Equal $ramp[$ramp.Count - 1] $line.Substring(9, 1)

    # Longer than the width: keeps the newest, drops the oldest.
    $long = New-Sparkline -Values @(1..50) -Width 10 -Maximum 50
    Assert-Equal 10 $long.Length
    Assert-Equal $ramp[$ramp.Count - 1] $long.Substring(9, 1)

    Assert-Equal 10 (New-Sparkline -Values @(500) -Width 10 -Maximum 100).Length
    Assert-Equal '' (New-Sparkline -Values @(1, 2) -Width 0)
    Assert-Equal 6 (New-Sparkline -Values @() -Width 6).Length
}

Test-Case 'both glyph sets carry a sparkline ramp of the same depth' {
    $unicode = New-GlyphSet -Unicode $true
    $ascii   = New-GlyphSet -Unicode $false

    Assert-Equal @($ascii.Spark).Count @($unicode.Spark).Count
    Assert-True (@($unicode.Spark).Count -ge 4) 'the ramp is too shallow to show a shape'
}

Test-Case 'CPU load is the complement of idle, with _Total already averaged' {
    # One second of 100ns ticks.
    $tick = 10000000

    $previous = @{
        '_Total' = [pscustomobject]@{ Idle = 0.0;      Stamp = 0.0 }
        '0'      = [pscustomobject]@{ Idle = 0.0;      Stamp = 0.0 }
        '1'      = [pscustomobject]@{ Idle = 0.0;      Stamp = 0.0 }
    }
    # Core 0 was 25% idle, core 1 was 75% idle. _Total carries the mean, 50%.
    $current = @{
        '_Total' = [pscustomobject]@{ Idle = ($tick * 0.50); Stamp = $tick }
        '0'      = [pscustomobject]@{ Idle = ($tick * 0.25); Stamp = $tick }
        '1'      = [pscustomobject]@{ Idle = ($tick * 0.75); Stamp = $tick }
    }

    $load = Get-CpuLoad -Previous $previous -Current $current
    Assert-True $load.Ready 'a load with both samples reported itself unready'
    Assert-Equal 50 ([int][Math]::Round($load.Total))
    Assert-Equal 2 @($load.Cores).Count
    Assert-Equal 75 ([int][Math]::Round($load.Cores[0]))
    Assert-Equal 25 ([int][Math]::Round($load.Cores[1]))

    # The invariant the divisor was chosen for, and the reason it is not
    # multiplied by the core count.
    $mean = (@($load.Cores) | Measure-Object -Average).Average
    Assert-True ([Math]::Abs($load.Total - $mean) -lt 0.01) "_Total $($load.Total) is not the mean $mean"

    # No previous sample means no delta, so nothing is claimed.
    $cold = Get-CpuLoad -Previous $null -Current $current
    Assert-True (-not $cold.Ready) 'a first sample claimed to be ready'
    Assert-Equal 0 @($cold.Cores).Count
}

Test-Case 'per-core order is numeric, so core 10 does not land next to core 1' {
    $tick = 10000000
    $previous = @{}
    $current = @{}

    foreach ($name in @('_Total', '0', '1', '2', '9', '10', '11')) {
        $previous[$name] = [pscustomobject]@{ Idle = 0.0; Stamp = 0.0 }
        $current[$name] = [pscustomobject]@{ Idle = 0.0; Stamp = $tick }
    }
    # Make each core's load its own index, so position is checkable.
    foreach ($pair in @(@('0', 0), @('1', 10), @('2', 20), @('9', 90), @('10', 95), @('11', 99))) {
        $current[$pair[0]].Idle = $tick * (1.0 - ($pair[1] / 100.0))
    }

    $load = Get-CpuLoad -Previous $previous -Current $current
    $expected = @(0, 10, 20, 90, 95, 99)
    Assert-Equal $expected.Count @($load.Cores).Count
    for ($i = 0; $i -lt $expected.Count; $i++) {
        Assert-Equal $expected[$i] ([int][Math]::Round($load.Cores[$i]))
    }
}

Test-Case 'network rates come from byte deltas, and a reset counter is skipped' {
    $frequency = 10000000

    $previous = @{
        'eth' = [pscustomobject]@{ Received = 1000.0; Sent = 500.0; Stamp = 0.0; Frequency = $frequency }
        'wifi' = [pscustomobject]@{ Received = 9000.0; Sent = 100.0; Stamp = 0.0; Frequency = $frequency }
    }
    $current = @{
        'eth' = [pscustomobject]@{ Received = 3048.0; Sent = 1524.0; Stamp = $frequency; Frequency = $frequency }
        # This adapter was reset: the counter went backwards.
        'wifi' = [pscustomobject]@{ Received = 40.0; Sent = 612.0; Stamp = $frequency; Frequency = $frequency }
    }

    $net = Get-NetworkLoad -Previous $previous -Current $current
    Assert-True $net.Ready 'a rate with both samples reported itself unready'

    # eth contributed 2048 down and 1024 up over one second; wifi's negative
    # receive delta was dropped but its positive send delta counted.
    Assert-Equal 2048 ([int]$net.Received)
    Assert-Equal 1536 ([int]$net.Sent)

    $cold = Get-NetworkLoad -Previous $null -Current $current
    Assert-True (-not $cold.Ready) 'a first network sample claimed to be ready'
    Assert-Equal 0 ([int]$cold.Received)
}

Test-Case 'process CPU is its share of every core, and unknown stays unknown' {
    $previous = @{
        10 = [pscustomobject]@{ Id = 10; Name = 'busy';  WorkingSet = 1000.0; Threads = 4; CpuSeconds = 100.0 }
        11 = [pscustomobject]@{ Id = 11; Name = 'idle';  WorkingSet = 2000.0; Threads = 2; CpuSeconds = 50.0 }
        12 = [pscustomobject]@{ Id = 12; Name = 'closed'; WorkingSet = 500.0; Threads = 1; CpuSeconds = 5.0 }
    }
    $current = @{
        10 = [pscustomobject]@{ Id = 10; Name = 'busy';  WorkingSet = 1100.0; Threads = 4; CpuSeconds = 102.0 }
        11 = [pscustomobject]@{ Id = 11; Name = 'idle';  WorkingSet = 2000.0; Threads = 2; CpuSeconds = 50.0 }
        # Protected process: its CPU time could not be read.
        13 = [pscustomobject]@{ Id = 13; Name = 'guarded'; WorkingSet = 300.0; Threads = 1; CpuSeconds = $null }
        # Brand new since the last sample, so there is no delta for it.
        14 = [pscustomobject]@{ Id = 14; Name = 'fresh'; WorkingSet = 100.0; Threads = 1; CpuSeconds = 0.5 }
    }

    $rows = @(Get-ProcessLoad -Previous $previous -Current $current -ElapsedSeconds 1.0 -Cores 4)
    $byId = @{}
    foreach ($row in $rows) { $byId[$row.Id] = $row }

    # A process that dropped off is gone from the list, not carried forward.
    Assert-Equal 4 $rows.Count
    Assert-True (-not $byId.ContainsKey(12)) 'an exited process is still listed'

    # Two CPU seconds over one wall second on four cores is 50%.
    Assert-True $byId[10].CpuKnown 'a process with two samples has no CPU figure'
    Assert-Equal 50 ([int][Math]::Round($byId[10].Cpu))
    Assert-Equal 0 ([int][Math]::Round($byId[11].Cpu))

    # Neither of these can be differenced, and 0.0 would be a claim we cannot make.
    Assert-True (-not $byId[13].CpuKnown) 'an unreadable process claimed a CPU figure'
    Assert-True (-not $byId[14].CpuKnown) 'a brand new process claimed a CPU figure'
}

Test-Case 'sorting and filtering the process list' {
    $rows = @(
        [pscustomobject]@{ Id = 30; Name = 'zeta';  Cpu = 1.0;  CpuKnown = $true; WorkingSet = 300.0; Threads = 1; CpuSeconds = 1.0 }
        [pscustomobject]@{ Id = 10; Name = 'alpha'; Cpu = 9.0;  CpuKnown = $true; WorkingSet = 100.0; Threads = 1; CpuSeconds = 1.0 }
        [pscustomobject]@{ Id = 20; Name = 'mid';   Cpu = 5.0;  CpuKnown = $true; WorkingSet = 900.0; Threads = 1; CpuSeconds = 1.0 }
    )

    Assert-Equal 10 (@(Sort-TaskProcess -Processes $rows -Key 'cpu')[0].Id)
    Assert-Equal 20 (@(Sort-TaskProcess -Processes $rows -Key 'mem')[0].Id)
    Assert-Equal 10 (@(Sort-TaskProcess -Processes $rows -Key 'pid')[0].Id)
    Assert-Equal 'alpha' (@(Sort-TaskProcess -Processes $rows -Key 'name')[0].Name)

    # An unknown key falls back to CPU rather than throwing mid-refresh.
    Assert-Equal 10 (@(Sort-TaskProcess -Processes $rows -Key 'nonsense')[0].Id)

    Assert-Equal 3 (@(Select-TaskProcess -Processes $rows -Filter '').Count)
    Assert-Equal 3 (@(Select-TaskProcess -Processes $rows -Filter '   ').Count)
    Assert-Equal 1 (@(Select-TaskProcess -Processes $rows -Filter 'alph').Count)
    # Filtering by pid, not just name.
    Assert-Equal 1 (@(Select-TaskProcess -Processes $rows -Filter '20').Count)
    Assert-Equal 0 (@(Select-TaskProcess -Processes $rows -Filter 'nothing').Count)
}

Test-Case 'the critical process list covers what bugchecks Windows' {
    # Ending any of these is a CRITICAL_PROCESS_DIED stop, not a closed program,
    # so Stop-TaskProcess refuses rather than confirming.
    foreach ($name in @('csrss', 'smss', 'wininit', 'winlogon', 'services', 'lsass', 'System', 'Idle')) {
        Assert-True (Test-CriticalProcess -Name $name) "$name is not guarded"
    }
    # Case must not matter: the name comes from whatever Get-Process reports.
    Assert-True (Test-CriticalProcess -Name 'CSRSS') 'the guard is case sensitive'

    foreach ($name in @('notepad', 'chrome', 'svchost', 'explorer', 'discord', '')) {
        Assert-True (-not (Test-CriticalProcess -Name $name)) "$name is guarded but should not be"
    }
}

Test-Case 'history rings trim to their limit, oldest first' {
    $ring = [System.Collections.Generic.List[double]]::new()
    foreach ($value in 1..10) { Add-TaskHistory -History $ring -Value $value -Limit 4 }

    Assert-Equal 4 $ring.Count
    Assert-Equal 7 $ring[0]
    Assert-Equal 10 $ring[3]
}

Test-Case 'the monitor starts cold and says so' {
    $monitor = New-TaskMonitor
    Assert-True (-not $monitor.Ready) 'a fresh monitor claimed to be ready'
    Assert-Equal 'cpu' $monitor.SortKey
    Assert-True ($monitor.Cores -ge 1) 'the core count is not positive'
    Assert-Equal 0 @($monitor.Processes).Count
}

Test-Case 'two real samples populate every panel' {
    # The one test that touches live counters. Reads only - it samples and
    # measures, and never calls Stop-TaskProcess.
    $monitor = New-TaskMonitor
    Update-TaskMonitor -Monitor $monitor | Out-Null
    Start-Sleep -Milliseconds 350
    Update-TaskMonitor -Monitor $monitor | Out-Null

    Assert-Equal 0 @($monitor.Errors).Count "sampling reported: $(@($monitor.Errors) -join '; ')"
    Assert-True $monitor.Ready 'two samples did not make the monitor ready'

    Assert-True ($monitor.Cpu.Total -ge 0 -and $monitor.Cpu.Total -le 100) "CPU total is $($monitor.Cpu.Total)"
    Assert-Equal $monitor.Cores @($monitor.Cpu.Cores).Count

    Assert-True ($null -ne $monitor.Memory) 'no memory sample'
    Assert-True ($monitor.Memory.Total -gt 0) 'total memory is not positive'
    Assert-True ($monitor.Memory.Used -le $monitor.Memory.Total) 'used memory exceeds total'

    Assert-True (@($monitor.Disks).Count -ge 1) 'no fixed disk was found'
    Assert-True (@($monitor.Processes).Count -gt 10) 'suspiciously few processes'

    # The history rings only take a value once there is a delta behind it.
    Assert-True ($monitor.CpuHistory.Count -ge 1) 'no CPU history was recorded'
    Assert-True ($monitor.MemHistory.Count -ge 2) 'no memory history was recorded'

    foreach ($proc in @($monitor.Processes)) {
        Assert-True ($proc.Id -ge 0) "process id $($proc.Id) is negative"
        Assert-True ($proc.Cpu -ge 0 -and $proc.Cpu -le 100) "process CPU is $($proc.Cpu)"
    }
}


Test-Case 'the key hint fits an 80-column window' {
    # Write-Frame truncates at the window width, and the tail of this line is
    # 'esc back' - the one key someone stuck in the monitor needs to find.
    $hint = Get-TaskKeyHint
    Assert-True ($hint.Length -le 79) "the hint is $($hint.Length) characters"
    Assert-True ($hint -match 'esc back$') 'the hint does not end with the way out'

    foreach ($key in @('up/down', 'sort', 'kill', 'filter', 'pause')) {
        Assert-True ($hint -match [regex]::Escape($key)) "the hint never mentions $key"
    }
}

Test-Case 'the live view polls the Console API, not RawUI' {
    # The bug this guards against: $Host.UI.RawUI.KeyAvailable reports any
    # pending console input record - focus changes, resizes, key-UP events -
    # while ReadKey('IncludeKeyDown') accepts only key-down records. So RawUI
    # says a key is waiting, ReadKey blocks, and the monitor stops refreshing
    # until a real key arrives. [Console]::KeyAvailable and [Console]::ReadKey
    # are a matched pair.
    # Comment lines are stripped: the header explains the bug by naming the API
    # it does not use, and that explanation should not fail its own test.
    $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/65-TaskView.ps1') -Raw
    $code = (@($source -split "`r?`n" | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n")

    Assert-True ($code -match '\[Console\]::KeyAvailable') 'the view does not poll [Console]::KeyAvailable'
    Assert-True ($code -match '\[Console\]::ReadKey') 'the view does not read through [Console]::ReadKey'
    Assert-True ($code -notmatch 'RawUI\.KeyAvailable') 'the view is back on RawUI.KeyAvailable'
    Assert-True ($code -notmatch 'Read-MenuKey') 'the view is back on the selector key reader'

    # ConsoleKey's numeric values are the virtual key codes the switch arms
    # use, which is why swapping the reader did not change them.
    Assert-Equal 38 ([int][ConsoleKey]::UpArrow)
    Assert-Equal 40 ([int][ConsoleKey]::DownArrow)
    Assert-Equal 27 ([int][ConsoleKey]::Escape)
    Assert-Equal 8  ([int][ConsoleKey]::Backspace)
}

Test-Case 'a history graph is exactly the size it was asked for' {
    foreach ($unicode in @($true, $false)) {
        $Ctx.Theme.Glyph = New-GlyphSet -Unicode $unicode
        $Ctx.Theme.Unicode = $unicode

        foreach ($height in @(1, 2, 3)) {
            $graph = @(New-HistoryGraph -Values @(0, 25, 50, 75, 100) -Width 20 -Height $height -Maximum 100)
            Assert-Equal $height $graph.Count "height $height gave $($graph.Count) rows (unicode=$unicode)"
            foreach ($row in $graph) {
                Assert-Equal 20 $row.Length "a row is $($row.Length) characters wide (unicode=$unicode)"
            }
        }

        # Degenerate inputs must not throw mid-refresh.
        Assert-Equal 0 @(New-HistoryGraph -Values @(1, 2) -Width 0 -Height 3).Count
        Assert-Equal 0 @(New-HistoryGraph -Values @(1, 2) -Width 10 -Height 0).Count
        Assert-Equal 2 @(New-HistoryGraph -Values @() -Width 10 -Height 2).Count
        Assert-Equal 2 @(New-HistoryGraph -Values @(50) -Width 10 -Height 2 -Maximum 0).Count
    }

    $Ctx.Theme.Glyph = New-GlyphSet -Unicode $true
    $Ctx.Theme.Unicode = $true

    # Braille: every cell is in the U+2800 block, and a full-scale reading
    # fills the bottom row completely.
    $graph = @(New-HistoryGraph -Values @(100, 100, 100) -Width 6 -Height 2 -Maximum 100)
    foreach ($row in $graph) {
        foreach ($char in $row.ToCharArray()) {
            $code = [int][char]$char
            Assert-True ($code -ge 0x2800 -and $code -le 0x28FF) "0x$('{0:X}' -f $code) is not a braille cell"
        }
    }
    Assert-Equal ((ConvertTo-Char 0x28FF) * 6) $graph[1]

    # Nothing recorded draws as blank, not as a measured zero.
    $empty = @(New-HistoryGraph -Values @() -Width 4 -Height 1 -Maximum 100)
    Assert-Equal ((ConvertTo-Char 0x2800) * 4) $empty[0]

    # A short history is stretched to fill rather than left as a stub against
    # the right edge - three minutes of empty box reads as broken.
    $stretched = @(New-HistoryGraph -Values @(100, 100) -Width 8 -Height 1 -Maximum 100)
    Assert-True ($stretched[0] -notmatch [regex]::Escape((ConvertTo-Char 0x2800))) 'a stretched graph left blank cells'
}

Test-Case 'a meter shades along its own length and stays its own width' {
    foreach ($percent in @(0, 1, 37, 60, 85, 100)) {
        $segments = @(New-TaskMeterSegments -Percent $percent -Width 20)
        $rendered = -join @($segments | ForEach-Object { [string]$_.Text })
        Assert-Equal 20 $rendered.Length "at $percent% the meter is $($rendered.Length) wide"
    }

    # Clamped, so a glitched counter cannot draw past its column.
    Assert-Equal 20 (-join @((New-TaskMeterSegments -Percent 150 -Width 20) | ForEach-Object { $_.Text })).Length
    Assert-Equal 20 (-join @((New-TaskMeterSegments -Percent -10 -Width 20) | ForEach-Object { $_.Text })).Length
    Assert-Equal 0 @(New-TaskMeterSegments -Percent 50 -Width 0).Count

    # A full meter passes through every load band, because the cells are
    # coloured by their own position rather than by the reading - which is what
    # shows headroom as well as load.
    $full = @(New-TaskMeterSegments -Percent 100 -Width 20)
    $colors = @($full | ForEach-Object { [string]$_.Color } | Sort-Object -Unique)
    Assert-Equal 3 $colors.Count "a full meter used $($colors.Count) colours: $($colors -join ', ')"

    # An empty one is all dim, no green.
    $none = @(New-TaskMeterSegments -Percent 0 -Width 20)
    Assert-Equal 1 @($none).Count
    Assert-Equal ([string](Get-Color 'Muted')) ([string]$none[0].Color)
}

Test-Case 'every line of a box is exactly as wide as the box' {
    $monitor = New-TaskMonitor
    Update-TaskMonitor -Monitor $monitor | Out-Null
    Start-Sleep -Milliseconds 250
    Update-TaskMonitor -Monitor $monitor | Out-Null

    $rows = @($monitor.Processes)

    # A top edge two characters short of the walls below it is exactly the kind
    # of thing that looks broken and reads fine in the source.
    foreach ($width in @(50, 78, 96)) {
        $boxes = @()
        $boxes += @(New-TaskCpuBox -Monitor $monitor -Width $width -GraphHeight 2)
        $boxes += @(New-TaskSystemBox -Monitor $monitor -Width $width)
        $boxes += @(New-TaskProcessBox -Rows $rows -Cursor 0 -Offset 0 -Viewport 4 -Width $width -Monitor $monitor)

        foreach ($line in $boxes) {
            # Two spaces of indent outside the box, then the box itself.
            Assert-Equal ($width + 2) $line.Text.Length "at box width $width a line is $($line.Text.Length): $($line.Text)"
        }
    }
}

Test-Case 'the frame fits the window it is drawn into' {
    # Write-Frame homes the cursor to the top of the buffer to repaint. A frame
    # as tall as the window scrolls it by one on the final newline, which moves
    # (0,0) off screen and breaks every later repaint - so the layout has to
    # leave at least one row spare.
    $monitor = New-TaskMonitor
    Update-TaskMonitor -Monitor $monitor | Out-Null
    Start-Sleep -Milliseconds 250
    Update-TaskMonitor -Monitor $monitor | Out-Null

    $rows = @($monitor.Processes)

    foreach ($height in @(20, 24, 30, 40, 60)) {
        foreach ($consoleWidth in @(80, 100, 200)) {
            $frame = New-TaskFrame -Monitor $monitor -Rows $rows `
                -Width (Get-TaskBoxWidth -ConsoleWidth $consoleWidth) -ConsoleHeight $height

            Assert-True (@($frame.Lines).Count -lt $height) `
                "at ${consoleWidth}x$height the frame is $(@($frame.Lines).Count) rows"
            Assert-True ($frame.Viewport -ge 3) "the process list got $($frame.Viewport) rows"
        }
    }
}

Test-Case 'the frame degrades rather than overflowing on a small window' {
    $monitor = New-TaskMonitor
    Update-TaskMonitor -Monitor $monitor | Out-Null

    # The graph is the first thing to give up rows: another process row is
    # worth more than another row of history.
    Assert-Equal 0 (Get-TaskGraphHeight -ConsoleHeight 24)
    Assert-Equal 2 (Get-TaskGraphHeight -ConsoleHeight 30)
    Assert-Equal 3 (Get-TaskGraphHeight -ConsoleHeight 40)

    # And the box never gets narrower than the columns need, or wider than is
    # readable.
    Assert-Equal 46 (Get-TaskBoxWidth -ConsoleWidth 40)
    Assert-Equal 76 (Get-TaskBoxWidth -ConsoleWidth 80)
    Assert-Equal 96 (Get-TaskBoxWidth -ConsoleWidth 300)
}

Test-Case 'frame segments carry their own text, and plain lines still work' {
    # Write-Frame reads .Segments on every line, and Set-StrictMode makes an
    # absent property throw - so the plain constructor has to define it too.
    $plain = New-FrameLine 'hello' 'Red'
    Assert-Equal 0 @($plain.Segments).Count
    Assert-Equal 'hello' $plain.Text

    $line = New-FrameLineFromSegments -Segments @(
        (New-FrameSegment 'ab' 'Red')
        (New-FrameSegment 'cd' 'Green')
    )
    # Text stays in step with the segments so a caller can still measure or
    # match the line - the tests do, and so does the log pane.
    Assert-Equal 'abcd' $line.Text
    Assert-Equal 2 @($line.Segments).Count
}

# -----------------------------------------------------------------------------
Write-Section 'GUI'

$xamlPath = Join-Path $RepoRoot 'data/gui.xaml'

Test-Case 'gui.xaml is well-formed and pure ASCII' {
    $raw = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $null = [xml]$raw
    # XAML has no \uXXXX escape, so build.ps1 rejects rather than escapes it.
    Assert-True ($raw -notmatch '[^\x00-\x7F]') 'gui.xaml contains non-ASCII characters'
}

Test-Case 'every control the code looks up exists in the XAML' {
    # A typo here would only surface as a null reference when the window opens.
    $xml = [xml](Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8)
    $namespace = New-Object Xml.XmlNamespaceManager $xml.NameTable
    $namespace.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')

    $declared = @($xml.SelectNodes('//*[@x:Name]', $namespace) | ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') })

    $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/70-Gui.ps1') -Raw
    $block = [regex]::Match($source, '\$ui = @\{\}\s*foreach \(\$name in @\((?<list>.*?)\)\) \{', 'Singleline')
    Assert-True $block.Success 'could not find the FindName list in 70-Gui.ps1'

    $wanted = @([regex]::Matches($block.Groups['list'].Value, "'([A-Za-z0-9_]+)'") | ForEach-Object { $_.Groups[1].Value })
    Assert-True ($wanted.Count -gt 20) "only found $($wanted.Count) names to check"

    $missing = @($wanted | Where-Object { $declared -notcontains $_ })
    Assert-Equal 0 $missing.Count "looked up but not in the XAML: $($missing -join ', ')"
}

Test-Case 'the bundle embeds the XAML' {
    $bundle = Get-Content -LiteralPath (Join-Path $RepoRoot 'moscovium.ps1') -Raw
    Assert-True ($bundle -match '<Window xmlns=') 'gui.xaml was not embedded into the bundle'
    Assert-True ($bundle -match 'EmbeddedGuiXaml = @''') 'the XAML placeholder was not replaced'
}

Test-Case 'a sink redirects every kind of engine output' {
    # This is what makes the GUI a second front-end rather than a second
    # implementation: the engine writes the same way, the sink catches it.
    $captured = [System.Collections.Generic.List[object]]::new()
    $Ctx.Sink = { param($text, $color, $newline) $captured.Add([pscustomobject]@{ Text = $text; Color = $color }) }.GetNewClosure()

    try {
        Write-Ok 'ok line'
        Write-Warn 'warn line'
        Write-Err 'err line'
        Write-Info 'info line'
        Write-Rule -Title 'a rule'
    }
    finally { $Ctx.Sink = $null }

    $all = ($captured | ForEach-Object { $_.Text }) -join ''
    foreach ($expected in @('ok line', 'warn line', 'err line', 'info line', 'a rule')) {
        Assert-True ($all -like "*$expected*") "'$expected' never reached the sink"
    }

    # Colour has to survive, or the log pane cannot colour errors red.
    $colors = @($captured | Where-Object { $_.Color } | ForEach-Object { [string]$_.Color })
    Assert-True ($colors -contains 'Red') 'no red reached the sink'
    Assert-True ($colors -contains 'Green') 'no green reached the sink'
}

Test-Case 'a confirm sink answers instead of Read-Host' {
    $asked = [System.Collections.Generic.List[string]]::new()
    $Ctx.ConfirmSink = { param($message, $defaultYes) $asked.Add([string]$message); return $true }.GetNewClosure()

    try {
        Assert-Equal $true (Confirm-Action 'proceed?')
        Assert-Equal 1 $asked.Count
        Assert-Equal 'proceed?' $asked[0]

        $Ctx.ConfirmSink = { param($message, $defaultYes) return $false }.GetNewClosure()
        Assert-Equal $false (Confirm-Action 'proceed?' -DefaultYes)
    }
    finally { $Ctx.ConfirmSink = $null }
}

Test-Case 'a progress sink receives both determinate and indeterminate work' {
    $seen = [System.Collections.Generic.List[object]]::new()
    $Ctx.ProgressSink = { param($label, $fraction, $detail) $seen.Add([pscustomobject]@{ Label = $label; Fraction = $fraction }) }.GetNewClosure()

    try {
        Write-ProgressBar -Label 'downloading' -Fraction 0.25 -Detail '1 MB'
        Write-Activity -Message 'installing' -Tick 3
    }
    finally { $Ctx.ProgressSink = $null }

    Assert-Equal 2 $seen.Count
    Assert-Equal 0.25 $seen[0].Fraction
    # Write-Activity has no percentage, so it reports -1 for "pulse".
    Assert-True ($seen[1].Fraction -lt 0) 'indeterminate work did not report a negative fraction'
}

Test-Case 'no event handler uses GetNewClosure' {
    # This one shipped broken and only failed in the bundle.
    #
    # .GetNewClosure() binds a script block to a new dynamic module whose command
    # lookup falls back to the *global* scope. The bundle runs everything inside
    # `& { ... }`, so every engine function lives in that wrapper scope and a
    # closure cannot call any of them - "Get-ToolboxActions is not recognized".
    # Running from src/ hides it, because there the functions sit at script scope.
    #
    # Plain script blocks resolve functions and enclosing variables correctly, so
    # handler state lives on $Ctx.Gui instead of being captured.
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -Filter '*.ps1')) {
        # Actual calls only - the note above this rule lives in a comment.
        $lines = @(
            Select-String -LiteralPath $file.FullName -Pattern '\.GetNewClosure\(' |
                Where-Object { -not $_.Line.TrimStart().StartsWith('#') } |
                ForEach-Object { $_.LineNumber }
        )
        Assert-Equal 0 $lines.Count "$($file.Name) line(s) $($lines -join ', ') call GetNewClosure"
    }
}

Test-Case 'a plain script block can reach engine functions from the wrapper scope' {
    # The property the fix depends on, asserted directly against the bundle's
    # shape rather than trusted.
    $probe = {
        & {
            function Get-EngineThing { 'reached' }
            $captured = 'visible'
            $handler = { "$(Get-EngineThing)/$captured" }
            & $handler
        }
    }
    Assert-Equal 'reached/visible' (& $probe)
}

Test-Case 'the GUI never reimplements what the CLI already does' {
    # Guard against the two front-ends drifting: the GUI must call the engine,
    # not grow its own registry writes or winget invocations.
    $source = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/70-Gui.ps1') -Raw

    # Start-Process is fine here - Invoke-StaRelaunch needs it to reach an STA
    # host - so the check is about engine logic, not process launching.
    foreach ($forbidden in @('Set-RegistryValue', 'Remove-RegistryValue', 'winget.exe', 'Invoke-WebRequest')) {
        Assert-True ($source -notmatch [regex]::Escape($forbidden)) "70-Gui.ps1 calls $forbidden directly"
    }
    foreach ($required in @('Invoke-Tweaks', 'Invoke-AppInstall', 'Invoke-ToolboxAction', 'Invoke-SetupProfile')) {
        Assert-True ($source -match [regex]::Escape($required)) "70-Gui.ps1 no longer routes through $required"
    }
}

if (Test-StaApartment) {
    Test-Case 'the window builds and populates from the real catalog' {
        Import-WpfAssembly
        $gui = New-GuiWindow

        try {
            Assert-True ($null -ne $gui.Window) 'no window was created'
            Assert-Equal $Ctx.Tweaks.Count $gui.Rows.Tweaks.Count
            Assert-Equal $Ctx.Apps.Count $gui.Rows.Apps.Count
            # The one-click box is not a toolbox row; it has the landing page.
            Assert-Equal @(Get-ToolboxListActions).Count $gui.Rows.Toolbox.Count

            # The box is the landing page: first in the sidebar, and the panel
            # already showing before anything is clicked.
            Assert-Equal 0 $gui.Ui.NavList.SelectedIndex
            Assert-Equal 'One click' $gui.NavNames[0]
            Assert-Equal 'Visible' ([string]$gui.Ui.OneClickPanel.Visibility)
            Assert-Equal 'Collapsed' ([string]$gui.Ui.TweaksPanel.Visibility)

            # One drawn row per step, built from the presets rather than XAML.
            Assert-Equal @(Get-OneClickSteps).Count $gui.Ui.OneClickSteps.Children.Count

            # The task page exists, is wired, and is not sampling until it is
            # looked at - a CIM round trip a second is not free.
            Assert-True ($null -ne $gui.Ui.TasksPanel) 'no task panel'
            Assert-True ($null -ne $gui.Ui.TaskRows) 'no process table'
            Assert-Equal 'Tasks' $gui.NavNames[1]
            Assert-Equal 'Collapsed' ([string]$gui.Ui.TasksPanel.Visibility)
            Assert-True (-not $Ctx.Gui.TaskTimer.IsEnabled) 'the sampler is running on a page nobody opened'

            # Sort picker: one entry per sort key the engine understands.
            Assert-Equal 4 $gui.Ui.TaskSort.Items.Count

            # Package managers page: one row per manager, and the nav count
            # agrees with the catalog.
            Assert-True ($null -ne $gui.Ui.PackagesPanel) 'no package managers panel'
            Assert-Equal @(Get-PackageManagers).Count $gui.Ui.PackageRows.Children.Count
            Assert-Equal 'Package managers' $gui.NavNames[4]

            # A nav item with no panel behind it would silently show nothing.
            Assert-Equal $gui.Ui.NavList.Items.Count $gui.NavNames.Count

            # Category pickers get an "All" entry plus one per category.
            Assert-Equal ($Ctx.TweakCategories.Count + 1) $gui.Ui.TweakCategory.Items.Count
            Assert-Equal ($Ctx.AppCategories.Count + 1) $gui.Ui.AppCategory.Items.Count

            Assert-Equal "v$($Ctx.Version)" $gui.Ui.VersionText.Text
        }
        finally { $gui.Window.Close() }
    }

    Test-Case 'ticking rows is what selection reads back' {
        Import-WpfAssembly
        $gui = New-GuiWindow

        try {
            Assert-Equal 0 @(Get-CheckedItem -Rows $gui.Rows.Tweaks).Count

            $gui.Rows.Tweaks[0].CheckBox.IsChecked = $true
            $gui.Rows.Tweaks[3].CheckBox.IsChecked = $true

            $selected = @(Get-CheckedItem -Rows $gui.Rows.Tweaks)
            Assert-Equal 2 $selected.Count
            Assert-Equal $gui.Rows.Tweaks[0].Item.name $selected[0].name

            # And those items must resolve against the catalog unchanged.
            Assert-Equal 0 (Resolve-Tweak -Names @($selected | ForEach-Object { $_.name })).Unknown.Count
        }
        finally { $gui.Window.Close() }
    }

    Test-Case 'lists are grouped by category, with a header per group' {
        Import-WpfAssembly
        $gui = New-GuiWindow

        try {
            # Every row, plus one header per category that has any rows.
            $populated = 0
            foreach ($category in $Ctx.TweakCategories) {
                if (@($Ctx.Tweaks | Where-Object { $_.category -eq $category }).Count -gt 0) { $populated++ }
            }

            Assert-Equal ($Ctx.Tweaks.Count + $populated) $gui.Ui.TweakRows.Children.Count `
                'children should be one header per non-empty category plus every row'

            # Headers are DockPanels; rows are Borders.
            $headers = @($gui.Ui.TweakRows.Children | Where-Object { $_ -is [Windows.Controls.DockPanel] })
            Assert-Equal $Ctx.TweakCategories.Count $headers.Count
        }
        finally { $gui.Window.Close() }
    }

    Test-Case 'action buttons track the selection' {
        Import-WpfAssembly
        $gui = New-GuiWindow

        try {
            Assert-Equal $false $gui.Ui.BtnApply.IsEnabled 'Apply is enabled with nothing selected'
            Assert-Equal 'Apply selected' $gui.Ui.BtnApply.Content

            $gui.Rows.Tweaks[0].CheckBox.IsChecked = $true
            $gui.Rows.Tweaks[1].CheckBox.IsChecked = $true

            Assert-Equal $true $gui.Ui.BtnApply.IsEnabled
            Assert-Equal 'Apply 2' $gui.Ui.BtnApply.Content
            Assert-Equal 'Revert 2' $gui.Ui.BtnRevert.Content

            $gui.Rows.Tweaks[0].CheckBox.IsChecked = $false
            Assert-Equal 'Apply 1' $gui.Ui.BtnApply.Content

            $gui.Rows.Tweaks[1].CheckBox.IsChecked = $false
            Assert-Equal $false $gui.Ui.BtnApply.IsEnabled
        }
        finally { $gui.Window.Close() }
    }

    Test-Case 'closing the window puts the console sinks back' {
        Import-WpfAssembly
        $gui = New-GuiWindow

        Assert-True ($null -ne $Ctx.Sink) 'the window did not install a sink'
        $gui.Window.Close()

        Assert-True ($null -eq $Ctx.Sink) 'the sink outlived the window'
        Assert-True ($null -eq $Ctx.ProgressSink) 'the progress sink outlived the window'
        Assert-True ($null -eq $Ctx.ConfirmSink) 'the confirm sink outlived the window'
    }
}
else {
    Write-Host '  SKIP  window construction (host is MTA; run under powershell.exe for these)' -ForegroundColor DarkYellow
}

Test-Case 'the built bundle can open the GUI for real' {
    # The end-to-end check the unit tests could not give: construct the window
    # from the *bundle*, inside its `& { }` wrapper, in a fresh STA process.
    # Everything above runs against src/, where the scope differs - which is
    # exactly how the GetNewClosure bug reached the user.
    #
    # Driven with -DryRun, which is the one mode the GUI opens unelevated in.
    $bundlePath = Join-Path $RepoRoot 'moscovium.ps1'
    $marker = Join-Path $Ctx.StateDir 'gui-smoke.txt'

    # A working GUI blocks in ShowDialog and stays alive; a broken one throws and
    # exits at once, writing why. That difference is the assertion.
    $driver = @"
`$ErrorActionPreference = 'Stop'
try {
    `$sb = [scriptblock]::Create((Get-Content -LiteralPath '$bundlePath' -Raw))
    # -DryRun so the window opens without a UAC prompt: the GUI is elevated by
    # default, and an unattended test cannot answer one.
    & `$sb -Gui -DryRun -NoBanner
    'CLOSED' | Set-Content -LiteralPath '$marker'
}
catch {
    "FAIL: `$(`$_.Exception.Message)" | Set-Content -LiteralPath '$marker'
}
"@

    $driverPath = Join-Path $Ctx.StateDir 'gui-driver.ps1'
    Set-Content -LiteralPath $driverPath -Value $driver -Encoding UTF8

    $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $driverPath) `
        -WindowStyle Minimized -PassThru

    $exitedEarly = $process.WaitForExit(12000)

    if ($exitedEarly) {
        $reason = if (Test-Path -LiteralPath $marker) { (Get-Content -LiteralPath $marker -Raw).Trim() } else { 'no output' }
        throw "the GUI exited instead of staying open: $reason"
    }

    # Still running after 12s means the window built and ShowDialog is blocking.
    try { $process.Kill() } catch { }
    Assert-True $true
}

# -----------------------------------------------------------------------------
Write-Section 'Bundle'

Test-Case 'moscovium.ps1 is up to date with src/ and data/' {
    & (Join-Path $RepoRoot 'build.ps1') -Check | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'bundle is stale; run build.ps1' }
}

Test-Case 'bundle parses cleanly' {
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'moscovium.ps1'), [ref]$null, [ref]$errors)
    Assert-Equal 0 @($errors).Count "$(@($errors).Count) parse error(s)"
}

Test-Case 'bundle has no BOM' {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $RepoRoot 'moscovium.ps1'))
    $hasBom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Assert-True (-not $hasBom) 'file starts with a UTF-8 BOM, which iex would choke on'
}

Test-Case 'bundle is pure ASCII' {
    # Follows from having no BOM: Windows PowerShell 5.1 reads a BOM-less script
    # as ANSI, so any non-ASCII byte is corrupted when run from disk.
    $bytes = [IO.File]::ReadAllBytes((Join-Path $RepoRoot 'moscovium.ps1'))
    $high = @($bytes | Where-Object { $_ -gt 127 })
    Assert-Equal 0 $high.Count "$($high.Count) byte(s) above 0x7F"
}

Test-Case 'bundle reads identically as UTF-8 and as ANSI' {
    # The practical consequence of the two checks above: however the file is
    # decoded - by irm, by Get-Content, by the 5.1 script host - it is the same.
    $path = Join-Path $RepoRoot 'moscovium.ps1'
    $bytes = [IO.File]::ReadAllBytes($path)

    $asUtf8 = [Text.Encoding]::UTF8.GetString($bytes)
    $asAnsi = [Text.Encoding]::Default.GetString($bytes)

    Assert-Equal $asUtf8.Length $asAnsi.Length 'decoding differs between UTF-8 and ANSI'
    Assert-True ($asUtf8 -ceq $asAnsi) 'the file decodes differently depending on encoding'
}

Test-Case 'running the bundle leaves nothing behind in the caller scope' {
    # This is the whole reason the bundle wraps itself in a script block: iex runs
    # its input in the caller's scope, so a bare concatenation would leave every
    # function and $Ctx sitting in the user's session.
    #
    # The comparison is against Moscovium's own names specifically. A blanket
    # "no new functions" check fails spuriously, because merely using a cmdlet
    # autoloads Microsoft.PowerShell.Utility and that module exports functions
    # (New-Guid, Get-FileHash, ...) of its own.
    $bundlePath = Join-Path $RepoRoot 'moscovium.ps1'

    $output = & powershell.exe -NoProfile -NonInteractive -Command "
        `$sb = [scriptblock]::Create((Get-Content -LiteralPath '$bundlePath' -Raw))
        & `$sb -Version | Out-Null
        @(Get-ChildItem function: | ForEach-Object { `$_.Name }) -join ','
        @(Get-Variable | ForEach-Object { `$_.Name }) -join ','
    "

    $functions = @(([string]$output[-2]) -split ',')
    $variables = @(([string]$output[-1]) -split ',')

    # A representative function from each source file.
    $ours = @(
        'New-MoscoviumContext', 'Write-Ok', 'Initialize-Catalog', 'Resolve-Tweak',
        'Set-RegistryValue', 'Invoke-TweakApply', 'Install-App', 'Invoke-ToolboxAction',
        'Save-SetupProfile', 'Show-Selector', 'Invoke-Main', 'Test-Flag'
    )

    $leaked = @($ours | Where-Object { $functions -contains $_ })
    Assert-Equal 0 $leaked.Count "these functions leaked: $($leaked -join ', ')"

    Assert-True ($variables -notcontains 'Ctx') '$Ctx leaked into the caller scope'
    Assert-True ($variables -notcontains 'EmbeddedTweaksJson') 'the embedded catalog leaked into the caller scope'
}

}
finally {
    Remove-TestKey
    if (Test-Path -LiteralPath $Ctx.StateDir) {
        Remove-Item -LiteralPath $Ctx.StateDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host ('  {0} passed, {1} failed' -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed) { 'Red' } else { 'Green' })

if ($script:Failed -gt 0) {
    Write-Host ''
    foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}

exit 0
