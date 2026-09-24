@echo off
REM kr6-trainer uninstaller -- double-click this file.
REM Removes only what the mod wrote into the save directory. The game's own
REM saves, and your save backups, are never touched. Messages come from
REM uninstall.ps1 (UTF-8 with BOM); this file is ASCII-only on purpose.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
echo.
pause
