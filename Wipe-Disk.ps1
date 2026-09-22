<#
.SYNOPSIS
  Wipe-Disk.ps1 - overwrite every sector of ONE physical disk with zeros
  (diskpart "clean all"), then read the disk back and verify it is all zero.

.DESCRIPTION
  DEFAULT IS DRY RUN. Nothing is written unless -Apply is given.
  -Apply requires an elevated PowerShell (Run as administrator) and two
  interactive confirmations (disk model, then the word WIPE).
  -VerifyOnly reads the disk back and reports whether it is all zero
  (no write; also needs elevation). -VerifyOnly wins over -Apply.

  Guards (the script refuses to run if any of these fail):
    * the disk is the boot or system disk
    * the disk is not on the USB bus (this script is for a USB dock)
    * the disk reports MediaType SSD (zero-fill is not enough for SSDs)
    * the drive holding this script or %TEMP% is on the target disk
    * -ExpectModel is given and the disk model does not contain it

  A single zero pass is a "Clear" overwrite in the sense of NIST SP 800-88 Rev.2 sec. 3.1.1.
  There is NO undo. If in doubt, run without -Apply first.

  Logs go to <script folder>\logs\wipe-disk<N>-<timestamp>.log unless -LogPath is given.
  After -Apply or -VerifyOnly a certificate is written next to the log:
    logs\wipe-report-<serial>-<timestamp>.txt  (Japanese, from report.ja.txt)
    logs\wipe-report-<serial>-<timestamp>.json (machine readable)
  The drive's label serial comes from smartctl (see Get-DriveIdentity.ps1) when available,
  else from -LabelSerial / the interactive prompt (recorded as "manual"), else Windows' value
  (which behind a USB dock is the bridge's serial, and is recorded as such).
  Exit codes: 0 = PASS / dry run, 1 = verify FAILED or diskpart failed, 2 = guard or
              confirmation aborted (nothing written), 3 = verify could not be performed (UNKNOWN).

.EXAMPLE
  .\Wipe-Disk.ps1 -DiskNumber 3 -ExpectModel ST500DM002            # dry run
  .\Wipe-Disk.ps1 -DiskNumber 3 -ExpectModel ST500DM002 -Apply     # wipe + sampled verify
  .\Wipe-Disk.ps1 -DiskNumber 3 -ExpectModel ST500DM002 -Apply -FullVerify   # + read every sector
  .\Wipe-Disk.ps1 -DiskNumber 3 -VerifyOnly -FullVerify           # read every sector, no write
  .\Wipe-Disk.ps1 -DiskNumber 3 -Apply -FullVerify -LabelSerial 5VM0XXXX -Operator "Taro Yamada"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$DiskNumber,
    [string]$ExpectModel = '',
    [switch]$Apply,
    [switch]$VerifyOnly,
    [switch]$FullVerify,
    [int]$VerifySamples = 64,
    [string]$LogPath = '',
    [string]$LabelSerial = '',
    [string]$Operator = ''
)

$ToolVersion = '1.2.1 (2026-09-22)'
$ErrorActionPreference = 'Stop'
if (-not $LogPath) {
    $logDir = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $LogPath = Join-Path $logDir ("wipe-disk{0}-{1}.log" -f $DiskNumber, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Log([string]$msg) {
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $LogPath -Value $line -Encoding ASCII
}

function Fail([string]$msg) {
    Log ("ABORT: " + $msg)
    exit 2
}

function NoSpace([string]$s) { return ($s -replace '\s', '') }

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Keep the PC from sleeping while this process runs (on 2026-09-19 it slept between the wipe and the verify).
# The flag is per-process and clears when the process exits; no power setting is changed.
Add-Type -Namespace WipeDisk -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
function Keep-Awake {
    $ES_CONTINUOUS = [uint32]2147483648      # 0x80000000 (a hex literal would be a negative int32 in PowerShell)
    $ES_SYSTEM_REQUIRED = [uint32]1          # 0x00000001
    $r = [WipeDisk.Power]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)
    if ($r -eq 0) { Log "WARNING: could not set the keep-awake flag; the PC may sleep during the run" } else { Log "keep-awake flag set for this process" }
}

# Returns $true when the first $len bytes of the array are all zero.
# Compares MD5 of the chunk with the MD5 of a zero chunk of the same length
# (cached per length) - far faster than a per-byte compare in PowerShell 5.1.
$script:Md5 = [System.Security.Cryptography.MD5]::Create()
$script:ZeroHash = @{}
function Test-AllZero([byte[]]$buf, [int]$len) {
    if (-not $script:ZeroHash.ContainsKey($len)) {
        $z = New-Object byte[] $len
        $script:ZeroHash[$len] = [BitConverter]::ToString($script:Md5.ComputeHash($z, 0, $len))
    }
    $h = [BitConverter]::ToString($script:Md5.ComputeHash($buf, 0, $len))
    return ($h -eq $script:ZeroHash[$len])
}

# Read $count regions of $chunk bytes spread over the disk (always includes first and last).
# With -Full, read the whole disk sequentially. Returns number of non-zero regions (-1 = could not read).
# $path defaults to the raw physical drive; -TestPath lets a plain file stand in for it (unit test only).
function Verify-Zero([int]$number, [long]$size, [int]$sector, [switch]$Full, [int]$count, [string]$TestPath = '') {
    $chunk = 4MB
    if ($size -lt $chunk) { $chunk = [int]($size - ($size % $sector)) }
    $path = if ($TestPath) { $TestPath } else { "\\.\PhysicalDrive$number" }
    $fs = $null
    $bad = 0
    $script:VerifyBytes = [long]0        # for the certificate
    $script:VerifySeconds = 0
    $vsw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite, 1MB, [System.IO.FileOptions]::None)
        $buf = New-Object byte[] $chunk
        if ($Full) {
            $pos = [long]0
            $total = $size
            $nextReport = 0.0
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($pos -lt $total) {
                $want = [int][math]::Min([long]$chunk, $total - $pos)
                $want = $want - ($want % $sector)
                if ($want -le 0) { break }
                $got = $fs.Read($buf, 0, $want)
                if ($got -le 0) { Log ("read returned {0} at offset {1}" -f $got, $pos); return -1 }
                if (-not (Test-AllZero $buf $got)) { $bad++; Log ("NON-ZERO data at offset {0}" -f $pos) }
                $pos += $got
                $script:VerifyBytes = $pos
                $pct = [math]::Floor(100.0 * $pos / $total)
                if ($pct -ge $nextReport) {
                    # NOTE: keep every -f argument in parentheses - "," binds tighter than "/" in PowerShell.
                    $status = "{0}% ({1:N1} GB, {2:N0} s)" -f $pct, ($pos / 1GB), ($sw.Elapsed.TotalSeconds)
                    Write-Progress -Activity "Full verify" -Status $status -PercentComplete $pct
                    Log ("full verify {0}" -f $status)
                    $nextReport += 5
                }
            }
            Write-Progress -Activity "Full verify" -Completed
            Log ("full verify read {0:N0} bytes in {1:N0} s" -f $pos, $sw.Elapsed.TotalSeconds)
        }
        else {
            if ($count -lt 2) { $count = 2 }
            $step = [long][math]::Floor(($size - $chunk) / ($count - 1))
            $step = $step - ($step % $sector)
            for ($i = 0; $i -lt $count; $i++) {
                $off = [long]$i * $step
                if ($i -eq $count - 1) { $off = $size - $chunk }
                $off = $off - ($off % $sector)
                [void]$fs.Seek($off, [System.IO.SeekOrigin]::Begin)
                $got = $fs.Read($buf, 0, $chunk)
                if ($got -le 0) { Log ("read returned {0} at offset {1}" -f $got, $off); return -1 }
                if (-not (Test-AllZero $buf $got)) { $bad++; Log ("NON-ZERO data at offset {0}" -f $off) }
                $script:VerifyBytes += $got
            }
            Log ("sampled verify: {0} regions x {1} MB read" -f $count, ($chunk / 1MB))
        }
    }
    catch {
        Log ("verify read failed: " + $_.Exception.Message)
        return -1
    }
    finally {
        if ($fs) { $fs.Dispose() }
        $script:VerifySeconds = [math]::Round($vsw.Elapsed.TotalSeconds)
    }
    return $bad
}

# ---------------------------------------------------------------- certificate
# $R collects everything the certificate needs; Write-Report renders report.ja.txt and a JSON twin.
$script:R = [ordered]@{}
function Set-R([string]$key, $value) { $script:R[$key] = $value }

# report.ja.txt = "@key=text" dictionary lines, a line "@@", then the certificate body with {{Placeholder}} tokens.
# Keeping every Japanese string in that file lets this script stay pure ASCII (PowerShell 5.1 reads it as cp932).
$script:Tpl = $null
$script:Dict = @{}
function Load-Template {
    if ($script:Tpl -ne $null) { return }
    $raw = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot 'report.ja.txt')
    $parts = $raw -split "(?m)^@@\r?\n", 2
    foreach ($line in ($parts[0] -split "\r?\n")) {
        if ($line -match '^@([\w.]+)=(.*)$') { $script:Dict[$Matches[1]] = $Matches[2] }
    }
    $script:Tpl = $parts[1]
}
function T([string]$key) {
    Load-Template
    if ($script:Dict.ContainsKey($key)) { return $script:Dict[$key] }
    return "[$key]"
}

function Write-Report([string]$verdictKey) {
    Load-Template
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $serialForName = ($script:R['Serial'] -replace '[^A-Za-z0-9_-]', '')
    if (-not $serialForName) { $serialForName = "disk$DiskNumber" }
    $base = Join-Path (Split-Path $LogPath) ("wipe-report-{0}-{1}" -f $serialForName, $ts)
    $txtPath = "$base.txt"; $jsonPath = "$base.json"
    Set-R 'ReportId' ("WIPE-{0}-{1}" -f $ts, $serialForName)
    Set-R 'IssuedAt' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Set-R 'Verdict' (T ("Verdict." + $verdictKey))
    Set-R 'LogPath' $LogPath
    Set-R 'JsonPath' $jsonPath
    Set-R 'ToolVersion' $ToolVersion
    # every placeholder must resolve; unknown ones render as "-" so a blank never looks like a fact.
    # Two passes, because dictionary texts may themselves contain placeholders.
    $eval = {
        param($m)
        $k = $m.Groups[1].Value
        if ($script:R.Contains($k) -and $null -ne $script:R[$k] -and "$($script:R[$k])" -ne '') { "$($script:R[$k])" } else { '-' }
    }
    $txt = [regex]::Replace($script:Tpl, '\{\{(\w+)\}\}', $eval)
    $txt = [regex]::Replace($txt, '\{\{(\w+)\}\}', $eval)
    [System.IO.File]::WriteAllText($txtPath, $txt, [System.Text.Encoding]::UTF8)   # UTF-8 with BOM (Notepad-safe)
    [System.IO.File]::WriteAllText($jsonPath, ([pscustomobject]$script:R | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8)
    Log ("certificate written: {0}" -f $txtPath)
    Log ("certificate data   : {0}" -f $jsonPath)
}

# Prints the verdict line and returns the exit code.
function Report-Verdict([int]$bad, [string]$what) {
    if ($bad -eq 0) {
        Log ("VERDICT: PASS - disk {0} ({1}) read back as all zero ({2})." -f $DiskNumber, $model, $what)
        if (-not $FullVerify) { Log "Sampled verify cannot prove every sector; run -VerifyOnly -FullVerify if you need that." }
        return 0
    }
    elseif ($bad -gt 0) {
        Log ("VERDICT: FAILED - {0} region(s) still contain non-zero data. Do not dispose of the drive yet." -f $bad)
        return 1
    }
    else {
        Log "VERDICT: UNKNOWN - the read-back could not be performed. Treat as not verified."
        return 3
    }
}

# ---------------------------------------------------------------- inspect
Log ("Wipe-Disk.ps1 start; DiskNumber={0} Apply={1} VerifyOnly={2} FullVerify={3} log={4}" -f $DiskNumber, $Apply.IsPresent, $VerifyOnly.IsPresent, $FullVerify.IsPresent, $LogPath)

$disk = Get-Disk -Number $DiskNumber
$pd = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq "$DiskNumber" } | Select-Object -First 1
$parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)

$sizeGB = [math]::Round($disk.Size / 1GB, 2)
$model = $disk.FriendlyName.Trim()
$media = if ($pd) { [string]$pd.MediaType } else { 'Unknown' }
$verifyWhat = if ($FullVerify) { 'every sector' } else { "$VerifySamples sampled regions" }

Log "---- target disk ----"
Log ("Number        : {0}" -f $disk.Number)
Log ("Model         : {0}" -f $model)
Log ("SerialNumber  : {0}   (for a USB dock this is usually the bridge's serial, not the drive's)" -f $disk.SerialNumber)
Log ("BusType       : {0}" -f $disk.BusType)
Log ("MediaType     : {0}" -f $media)
Log ("Size          : {0} GB ({1:N0} bytes), sector {2}" -f $sizeGB, $disk.Size, $disk.LogicalSectorSize)
Log ("PartitionStyle: {0}  IsBoot={1} IsSystem={2} IsOffline={3}" -f $disk.PartitionStyle, $disk.IsBoot, $disk.IsSystem, $disk.IsOffline)
Log "---- partitions / volumes that will be destroyed ----"
$lettersOnDisk = @()
$partLines = @()
foreach ($p in $parts) {
    $vol = $null
    try { $vol = $p | Get-Volume -ErrorAction SilentlyContinue } catch { }
    $label = if ($vol) { $vol.FileSystemLabel } else { '' }
    $fsys = if ($vol) { $vol.FileSystem } else { '' }
    $letter = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { '-' }
    if ($p.DriveLetter) { $lettersOnDisk += [string]$p.DriveLetter }
    $partLines += ("  #{0} {1,-3} {2,10:N2} GB {3,-6} {4,-5} {5}" -f $p.PartitionNumber, $letter, ($p.Size / 1GB), $fsys, $p.Type, $label)
}
if ($parts.Count -eq 0) { $partLines += "  (no partitions)" }
foreach ($l in $partLines) { Log $l }

# certificate: media facts as Windows sees them (the drive's own serial is added after the guards)
Set-R 'DiskNumber' $DiskNumber
Set-R 'WindowsModel' $model
Set-R 'BridgeSerial' ("" + $disk.SerialNumber).Trim()
Set-R 'BusType' ([string]$disk.BusType)
Set-R 'SizeBytes' ("{0:N0}" -f $disk.Size)
Set-R 'SizeGB' $sizeGB
Set-R 'SectorSize' $disk.LogicalSectorSize
Set-R 'SectorCount' ("{0:N0}" -f ($disk.Size / $disk.LogicalSectorSize))
Set-R 'MaxLba' ("{0:N0}" -f ($disk.Size / $disk.LogicalSectorSize - 1))
Set-R 'PartitionStyleBefore' ([string]$disk.PartitionStyle)
Set-R 'PartitionsBefore' (($partLines | ForEach-Object { '                    ' + $_.Trim() }) -join "`r`n")
Set-R 'Operator' $(if ($Operator) { $Operator } else { "$env:USERDOMAIN\$env:USERNAME" })
Set-R 'ComputerName' $env:COMPUTERNAME
try { $os = Get-CimInstance Win32_OperatingSystem; Set-R 'OsCaption' $os.Caption; Set-R 'OsBuild' $os.BuildNumber } catch { }
Set-R 'RunType' $(if ($VerifyOnly) { 'VERIFY ONLY (read-back only; overwrite was done in an earlier run - see its log)' } else { 'WIPE (overwrite + read-back verification)' })

# ---------------------------------------------------------------- guards
$problems = @()
if ($disk.IsBoot -or $disk.IsSystem) { $problems += "disk is the boot/system disk" }
if ([string]$disk.BusType -ne 'USB') { $problems += ("BusType is {0}, not USB" -f $disk.BusType) }
if ($media -eq 'SSD') { $problems += "MediaType is SSD; zero-fill is not a reliable erase for SSDs, this tool is for magnetic HDDs only" }
if ($ExpectModel -and ((NoSpace $model) -notlike ("*" + (NoSpace $ExpectModel) + "*"))) {
    $problems += ("model '{0}' does not contain expected '{1}'" -f $model, $ExpectModel)
}
$scriptDrive = (Split-Path -Qualifier $PSCommandPath).TrimEnd(':')
$tempDrive = (Split-Path -Qualifier $env:TEMP).TrimEnd(':')
$sysDrive = $env:SystemDrive.TrimEnd(':')
foreach ($l in $lettersOnDisk) {
    if ($l -eq $scriptDrive) { $problems += "this script is stored on the target disk" }
    if ($l -eq $tempDrive)   { $problems += "%TEMP% is on the target disk" }
    if ($l -eq $sysDrive)    { $problems += "SystemDrive is on the target disk" }
}
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Log ("GUARD FAILED: " + $p) }
    Fail "refusing to touch this disk"
}
if ($media -ne 'HDD') {
    Log ("WARNING: MediaType is '{0}' (USB bridges often hide it). Make sure this is a magnetic HDD." -f $media)
}
Log "all guards passed"

# ---------------------------------------------------------------- dry run
if (-not $Apply -and -not $VerifyOnly) {
    Log "DRY RUN - nothing was written."
    Log ("Would run : diskpart  'select disk {0}' + 'clean all'  (zero every sector, ~{1} GB)" -f $DiskNumber, $sizeGB)
    Log ("Then      : read back {0} and confirm it is all zero ({1})" -f "\\.\PhysicalDrive$DiskNumber", $verifyWhat)
    Log "Then      : write the certificate logs\wipe-report-<serial>-<timestamp>.txt/.json"
    Log "Re-run with -Apply from an elevated PowerShell to do it."
    exit 0
}

if (-not (Test-IsAdmin)) { Fail ($(if ($VerifyOnly) { '-VerifyOnly' } else { '-Apply' }) + " needs an elevated PowerShell (Run as administrator)") }

# ---------------------------------------------------------------- drive identity (label serial) for the certificate
# NOTE: dot-sourcing runs that script's own param() block in THIS scope, so its
# "param([int]$DiskNumber = -1)" overwrites our $DiskNumber with -1 (seen 2026-09-22:
# Get-Disk -Number -1 threw before the identity line was even logged). Save and restore it.
$dn = $DiskNumber
. (Join-Path $PSScriptRoot 'Get-DriveIdentity.ps1')
$DiskNumber = $dn
$identity = Get-DriveIdentity $DiskNumber
Log "---- drive identity ----"
Log ("identity source: {0} ({1})" -f $identity.Source, $identity.Tool)
if ($identity.Error) { Log ("identity note  : {0}" -f $identity.Error) }
Log ("model {0} / serial {1} / firmware {2} / WWN {3}" -f $identity.Model, $identity.Serial, $identity.Firmware, $(if ($identity.WWN) { $identity.WWN } else { '-' }))
if ($identity.SizeMatches -eq $false) { Log ("WARNING: smartctl capacity {0} differs from Windows size {1}" -f $identity.SmartctlSizeBytes, $identity.WindowsSizeBytes) }

if (-not $LabelSerial -and $identity.Source -ne 'smartctl') {
    Write-Host ""
    Write-Host "The drive's own serial could not be read through the dock (smartctl not available)." -ForegroundColor Yellow
    $LabelSerial = (Read-Host "Type the serial number printed on the drive label for the certificate (Enter to skip)").Trim()
}
Set-R 'Model' $identity.Model
Set-R 'Firmware' $identity.Firmware
Set-R 'WWN' $identity.WWN
Set-R 'IdentityTool' $identity.Tool
Set-R 'LabelSerial' $LabelSerial
Set-R 'IdentifySerial' $(if ($identity.Source -eq 'smartctl') { $identity.Serial } else { '' })
if ($identity.Source -eq 'smartctl') {
    Set-R 'Serial' $identity.Serial
    if ($LabelSerial -and ((NoSpace $LabelSerial) -ne (NoSpace $identity.Serial))) {
        Log ("WARNING: typed label serial '{0}' differs from IDENTIFY serial '{1}'" -f $LabelSerial, $identity.Serial)
        Set-R 'SerialSource' (T 'SerialSource.mismatch')
    } else { Set-R 'SerialSource' (T 'SerialSource.smartctl') }
} elseif ($LabelSerial) {
    Set-R 'Serial' $LabelSerial
    Set-R 'SerialSource' (T 'SerialSource.manual')
    Log ("label serial (manual): {0}" -f $LabelSerial)
} else {
    Set-R 'Serial' $identity.Serial
    Set-R 'SerialSource' (T 'SerialSource.windows')
    Log "WARNING: no label serial; the certificate will carry the USB bridge's serial, marked as such"
}
Set-R 'VerifyScope' $(if ($FullVerify) { T 'VerifyScope.full' } else { T 'VerifyScope.sampled' })
Set-R 'VerifySamples' $VerifySamples
Set-R 'VerifyResult' (T 'VerifyResult.notrun')
Set-R 'DiskpartMessage' (T 'Diskpart.notrun')

# Fills the verification fields from the last Verify-Zero call and maps its result to a verdict key.
function Set-VerifyFacts([int]$bad) {
    Set-R 'VerifyBytes' ("{0:N0}" -f $script:VerifyBytes)
    Set-R 'VerifySeconds' $script:VerifySeconds
    Set-R 'NonZeroRegions' $(if ($bad -ge 0) { $bad } else { '-' })
    if ($bad -eq 0) { Set-R 'VerifyResult' (T 'VerifyResult.pass'); return 'pass' }
    if ($bad -gt 0) { Set-R 'VerifyResult' (T 'VerifyResult.fail'); return 'fail' }
    Set-R 'VerifyResult' (T 'VerifyResult.unknown'); return 'unknown'
}

# ---------------------------------------------------------------- verify only (no write)
if ($VerifyOnly) {
    Log ("VERIFY ONLY - reading {0} back ({1}); nothing will be written." -f "\\.\PhysicalDrive$DiskNumber", $verifyWhat)
    Keep-Awake
    $bad = Verify-Zero -number $DiskNumber -size $disk.Size -sector $disk.LogicalSectorSize -Full:$FullVerify -count $VerifySamples
    $key = Set-VerifyFacts $bad
    Set-R 'PartitionStyleAfter' ([string]$disk.PartitionStyle)
    Set-R 'PartitionsAfter' $parts.Count
    Set-R 'VerdictText' (T $(if ($key -eq 'pass') { 'VerdictText.verifypass' } else { "VerdictText.$key" }))
    $code = Report-Verdict $bad $verifyWhat
    Write-Report $key
    exit $code
}

# ---------------------------------------------------------------- apply
Write-Host ""
Write-Host ("About to ZERO EVERY SECTOR of disk {0}: {1}, {2} GB, {3}. This cannot be undone." -f $DiskNumber, $model, $sizeGB, $disk.BusType) -ForegroundColor Yellow
$typed = Read-Host ("Type the disk model exactly as shown above to continue (Ctrl+C to abort): [{0}]" -f $model)
if ((NoSpace $typed) -ne (NoSpace $model)) { Fail "model confirmation did not match" }
$typed = Read-Host "Type WIPE (upper case) to start"
if ($typed -cne 'WIPE') { Fail "WIPE confirmation did not match" }

$dpFile = Join-Path $env:TEMP ("wipe-disk{0}.dp.txt" -f $DiskNumber)
@("select disk $DiskNumber", "clean all", "exit") | Set-Content -Path $dpFile -Encoding ASCII
Log ("diskpart script: " + $dpFile)
Log ("running diskpart clean all ... roughly {0:N0}-{1:N0} min at 150-50 MB/s; do not touch the dock" -f ($disk.Size / 150MB / 60), ($disk.Size / 50MB / 60))
Keep-Awake

Set-R 'WipeStart' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dpOut = & diskpart.exe /s $dpFile 2>&1
$dpExit = $LASTEXITCODE
$sw.Stop()
Set-R 'WipeEnd' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
$dpLines = @($dpOut | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
foreach ($line in $dpLines) { Log ("  diskpart> " + $line) }
$wipeSec = [math]::Round($sw.Elapsed.TotalSeconds)
$wipeMBps = [math]::Round($disk.Size / 1MB / [math]::Max(1, $sw.Elapsed.TotalSeconds))
Log ("diskpart exit code {0}, elapsed {1:N0} s ({2:N0} MB/s)" -f $dpExit, $wipeSec, $wipeMBps)
Remove-Item $dpFile -ErrorAction SilentlyContinue
Set-R 'WipeSeconds' ("{0:N0}" -f $wipeSec)
Set-R 'WipeMBps' $wipeMBps
Set-R 'DiskpartExit' $dpExit
Set-R 'DiskpartVersion' $(if ($dpLines.Count -gt 0) { ($dpLines[0] -replace '^\D*', '') } else { '' })   # first line ends with the version number
Set-R 'DiskpartMessage' (($dpLines | Select-Object -Skip 1 | Where-Object { $_ -notmatch 'Copyright|Microsoft' }) -join ' / ')

if ($dpExit -ne 0) {
    Log "VERDICT: FAILED - diskpart reported failure; the disk may be only partially wiped. Do not dispose of the drive yet."
    Set-R 'VerdictText' (T 'VerdictText.dpfail')
    Write-Report 'fail'
    exit 1
}

try { Update-HostStorageCache } catch { }
Start-Sleep -Seconds 2
$after = Get-Disk -Number $DiskNumber
$afterParts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue).Count
Log ("after clean: PartitionStyle={0} partitions={1}" -f $after.PartitionStyle, $afterParts)
Set-R 'PartitionStyleAfter' ([string]$after.PartitionStyle)
Set-R 'PartitionsAfter' $afterParts

# ---------------------------------------------------------------- verify
Log "verifying by reading the disk back ..."
$bad = Verify-Zero -number $DiskNumber -size $disk.Size -sector $disk.LogicalSectorSize -Full:$FullVerify -count $VerifySamples
$key = Set-VerifyFacts $bad
Set-R 'VerdictText' (T "VerdictText.$key")
$code = Report-Verdict $bad $verifyWhat
Write-Report $key
if ($code -eq 0) {
    Log ("Windows may now offer to initialize disk {0} - just cancel. Power off the dock and remove the drive." -f $DiskNumber)
}
exit $code
