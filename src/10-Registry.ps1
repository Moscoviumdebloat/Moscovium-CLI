# =============================================================================
# Registry read/write plus the snapshot format that makes tweaks reversible.
#
# The GUI applies tweaks one way only. The CLI records the prior state of every
# value it touches before writing, so -Revert can put it back exactly: restore
# the old value, delete values that did not exist, and drop keys we created if
# they end up empty again.
#
# Uses the .NET registry API rather than the PowerShell provider for exact
# control over value kinds, and pins the 64-bit view so a 32-bit host does not
# silently land in WOW6432Node.
# =============================================================================

function Resolve-RegistryPath {
    param([Parameter(Mandatory)][string]$FullPath)

    $separator = $FullPath.IndexOf('\')
    if ($separator -lt 0) { throw "Registry path '$FullPath' has no subkey." }

    $hiveName = $FullPath.Substring(0, $separator)
    $subPath  = $FullPath.Substring($separator + 1)

    $hive = switch ($hiveName.ToUpperInvariant()) {
        'HKEY_LOCAL_MACHINE'  { [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKLM'                { [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKEY_CURRENT_USER'   { [Microsoft.Win32.RegistryHive]::CurrentUser }
        'HKCU'                { [Microsoft.Win32.RegistryHive]::CurrentUser }
        'HKEY_CLASSES_ROOT'   { [Microsoft.Win32.RegistryHive]::ClassesRoot }
        'HKCR'                { [Microsoft.Win32.RegistryHive]::ClassesRoot }
        'HKEY_USERS'          { [Microsoft.Win32.RegistryHive]::Users }
        'HKU'                 { [Microsoft.Win32.RegistryHive]::Users }
        default { throw "Unsupported registry hive '$hiveName' in '$FullPath'." }
    }

    [pscustomobject]@{
        Hive     = $hive
        SubPath  = $subPath
        FullPath = $FullPath
        # HKLM and HKU are machine-wide; HKCU is not.
        NeedsAdmin = ($hive -eq [Microsoft.Win32.RegistryHive]::LocalMachine) -or
                     ($hive -eq [Microsoft.Win32.RegistryHive]::ClassesRoot) -or
                     ($hive -eq [Microsoft.Win32.RegistryHive]::Users)
    }
}

function Open-RegistryBase {
    param([Parameter(Mandatory)][Microsoft.Win32.RegistryHive]$Hive)
    [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
}

function ConvertTo-RegistryValueKind {
    param([Parameter(Mandatory)][string]$Type)

    switch ($Type.ToUpperInvariant()) {
        'DWORD'  { [Microsoft.Win32.RegistryValueKind]::DWord }
        'QWORD'  { [Microsoft.Win32.RegistryValueKind]::QWord }
        'STRING' { [Microsoft.Win32.RegistryValueKind]::String }
        'EXPANDSTRING' { [Microsoft.Win32.RegistryValueKind]::ExpandString }
        'BINARY' { [Microsoft.Win32.RegistryValueKind]::Binary }
        default  { throw "Unsupported registry value type '$Type'." }
    }
}

function ConvertTo-TypedRegistryValue {
    param([Parameter(Mandatory)][string]$Type, [AllowNull()]$Value)

    switch ($Type.ToUpperInvariant()) {
        'DWORD'  { return [int]$Value }
        'QWORD'  { return [long]$Value }
        default  { if ($null -eq $Value) { return '' } else { return [string]$Value } }
    }
}

# Captures enough state to undo a single value write.
function Get-RegistryValueSnapshot {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    $target = Resolve-RegistryPath -FullPath $Path
    $base = $null
    $key = $null

    try {
        $base = Open-RegistryBase -Hive $target.Hive
        $key  = $base.OpenSubKey($target.SubPath, $false)

        if ($null -eq $key) {
            return [pscustomobject]@{
                path = $Path; name = $Name; keyExisted = $false; existed = $false; type = $null; value = $null
            }
        }

        # GetValue with $null default distinguishes "absent" from "present and empty".
        $current = $key.GetValue($Name, $null)
        if ($null -eq $current) {
            return [pscustomobject]@{
                path = $Path; name = $Name; keyExisted = $true; existed = $false; type = $null; value = $null
            }
        }

        $kind = $key.GetValueKind($Name)
        return [pscustomobject]@{
            path = $Path; name = $Name; keyExisted = $true; existed = $true
            type = $kind.ToString(); value = $current
        }
    }
    finally {
        if ($key)  { $key.Dispose() }
        if ($base) { $base.Dispose() }
    }
}

function Set-RegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][string]$Type,
        [AllowNull()]$Value
    )

    $target = Resolve-RegistryPath -FullPath $Path
    $base = $null
    $key = $null

    try {
        $base = Open-RegistryBase -Hive $target.Hive
        $key  = $base.CreateSubKey($target.SubPath, $true)
        if ($null -eq $key) { throw "Cannot open or create key '$Path'." }

        $key.SetValue($Name, (ConvertTo-TypedRegistryValue -Type $Type -Value $Value), (ConvertTo-RegistryValueKind -Type $Type))
    }
    finally {
        if ($key)  { $key.Dispose() }
        if ($base) { $base.Dispose() }
    }
}

function Remove-RegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    $target = Resolve-RegistryPath -FullPath $Path
    $base = $null
    $key = $null

    try {
        $base = Open-RegistryBase -Hive $target.Hive
        $key  = $base.OpenSubKey($target.SubPath, $true)
        if ($null -eq $key) { return }

        $key.DeleteValue($Name, $false)
    }
    finally {
        if ($key)  { $key.Dispose() }
        if ($base) { $base.Dispose() }
    }
}

# Deletes a key only when it is empty. Used on revert to clean up keys the tweak
# created; never touches a key that already held anything.
function Remove-EmptyRegistryKey {
    param([Parameter(Mandatory)][string]$Path)

    $target = Resolve-RegistryPath -FullPath $Path
    $base = $null

    try {
        $base = Open-RegistryBase -Hive $target.Hive

        $key = $base.OpenSubKey($target.SubPath, $false)
        if ($null -eq $key) { return $false }

        $isEmpty = ($key.SubKeyCount -eq 0) -and ($key.ValueCount -eq 0)
        $key.Dispose()
        if (-not $isEmpty) { return $false }

        $base.DeleteSubKey($target.SubPath, $false)
        return $true
    }
    catch {
        Write-Log "Could not remove empty key '$Path': $($_.Exception.Message)" 'WARN'
        return $false
    }
    finally {
        if ($base) { $base.Dispose() }
    }
}

# True when the live registry already holds the value a tweak wants.
function Test-RegistryValueApplied {
    param([Parameter(Mandatory)]$Desired)

    $snapshot = Get-RegistryValueSnapshot -Path $Desired.path -Name $Desired.name
    if (-not $snapshot.existed) { return $false }

    $expected = ConvertTo-TypedRegistryValue -Type $Desired.type -Value $Desired.value

    # Compare as strings so DWord 0 read back as Int32 still matches the JSON value.
    return ([string]$snapshot.value -eq [string]$expected)
}

# -----------------------------------------------------------------------------
# Backups
# -----------------------------------------------------------------------------

function New-BackupRecord {
    [pscustomobject]@{
        version   = $Ctx.Version
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        entries   = @{}
    }
}

function Save-BackupRecord {
    param([Parameter(Mandatory)]$Record)

    if ($Record.entries.Count -eq 0) { return $null }

    Initialize-State
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $path  = Join-Path $Ctx.BackupDir "backup-$stamp.json"

    $json = $Record | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding $false))

    Write-Log "Backup written: $path"
    return $path
}

# Newest first. Callers must wrap this in @(): PowerShell unrolls a returned
# array, so zero backups come back as $null and one comes back as a bare object.
function Get-BackupRecords {
    if (-not (Test-Path -LiteralPath $Ctx.BackupDir)) { return @() }

    @(Get-ChildItem -LiteralPath $Ctx.BackupDir -Filter 'backup-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property Name -Descending |
        ForEach-Object {
            try {
                [pscustomobject]@{
                    File   = $_.FullName
                    Record = (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
                }
            }
            catch {
                Write-Log "Skipping unreadable backup '$($_.FullName)': $($_.Exception.Message)" 'WARN'
            }
        })
}

# Most recent snapshot taken for a given tweak, or $null if it was never applied
# through this CLI.
function Find-TweakBackup {
    param([Parameter(Mandatory)][string]$TweakName)

    foreach ($backup in @(Get-BackupRecords)) {
        $entries = $backup.Record.entries
        if ($null -eq $entries) { continue }

        # ConvertFrom-Json yields a PSCustomObject, so look the name up as a property.
        $entry = $entries.PSObject.Properties | Where-Object { $_.Name -eq $TweakName } | Select-Object -First 1
        if ($entry) {
            return [pscustomobject]@{ File = $backup.File; Entry = $entry.Value }
        }
    }

    return $null
}
