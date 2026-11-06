# BitLocker status, read-only-safe unlock, and permanent removal for Windows and WinPE.
# Uses manage-bde.exe, which is present on full Windows and on WinPE / Hiren's BootCD PE.
# A recovery password is never taken as a parameter. Unlock sends it through an in-process
# WMI call, or lets manage-bde prompt (-Password / -RecoveryKey for a .bek path).
# Diagnostic text from this script drops 48-digit passwords before it is printed.
#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Action = 'status',
    [string]$Drive = '',
    [string]$Bek = '',
    [switch]$DryRun,
    [switch]$SelfTest,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rejected
)

$ErrorActionPreference = 'Continue'

function Write-RedeemErr([string]$Message) {
    [Console]::Error.WriteLine("redeem-bitlocker: $Message")
}

function Remove-RedeemSecretText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $clean = [regex]::Replace($Text, '\b\d{6}(?:-\d{6}){7}\b', '[redacted]')
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($clean -split "`r?`n")) {
        if ($line -match '^\s*Password:\s*$') { continue }
        if ($line -match '^\s*Password:\s+\S') { continue }
        $kept.Add($line)
    }
    return ($kept -join "`n")
}

function Select-RedeemProtectorReport([string]$Text) {
    $clean = Remove-RedeemSecretText $Text
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($clean -split "`r?`n")) {
        if ($line -match 'ID:|Numerical Password:|TPM|External Key:|Startup Key:|Password Protector|All Key Protectors|Key Protector|^Volume ') {
            $kept.Add($line.TrimEnd())
        }
    }
    if ($kept.Count -eq 0) { return "(no protector ids parsed)" }
    return ($kept -join "`n")
}

function Test-RedeemHealthFailing([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [regex]::IsMatch(
        $Text,
        'FAILED!|HealthStatus\s*[:=]\s*Unhealthy|OperationalStatus[^:\r\n]*Predictive Failure|Predictive Failure|Pred Fail|SMART Health Status:\s*FAILED|overall-health[^\r\n]*FAILED',
        'IgnoreCase')
}

function Test-RedeemHealthHealthy([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if (Test-RedeemHealthFailing $Text) { return $false }
    return [regex]::IsMatch($Text, 'HealthStatus\s*[:=]\s*Healthy|overall-health[^\r\n]*PASSED|SMART Health Status:\s*OK|\bStatus\s+OK\b', 'IgnoreCase')
}

function Test-RedeemConfirmPhrase([string]$Typed, [string]$DriveName) {
    # -ceq is case-sensitive. "decrypt c:" must not start decryption.
    return $Typed -ceq ("DECRYPT " + $DriveName)
}

function ConvertTo-RedeemDrive([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $d = $Value.Trim().TrimEnd('\').ToUpperInvariant()
    if ($d -match '^[A-Z]$') { $d += ':' }
    if ($d -notmatch '^[A-Z]:$') {
        Write-RedeemErr "drive must look like C:. The value was not used."
        exit 2
    }
    return $d
}

function Invoke-RedeemSelfTest {
    $sample = @"
Volume C: []
All Key Protectors

    Numerical Password:
      ID: {A1B2C3D4-1111-2222-3333-444444444444}
      Password:
        111111-222222-333333-444444-555555-666666-777777-888888

    TPM:
      ID: {C0FFEE01-AAAA-BBBB-CCCC-DDDDEEEEFFFF}
"@
    $clean = Remove-RedeemSecretText $sample
    if ($clean -match '111111-222222') { Write-RedeemErr 'self-test: secret leaked from scrub'; exit 1 }
    $report = Select-RedeemProtectorReport $sample
    if ($report -notmatch 'A1B2C3D4') { Write-RedeemErr 'self-test: key id dropped'; exit 1 }
    if ($report -notmatch 'TPM') { Write-RedeemErr 'self-test: TPM type dropped'; exit 1 }
    if ($report -match '111111-222222') { Write-RedeemErr 'self-test: protector report leaked a password'; exit 1 }
    if (-not (Test-RedeemHealthFailing 'SMART overall-health self-assessment test result: FAILED')) {
        Write-RedeemErr 'self-test: FAILED health was not detected'
        exit 1
    }
    if (Test-RedeemHealthFailing 'SMART overall-health self-assessment test result: PASSED') {
        Write-RedeemErr 'self-test: PASSED health was treated as failing'
        exit 1
    }
    if (-not (Test-RedeemHealthHealthy 'HealthStatus: Healthy')) {
        Write-RedeemErr 'self-test: Healthy was not accepted'
        exit 1
    }
    if (-not (Test-RedeemConfirmPhrase 'DECRYPT C:' 'C:')) { Write-RedeemErr 'self-test: confirm phrase'; exit 1 }
    if (Test-RedeemConfirmPhrase 'decrypt c:' 'C:') { Write-RedeemErr 'self-test: phrase must be exact'; exit 1 }
    if ((ConvertTo-RedeemDrive 'c') -ne 'C:') { Write-RedeemErr 'self-test: drive normalize'; exit 1 }
    Write-Output 'self-test ok'
    exit 0
}

if ($SelfTest) { Invoke-RedeemSelfTest }

if ($Rejected -and $Rejected.Count -gt 0) {
    Write-RedeemErr "refusing extra arguments. Do not pass a recovery key or password on the command line."
    exit 2
}
if ($Bek -match '^\d{6}(-\d{6}){7}$') {
    Write-RedeemErr "refusing a recovery-password-shaped -Bek value. Pass a .bek file path, or type the password at the prompt."
    exit 2
}

$Action = $Action.ToLowerInvariant()
if ($Action -eq 'decrypt') { $Action = 'remove' }
if (@('status', 'unlock', 'remove') -notcontains $Action) {
    Write-RedeemErr "unknown action. Use status, unlock, or remove."
    exit 2
}

$Drive = ConvertTo-RedeemDrive $Drive
if ($Action -ne 'status' -and -not $Drive) {
    Write-RedeemErr "unlock and remove need a drive letter, for example C:."
    exit 2
}

function Get-RedeemDriveHealth([string]$DriveName) {
    $detail = New-Object System.Collections.Generic.List[string]
    $scoped = ''
    $letter = ''
    if ($DriveName) { $letter = $DriveName.TrimEnd(':') }
    if ($letter -and (Get-Command Get-Partition -ErrorAction SilentlyContinue)) {
        try {
            $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
            $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
            $ops = ($disk.OperationalStatus -join ',')
            $scoped = "Get-Disk Number=$($disk.Number) HealthStatus=$($disk.HealthStatus) OperationalStatus=$ops"
            $detail.Add($scoped)
        } catch {
            $detail.Add("Get-Disk for $DriveName failed: $($_.Exception.Message)")
        }
    }
    if (-not $scoped -and (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        try {
            foreach ($disk in @(Get-PhysicalDisk -ErrorAction Stop)) {
                $ops = ($disk.OperationalStatus -join ',')
                $detail.Add("PhysicalDisk $($disk.FriendlyName) HealthStatus=$($disk.HealthStatus) OperationalStatus=$ops")
            }
        } catch {
            $detail.Add("Get-PhysicalDisk failed: $($_.Exception.Message)")
        }
    }
    $wmic = Get-Command wmic.exe -ErrorAction SilentlyContinue
    if (-not $wmic) { $wmic = Get-Command wmic -ErrorAction SilentlyContinue }
    if ($wmic -and -not $scoped) {
        try {
            $detail.Add((& $wmic.Source diskdrive get status 2>&1 | Out-String).TrimEnd())
        } catch {
            $detail.Add("wmic diskdrive get status failed: $($_.Exception.Message)")
        }
    }
    $smart = Get-Command smartctl -ErrorAction SilentlyContinue
    if ($smart) {
        try {
            $detail.Add((& $smart.Source -H \\.\PhysicalDrive0 2>&1 | Out-String).TrimEnd())
        } catch {
            $detail.Add("smartctl failed: $($_.Exception.Message)")
        }
    }
    $text = ($detail -join "`n")
    $status = 'unknown'
    if ($scoped) {
        if (Test-RedeemHealthFailing $scoped) { $status = 'failing' }
        elseif (Test-RedeemHealthHealthy $scoped) { $status = 'healthy' }
    } elseif (Test-RedeemHealthFailing $text) {
        $status = 'failing'
    } elseif (Test-RedeemHealthHealthy $text) {
        $status = 'healthy'
    }
    return [pscustomobject]@{ Status = $status; Detail = $(if ($text) { $text } else { 'disk health: no smartctl, Get-Disk, or wmic result' }) }
}

function Write-RedeemPowerReminder {
    Write-Output "Keep the PC on AC power. manage-bde -off rewrites every encrypted sector. Power loss in the middle leaves a half-converted volume."
    try {
        $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
        if ($batteries.Count -eq 0) { return }
        $onAc = $false
        foreach ($battery in $batteries) {
            if ($battery.BatteryStatus -eq 2) { $onAc = $true }
        }
        if (-not $onAc) {
            Write-Output "warning: a battery is present and BatteryStatus is not 2 (AC). Plug in mains power before decrypting."
        }
    } catch {
        Write-Output "Battery status was not available. That is normal on a desktop or in some WinPE images."
    }
}

function Show-RedeemStatus([string]$DriveName) {
    $bde = Get-Command manage-bde.exe -ErrorAction SilentlyContinue
    if (-not $bde) {
        Write-Output "manage-bde.exe: not found"
        return
    }
    $status = ''
    $protectors = ''
    if ($DriveName) {
        $status = (& $bde.Source -status $DriveName 2>&1 | Out-String)
        $protectors = (& $bde.Source -protectors -get $DriveName 2>&1 | Out-String)
    } else {
        $status = (& $bde.Source -status 2>&1 | Out-String)
        foreach ($match in [regex]::Matches($status, 'Volume ([A-Z]):')) {
            $letter = $match.Groups[1].Value + ':'
            $protectors += "`n--- $letter ---`n"
            $protectors += (& $bde.Source -protectors -get $letter 2>&1 | Out-String)
        }
    }
    Write-Output (Remove-RedeemSecretText $status)
    Write-Output "protectors (ids and types only; recovery passwords are not printed):"
    Write-Output (Select-RedeemProtectorReport $protectors)
    if ($status -match 'Protection Off' -and $status -match 'Percentage Encrypted:\s+(?!0\.0%)[0-9]') {
        Write-Output "Protection is Off while the volume is still encrypted. That is suspended BitLocker (clear key). Linux can mount it read-only with: redeem-bitlocker unlock --clearkey DEVICE"
    }
    if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        foreach ($vol in @(Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
            if ($DriveName -and $vol.MountPoint -ne ($DriveName + '\')) { continue }
            Write-Output ("MountPoint={0} VolumeStatus={1} ProtectionStatus={2} EncryptionPercentage={3} LockStatus={4} VolumeType={5}" -f `
                $vol.MountPoint, $vol.VolumeStatus, $vol.ProtectionStatus, $vol.EncryptionPercentage, $vol.LockStatus, $vol.VolumeType)
            foreach ($kp in @($vol.KeyProtector)) {
                Write-Output ("ProtectorId={0} Type={1}" -f $kp.KeyProtectorId, $kp.KeyProtectorType)
            }
            if ($vol.ProtectionStatus -eq 'Off' -and $vol.EncryptionPercentage -gt 0) {
                Write-Output "Suspended: ProtectionStatus=Off and encryption percentage is $($vol.EncryptionPercentage). A clear key may be active."
            }
        }
    }
}

function Unlock-RedeemWithCim([string]$DriveName) {
    $letter = $DriveName.TrimEnd(':')
    $vol = $null
    try {
        $vol = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$letter'" -ErrorAction Stop
    } catch {
        return $false
    }
    if (-not $vol) { return $false }
    $secure = Read-Host -AsSecureString -Prompt "Recovery password or passphrase (local input, not saved)"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $plain = $null
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $result = $null
    try {
        if ($plain -match '^\d{48}$') {
            $groups = @()
            for ($i = 0; $i -lt 48; $i += 6) { $groups += $plain.Substring($i, 6) }
            $plain = $groups -join '-'
        }
        if ($plain -match '^\d{6}(-\d{6}){7}$') {
            $result = Invoke-CimMethod -InputObject $vol -MethodName UnlockWithNumericalPassword -Arguments @{ NumericalPassword = $plain }
        } else {
            $result = Invoke-CimMethod -InputObject $vol -MethodName UnlockWithPassphrase -Arguments @{ Passphrase = $plain }
        }
    } catch {
        $plain = $null
        Write-Output "In-process WMI unlock is not available on this image ($($_.Exception.Message))."
        return $false
    } finally {
        $plain = $null
    }
    if ($result -and $result.ReturnValue -eq 0) {
        Write-Output "unlocked $DriveName"
        return $true
    }
    $code = if ($result) { $result.ReturnValue } else { 'none' }
    Write-Output "unlock returned $code"
    return $false
}

function Invoke-RedeemUnlock([string]$DriveName, [string]$BekPath) {
    if ($BekPath) {
        if (-not (Test-Path -LiteralPath $BekPath -PathType Leaf)) {
            Write-RedeemErr "bek file was not found. Nothing was unlocked."
            exit 1
        }
        if ($DryRun) {
            Write-Output "dry-run: manage-bde -unlock $DriveName -RecoveryKey <bek-path>"
            return
        }
        $bde = Get-Command manage-bde.exe -ErrorAction SilentlyContinue
        if (-not $bde) { Write-RedeemErr "manage-bde.exe: not found"; exit 1 }
        & $bde.Source -unlock $DriveName -RecoveryKey $BekPath
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        return
    }
    if ($DryRun) {
        Write-Output "dry-run: would prompt on this console. The secret is not a parameter of this script or of manage-bde."
        return
    }
    if (Unlock-RedeemWithCim $DriveName) { return }
    $bde = Get-Command manage-bde.exe -ErrorAction SilentlyContinue
    if (-not $bde) { Write-RedeemErr "manage-bde.exe: not found"; exit 1 }
    Write-Output "WMI did not unlock the volume. manage-bde will prompt for a password protector. That prompt does not put the secret on the command line."
    Write-Output "A 48-digit recovery password is not passed to manage-bde from this helper. Use the WMI path above on full Windows, or a .bek file: -Bek PATH."
    & $bde.Source -unlock $DriveName -Password
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Invoke-RedeemRemove([string]$DriveName) {
    $health = Get-RedeemDriveHealth $DriveName
    Write-Output "disk health: $($health.Status)"
    Write-Output $health.Detail
    if ($health.Status -eq 'failing') {
        Write-RedeemErr "refusing manage-bde -off. The disk reports failing or unhealthy status. Copy files off read-only first. In-place decryption rewrites every encrypted sector."
        exit 1
    }
    if ($health.Status -eq 'unknown') {
        Write-Output "warning: disk health is unknown. Do not decrypt in place if the disk is clicking, timing out, or already losing sectors. Copy files read-only first."
    }
    Write-RedeemPowerReminder
    if ($DryRun) {
        Write-Output "dry-run: would require the exact phrase DECRYPT $DriveName"
        Write-Output "dry-run: manage-bde -off $DriveName"
        Write-Output "dry-run: watch with manage-bde -status $DriveName until Percentage Encrypted is 0.0% and Conversion Status is Fully Decrypted."
        return
    }
    $typed = Read-Host "Type DECRYPT $DriveName to run manage-bde -off $DriveName"
    if (-not (Test-RedeemConfirmPhrase $typed $DriveName)) {
        Write-RedeemErr "confirmation did not match. manage-bde -off was not run."
        exit 2
    }
    $bde = Get-Command manage-bde.exe -ErrorAction SilentlyContinue
    if (-not $bde) { Write-RedeemErr "manage-bde.exe: not found"; exit 1 }
    & $bde.Source -off $DriveName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Output "Decryption is running. Watch it with:"
    Write-Output "  manage-bde -status $DriveName"
    Write-Output "It is finished when Percentage Encrypted is 0.0% and Conversion Status is Fully Decrypted."
    Write-Output "Do not power off or unplug the disk before that."
}

switch ($Action) {
    'status' { Show-RedeemStatus $Drive }
    'unlock' { Invoke-RedeemUnlock $Drive $Bek }
    'remove' { Invoke-RedeemRemove $Drive }
}
