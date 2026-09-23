@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0deck-skills.ps1" %*
exit /b %ERRORLEVEL%
