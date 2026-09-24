@echo off
REM kr6-trainer installer -- double-click this file.
REM
REM All messages are in Chinese and come from install.ps1 (which is UTF-8 with
REM BOM, so PowerShell reads it correctly). This file is deliberately ASCII-only:
REM cmd.exe reads .bat files in the OEM codepage, so non-ASCII comments here
REM would show up as garbage.
REM
REM -ExecutionPolicy Bypass applies to this one run only and changes no system
REM setting. Without it a default Windows refuses to run any PowerShell script
REM at all. Explorer's own "Run with PowerShell" uses the same flag.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
