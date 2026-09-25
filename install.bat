@echo off
REM kr6-trainer installer -- double-click this file.
REM ASCII-only on purpose: cmd.exe reads .bat in the OEM codepage, so Chinese
REM here would show up as garbage. All messages come from install.ps1 (UTF-8 BOM).
REM -ExecutionPolicy Bypass applies to this one run only and changes no system
REM setting; without it a default Windows refuses to run any PowerShell script.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
