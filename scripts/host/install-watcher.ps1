# Install a per-user scheduled task that starts Redeem only when the arriving
# volume serial or partition GUID matches -Uuid. -DryRun writes nothing.
param(
    [string]$Uuid = "",
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$Detect
)

$ErrorActionPreference = "Stop"
$TaskName = "Redeem USB Watcher"

function Write-Refuse([string]$Value) {
    Write-Error ("redeem: refusing UUID '{0}' (empty, wildcard, or malformed)" -f $Value)
    exit 2
}

function ConvertTo-CanonicalUuid([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -match '[\*\?\[\]\s\\/]') { return $null }
    $lower = $Value.ToLowerInvariant()
    if ($lower -in @("any", "all", "none", "wildcard", "nil")) { return $null }
    if ($Value -match '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') {
        if ($lower -eq "00000000-0000-0000-0000-000000000000") { return $null }
        return $lower
    }
    if ($Value -match '^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$') {
        if ($lower -eq "0000-0000") { return $null }
        return $Value.ToUpperInvariant()
    }
    if ($Value -match '^[0-9A-Fa-f]{8}$') {
        if ($lower -eq "00000000") { return $null }
        $upper = $Value.ToUpperInvariant()
        return ("{0}-{1}" -f $upper.Substring(0, 4), $upper.Substring(4, 4))
    }
    return $null
}

if ($Detect) {
    $found = $false
    Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.VolumeName -eq "Ventoy" } | ForEach-Object {
        $found = $true
        $serial = [string]$_.VolumeSerialNumber
        if ($serial -match '^[0-9A-Fa-f]{8}$') {
            $upper = $serial.ToUpperInvariant()
            Write-Output ("{0}-{1}" -f $upper.Substring(0, 4), $upper.Substring(4, 4))
        } elseif ($serial) {
            Write-Output $serial
        }
    }
    if (-not $found) {
        Write-Error "redeem: no volume labeled Ventoy"
        exit 1
    }
    exit 0
}

$destDir = Join-Path $env:LOCALAPPDATA "redeem"
$dest = Join-Path $destDir "windows-volume-watcher.ps1"
$source = Join-Path $PSScriptRoot "windows-volume-watcher.ps1"

if ($Uninstall) {
    if ($DryRun) {
        Write-Output "# redeem watcher dry-run uninstall (windows)"
        Write-Output "# would remove:"
        Write-Output $TaskName
        Write-Output $dest
        exit 0
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
    Write-Output "redeem: windows watcher removed"
    exit 0
}

$canonical = ConvertTo-CanonicalUuid $Uuid
if (-not $canonical) { Write-Refuse $Uuid }

$arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dest`" -Uuid `"$canonical`""
if ($DryRun) {
    Write-Output "# redeem watcher dry-run (windows)"
    Write-Output "# uuid: $canonical"
    Write-Output "# no host paths written"
    Write-Output ""
    Write-Output "===== scheduled task $TaskName ====="
    Write-Output "Execute: powershell.exe"
    Write-Output "Arguments: $arg"
    Write-Output "Trigger: At log on"
    Write-Output "User: $env:USERNAME"
    Write-Output ""
    Write-Output "===== $dest ====="
    if (Test-Path -LiteralPath $source) { Get-Content -LiteralPath $source -Raw }
    exit 0
}

if (-not (Test-Path -LiteralPath $source)) {
    Write-Error "redeem: missing $source"
    exit 1
}
New-Item -ItemType Directory -Force -Path $destDir | Out-Null
Copy-Item -LiteralPath $source -Destination $dest -Force
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -User $env:USERNAME -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Output "redeem: windows watcher installed for $canonical"
