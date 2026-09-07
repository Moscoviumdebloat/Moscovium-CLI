# =============================================================================
# Drivers: what is installed, what is broken, and where the real ones come from.
#
# Deliberately not a driver installer. The tools that mass-install drivers from
# scraped packs are exactly the kind of thing that turns a working machine into
# a non-booting one, and this tool is run on machines people have just set up.
# So this reports, backs up, and points at the vendor.
#
# Where the vendor links come from
# -----------------------------------------------------------------------------
# winget does not carry the GPU vendor tools. Checked live: searching it for
# 'nvidia', 'geforce', 'intel driver', 'AMD Adrenalin' and 'AMD Radeon' turns up
# CUDA, GeForce NOW and AMD's Cloud Edition, and nothing that installs a display
# driver. Display Driver Uninstaller is the one real package
# (Wagnardsoft.DisplayDriverUninstaller), so it is the one thing offered as an
# install; everything else is a link to the vendor's own download page, which is
# where a GPU driver should come from anyway.
#
# Why the PCI vendor id and not AdapterCompatibility
# -----------------------------------------------------------------------------
# Win32_VideoController.AdapterCompatibility is whatever the driver put there.
# On the machine this was written on it reads 'Broadcom Inc.' for a VMware
# adapter. PNPDeviceID carries VEN_xxxx, which is the actual PCI vendor and does
# not lie.
# =============================================================================

# PCI vendor ids, from the PCI-SIG assignments.
function Get-GraphicsVendors {
    @(
        [pscustomobject]@{
            Id = 'nvidia'; Name = 'NVIDIA'; PciIds = @('10DE')
            Url = 'https://www.nvidia.com/en-us/drivers/'
            Virtual = $false
        }
        [pscustomobject]@{
            # 1002 is ATI/Radeon, 1022 is AMD's own id used by some integrated parts.
            Id = 'amd'; Name = 'AMD'; PciIds = @('1002', '1022')
            Url = 'https://www.amd.com/en/support/download/drivers.html'
            Virtual = $false
        }
        [pscustomobject]@{
            Id = 'intel'; Name = 'Intel'; PciIds = @('8086')
            Url = 'https://www.intel.com/content/www/us/en/download-center/home.html'
            Virtual = $false
        }
        # Virtual adapters have no vendor driver to go and get, and saying so is
        # more use than sending someone to a download page for hardware they do
        # not have.
        [pscustomobject]@{
            Id = 'vmware'; Name = 'VMware'; PciIds = @('15AD'); Url = ''; Virtual = $true
        }
        [pscustomobject]@{
            Id = 'hyperv'; Name = 'Microsoft'; PciIds = @('1414'); Url = ''; Virtual = $true
        }
        [pscustomobject]@{
            Id = 'virtualbox'; Name = 'VirtualBox'; PciIds = @('80EE'); Url = ''; Virtual = $true
        }
        [pscustomobject]@{
            Id = 'qemu'; Name = 'QEMU / Red Hat'; PciIds = @('1234', '1AF4'); Url = ''; Virtual = $true
        }
    )
}

function Resolve-GraphicsVendor {
    param([AllowEmptyString()][string]$PnpDeviceId)

    if ([string]::IsNullOrWhiteSpace($PnpDeviceId)) { return $null }
    if ($PnpDeviceId -notmatch 'VEN_([0-9A-Fa-f]{4})') { return $null }

    $pci = $Matches[1].ToUpperInvariant()
    foreach ($vendor in Get-GraphicsVendors) {
        if ($vendor.PciIds -contains $pci) { return $vendor }
    }

    return $null
}

function Get-GraphicsAdapter {
    $query = 'SELECT Name,DriverVersion,DriverDate,AdapterCompatibility,PNPDeviceID,AdapterRAM,Status FROM Win32_VideoController'
    $adapters = [System.Collections.Generic.List[object]]::new()

    foreach ($row in @(Get-CimInstance -Query $query -ErrorAction Stop)) {
        $vendor = Resolve-GraphicsVendor -PnpDeviceId ([string]$row.PNPDeviceID)

        $pci = ''
        if ([string]$row.PNPDeviceID -match 'VEN_([0-9A-Fa-f]{4})') { $pci = $Matches[1].ToUpperInvariant() }

        $date = $null
        try { if ($row.DriverDate) { $date = [DateTime]$row.DriverDate } } catch { }

        $adapters.Add([pscustomobject]@{
            Name          = [string]$row.Name
            DriverVersion = [string]$row.DriverVersion
            DriverDate    = $date
            Vendor        = $vendor
            PciId         = $pci
            # Kept so the difference is visible when it disagrees with the PCI id.
            ReportedBy    = [string]$row.AdapterCompatibility
        })
    }

    return @($adapters)
}

# -----------------------------------------------------------------------------
# Where the drivers come from
#
# Each vendor is reached the only way that vendor allows, and the three are not
# the same. All of this was checked against the live sites:
#
#   Intel   dsadata.intel.com/installer is a stable 'always current' endpoint -
#           it answered 200 with an 8.7MB installer. One tool covers graphics,
#           chipset, Wi-Fi and Bluetooth, so Intel needs no separate CPU entry.
#
#   NVIDIA  No stable endpoint, but their own page carries the current link, so
#           the installer URL is scraped from it the same way Nilesoft's is.
#           Verified: 183MB, application/octet-stream.
#
#   AMD     Blocks direct downloads. Both drivers.amd.com/drivers/
#           AMDSoftwareInstaller.exe and a full versioned Adrenalin URL redirect
#           to amd.com/.../Download-Incomplete.html, so there is nothing to
#           fetch - the entry opens their page instead of pretending.
#
# The GPU driver itself still comes from the vendor's own installer, which is
# what every one of these downloads is. Nothing here installs a driver directly.
# -----------------------------------------------------------------------------

function Get-DriverSources {
    @(
        [pscustomobject]@{
            Id = 'nvidia-app'; Vendor = 'nvidia'; For = 'gpu'
            Name = 'NVIDIA App'
            Summary = 'NVIDIA''s own driver manager. Installs the GeForce driver and keeps it current.'
            # Scraped rather than pinned: NVIDIA versions the path, and their
            # page always carries the current one. The pinned URL is only the
            # fallback for when the page changes shape.
            PageUrl = 'https://www.nvidia.com/en-us/software/nvidia-app/'
            Pattern = 'https://us\.download\.nvidia\.com/nvapp/client/[0-9.]+/NVIDIA_app_v[0-9.]+\.exe'
            DownloadUrl = 'https://us.download.nvidia.com/nvapp/client/11.0.9.251/NVIDIA_app_v11.0.9.251.exe'
            OpenUrl = 'https://www.nvidia.com/en-us/drivers/'
        }
        [pscustomobject]@{
            Id = 'intel-dsa'; Vendor = 'intel'; For = 'both'
            Name = 'Intel Driver and Support Assistant'
            Summary = 'Intel''s own detector. Covers graphics, chipset, Wi-Fi and Bluetooth in one tool.'
            PageUrl = ''
            Pattern = ''
            DownloadUrl = 'https://dsadata.intel.com/installer'
            OpenUrl = 'https://www.intel.com/content/www/us/en/download-center/home.html'
        }
        [pscustomobject]@{
            Id = 'amd-gpu'; Vendor = 'amd'; For = 'gpu'
            Name = 'AMD Software: Adrenalin Edition'
            Summary = 'The Radeon driver and control panel. AMD blocks direct downloads, so this opens their page.'
            PageUrl = ''
            Pattern = ''
            # Empty on purpose - see the note above.
            DownloadUrl = ''
            OpenUrl = 'https://www.amd.com/en/support/download/drivers.html'
        }
        [pscustomobject]@{
            Id = 'amd-chipset'; Vendor = 'amd'; For = 'cpu'
            Name = 'AMD Chipset Drivers'
            Summary = 'Chipset and power plan drivers for a Ryzen or Threadripper board. Also a download AMD gates.'
            PageUrl = ''
            Pattern = ''
            DownloadUrl = ''
            OpenUrl = 'https://www.amd.com/en/support/download/drivers.html'
        }
    )
}

function Resolve-DriverSource {
    param([Parameter(Mandatory)][string]$Id)

    $sources = Get-DriverSources

    $exact = @($sources | Where-Object { $_.Id -eq $Id })
    if ($exact.Count -eq 1) { return $exact[0] }

    $fuzzy = @($sources | Where-Object {
        (Test-NameMatch -Value $_.Id -Pattern $Id) -or (Test-NameMatch -Value $_.Name -Pattern $Id)
    })
    if ($fuzzy.Count -eq 1) { return $fuzzy[0] }

    if ($fuzzy.Count -gt 1) {
        Write-Err "'$Id' is ambiguous. Did you mean one of these?"
        foreach ($source in $fuzzy) { Write-Info $source.Id }
        return $null
    }

    Write-Err "Unknown driver source '$Id'. Known: $((Get-DriverSources | ForEach-Object { $_.Id }) -join ', ')."
    return $null
}

# AuthenticAMD / GenuineIntel, straight off the processor.
function Get-ProcessorVendor {
    try {
        $processor = @(Get-CimInstance -Query 'SELECT Manufacturer FROM Win32_Processor' -ErrorAction Stop)[0]
        switch ([string]$processor.Manufacturer) {
            'AuthenticAMD' { return 'amd' }
            'GenuineIntel' { return 'intel' }
            default        { return '' }
        }
    }
    catch { return '' }
}

# Only the sources that match hardware actually in this machine: an NVIDIA
# entry on an all-AMD box is noise, and a link to a driver for hardware someone
# does not own is worse than no link.
function Get-RelevantDriverSources {
    $wanted = [System.Collections.Generic.List[string]]::new()

    foreach ($adapter in @(Get-GraphicsAdapter)) {
        if (-not $adapter.Vendor -or $adapter.Vendor.Virtual) { continue }
        if (-not $wanted.Contains("gpu:$($adapter.Vendor.Id)")) { $wanted.Add("gpu:$($adapter.Vendor.Id)") }
    }

    $cpu = Get-ProcessorVendor
    if ($cpu) { $wanted.Add("cpu:$cpu") }

    $relevant = [System.Collections.Generic.List[object]]::new()
    foreach ($source in Get-DriverSources) {
        $matched = $false

        # 'both' means the vendor's one tool covers graphics and chipset, so it
        # is relevant if either matches.
        if ($source.For -in @('gpu', 'both') -and $wanted.Contains("gpu:$($source.Vendor)")) { $matched = $true }
        if ($source.For -in @('cpu', 'both') -and $wanted.Contains("cpu:$($source.Vendor)")) { $matched = $true }

        if ($matched) { $relevant.Add($source) }
    }

    return @($relevant)
}

# Downloads and runs the vendor's own installer where the vendor allows it, and
# opens their page where it does not.
function Install-DriverSource {
    param([Parameter(Mandatory)][string]$Id)

    $source = Resolve-DriverSource -Id $Id
    if (-not $source) { return $false }

    if ([string]::IsNullOrWhiteSpace($source.DownloadUrl)) {
        Write-SectionHeading $source.Name
        Write-Info $source.Summary
        Write-Info 'This one has to come from the vendor page - they do not allow a direct download.'
        Write-Line "      $($source.OpenUrl)" -Color White

        if ($Ctx.DryRun) { return $false }

        if (Confirm-Action 'Open it in your browser?' -DefaultYes) {
            try { Start-Process $source.OpenUrl | Out-Null }
            catch { Write-Err "Could not open the browser: $($_.Exception.Message)" }
        }
        return $false
    }

    if ($Ctx.DryRun) {
        Write-Status -Glyph (Get-Glyph 'Info') -Color (Get-Color 'Warn') -Message $source.Name -MessageColor (Get-Color 'Warn')
        if ($source.PageUrl) { Write-Info "would take the current installer link from $($source.PageUrl) and run it" }
        else { Write-Info "would download the installer from $($source.DownloadUrl) and run it" }
        return $false
    }

    Write-Line ''
    Write-Warn "$($source.Name) is $($source.Vendor.ToUpperInvariant())'s own installer:"
    Write-Line "      $($source.OpenUrl)" -Color White
    Write-Info 'Moscovium downloads and starts it; the vendor installer does the rest.'

    # Through Install-App, which already has the download, progress, exit-code
    # and counter handling - and knows how to run an .exe installer.
    $app = [pscustomobject]@{
        id             = $source.Id
        name           = $source.Name
        downloadUrl    = $source.DownloadUrl
        resolvePageUrl = $(if ($source.PageUrl) { $source.PageUrl } else { $null })
        resolvePattern = $(if ($source.Pattern) { $source.Pattern } else { $null })
        zipUrl         = $null
        scriptUrl      = $null
        wingetId       = $null
        source         = $null
    }

    $before = $Ctx.Applied
    Install-App -App $app
    return ($Ctx.Applied -gt $before)
}

# -----------------------------------------------------------------------------
# Devices that are not working
# -----------------------------------------------------------------------------

# Win32_PnPEntity.ConfigManagerErrorCode, in the words Device Manager uses.
# The common ones are worth spelling out - '28' means nothing to anyone, while
# 'the drivers for this device are not installed' is the whole answer.
function Get-DeviceProblemMeaning {
    param([Parameter(Mandatory)][int]$Code)

    switch ($Code) {
        1  { return 'Not configured correctly.' }
        3  { return 'The driver may be corrupted, or the system is low on memory.' }
        9  { return 'Windows cannot identify this hardware - its registry information is invalid.' }
        10 { return 'The device cannot start.' }
        12 { return 'Cannot find enough free resources to use.' }
        14 { return 'Cannot work properly until the computer is restarted.' }
        16 { return 'Windows cannot identify all the resources this device uses.' }
        18 { return 'Reinstall the drivers for this device.' }
        19 { return 'The registry entry for this device is incomplete or damaged.' }
        21 { return 'Windows is removing this device.' }
        22 { return 'This device is disabled.' }
        24 { return 'Not present, not working properly, or missing drivers.' }
        28 { return 'The drivers for this device are not installed.' }
        29 { return 'Disabled because its firmware did not give it the required resources.' }
        31 { return 'Windows cannot load the drivers required for this device.' }
        32 { return 'A driver for this device has been disabled - a dependency is not starting.' }
        33 { return 'Windows cannot determine which resources this device requires.' }
        34 { return 'Windows cannot determine the settings for this device.' }
        35 { return 'The system firmware does not have enough information to configure this device.' }
        36 { return 'This device is requesting a PCI interrupt but is configured for ISA, or the reverse.' }
        37 { return 'Windows cannot initialize the device driver.' }
        38 { return 'A previous instance of the driver is still in memory.' }
        39 { return 'The driver may be corrupted or missing.' }
        40 { return 'Its service key information in the registry is missing or wrong.' }
        41 { return 'The driver loaded but Windows cannot find the hardware.' }
        42 { return 'A duplicate device is already running.' }
        43 { return 'Windows stopped this device because it reported problems.' }
        44 { return 'An application or service shut this device down.' }
        45 { return 'Not currently connected to the computer.' }
        46 { return 'Not available because the system is shutting down.' }
        47 { return 'Prepared for safe removal, but not removed.' }
        48 { return 'The software for this device has been blocked from starting.' }
        49 { return 'Windows cannot start new devices - the system hive is too large.' }
        50 { return 'Windows cannot apply all the properties for this device.' }
        51 { return 'Waiting on another device to start.' }
        52 { return 'Windows cannot verify the digital signature for this driver.' }
        default { return "Device Manager problem code $Code." }
    }
}

function Get-DriverProblemDevice {
    $query = 'SELECT Name,DeviceID,ConfigManagerErrorCode,PNPClass,Manufacturer,Status FROM Win32_PnPEntity WHERE ConfigManagerErrorCode <> 0'
    $devices = [System.Collections.Generic.List[object]]::new()

    foreach ($row in @(Get-CimInstance -Query $query -ErrorAction Stop)) {
        $code = [int]$row.ConfigManagerErrorCode

        $devices.Add([pscustomobject]@{
            Name         = [string]$row.Name
            Class        = [string]$row.PNPClass
            Manufacturer = [string]$row.Manufacturer
            Code         = $code
            Meaning      = (Get-DeviceProblemMeaning -Code $code)
            DeviceId     = [string]$row.DeviceID
            # 22 and 45 are a disabled device and an unplugged one - both are
            # states someone chose, not faults to go hunting drivers for.
            Missing      = ($code -in @(28, 31, 39, 18, 24))
        })
    }

    return @($devices | Sort-Object -Property Code, Name)
}

# -----------------------------------------------------------------------------
# Third-party driver packages, and backing them up
# -----------------------------------------------------------------------------

# Get-WindowsDriver and Export-WindowsDriver both refuse without elevation, so
# say which one is missing rather than letting DISM's own message surface.
function Test-DriverToolsAvailable {
    if (-not (Get-Command -Name 'Get-WindowsDriver' -ErrorAction SilentlyContinue)) {
        Write-Err 'The DISM PowerShell module is not available on this machine.'
        return $false
    }
    if (-not $Ctx.IsAdmin) {
        Write-Err 'Listing and exporting driver packages needs administrator rights.'
        Write-Info 'Re-run from an elevated prompt, or use -Elevate.'
        return $false
    }
    return $true
}

function Get-DriverPackage {
    if (-not (Test-DriverToolsAvailable)) { return @() }

    try { return @(Get-WindowsDriver -Online -ErrorAction Stop) }
    catch {
        Write-Err "Could not list driver packages: $($_.Exception.Message)"
        return @()
    }
}

# Every third-party driver package on the machine, copied out as .inf folders.
# The thing to do before wiping a machine whose network or chipset drivers came
# off a disc nobody can find any more.
function Backup-Driver {
    param([Parameter(Mandatory)][string]$Path)

    # Dry run before the admin check, so a preview describes what an elevated
    # run would do rather than refusing because this process is not elevated.
    # Same order as Invoke-TweakApply and Invoke-ToolboxAction.
    if ($Ctx.DryRun) {
        Write-Status -Glyph (Get-Glyph 'Info') -Color (Get-Color 'Warn') -Message 'Driver backup' -MessageColor (Get-Color 'Warn')
        Write-Info "would export every third-party driver package to $Path"
        if (-not $Ctx.IsAdmin) { Write-Info 'needs administrator rights' }
        return $false
    }

    if (-not (Test-DriverToolsAvailable)) { return $false }

    Write-Line ''
    Write-Info "Exporting every third-party driver package to:"
    Write-Line "      $Path" -Color White
    Write-Info 'This is the drivers Windows did not ship with - graphics, chipset, network, printers.'
    Write-Info 'It can be a few hundred megabytes and take a minute.'

    if (-not (Confirm-Action 'Export them now?' -DefaultYes)) {
        Write-Warn 'Driver backup - skipped.'
        return $false
    }

    try {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Step 'Exporting'

        $exported = @(Export-WindowsDriver -Online -Destination $Path -ErrorAction Stop)

        Write-Ok "$($exported.Count) driver package(s) exported."
        Write-Info "Restore one later with:  pnputil /add-driver <inf> /install"
        Write-Log "driver backup: $($exported.Count) packages to $Path"
        return $true
    }
    catch {
        Write-Err "Driver backup failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-DefaultDriverBackupPath {
    Join-Path $Ctx.StateDir ('drivers-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

# -----------------------------------------------------------------------------
# Console output
# -----------------------------------------------------------------------------

function Show-DriverOverview {
    Write-SectionHeading 'Drivers'

    # ---- graphics ----------------------------------------------------------
    $adapters = @()
    try { $adapters = @(Get-GraphicsAdapter) }
    catch { Write-Err "Could not read the display adapters: $($_.Exception.Message)" }

    if ($adapters.Count -eq 0) { Write-Warn 'No display adapter reported.' }

    foreach ($adapter in $adapters) {
        Write-Line ''
        Write-Line '  ' -NoNewline
        Write-Line $adapter.Name -Color White

        $version = $adapter.DriverVersion
        if (-not $version) { $version = 'unknown' }

        $date = ''
        if ($adapter.DriverDate) { $date = '   ' + $adapter.DriverDate.ToString('yyyy-MM-dd') }
        Write-Info "driver $version$date"

        if (-not $adapter.Vendor) {
            Write-Info "PCI vendor $($adapter.PciId) - not one Moscovium has a download page for."
            continue
        }

        if ($adapter.Vendor.Virtual) {
            Write-Info "$($adapter.Vendor.Name) virtual adapter - there is no vendor driver to install."
            continue
        }

        Write-Line '      get drivers: ' -Color (Get-Color 'Muted') -NoNewline
        Write-Line $adapter.Vendor.Url -Color (Get-Color 'Accent')
    }

    # ---- problem devices ---------------------------------------------------
    $problems = @()
    try { $problems = @(Get-DriverProblemDevice) }
    catch { Write-Err "Could not read the device list: $($_.Exception.Message)" }

    Write-Line ''
    if ($problems.Count -eq 0) {
        Write-Ok 'No device is reporting a problem.'
    }
    else {
        Write-Line "  $($problems.Count) device(s) reporting a problem" -Color (Get-Color 'Warn')
        foreach ($device in $problems) {
            $color = Get-Color 'Muted'
            if ($device.Missing) { $color = Get-Color 'Err' }

            Write-Line '    ' -NoNewline
            Write-Line ("code $($device.Code)").PadRight(10) -Color $color -NoNewline
            Write-Line $device.Name -Color White
            Write-Info $device.Meaning
        }
    }

    # ---- where to get drivers ----------------------------------------------
    $sources = @()
    try { $sources = @(Get-RelevantDriverSources) } catch { }

    if ($sources.Count -gt 0) {
        Write-Line ''
        Write-Line '  Drivers for this machine' -Color (Get-Color 'Faint')

        foreach ($source in $sources) {
            $how = 'opens the vendor page'
            $color = Get-Color 'Muted'
            if ($source.DownloadUrl) { $how = 'downloads and runs the vendor installer'; $color = Get-Color 'Ok' }

            Write-Line '    ' -NoNewline
            Write-Line $source.Id.PadRight(14) -Color White -NoNewline
            Write-Line $source.Name.PadRight(38) -Color Gray -NoNewline
            Write-Line $how -Color $color
            Write-Info $source.Summary
        }

        Write-Line ''
        Write-Info 'Install one with:  -GetDriver <id>'
    }

    Write-Line ''
    Write-Info 'Back them up with:  -BackupDrivers <folder>     device manager:  -Toolbox device-manager'
}
