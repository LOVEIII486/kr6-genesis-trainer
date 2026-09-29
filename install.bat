@echo off
REM kr6-trainer installer -- double-click this file.
REM ASCII-only on purpose: cmd.exe reads .bat in the OEM codepage (Chinese would show as garbage).
REM -ExecutionPolicy Bypass applies to this run only, changes no system setting; a default
REM Windows otherwise refuses to run any PowerShell script.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
