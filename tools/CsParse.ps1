<#
.SYNOPSIS
    Minimal parser for the C# collection-initializer literals used by the Moscovium
    GUI catalogs (TweakCatalog.cs / SetupCatalog.cs).

.DESCRIPTION
    These catalogs are plain data expressed as C# records, so a full C# parser is
    overkill. What we need is: find a named initializer block, split its top-level
    entries, and unquote C# string literals (both "regular" and @"verbatim").

    Everything here is depth- and string-aware, so braces or commas inside a string
    literal (registry GUIDs, regex patterns) do not split an entry in the wrong place.
#>

Set-StrictMode -Version Latest

# Advances past a C# string literal starting at $Index (which must point at the
# opening quote, or at the '@' of a verbatim string). Returns the index just past
# the closing quote.
function Step-CsString {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$Index
    )

    $i = $Index
    $verbatim = $false

    if ($Text[$i] -eq '@') { $verbatim = $true; $i++ }
    $i++  # past the opening quote

    while ($i -lt $Text.Length) {
        $c = $Text[$i]

        if ($verbatim) {
            if ($c -eq '"') {
                # "" is an escaped quote inside a verbatim string
                if (($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq '"') { $i += 2; continue }
                return $i + 1
            }
            $i++
        }
        else {
            if ($c -eq '\') { $i += 2; continue }
            if ($c -eq '"') { return $i + 1 }
            $i++
        }
    }

    throw "Unterminated string literal at offset $Index."
}

# Splits $Text on $Separator, but only where nesting depth is zero and we are not
# inside a string literal.
function Split-CsList {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [char]$Separator = ','
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $depth = 0
    $start = 0
    $i     = 0

    while ($i -lt $Text.Length) {
        $c = $Text[$i]

        # '@' only opens a string when immediately followed by a quote
        if ($c -eq '"' -or ($c -eq '@' -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq '"')) {
            $i = Step-CsString -Text $Text -Index $i
            continue
        }

        switch ($c) {
            '(' { $depth++ }
            '{' { $depth++ }
            '[' { $depth++ }
            ')' { $depth-- }
            '}' { $depth-- }
            ']' { $depth-- }
        }

        if ($depth -eq 0 -and $c -eq $Separator) {
            $parts.Add($Text.Substring($start, $i - $start))
            $start = $i + 1
        }

        $i++
    }

    if ($start -lt $Text.Length) { $parts.Add($Text.Substring($start)) }

    # Trailing commas in the C# source leave empty tail entries. Emitted unwrapped
    # so callers can pipe or foreach directly; wrap in @() where array semantics matter.
    @($parts | Where-Object { $_.Trim().Length -gt 0 })
}

# Returns the balanced contents of the first $Open block at or after $From,
# excluding the delimiters themselves.
function Get-CsBlock {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$From,
        [char]$Open  = '{',
        [char]$Close = '}'
    )

    $i = $Text.IndexOf($Open, $From)
    if ($i -lt 0) { throw "No '$Open' found after offset $From." }

    $contentStart = $i + 1
    $depth = 0

    while ($i -lt $Text.Length) {
        $c = $Text[$i]

        if ($c -eq '"' -or ($c -eq '@' -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq '"')) {
            $i = Step-CsString -Text $Text -Index $i
            continue
        }

        if ($c -eq $Open)  { $depth++ }
        if ($c -eq $Close) {
            $depth--
            if ($depth -eq 0) {
                return [pscustomobject]@{
                    Content = $Text.Substring($contentStart, $i - $contentStart)
                    End     = $i + 1
                }
            }
        }

        $i++
    }

    throw "Unbalanced '$Open' starting at offset $contentStart."
}

# Finds `<anchor> ... {` and returns the balanced block after it.
function Get-CsInitializer {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$AnchorPattern
    )

    $m = [regex]::Match($Text, $AnchorPattern)
    if (-not $m.Success) { throw "Anchor /$AnchorPattern/ not found in source." }

    (Get-CsBlock -Text $Text -From $m.Index).Content
}

# Unquotes a single C# string literal token. Non-string tokens come back trimmed.
function ConvertFrom-CsString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Token)

    $t = $Token.Trim()

    if ($t.StartsWith('@"')) {
        return $t.Substring(2, $t.Length - 3).Replace('""', '"')
    }

    if (-not $t.StartsWith('"')) { return $t }

    $inner = $t.Substring(1, $t.Length - 2)
    $sb = New-Object System.Text.StringBuilder

    for ($i = 0; $i -lt $inner.Length; $i++) {
        if ($inner[$i] -eq '\' -and ($i + 1) -lt $inner.Length) {
            switch ($inner[$i + 1]) {
                '\'     { [void]$sb.Append('\') }
                '"'     { [void]$sb.Append('"') }
                'n'     { [void]$sb.Append("`n") }
                'r'     { [void]$sb.Append("`r") }
                't'     { [void]$sb.Append("`t") }
                '0'     { [void]$sb.Append([char]0) }
                default { [void]$sb.Append($inner[$i + 1]) }
            }
            $i++
        }
        else {
            [void]$sb.Append($inner[$i])
        }
    }

    $sb.ToString()
}

# Splits the argument list of a `new(...)` expression into positional and named parts.
function ConvertFrom-CsCtor {
    param([Parameter(Mandatory)][string]$Entry)

    $block = Get-CsBlock -Text $Entry -From 0 -Open '(' -Close ')'
    $ctorArgs = Split-CsList -Text $block.Content

    $positional = [System.Collections.Generic.List[string]]::new()
    $named      = @{}

    foreach ($arg in $ctorArgs) {
        # A named argument starts with a bare identifier + ':'. A string literal
        # never can, so this cannot misfire on text that merely contains a colon.
        $m = [regex]::Match($arg, '^\s*([A-Za-z_]\w*)\s*:\s*(.*)$', 'Singleline')
        if ($m.Success) {
            $named[$m.Groups[1].Value] = $m.Groups[2].Value.Trim()
        }
        else {
            $positional.Add($arg.Trim())
        }
    }

    [pscustomobject]@{
        Positional = @($positional)
        Named      = $named
    }
}
