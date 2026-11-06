# Waits for a volume to arrive and starts Redeem only when the serial or
# partition GUID matches the pinned UUID. Every other disk is ignored.
param(
    [Parameter(Mandatory = $true)]
    [string]$Uuid
)

$ErrorActionPreference = 'Continue'

function ConvertTo-RedeemKey([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value -replace '-', '').ToUpperInvariant()
}

$want = ConvertTo-RedeemKey $Uuid
if (-not $want) {
    Write-Error "redeem: refusing empty UUID"
    exit 2
}

Register-WmiEvent -Query "SELECT * FROM Win32_VolumeChangeEvent WHERE EventType = 2" -SourceIdentifier RedeemUsb | Out-Null
Write-Output "redeem: watching for volume $Uuid"

while ($true) {
    $evt = Wait-Event -SourceIdentifier RedeemUsb
    $drive = [string]$evt.SourceEventArgs.NewEvent.DriveName
    Remove-Event -EventIdentifier $evt.EventIdentifier
    if ($drive -notmatch '^[A-Za-z]:$') { continue }

    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive)
    if (-not $disk) { continue }
    $serial = ConvertTo-RedeemKey ([string]$disk.VolumeSerialNumber)
    $guid = ''
    $letter = $drive.TrimEnd(':')
    try {
        $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $guid = ConvertTo-RedeemKey ([string]$part.Guid)
    } catch {
        $guid = ''
    }
    if ($serial -ne $want -and $guid -ne $want) { continue }

    $bat = Join-Path ($drive + '\') 'Start-Redeem-Windows.bat'
    if (Test-Path -LiteralPath $bat) {
        Start-Process -FilePath $bat
    }
}
