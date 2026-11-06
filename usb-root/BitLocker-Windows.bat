@echo off
setlocal EnableExtensions
REM Status, unlock, and permanent BitLocker removal.
REM Works on full Windows and on WinPE / Hiren's BootCD PE.
REM A recovery password is never forwarded on a command line.
REM If powershell.exe is missing, manage-bde.exe is used directly.

set "ROOT=%~dp0"
set "ACTION=%~1"
if "%ACTION%"=="" set "ACTION=status"
set "DRIVE=%~2"
set "BEK="

if /I "%~3"=="--password" goto refuse_secret
if /I "%~3"=="--key" goto refuse_secret
if /I "%~3"=="-rp" goto refuse_secret
if /I "%~3"=="--rw" goto refuse_secret
if /I "%~3"=="--bek" set "BEK=%~4"
if not "%~3"=="" if /I not "%~3"=="--bek" goto refuse_extra
if /I "%~3"=="--bek" if "%~4"=="" goto refuse_extra
if not "%~5"=="" goto refuse_extra

echo %ACTION% %DRIVE% %BEK% | findstr /R /C:"[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]" >nul
if not errorlevel 1 goto refuse_secret

set "PS1=%ROOT%ai\scripts\bitlocker-windows.ps1"
if not exist "%PS1%" set "PS1=%ROOT%..\scripts\host\bitlocker-windows.ps1"

where powershell.exe >nul 2>&1
if errorlevel 1 goto BATONLY

if "%BEK%"=="" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Action "%ACTION%" -Drive "%DRIVE%"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Action "%ACTION%" -Drive "%DRIVE%" -Bek "%BEK%"
)
exit /b %ERRORLEVEL%

:BATONLY
echo redeem: powershell.exe is not on this image. Using manage-bde.exe.
echo redeem: a recovery password will not be placed on a command line.
if /I "%ACTION%"=="status" goto BAT_STATUS
if /I "%ACTION%"=="unlock" goto BAT_UNLOCK
if /I "%ACTION%"=="remove" goto BAT_REMOVE
if /I "%ACTION%"=="decrypt" goto BAT_REMOVE
echo redeem: unknown action. Use status, unlock, or remove.
exit /b 2

:BAT_STATUS
echo redeem: protector output stays on this screen. It is not written to a file.
if "%DRIVE%"=="" (
  manage-bde -status
) else (
  manage-bde -status %DRIVE%
  manage-bde -protectors -get %DRIVE%
)
exit /b %ERRORLEVEL%

:BAT_UNLOCK
if "%DRIVE%"=="" goto need_drive
if not "%BEK%"=="" (
  manage-bde -unlock %DRIVE% -rk "%BEK%"
  exit /b %ERRORLEVEL%
)
echo redeem: manage-bde will prompt for a password protector.
echo redeem: that prompt does not put the secret on the command line.
echo redeem: a 48-digit recovery password needs PowerShell, which this image does not have.
echo redeem: use a .bek file, or boot Hiren's BootCD PE / full Windows and run this helper again.
manage-bde -unlock %DRIVE% -Password
exit /b %ERRORLEVEL%

:BAT_REMOVE
if "%DRIVE%"=="" goto need_drive
echo redeem: in-place decryption rewrites every encrypted sector. Use AC power.
where wmic >nul 2>&1
if errorlevel 1 goto BAT_NO_WMIC
wmic diskdrive get status | findstr /I "Pred Fail" >nul
if not errorlevel 1 (
  echo redeem: refusing manage-bde -off. wmic reports a failing disk. Copy files off read-only first.
  exit /b 1
)
:BAT_NO_WMIC
echo Type DECRYPT %DRIVE% to run manage-bde -off %DRIVE%
set /p CONFIRM=
if not "%CONFIRM%"=="DECRYPT %DRIVE%" (
  echo redeem: confirmation did not match. manage-bde -off was not run.
  exit /b 2
)
manage-bde -off %DRIVE%
echo Watch progress: manage-bde -status %DRIVE%
echo Finished when Percentage Encrypted is 0.0%% and Conversion Status is Fully Decrypted.
exit /b %ERRORLEVEL%

:need_drive
echo redeem: this action needs a drive letter, for example C:
exit /b 2

:refuse_secret
echo redeem: refusing a password flag or a recovery-password-shaped argument. Type the secret at the local prompt.
exit /b 2

:refuse_extra
echo redeem: refusing an extra argument. Do not pass a recovery key on the command line.
exit /b 2
