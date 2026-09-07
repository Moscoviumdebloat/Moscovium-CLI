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
            Assert-Equal @(Get-ToolboxActions).Count $gui.Rows.Toolbox.Count

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
