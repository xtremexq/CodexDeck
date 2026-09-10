@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-deck-session.ps1" %*
exit /b %ERRORLEVEL%
