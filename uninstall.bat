@echo off
REM kr6-trainer uninstaller -- double-click this file.
REM Removes only what the mod wrote into the save directory; the game's own saves and your
REM save backups are never touched. ASCII-only on purpose (see install.bat).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
echo.
pause
