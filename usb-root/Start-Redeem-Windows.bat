@echo off
REM Double-click in Explorer. Read-only Windows triage. Does not unlock BitLocker.
set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%ai\scripts\rescue-windows.ps1" -UsbRoot "%ROOT%"
if errorlevel 1 pause
