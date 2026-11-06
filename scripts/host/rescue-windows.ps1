# Read-only Windows storage triage for redeem.
# BitLocker is status only. Unlock-BitLocker and manage-bde -unlock are not used.
# A later repair would be a WRITE and is not run by this script.
param(
    [string]$UsbRoot = ""
)

$ErrorActionPreference = 'Continue'

if (-not $UsbRoot) {
    $UsbRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$UsbRoot = $UsbRoot.TrimEnd('\')
$kb = Join-Path $UsbRoot 'ai\kb'
$manifest = Join-Path $UsbRoot 'ai\models\manifest.tsv'
$server = Join-Path $UsbRoot 'ai\bin\win-x64\llama-server.exe'
$port = 8080
if ($env:RESCUE_PORT) { $port = [int]$env:RESCUE_PORT }
$tmp = if ($env:RESCUE_TMP) { $env:RESCUE_TMP } else { Join-Path $env:TEMP 'redeem' }
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

Write-Output "redeem: read-only session. Writes happen only after an explicit human OK."
Write-Output "redeem: BitLocker is detect-and-explain only. This tool will not unlock a volume."

function Add-Section([System.Text.StringBuilder]$Buf, [string]$Title, [scriptblock]$Body) {
    [void]$Buf.AppendLine("")
    [void]$Buf.AppendLine("## $Title")
    try {
        $text = & $Body | Out-String
        if ([string]::IsNullOrWhiteSpace($text)) { $text = "(none)`r`n" }
        [void]$Buf.Append($text)
    } catch {
        [void]$Buf.AppendLine("(failed: $($_.Exception.Message))")
    }
}

$diag = New-Object System.Text.StringBuilder
[void]$diag.AppendLine("# redeem Windows diagnostics (read-only, no repairs applied)")
[void]$diag.AppendLine("collected: $(Get-Date -Format o)")
Add-Section $diag 'computer' { Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, OSArchitecture | Format-List }
Add-Section $diag 'disk' { Get-Disk | Format-List }
Add-Section $diag 'physical-disk' { Get-PhysicalDisk | Format-List }
Add-Section $diag 'partition' { Get-Partition | Format-List }
Add-Section $diag 'volume' { Get-Volume | Format-List }
Add-Section $diag 'bitlocker' {
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        "Get-BitLockerVolume: not available. The volume was not unlocked."
        return
    }
    Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionPercentage, LockStatus, VolumeType | Format-List
}
Add-Section $diag 'system-log' {
    $start = (Get-Date).AddDays(-7)
    $names = @('disk', 'Ntfs', 'stornvme', 'storahci', 'Disk')
    foreach ($name in $names) {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $name; Level = 2, 3; StartTime = $start } -MaxEvents 15 -ErrorAction SilentlyContinue |
            Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message |
            Format-List
    }
}

$diagText = $diag.ToString()
if ($diagText.Length -gt 8000) { $diagText = $diagText.Substring(0, 8000) + "`n[truncated]`n" }
$diagPath = Join-Path $tmp 'rescue-diag.txt'
Set-Content -LiteralPath $diagPath -Value $diagText -Encoding utf8

function Get-RedeemNotes([string]$KbDir, [string]$Query, [int]$MaxBytes) {
    if (-not (Test-Path -LiteralPath $KbDir)) { return "[knowledge pack directory is empty]" }
    $words = @{}
    foreach ($match in [regex]::Matches($Query.ToLowerInvariant(), '[a-z0-9]{3,}')) {
        $words[$match.Value] = $true
    }
    $chunks = New-Object System.Collections.Generic.List[object]
    Get-ChildItem -LiteralPath $KbDir -Filter '*.md' -File | Where-Object { $_.Name -ne 'README.md' } | ForEach-Object {
        $title = $_.Name
        $body = New-Object System.Text.StringBuilder
        foreach ($line in (Get-Content -LiteralPath $_.FullName)) {
            if ($line -match '^#{1,6} ') {
                if ($body.Length -ge 40) {
                    $chunks.Add([pscustomobject]@{ File = $_.Name; Title = $title; Body = $body.ToString() })
                }
                $title = ($line -replace '^#{1,6} ', '')
                $body = New-Object System.Text.StringBuilder
            } else {
                [void]$body.AppendLine($line)
            }
        }
        if ($body.Length -ge 40) {
            $chunks.Add([pscustomobject]@{ File = $_.Name; Title = $title; Body = $body.ToString() })
        }
    }
    $ranked = foreach ($chunk in $chunks) {
        $score = 0
        $seen = @{}
        foreach ($match in [regex]::Matches($chunk.Body.ToLowerInvariant(), '[a-z0-9]{3,}')) {
            if ($words.ContainsKey($match.Value) -and -not $seen.ContainsKey($match.Value)) {
                $score++
                $seen[$match.Value] = $true
            }
        }
        [pscustomobject]@{ Score = $score; Chunk = $chunk }
    }
    $used = 0
    $out = New-Object System.Text.StringBuilder
    foreach ($item in ($ranked | Sort-Object Score -Descending | Select-Object -First 4)) {
        if ($item.Score -le 0) { break }
        $block = "[{0} # {1}]`r`n{2}`r`n" -f $item.Chunk.File, $item.Chunk.Title, $item.Chunk.Body.Trim()
        if ($used -gt 0 -and ($used + $block.Length) -gt $MaxBytes) { break }
        [void]$out.AppendLine($block)
        $used += $block.Length
    }
    if ($out.Length -eq 0) { return "[no knowledge-pack section matched these diagnostics]" }
    return $out.ToString()
}

$rules = @'
You are Redeem, the offline rescue assistant. You triage disks and boot problems. Phones and tablets cannot boot the stick. They are browser clients only.

Rules you do not break:
- Read-only by default. A command that writes, formats, partitions, installs a bootloader, clears a dirty flag, deletes hibernation, or unlocks encryption is a WRITE. Describe a WRITE only together with the words that a person must agree before it is run. Never tell the user to run a WRITE immediately.
- Use device names, serial numbers, sizes, and SMART or NVMe counts only when they appear in the diagnostics or the notes below. If a fact is missing, say so and name the next read-only command.
- BitLocker and Linux LUKS: detect and explain only. You do not have a recovery key. Never print a recovery key or a string of digit groups that looks like one. Do not run dislocker, manage-bde, or cryptsetup.
- Never recommend mkfs, wipefs, shred, or dd from /dev/zero or /dev/urandom.
- ntfsfix is not chkdsk. It only clears a dirty flag, and only a Windows chkdsk is a real NTFS check. Do not mention remove_hiberfile.
- If the disk looks like it is failing, the preservation step is GNU ddrescue onto a different healthy disk. That WRITE waits for a person. Do not write to the failing disk. The rescue USB is too small for a big image.
- Lead with the conclusion. Do not repeat a point.

Notes retrieved from the offline pack (incomplete by design):
'@
$notes = Get-RedeemNotes $kb $diagText 1400
$system = $rules + "`r`n" + $notes
$user = "Diagnostics from this machine (read-only collection, nothing was repaired):`r`n`r`n$diagText`r`nWhat is wrong, what is healthy, and what is the next read-only check? If a later step would write to a disk, label it WRITE and wait for an explicit human OK."
$systemPath = Join-Path $tmp 'system.txt'
$userPath = Join-Path $tmp 'user.txt'
Set-Content -LiteralPath $systemPath -Value $system -Encoding utf8
Set-Content -LiteralPath $userPath -Value $user -Encoding utf8

function Test-RedeemEndpoint([string]$Base) {
    foreach ($suffix in @('/v1/models', '/health')) {
        try {
            $resp = Invoke-WebRequest -Uri ($Base.TrimEnd('/') + $suffix) -UseBasicParsing -TimeoutSec 3
            if ($resp.StatusCode -eq 200) { return $true }
        } catch {
            continue
        }
    }
    return $false
}

$base = $null
$proc = $null
if ($env:RESCUE_ENDPOINT -and (Test-RedeemEndpoint $env:RESCUE_ENDPOINT)) {
    $base = $env:RESCUE_ENDPOINT.TrimEnd('/')
    Write-Output "redeem: using RESCUE_ENDPOINT $base"
} else {
    $os = Get-CimInstance Win32_OperatingSystem
    $freeMb = [math]::Floor($os.FreePhysicalMemory / 1024)
    Write-Output "redeem: FreePhysicalMemory $freeMb MiB"
    $models = @{}
    if (Test-Path -LiteralPath $manifest) {
        foreach ($line in (Get-Content -LiteralPath $manifest)) {
            if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
            $cols = $line -split "`t"
            if ($cols.Count -lt 2) { continue }
            $path = Join-Path $UsbRoot ("ai\models\" + $cols[1])
            if (Test-Path -LiteralPath $path) { $models[$cols[0]] = $path }
        }
    }
    $model = $null
    if ($freeMb -ge 5120 -and $models.ContainsKey('qwen3-4b')) { $model = $models['qwen3-4b'] }
    elseif ($freeMb -ge 1536 -and $models.ContainsKey('llama32-1b')) { $model = $models['llama32-1b'] }
    elseif ($models.ContainsKey('qwen3-0.6b')) { $model = $models['qwen3-0.6b'] }
    elseif ($models.ContainsKey('llama32-1b')) { $model = $models['llama32-1b'] }
    elseif ($models.ContainsKey('qwen3-4b')) { $model = $models['qwen3-4b'] }
    if (-not $model) {
        Write-Error "redeem: no GGUF under $UsbRoot\ai\models"
        exit 1
    }
    if (-not (Test-Path -LiteralPath $server)) {
        Write-Error "redeem: missing $server (run build/fetch-host-binaries.sh)"
        exit 1
    }
    $ctx = 3072
    $maxTokens = 512
    if ($model -match '4B|4b') { $ctx = 4096; $maxTokens = 640 }
    $threads = [int]$env:NUMBER_OF_PROCESSORS
    if ($threads -lt 1) { $threads = 2 }
    if ($threads -gt 8) { $threads = 8 }
    $help = & $server --help 2>&1 | Out-String
    $argList = @('-m', $model, '-c', "$ctx", '-t', "$threads", '--host', '127.0.0.1', '--port', "$port", '-ngl', '0')
    if ($help -match '--reasoning') { $argList += @('--reasoning', 'off') }
    if ($help -match '--cache-ram') { $argList += @('--cache-ram', '0') }
    if ($help -match '--temp') { $argList += @('--temp', '0.2') }
    if ($help -match '--jinja') { $argList += '--jinja' }
    $log = Join-Path $tmp 'llama-server.log'
    $err = Join-Path $tmp 'llama-server.err'
    Write-Output "redeem: model $model"
    Write-Output "redeem: binary $server"
    $proc = Start-Process -FilePath $server -ArgumentList $argList -WorkingDirectory $env:TEMP -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $err
    $ready = $false
    for ($i = 0; $i -lt 180; $i++) {
        if ($proc.HasExited) {
            Write-Error "llama-server exited early"
            if (Test-Path $err) { Get-Content $err -Tail 40 }
            exit 1
        }
        try {
            $health = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2
            if ($health.Content -match 'ok') { $ready = $true; break }
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    if (-not $ready) {
        Write-Error "llama-server did not become ready"
        exit 1
    }
    $base = "http://127.0.0.1:$port"
    $script:MaxTokens = $maxTokens
}

if (-not (Get-Variable -Name MaxTokens -Scope Script -ErrorAction SilentlyContinue)) { $script:MaxTokens = 512 }

$bodyObj = @{
    messages = @(
        @{ role = 'system'; content = $system },
        @{ role = 'user'; content = $user }
    )
    temperature = 0.2
    max_tokens = $script:MaxTokens
    stream = $false
    chat_template_kwargs = @{ enable_thinking = $false }
}
$body = $bodyObj | ConvertTo-Json -Depth 8
try {
    $chat = Invoke-RestMethod -Uri ($base.TrimEnd('/') + '/v1/chat/completions') -Method Post -ContentType 'application/json' -Body $body
} catch {
    Write-Error "redeem: first turn failed: $($_.Exception.Message)"
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    exit 1
}
$text = [string]$chat.choices[0].message.content
if ([string]::IsNullOrWhiteSpace($text)) { $text = [string]$chat.choices[0].message.reasoning_content }
$reply = Join-Path $tmp 'first-turn.txt'
Set-Content -LiteralPath $reply -Value $text -Encoding utf8
Write-Output $text
Write-Output ""
Write-Output "redeem: first turn saved to $reply"
$ui = if ($env:RESCUE_ENDPOINT -and $base -eq $env:RESCUE_ENDPOINT.TrimEnd('/')) { $base } else { "http://127.0.0.1:$port" }
Write-Output "redeem: web UI $ui"
Start-Process $ui
if ($proc) {
    Write-Output "redeem: server is running. Close this window to stop it."
    try {
        Wait-Process -Id $proc.Id
    } finally {
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    }
}
