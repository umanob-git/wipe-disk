@echo off
setlocal
rem ------------------------------------------------------------------
rem wipe-disk.cmd - zero-fill one USB HDD for disposal (Wipe-Disk.ps1).
rem Double-click it in Explorer: it asks for UAC, lists the disks, asks
rem for the disk number, then Wipe-Disk.ps1 shows the target, asks you
rem to type the model and WIPE, zero-fills it and reads every sector back.
rem
rem   wipe-disk.cmd                      interactive (full verify)
rem   wipe-disk.cmd 3                    disk 3 preselected
rem   wipe-disk.cmd 3 ST500DM002         also require the model to contain ST500DM002
rem   flags (after the disk number):
rem     /quick        sampled verify instead of every sector
rem     /dryrun       show what would happen, write nothing
rem     /verifyonly   read back only, write nothing
rem
rem Logs: logs\wipe-disk<N>-<timestamp>.log next to this file.
rem NOTE: never put ( or ) inside an echo within an if-block - ")" closes the block.
rem ------------------------------------------------------------------
set "HERE=%~dp0"
set "PS1=%HERE%Wipe-Disk.ps1"
if not exist "%PS1%" (
    echo Wipe-Disk.ps1 not found next to this batch: %PS1%
    pause
    exit /b 2
)

rem ---- self-elevate: re-open this batch in an elevated cmd /k window ----
fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator rights - UAC prompt follows ...
    set "WD_SELF=%~f0"
    set "WD_ARGS=%*"
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath $env:ComSpec -ArgumentList ('/k \"' + $env:WD_SELF + '\" ' + $env:WD_ARGS)"
    exit /b
)

rem ---- parse arguments ----
set "DISK=%~1"
set "MODEL=%~2"
set "VERIFY=-FullVerify"
set "MODE=apply"
for %%A in (%*) do (
    if /i "%%~A"=="/quick" set "VERIFY="
    if /i "%%~A"=="/dryrun" set "MODE=dryrun"
    if /i "%%~A"=="/verifyonly" set "MODE=verifyonly"
)
set "MODELARG="
if not "%MODEL%"=="" set "MODELARG=-ExpectModel %MODEL%"

echo.
echo ==== HDD wipe for disposal - zero every sector, then read it back ====
echo Only USB-attached magnetic HDDs are accepted. There is no undo.
echo.
echo ==== disks on this PC ====
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Disk | Sort-Object Number | Format-Table Number, FriendlyName, BusType, PartitionStyle, IsBoot, IsSystem, @{n='SizeGB';e={[math]::Round($_.Size/1GB,2)}} -AutoSize | Out-String -Width 160"

if "%DISK%"=="" set /p "DISK=Disk number to wipe - Ctrl+C or Enter to abort: "
if "%DISK%"=="" (
    echo No disk number given. Nothing done.
    goto :end
)

echo.
if "%MODE%"=="verifyonly" (
    echo ==== VERIFY ONLY: disk %DISK% - no write ====
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -DiskNumber %DISK% %MODELARG% -VerifyOnly %VERIFY%
) else if "%MODE%"=="dryrun" (
    echo ==== DRY RUN: disk %DISK% - nothing is written ====
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -DiskNumber %DISK% %MODELARG% %VERIFY%
) else (
    echo ==== WIPE: disk %DISK% - the script shows the target, then asks for the model and WIPE ====
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -DiskNumber %DISK% %MODELARG% -Apply %VERIFY%
)
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
    if "%MODE%"=="dryrun" (
        echo Result: DRY RUN finished - nothing was written. Run again without /dryrun to wipe.
    ) else (
        echo Result: PASS - the disk read back as all zero. You can dispose of it. - exit code 0
    )
) else if "%RC%"=="1" (
    echo Result: FAILED - non-zero data remains. Do NOT dispose of the drive yet. - exit code 1
) else if "%RC%"=="2" (
    echo Result: ABORTED - a guard or a confirmation stopped it. Nothing was written. - exit code 2
) else (
    echo Result: UNKNOWN - verify could not run. Treat as not verified. - exit code %RC%
)

:end
echo.
echo Logs: %HERE%logs\
echo You can close this window.
endlocal
