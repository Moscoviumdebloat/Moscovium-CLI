# =============================================================================
# Setup profiles.
#
# Same JSON shape as the GUI's SetupProfile record, so a profile saved in the
# desktop app runs here and vice versa. Property names are matched
# case-insensitively because the GUI's serializer and this one disagree on
# casing depending on version.
# =============================================================================

$ProfileVersion = 1

function Get-ProfileProperty {
    param(
        [Parameter(Mandatory)]$SetupProfile,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    $property = $SetupProfile.PSObject.Properties |
        Where-Object { $_.Name -eq $Name } |
        Select-Object -First 1

    if (-not $property) {
        $property = $SetupProfile.PSObject.Properties |
            Where-Object { $_.Name -ieq $Name } |
            Select-Object -First 1
    }

    if ($property -and $null -ne $property.Value) { return $property.Value }
    return $Default
}

function New-SetupProfile {
    param(
        [string[]]$Apps = @(),
        [string[]]$Tweaks = @(),
        [switch]$RunWindowsUpdate,
        [switch]$UpgradeAllApps,
        [switch]$InstallVCRuntimes,
        [switch]$RunChrisTitus,
        [switch]$RunRaphi
    )

    [pscustomobject]@{
        Version           = $ProfileVersion
        WingetApps        = @($Apps)
        Tweaks            = @($Tweaks)
        RunWindowsUpdate  = [bool]$RunWindowsUpdate
        UpgradeAllApps    = [bool]$UpgradeAllApps
        InstallVCRuntimes = [bool]$InstallVCRuntimes
        RunChrisTitus     = [bool]$RunChrisTitus
        RunRaphi          = [bool]$RunRaphi
    }
}

function Save-SetupProfile {
    param(
        [Parameter(Mandatory)]$SetupProfile,
        [Parameter(Mandatory)][string]$Path
    )

    $full = $Path
    if (-not [IO.Path]::IsPathRooted($full)) { $full = Join-Path (Get-Location).Path $full }

    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = $SetupProfile | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($full, $json, (New-Object Text.UTF8Encoding $false))

    Write-Ok "Profile saved to $full"
    return $full
}

function Import-SetupProfile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Profile not found: $Path" }

    $setupProfile = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json

    $version = Get-ProfileProperty -SetupProfile $setupProfile -Name 'Version' -Default 1
    if ([int]$version -gt $ProfileVersion) {
        Write-Warn "Profile is version $version but this build understands version $ProfileVersion. Unknown fields will be ignored."
    }

    return $setupProfile
}

# The GUI bundles a VC runtimes archive; winget carries the same redistributables
# and keeps them current, so the CLI installs them by package id instead.
function Get-VCRuntimePackageIds {
    @(
        'Microsoft.VCRedist.2015+.x64'
        'Microsoft.VCRedist.2015+.x86'
        'Microsoft.VCRedist.2013.x64'
        'Microsoft.VCRedist.2013.x86'
        'Microsoft.VCRedist.2012.x64'
        'Microsoft.VCRedist.2012.x86'
        'Microsoft.VCRedist.2010.x64'
        'Microsoft.VCRedist.2010.x86'
        'Microsoft.VCRedist.2008.x64'
        'Microsoft.VCRedist.2008.x86'
        'Microsoft.VCRedist.2005.x64'
        'Microsoft.VCRedist.2005.x86'
    )
}

function Install-VCRuntimes {
    if (-not (Assert-Winget)) { return }

    Write-SectionHeading 'Visual C++ runtimes'

    if ($Ctx.DryRun) {
        foreach ($id in Get-VCRuntimePackageIds) { Write-Info "would install $id" }
        return
    }

    foreach ($id in Get-VCRuntimePackageIds) {
        $result = Invoke-Winget -Quiet -Arguments @(
            'install', '--id', $id, '--exact', '--silent',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
        )

        if ($result.Benign)      { Write-Info "$id - already present" }
        elseif ($result.Success) { Write-Ok $id }
        else                     { Write-Warn "$id - winget returned $($result.ExitCode)" }
    }
}

function Invoke-WindowsUpdate {
    Write-SectionHeading 'Windows Update'

    if (-not $Ctx.IsAdmin) {
        Write-Err 'Windows Update needs administrator rights.'
        return
    }

    if ($Ctx.DryRun) {
        Write-Info 'would install the PSWindowsUpdate module and run Get-WindowsUpdate -Install -AcceptAll'
        return
    }

    Write-Warn 'This installs the PSWindowsUpdate module from the PowerShell Gallery, then installs all pending updates.'
    if (-not (Confirm-Action 'Continue?')) { return }

    try {
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Write-Step 'Installing PSWindowsUpdate'
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
            Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
        }

        Import-Module PSWindowsUpdate -ErrorAction Stop
        Write-Step 'Checking for updates'

        # -AutoReboot off: rebooting is the user's decision, not ours.
        Get-WindowsUpdate -Install -AcceptAll -IgnoreReboot -Verbose:$false -ErrorAction Stop |
            ForEach-Object { Write-Info $_ }

        Write-Ok 'Windows Update pass complete.'
    }
    catch {
        Write-Err "Windows Update failed: $($_.Exception.Message)"
    }
}

function Invoke-SetupProfile {
    param([Parameter(Mandatory)][string]$Path)

    $setupProfile = Import-SetupProfile -Path $Path

    $appIds = @(Get-ProfileProperty -SetupProfile $setupProfile -Name 'WingetApps' -Default @())
    $tweakNames = @(Get-ProfileProperty -SetupProfile $setupProfile -Name 'Tweaks' -Default @())

    Write-SectionHeading "Profile: $(Split-Path -Leaf $Path)"
    Write-Info "$($appIds.Count) app(s), $($tweakNames.Count) tweak(s)"

    $flags = @()
    foreach ($name in @('RunWindowsUpdate', 'UpgradeAllApps', 'InstallVCRuntimes', 'RunChrisTitus', 'RunRaphi')) {
        if (Get-ProfileProperty -SetupProfile $setupProfile -Name $name -Default $false) { $flags += $name }
    }
    if ($flags.Count -gt 0) { Write-Info "extras: $($flags -join ', ')" }

    if (-not $Ctx.DryRun -and -not (Confirm-Action 'Run this profile?' -DefaultYes)) {
        Write-Warn 'Cancelled.'
        return
    }

    # Order matters: a restore point and tweaks first, then apps, then the
    # long-running update passes.
    if ($tweakNames.Count -gt 0) {
        $resolved = Resolve-Tweak -Names $tweakNames
        foreach ($miss in $resolved.Unknown) { Write-Warn "Profile names an unknown tweak: $miss" }
        Invoke-Tweaks -Tweaks $resolved.Matched -Mode Apply
    }

    if (Get-ProfileProperty -SetupProfile $setupProfile -Name 'InstallVCRuntimes' -Default $false) {
        Install-VCRuntimes
    }

    if ($appIds.Count -gt 0) {
        $resolved = Resolve-App -Names $appIds
        foreach ($miss in $resolved.Unknown) { Write-Warn "Profile names an unknown app: $miss" }
        Invoke-AppInstall -Apps $resolved.Matched
    }

    if (Get-ProfileProperty -SetupProfile $setupProfile -Name 'RunChrisTitus' -Default $false) {
        Invoke-ToolboxAction -Id 'winutil-preset'
    }

    if (Get-ProfileProperty -SetupProfile $setupProfile -Name 'RunRaphi' -Default $false) {
        Invoke-ToolboxAction -Id 'raphi-auto'
    }

    if (Get-ProfileProperty -SetupProfile $setupProfile -Name 'UpgradeAllApps' -Default $false) {
        Invoke-UpgradeAll
    }

    if (Get-ProfileProperty -SetupProfile $setupProfile -Name 'RunWindowsUpdate' -Default $false) {
        Invoke-WindowsUpdate
    }

    Write-Line ''
    Write-Ok 'Profile complete.'
}
