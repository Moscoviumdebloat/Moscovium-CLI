# =============================================================================
# Package managers: detect them, and run their own installers.
#
# The interesting thing here is that the two installable ones need *opposite*
# privileges, and both enforce it:
#
#   Chocolatey installs machine-wide to %PROGRAMDATA%\chocolatey, so it needs
#   administrator.
#
#   Scoop installs per-user to ~\scoop and its installer *refuses* to run
#   elevated - "Running the installer as administrator is disabled by default"
#   - unless passed -RunAsAdmin, which changes it to a machine-wide install.
#
# Moscovium's window is always elevated and the CLI elevates for anything that
# changes the machine, so Scoop cannot simply be run inline from either. What
# happens instead is in Invoke-PackageManagerInstall.
#
# The install commands are stored verbatim from each project's own install page
# rather than rebuilt from parts. Someone else's installer invocation is not
# ours to improve, and printing the exact line a user would paste is the whole
# point of showing it.
# =============================================================================

function Get-PackageManagers {
    @(
        [pscustomobject]@{
            Id = 'winget'
            Name = 'winget'
            Site = 'https://learn.microsoft.com/windows/package-manager/'
            Summary = 'Ships with Windows. Moscovium installs its whole app catalog through this one.'
            # Neither requires nor refuses elevation.
            Elevation = 'either'
            # Not ours to install: it arrives with App Installer from the
            # Microsoft Store, and scripting that around the Store is exactly
            # the kind of thing that breaks on the next Windows build.
            InstallCommand = ''
            GlobalCommand = ''
            InstallNote = 'Part of App Installer. Get it from the Microsoft Store if it is missing.'
        }
        [pscustomobject]@{
            Id = 'choco'
            Name = 'Chocolatey'
            Site = 'https://chocolatey.org/install'
            Summary = 'Machine-wide, in C:\ProgramData\chocolatey. The largest Windows package repository.'
            Elevation = 'admin'
            InstallCommand = 'Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString(''https://community.chocolatey.org/install.ps1''))'
            GlobalCommand = ''
            InstallNote = 'Needs administrator, and always installs machine-wide.'
        }
        [pscustomobject]@{
            Id = 'scoop'
            Name = 'Scoop'
            Site = 'https://scoop.sh'
            Summary = 'Per-user, in ~\scoop. No UAC prompts, and nothing lands on the PATH you did not ask for.'
            Elevation = 'user'
            InstallCommand = 'irm get.scoop.sh | iex'
            # The documented escape hatch for a machine-wide Scoop. Its own
            # docs call this the admin case, not the normal one.
            GlobalCommand = '& ([scriptblock]::Create((irm get.scoop.sh))) -RunAsAdmin'
            InstallNote = 'Its installer refuses to run elevated unless you ask for a machine-wide install.'
        }
    )
}

function Resolve-PackageManager {
    param([Parameter(Mandatory)][string]$Id)

    $managers = Get-PackageManagers

    $exact = @($managers | Where-Object { $_.Id -eq $Id })
    if ($exact.Count -eq 1) { return $exact[0] }

    $fuzzy = @($managers | Where-Object {
        (Test-NameMatch -Value $_.Id -Pattern $Id) -or (Test-NameMatch -Value $_.Name -Pattern $Id)
    })
    if ($fuzzy.Count -eq 1) { return $fuzzy[0] }

    if ($fuzzy.Count -gt 1) {
        Write-Err "'$Id' is ambiguous. Did you mean one of these?"
        foreach ($manager in $fuzzy) { Write-Info $manager.Id }
        return $null
    }

    Write-Err "Unknown package manager '$Id'. Known: $((Get-PackageManagers | ForEach-Object { $_.Id }) -join ', ')."
    return $null
}

# Where each manager lands, checked on disk as well as on the PATH.
#
# The PATH alone is not enough: a manager installed a minute ago by a child
# process is on the *new* PATH, not this process's copy of it, so a fresh
# install would keep reporting itself missing until Moscovium was restarted.
function Get-PackageManagerStatus {
    param([Parameter(Mandatory)]$Manager)

    $command = $null
    $path = $null

    switch ($Manager.Id) {
        'winget' {
            $command = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
        }
        'choco' {
            $command = Get-Command -Name 'choco.exe' -ErrorAction SilentlyContinue
            if (-not $command) {
                $root = $env:ChocolateyInstall
                if ([string]::IsNullOrWhiteSpace($root)) { $root = Join-Path $env:ProgramData 'chocolatey' }
                $candidate = Join-Path $root 'bin\choco.exe'
                if (Test-Path -LiteralPath $candidate) { $path = $candidate }
            }
        }
        'scoop' {
            # Scoop is a PowerShell shim, so Get-Command has to look for the
            # command name rather than an .exe.
            $command = Get-Command -Name 'scoop' -ErrorAction SilentlyContinue
            if (-not $command) {
                $root = $env:SCOOP
                if ([string]::IsNullOrWhiteSpace($root)) { $root = Join-Path $env:USERPROFILE 'scoop' }
                $candidate = Join-Path $root 'shims\scoop.ps1'
                if (Test-Path -LiteralPath $candidate) { $path = $candidate }
            }
        }
    }

    if ($command) {
        $path = $command.Source
        if ([string]::IsNullOrWhiteSpace($path)) { $path = $command.Name }
    }

    [pscustomobject]@{
        Id        = $Manager.Id
        Installed = [bool]$path
        Path      = $path
        # True when it is on disk but not on this process's PATH - which means
        # it works in a new terminal and not in this one.
        OnPath    = [bool]$command
    }
}

function Get-PackageManagerReport {
    $report = [System.Collections.Generic.List[object]]::new()

    foreach ($manager in Get-PackageManagers) {
        $status = Get-PackageManagerStatus -Manager $manager
        $report.Add([pscustomobject]@{
            Manager   = $manager
            Installed = $status.Installed
            Path      = $status.Path
            OnPath    = $status.OnPath
        })
    }

    return @($report)
}

# Runs one manager's own installer, in a separate PowerShell process, after
# printing the exact command.
#
# Separate process for the same three reasons the toolbox scripts get one: this
# bundle runs under Set-StrictMode and $ErrorActionPreference = 'Stop' and child
# scopes inherit both, neither installer is written to survive that, and both
# want their own console. It is also the only way to get the elevation right,
# since the two need opposite privileges.
function Invoke-PackageManagerInstall {
    param(
        [Parameter(Mandatory)][string]$Id,
        # Scoop's documented machine-wide install. Ignored by anything else.
        [switch]$Global
    )

    $manager = Resolve-PackageManager -Id $Id
    if (-not $manager) { return $false }

    $status = Get-PackageManagerStatus -Manager $manager
    if ($status.Installed) {
        Write-Ok "$($manager.Name) is already installed - $($status.Path)"
        if (-not $status.OnPath) {
            Write-Info 'It is not on this session PATH yet. Open a new terminal to use it.'
        }
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($manager.InstallCommand)) {
        Write-Warn "$($manager.Name) is not something Moscovium installs."
        Write-Info $manager.InstallNote
        Write-Line "      $($manager.Site)" -Color White
        return $false
    }

    $command = $manager.InstallCommand
    $elevated = ($manager.Elevation -eq 'admin')

    # Scoop's installer refuses to run elevated. Moscovium's window is always
    # elevated, and so is the CLI once it has relaunched itself for a mutating
    # action, so the per-user install genuinely cannot be launched from here -
    # a child process inherits the elevation and there is no reliable way to
    # drop it. Offer the machine-wide install its own docs describe, and hand
    # over the command for a normal window if that is not what was wanted.
    if ($manager.Elevation -eq 'user' -and $Ctx.IsAdmin -and -not $Global) {
        Write-Line ''
        Write-Warn "$($manager.Name) will not install per-user from an elevated window - its own installer blocks it."
        Write-Info 'To install it per-user, run this in a normal, non-elevated PowerShell:'
        Write-Line "      $($manager.InstallCommand)" -Color White
        Write-Line ''

        if ([string]::IsNullOrWhiteSpace($manager.GlobalCommand)) { return $false }

        Write-Info 'Or install it machine-wide from here instead, which is what its docs call the admin case.'
        if (-not (Confirm-Action "Install $($manager.Name) machine-wide instead?")) {
            Write-Warn "$($manager.Name) - skipped."
            return $false
        }

        $command = $manager.GlobalCommand
    }
    elseif ($Global -and -not [string]::IsNullOrWhiteSpace($manager.GlobalCommand)) {
        $command = $manager.GlobalCommand
        $elevated = $true
    }

    if ($Ctx.DryRun) {
        Write-Status -Glyph (Get-Glyph 'Info') -Color (Get-Color 'Warn') -Message $manager.Name -MessageColor (Get-Color 'Warn')
        Write-Info "would run: $command"
        return $false
    }

    $needsElevation = $elevated -and -not $Ctx.IsAdmin

    Write-Line ''
    Write-Warn "$($manager.Name) is installed by a script published by its own project:"
    Write-Line "      $($manager.Site)" -Color White
    Write-Info 'Moscovium does not review or pin the contents of that script.'
    Write-Line ''
    Write-Info 'Runs in a new window as:'
    Write-Line "      $command" -Color Gray

    if ($needsElevation) { Write-Info 'It will ask for administrator rights.' }
    elseif ($manager.Elevation -eq 'user') { Write-Info 'It runs as you, not elevated.' }

    if (-not (Confirm-Action "Install $($manager.Name) now?" -DefaultYes)) {
        Write-Warn "$($manager.Name) - skipped."
        return $false
    }

    # Held open on a terminating error only: a successful install prints its own
    # summary and a flashed-past failure is the one thing worth stopping for.
    $handler = "Write-Host ''; " +
               "Write-Host ('Moscovium: the installer stopped with an error.') -ForegroundColor Red; " +
               "Write-Host (`$_.Exception.Message) -ForegroundColor Red; " +
               "Write-Host ''; " +
               "Read-Host 'Press Enter to close this window'"

    $wrapped = "try { $command } catch { $handler }"

    $start = @{
        FilePath     = Get-PowerShellHost
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $wrapped)
        Wait         = $true
        PassThru     = $true
        ErrorAction  = 'Stop'
    }
    if ($needsElevation) { $start.Verb = 'RunAs' }

    Write-Step "Installing $($manager.Name) - this returns when the installer finishes"
    Write-Log "package manager install: $wrapped"

    try {
        $process = Start-Process @start
    }
    catch {
        Write-Err "Could not start the $($manager.Name) installer: $($_.Exception.Message)"
        return $false
    }

    if ($process -and $process.ExitCode -ne 0) {
        Write-Warn "The $($manager.Name) installer exited with code $($process.ExitCode)."
        return $false
    }

    # Re-check on disk rather than trusting the exit code: this process's PATH
    # is a copy taken at startup and will not have grown a new entry.
    $after = Get-PackageManagerStatus -Manager $manager
    if ($after.Installed) {
        Write-Ok "$($manager.Name) installed - $($after.Path)"
        Write-Info 'Open a new terminal before using it: this session PATH was set before it existed.'
        return $true
    }

    Write-Warn "The $($manager.Name) installer finished, but it is still not on disk where it was expected."
    return $false
}

function Show-PackageManagerCatalog {
    Write-SectionHeading 'Package managers'

    foreach ($entry in @(Get-PackageManagerReport)) {
        $manager = $entry.Manager

        $mark = Get-Glyph 'Unchecked'
        $color = Get-Color 'Muted'
        $state = 'not installed'

        if ($entry.Installed) {
            $mark = Get-Glyph 'Ok'
            $color = Get-Color 'Ok'
            $state = 'installed'
            if (-not $entry.OnPath) { $state = 'installed, needs a new terminal' }
        }

        # Padded: the ASCII glyph set spells these '[ ]' and '+', so an
        # unpadded mark puts every column after it out of line.
        Write-Line '  ' -NoNewline
        Write-Line $mark.PadRight(4) -Color $color -NoNewline
        Write-Line $manager.Id.PadRight(10) -Color White -NoNewline
        Write-Line $manager.Name.PadRight(14) -Color Gray -NoNewline
        Write-Line $state -Color $color

        Write-Info $manager.Summary
        if ($entry.Installed) { Write-Info $entry.Path }
        else { Write-Info $manager.InstallNote }
    }

    Write-Line ''
    Write-Info 'Install one with:  -InstallManager <id>'
}
