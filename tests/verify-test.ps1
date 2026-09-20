# Unit test for Wipe-Disk.ps1: Verify-Zero (full + sampled), Keep-Awake and Report-Verdict, using plain files.
# Run (no elevation needed):  powershell -NoProfile -ExecutionPolicy Bypass -File tests\verify-test.ps1
# Exit code = number of failed checks.
$src = Get-Content -Raw -Encoding Ascii (Join-Path $PSScriptRoot '..\Wipe-Disk.ps1')
$head = $src.Substring(0, $src.IndexOf('# ---------------------------------------------------------------- inspect'))
$start = $head.IndexOf('[CmdletBinding()]')
$end = $head.IndexOf('$ErrorActionPreference')
$head = $head.Substring(0, $start) + $head.Substring($end)   # drop the param block, keep the functions
$LogPath = Join-Path $env:TEMP 'verify-test.log'
Remove-Item $LogPath -ErrorAction SilentlyContinue
$DiskNumber = 99
$model = 'TESTFILE'
$FullVerify = $true
$ToolVersion = 'test'
$PSScriptRoot_real = Split-Path -Parent $PSScriptRoot           # Write-Report / Load-Template read report.ja.txt from $PSScriptRoot
. ([scriptblock]::Create($head.Replace('$PSScriptRoot', '$PSScriptRoot_real')))

$size = 10MB + 512                      # not a multiple of the chunk: exercises the short tail read
$zero = Join-Path $env:TEMP 'verify-zero.bin'
$dirty = Join-Path $env:TEMP 'verify-dirty.bin'
$b = New-Object byte[] $size
[System.IO.File]::WriteAllBytes($zero, $b)
$b[9MB + 100] = 1
[System.IO.File]::WriteAllBytes($dirty, $b)

$fails = 0
function Check([string]$name, $got, $want) {
    $ok = ($got -eq $want)
    "{0,-58} got={1} want={2} {3}" -f $name, $got, $want, $(if ($ok) { 'OK' } else { 'FAIL' })
    if (-not $ok) { $script:fails++ }
}
Check 'full, zero file -> 0 bad'            (Verify-Zero -number 99 -size $size -sector 512 -Full -count 8 -TestPath $zero) 0
Check 'verify bytes recorded (full)'      $script:VerifyBytes $size
Check 'full, dirty file -> 1 bad'           (Verify-Zero -number 99 -size $size -sector 512 -Full -count 8 -TestPath $dirty) 1
Check 'sampled, zero file -> 0 bad'         (Verify-Zero -number 99 -size $size -sector 512 -count 8 -TestPath $zero) 0
# samples overlap on a 10 MB file, so the dirty byte may be counted more than once: only require a hit
Check 'sampled, dirty file (tail) -> hit'   ((Verify-Zero -number 99 -size $size -sector 512 -count 8 -TestPath $dirty) -ge 1) $true
Check 'missing file -> -1'                  (Verify-Zero -number 99 -size $size -sector 512 -Full -count 8 -TestPath (Join-Path $env:TEMP 'nope.bin')) -1
Check 'Report-Verdict 0 -> exit 0'  (Report-Verdict 0 'every sector') 0
Check 'Report-Verdict 2 -> exit 1'  (Report-Verdict 2 'every sector') 1
Check 'Report-Verdict -1 -> exit 3' (Report-Verdict -1 'every sector') 3
Keep-Awake
Check 'keep-awake logged' ((Get-Content $LogPath | Select-String 'keep-awake flag set').Count) 1
Check 'full verify progress lines logged' ((Get-Content $LogPath | Select-String 'full verify \d+%').Count -gt 0) $true

# ---- certificate rendering (report.ja.txt) ----
Check 'T known key'   ((T 'Verdict.pass').Length -gt 0 -and (T 'Verdict.pass') -notlike '[[]*') $true
Check 'T unknown key' (T 'nope.key') '[nope.key]'
Set-R 'Serial' 'TEST-SN 1'; Set-R 'Model' 'TEST MODEL'; Set-R 'MaxLba' '123'
Set-R 'SerialSource' (T 'SerialSource.manual'); Set-R 'BridgeSerial' 'BRIDGE01'
Set-R 'VerifyScope' (T 'VerifyScope.full'); Set-R 'VerdictText' (T 'VerdictText.pass')
Write-Report 'pass'
$rep = Get-ChildItem (Join-Path $env:TEMP 'wipe-report-TEST-SN1-*.txt') | Sort-Object LastWriteTime | Select-Object -Last 1
$js  = Get-ChildItem (Join-Path $env:TEMP 'wipe-report-TEST-SN1-*.json') | Sort-Object LastWriteTime | Select-Object -Last 1
Check 'report txt written' ($null -ne $rep) $true
Check 'report json written' ($null -ne $js) $true
if ($rep) {
    $body = Get-Content -Raw -Encoding UTF8 $rep.FullName
    Check 'no unresolved placeholders' ($body -notmatch '\{\{') $true
    Check 'no dictionary lines leaked' ($body -notmatch '(?m)^@') $true
    Check 'serial in report' ($body -match 'TEST-SN 1') $true
    Check 'nested placeholder resolved (BridgeSerial in manual text)' ($body -match 'BRIDGE01') $true
    Check 'nested placeholder resolved (MaxLba in scope text)' ($body -match 'LBA 0 - 123') $true
    Check 'PASS verdict text' ($body -match 'PASS') $true
    Check 'unknown fields render as -' ($body -match 'WWN\s+: -') $true
    $bom = [System.IO.File]::ReadAllBytes($rep.FullName)[0..2]
    Check 'UTF-8 BOM' (($bom -join ',') -eq '239,187,191') $true
    $j = Get-Content -Raw -Encoding UTF8 $js.FullName | ConvertFrom-Json
    Check 'json has ReportId' ($j.ReportId -like 'WIPE-*') $true
    Remove-Item $rep.FullName, $js.FullName -ErrorAction SilentlyContinue
}
Remove-Item $zero, $dirty, $LogPath -ErrorAction SilentlyContinue
"fails=$fails"
exit $fails
