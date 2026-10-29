@echo off
setlocal
set "CODEXDECK_DEFAULT_HARNESS=Antigravity"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-auth.ps1" %*
exit /b %ERRORLEVEL%
