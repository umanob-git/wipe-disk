<#
.SYNOPSIS
  Get-DriveIdentity.ps1 - the drive's own identity (model / serial / firmware / WWN / capacity)
  for the sanitization certificate. Behind a USB dock Windows only reports the bridge's serial,
  so the label serial has to come from an ATA IDENTIFY through the dock; this uses smartmontools'
  smartctl for that (it handles the SAT pass-through and the USB bridge quirks).

.DESCRIPTION
  READ ONLY (smartctl -i only reads the identify data). Elevation is needed by smartctl on Windows.
  Source priority:
    1. smartctl (bin\smartctl.exe next to this file, then Program Files, then PATH) -> Source "smartctl"
    2. Windows report (Get-Disk)                                                   -> Source "Windows"
  The caller may also pass a serial typed from the label (-LabelSerial); it is recorded as "manual".

  Dot-source to get the function:   . .\Get-DriveIdentity.ps1 ; Get-DriveIdentity 3
  Run directly:                     .\Get-DriveIdentity.ps1 -DiskNumber 3

  A failed pass-through experiment (IOCTL_ATA_PASS_THROUGH / SCSI ATA PASS-THROUGH via P/Invoke,
  Win32 error 5 even when elevated, 2026-09-19) was removed rather than guessed at.
#>
param([int]$DiskNumber = -1)

function Find-Smartctl {
    $candidates = @(
        (Join-Path $PSScriptRoot 'bin\smartctl.exe'),
        (Join-Path $env:ProgramFiles 'smartmontools\bin\smartctl.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'smartmontools\bin\smartctl.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command smartctl.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Runs smartctl -i -j for one device spec; returns the parsed JSON or $null.
function Invoke-SmartctlInfo([string]$exe, [string]$device, [string]$type) {
    $args = @('-i', '-j')
    if ($type) { $args += @('-d', $type) }
    $args += $device
    try {
        $raw = & $exe @args 2>$null
        $j = ($raw -join "`n") | ConvertFrom-Json
        if ($j.serial_number -and $j.model_name) { return $j }
    } catch { }
    return $null
}

function Get-DriveIdentity([int]$Number) {
    $disk = Get-Disk -Number $Number
    $res = [ordered]@{
        DiskNumber = $Number; BusType = [string]$disk.BusType
        WindowsModel = $disk.FriendlyName.Trim(); WindowsSerial = ("" + $disk.SerialNumber).Trim(); WindowsFirmware = ("" + $disk.FirmwareVersion).Trim()
        WindowsSizeBytes = [long]$disk.Size; LogicalSectorSize = [int]$disk.LogicalSectorSize
        Source = 'Windows'; Tool = 'Windows Get-Disk (bridge/controller report)'
        Model = $disk.FriendlyName.Trim(); Serial = ("" + $disk.SerialNumber).Trim(); Firmware = ("" + $disk.FirmwareVersion).Trim(); WWN = ''
        SmartctlSizeBytes = $null; SizeMatches = $null; SmartctlDeviceType = ''; Error = ''
    }
    $exe = Find-Smartctl
    if (-not $exe) { $res.Error = 'smartctl not found (install smartmontools or put smartctl.exe in bin\)'; return [pscustomobject]$res }

    $ver = (& $exe --version 2>$null | Select-Object -First 1)
    $dev = "/dev/pd$Number"
    $types = if ($res.BusType -eq 'USB') { @('', 'sat', 'sat,12') } else { @('', 'ata') }
    $j = $null
    foreach ($t in $types) { $j = Invoke-SmartctlInfo $exe $dev $t; if ($j) { $res.SmartctlDeviceType = $(if ($t) { $t } else { 'auto' }); break } }
    if (-not $j) { $res.Error = ("smartctl ({0}) returned no identify data for {1} (tried: auto, sat, sat,12)" -f $ver, $dev); return [pscustomobject]$res }

    $res.Source = 'smartctl'
    $res.Tool = "$ver ($exe)"
    $res.Model = ("" + $j.model_name).Trim()
    $res.Serial = ("" + $j.serial_number).Trim()
    $res.Firmware = ("" + $j.firmware_version).Trim()
    if ($j.wwn) { $res.WWN = ("{0:X}{1:X6}{2:X9}" -f [long]$j.wwn.naa, [long]$j.wwn.oui, [long]$j.wwn.id) }
    if ($j.user_capacity -and $j.user_capacity.bytes) {
        $res.SmartctlSizeBytes = [long]$j.user_capacity.bytes
        $res.SizeMatches = ($res.SmartctlSizeBytes -eq $res.WindowsSizeBytes)
    }
    return [pscustomobject]$res
}

if ($DiskNumber -ge 0) {
    Get-DriveIdentity $DiskNumber | Format-List
}
