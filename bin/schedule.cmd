@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-deck-session.ps1" schedule %*
exit /b %errorlevel%
