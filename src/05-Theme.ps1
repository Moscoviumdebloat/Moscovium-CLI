# =============================================================================
# Theme: terminal capability detection, glyphs, palette, and the drawing
# primitives everything else renders through.
#
# Two hard constraints shape this file.
#
# 1. src/ must stay pure ASCII (build.ps1 enforces it, because the bundle ships
#    without a BOM and Windows PowerShell 5.1 would decode it as ANSI). So every
#    box-drawing character is built from its code point at runtime, never typed
#    as a literal.
#
# 2. No ANSI escape sequences. Legacy conhost on a fresh Windows install does not
#    process them by default, and a debloat tool is exactly the thing people run
#    on a fresh install. Everything here uses Write-Host's 16 colours, which
#    render identically in conhost and Windows Terminal, and a foreground and
#    background pair is enough for a real selection bar.
#
# Unicode still needs the console output encoding to be UTF-8, so that is set on
# startup and restored on exit - and only when we have decided to use it.
# =============================================================================

function ConvertTo-Char {
    param([Parameter(Mandatory)][int]$CodePoint)
    [string][char]$CodePoint
}

# Windows Terminal and PowerShell 7 handle UTF-8 output reliably. Legacy conhost
# on an OEM code page does not, and would render box drawing as question marks.
function Test-UnicodeCapable {
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        if ($env:WT_SESSION) { return $true }
        if ($env:TERM_PROGRAM -eq 'vscode') { return $true }
        if ($PSVersionTable.PSVersion.Major -ge 6) { return $true }
        if ([Console]::OutputEncoding.CodePage -eq 65001) { return $true }
    }
    catch { }
    return $false
}

function New-GlyphSet {
    param([Parameter(Mandatory)][bool]$Unicode)

    if (-not $Unicode) {
        return @{
            Ok = '+'; Err = 'x'; Warn = '!'; Info = '.'; Step = '>'; Bullet = '-'
            Checked = '[x]'; Unchecked = '[ ]'; Partial = '[~]'; Action = '[>]'
            Pointer = '>'; Sep = '|'
            HLine = '-'; VLine = '|'
            TopLeft = '+'; TopRight = '+'; BottomLeft = '+'; BottomRight = '+'
            BarFull = '#'; BarEmpty = '.'
            Dot = '*'; Arrow = '->'
            Spinner = @('|', '/', '-', '\')
            # Sparkline ramp, lowest to highest. Eight levels either way, so a
            # graph has the same resolution on both consoles.
            Spark = @('_', '.', ',', '-', '=', '+', '*', '#')
        }
    }

    @{
        Ok          = ConvertTo-Char 0x2713   # check mark
        Err         = ConvertTo-Char 0x2717   # ballot x
        Warn        = ConvertTo-Char 0x25B2   # black up-pointing triangle
        Info        = ConvertTo-Char 0x00B7   # middle dot
        Step        = ConvertTo-Char 0x203A   # single right angle quotation
        Bullet      = ConvertTo-Char 0x2022   # bullet
        Checked     = ConvertTo-Char 0x25C9   # fisheye
        Unchecked   = ConvertTo-Char 0x25CB   # white circle
        Partial     = ConvertTo-Char 0x25D0   # circle with left half black
        Action      = ConvertTo-Char 0x25B8   # black right-pointing small triangle
        Pointer     = ConvertTo-Char 0x276F   # heavy right angle quotation
        Sep         = ConvertTo-Char 0x00B7
        HLine       = ConvertTo-Char 0x2500
        VLine       = ConvertTo-Char 0x2502
        TopLeft     = ConvertTo-Char 0x256D
        TopRight    = ConvertTo-Char 0x256E
        BottomLeft  = ConvertTo-Char 0x2570
        BottomRight = ConvertTo-Char 0x256F
        BarFull     = ConvertTo-Char 0x2588   # full block
        BarEmpty    = ConvertTo-Char 0x2591   # light shade
        Dot         = ConvertTo-Char 0x25CF   # black circle
        Arrow       = ConvertTo-Char 0x2192
        # Braille spinner: eight dots cycling, reads as smooth rotation.
        Spinner     = @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F |
                        ForEach-Object { ConvertTo-Char $_ })
        # Lower blocks, one eighth to full - the sparkline ramp the history
        # graphs draw with. U+2581 rather than U+2580 as the floor: a graph of
        # zeroes should still show a baseline.
        Spark       = @(0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588 |
                        ForEach-Object { ConvertTo-Char $_ })
    }
}

function New-Palette {
    @{
        # Purple, to match the window. Magenta and DarkMagenta are as close as
        # the sixteen console colours get; conhost draws both as violet.
        Accent      = [ConsoleColor]::Magenta
        AccentDim   = [ConsoleColor]::DarkMagenta
        Ok          = [ConsoleColor]::Green
        Warn        = [ConsoleColor]::Yellow
        Err         = [ConsoleColor]::Red
        Text        = [ConsoleColor]::Gray
        Bright      = [ConsoleColor]::White
        Muted       = [ConsoleColor]::DarkGray
        # Aliases Muted rather than being dimmer: DarkGray is the dimmest thing
        # in the sixteen that is still readable, and the next step down is
        # black. The window has a genuinely fainter Faint; here the two are the
        # same colour, and the name exists so both front-ends can ask for the
        # same role. Write-Line takes a [ConsoleColor], so a missing key throws.
        Faint       = [ConsoleColor]::DarkGray
        HighlightFg = [ConsoleColor]::White
        HighlightBg = [ConsoleColor]::DarkMagenta
        SelectedFg  = [ConsoleColor]::Green
    }
}

function New-Theme {
    param([switch]$Ascii)

    $unicode = (-not $Ascii) -and (Test-UnicodeCapable)

    [pscustomobject]@{
        Unicode = $unicode
        Glyph   = New-GlyphSet -Unicode $unicode
        Color   = New-Palette
    }
}

function Get-Glyph {
    param([Parameter(Mandatory)][string]$Name)
    $Ctx.Theme.Glyph[$Name]
}

function Get-Color {
    param([Parameter(Mandatory)][string]$Name)
    $Ctx.Theme.Color[$Name]
}

# Box drawing only renders if the console can encode it. Returns the previous
# encoding so the caller can put it back; native tools like winget are decoded
# through this same setting, so leaving it changed would be rude.
function Initialize-ConsoleEncoding {
    if (-not $Ctx.Theme.Unicode) { return $null }

    try {
        $previous = [Console]::OutputEncoding
        if ($previous.CodePage -ne 65001) {
            [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
            return $previous
        }
    }
    catch {
        # A host that will not let us set it also will not render the glyphs.
        $Ctx.Theme = New-Theme -Ascii
    }

    return $null
}

function Restore-ConsoleEncoding {
    param($Previous)
    if ($Previous) {
        try { [Console]::OutputEncoding = $Previous } catch { }
    }
}

# -----------------------------------------------------------------------------
# Drawing
# -----------------------------------------------------------------------------

# The wordmark, as lines already paired with their colour.
#
# Shared, so the splash and the menu header cannot drift apart - the menu used
# to print a plain word where the splash printed this.
#
# Plain ASCII only: it has to render in a legacy conhost window on code page
# 437, not just Windows Terminal. The backtick on the fourth line is part of the
# letterform, not a PowerShell escape - these are single-quoted strings, so it
# is taken literally.
function Get-WordmarkLines {
    $art = @(
        '   __  __                                   _',
        '  |  \/  |  ___   ___   ___   ___  __   __ (_) _   _  _ __ ___  ',
        '  | |\/| | / _ \ / __| / __| / _ \ \ \ / / | || | | || ''_ ` _ \ ',
        '  | |  | || (_) |\__ \| (__ | (_) | \ V /  | || |_| || | | | | |',
        '  |_|  |_| \___/ |___/ \___| \___/   \_/   |_| \__,_||_| |_| |_|'
    )

    # Top-down gradient, Magenta -> DarkMagenta. Only sixteen colours are in
    # play and neither is a true purple, but conhost draws both as violet and it
    # needs no ANSI support.
    #
    # No White at the top: the first line is the thin roof of the letterforms,
    # and a white roof over purple letters reads as a rendering fault rather
    # than a highlight. Every line is purple.
    $ramp = @(
        [ConsoleColor]::Magenta
        [ConsoleColor]::Magenta
        [ConsoleColor]::Magenta
        [ConsoleColor]::DarkMagenta
        [ConsoleColor]::DarkMagenta
    )

    for ($i = 0; $i -lt $art.Count; $i++) {
        [pscustomobject]@{
            Text  = $art[$i]
            Color = $ramp[[Math]::Min($i, $ramp.Count - 1)]
        }
    }
}

# The widest line, so a caller can tell whether the window can hold the art
# before drawing it into a fixed-height frame.
function Get-WordmarkWidth {
    $widest = 0
    foreach ($line in @(Get-WordmarkLines)) {
        if ($line.Text.Length -gt $widest) { $widest = $line.Text.Length }
    }
    return $widest
}

function Get-RuleWidth {
    $width = 78
    try {
        $available = $Host.UI.RawUI.WindowSize.Width - 4
        if ($available -gt 20) { $width = [Math]::Min(78, $available) }
    }
    catch { }
    return $width
}

# A titled horizontal rule:  --- Privacy & Telemetry ------------------ 7
function Write-Rule {
    param(
        [AllowEmptyString()][string]$Title = '',
        [AllowEmptyString()][string]$Suffix = '',
        [ConsoleColor]$TitleColor = [ConsoleColor]::White,
        # Suppresses the leading blank line, for rules that close a block rather
        # than open one.
        [switch]$Tight
    )

    $line = Get-Glyph 'HLine'
    $width = Get-RuleWidth

    if (-not $Tight) { Write-Line '' }

    if (-not $Title) {
        Write-Line ('  ' + ($line * $width)) -Color (Get-Color 'Muted')
        return
    }

    $lead = $line * 3
    $used = 2 + $lead.Length + 1 + $Title.Length + 1
    $suffixText = if ($Suffix) { ' ' + $Suffix } else { '' }
    $fill = [Math]::Max(3, $width - ($used - 2) - $suffixText.Length)

    Write-Line "  $lead " -Color (Get-Color 'Muted') -NoNewline
    Write-Line $Title -Color $TitleColor -NoNewline
    Write-Line (' ' + ($line * $fill)) -Color (Get-Color 'Muted') -NoNewline

    if ($suffixText) { Write-Line $suffixText -Color (Get-Color 'Muted') -NoNewline }
    Write-Line ''
}

# A row of "  a  .  b  .  c  " status chips.
function Write-Chips {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Chips)

    if ($Chips.Count -eq 0) { return }

    $separator = '   ' + (Get-Glyph 'Sep') + '   '

    Write-Line '  ' -NoNewline
    for ($i = 0; $i -lt $Chips.Count; $i++) {
        if ($i -gt 0) { Write-Line $separator -Color (Get-Color 'Muted') -NoNewline }

        $chip = $Chips[$i]
        if ($chip.Glyph) {
            Write-Line ($chip.Glyph + ' ') -Color $chip.Color -NoNewline
        }
        Write-Line $chip.Text -Color $(if ($chip.Dim) { Get-Color 'Muted' } else { $chip.Color }) -NoNewline
    }
    Write-Line ''
}

function New-Chip {
    param(
        [Parameter(Mandatory)][string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::Gray,
        [string]$Glyph = '',
        [switch]$Dim
    )
    [pscustomobject]@{ Text = $Text; Color = $Color; Glyph = $Glyph; Dim = [bool]$Dim }
}

# -----------------------------------------------------------------------------
# Live progress
#
# Both of these rewrite the current line with a carriage return, so they are
# suppressed when output is redirected - a log file should not collect 400
# copies of a progress bar.
# -----------------------------------------------------------------------------

function Write-InlineLine {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if (-not $Ctx.Animate) { return }

    $width = 100
    try { $width = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 1) } catch { }

    $text = if ($Text.Length -gt $width) { $Text.Substring(0, $width) } else { $Text.PadRight($width) }
    Write-Host ("`r" + $text) -NoNewline
}

function Clear-InlineLine {
    if (-not $Ctx.Animate) { return }

    $width = 100
    try { $width = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 1) } catch { }
    Write-Host ("`r" + (' ' * $width) + "`r") -NoNewline
}

function Write-ProgressBar {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][double]$Fraction,
        [AllowEmptyString()][string]$Detail = '',
        [int]$Width = 26
    )

    $Fraction = [Math]::Max(0.0, [Math]::Min(1.0, $Fraction))

    # The GUI drives a real progress bar from the same call sites.
    if ($Ctx.ProgressSink) { & $Ctx.ProgressSink $Label $Fraction $Detail; return }
    if (-not $Ctx.Animate) { return }

    $filled = [int][Math]::Round($Width * $Fraction)

    $bar = ((Get-Glyph 'BarFull') * $filled) + ((Get-Glyph 'BarEmpty') * ($Width - $filled))
    $percent = '{0,3:N0}%' -f ($Fraction * 100)

    Write-InlineLine ("    {0}  {1}  {2}{3}" -f $Label, $bar, $percent, $(if ($Detail) { "   $Detail" } else { '' }))
}

function Write-Activity {
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][int]$Tick
    )

    # Indeterminate work: report it as a pulsing bar in the GUI.
    if ($Ctx.ProgressSink) { & $Ctx.ProgressSink $Message (-1.0) ''; return }
    if (-not $Ctx.Animate) { return }

    $frames = @(Get-Glyph 'Spinner')
    $frame = $frames[$Tick % $frames.Count]
    Write-InlineLine "    $frame  $Message"
}
