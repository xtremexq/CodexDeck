@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-deck-session.ps1" delay %*
exit /b %errorlevel%
