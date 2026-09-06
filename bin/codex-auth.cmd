@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-auth.ps1" %*
exit /b %ERRORLEVEL%
