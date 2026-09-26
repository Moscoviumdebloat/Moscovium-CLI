# =============================================================================
# Window chrome: the Windows 11 frame WinUI 3 gets for free
# =============================================================================
# WinUI 3 itself is not reachable from here. Its managed surface is .NET 6 or
# later and the baseline for this script is Windows PowerShell 5.1 on .NET
# Framework, which cannot load those assemblies at all. The projection also
# ships with an application rather than with Windows - the installed App SDK
# runtime package does not contain Microsoft.WinUI.dll - and a single file
# fetched over irm has nowhere to put several megabytes of its own DLLs.
#
# The part of the WinUI look that is not actually WinUI is reachable, though.
# A dark title bar and rounded corners are properties of the window handle, set
# through DwmSetWindowAttribute, and they land on a plain WPF window exactly as
# they do on a WinUI one. Measured on build 26200: the caption goes from
# 243,243,243 to 32,32,32.
#
# Mica is deliberately NOT set, though DWMWA_SYSTEMBACKDROP_TYPE is accepted
# here and would appear to work. Mica tints a window with the desktop
# wallpaper. On a dark wallpaper it is invisible - captured with and without
# it, the caption is 32,32,32 either way - and on a light one it would wash
# grey through a palette whose whole point is that true black leaves OLED
# pixels switched off. Invisible at best, wrong at worst, so it is not worth
# the attribute. Acrylic was measured too and does change the caption
# (32 -> 84), which is how we know DWM was honouring the calls at all.
#
# Every call is best effort. An unsupported attribute returns a failing HRESULT
# and changes nothing, which is why the build gates below are advisory rather
# than load bearing - on a machine too old for any of it the window simply
# looks the way it looked before.
# =============================================================================

# Attribute ids, from dwmapi.h.
$DwmImmersiveDarkModeOld = 19   # 18362..18984 shipped it under this number
$DwmImmersiveDarkMode    = 20
$DwmWindowCornerPref     = 33

# DWM_WINDOW_CORNER_PREFERENCE: round the corners the way Windows 11 does.
$DwmCornerRound = 2

# The build each attribute starts answering on.
$WinBuildDarkModeOld = 18362   # 1903: dark caption, under the old id
$WinBuildDarkMode    = 18985   # the id changed to 20 here and stayed
$WinBuildRounded     = 22000   # Windows 11: corner preference

# One import. DwmSetWindowAttribute takes a pointer, but every attribute used
# here is a single int, so the ref overload covers all of them.
#
# Built by joining lines rather than a here-string - build.ps1 indents every
# source line into the bundle's script block, and a here-string terminator has
# to sit at column 0.
function Initialize-DwmNative {
    if ('Moscovium.DwmNative' -as [type]) { return }

    $signature = @(
        '[DllImport("dwmapi.dll", SetLastError = true)]',
        'public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attribute, ref int value, int size);'
    ) -join [Environment]::NewLine

    Add-Type -MemberDefinition $signature -Name 'DwmNative' -Namespace 'Moscovium' -PassThru | Out-Null
}

# What this machine will actually honour. Reported rather than assumed so the
# GUI can say what it did, and so a test can assert the gates without needing
# the window on screen.
function Get-GuiChromeSupport {
    param([int]$Build = [Environment]::OSVersion.Version.Build)

    [pscustomobject]@{
        Build          = $Build
        DarkTitleBar   = ($Build -ge $WinBuildDarkModeOld)
        DarkModeAttr   = $(if ($Build -ge $WinBuildDarkMode) { $DwmImmersiveDarkMode } else { $DwmImmersiveDarkModeOld })
        RoundedCorners = ($Build -ge $WinBuildRounded)
    }
}

# Sets one attribute. Returns whether DWM accepted it; S_OK is 0.
function Set-DwmWindowAttribute {
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][int]$Attribute,
        [Parameter(Mandatory)][int]$Value
    )

    $buffer = $Value
    try {
        $result = [Moscovium.DwmNative]::DwmSetWindowAttribute($Handle, $Attribute, [ref]$buffer, 4)
    }
    catch { return $false }

    return ($result -eq 0)
}

# Applies the chrome to a window that already has a handle. Safe to call on a
# window that has never been shown: the handle is zero until WPF creates it,
# and this returns an all-false report rather than throwing.
function Set-GuiWindowChrome {
    param([Parameter(Mandatory)]$Window)

    $report = [pscustomobject]@{
        DarkTitleBar   = $false
        RoundedCorners = $false
    }

    try { Initialize-DwmNative }
    catch { return $report }

    $helper = New-Object Windows.Interop.WindowInteropHelper $Window
    $handle = $helper.Handle
    if ($handle -eq [IntPtr]::Zero) { return $report }

    $support = Get-GuiChromeSupport

    if ($support.DarkTitleBar) {
        $report.DarkTitleBar = Set-DwmWindowAttribute -Handle $handle -Attribute $support.DarkModeAttr -Value 1
    }

    if ($support.RoundedCorners) {
        $report.RoundedCorners = Set-DwmWindowAttribute -Handle $handle -Attribute $DwmWindowCornerPref -Value $DwmCornerRound
    }

    return $report
}

# Arranges for the chrome to be applied as soon as WPF creates the handle.
#
# SourceInitialized is the first moment the HWND exists and the last moment
# before anything is painted, so the caption is never drawn light and then
# repainted dark. A window that is built but never shown - which is what the
# render tests do - never raises it, and never touches DWM.
function Register-GuiWindowChrome {
    param([Parameter(Mandatory)]$Window)

    $Window.Add_SourceInitialized({
        param($sender, $e)
        Set-GuiWindowChrome -Window $sender | Out-Null
    })
}
